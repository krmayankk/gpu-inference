# Pool: aws — EKS with a system node group and ONE GPU node group.
#
# This is the ONLY provider-specific code in the platform (ADR-0002). The pool
# is the *provider*; the hardware is a *profile* (var.gpu_profile): t4 and l4
# are rows in a map, not separate pools. Moving t4 -> l4 -> (future p5/H100)
# changes one variable here and one kustomization in platform/serving/gpus/.
#
# Architecture notes, in the order they bit:
#   - GPU nodes are tainted, so a system node group is REQUIRED: CoreDNS, the
#     GPU operator control pods, chat, and Prometheus need somewhere untainted.
#   - AL2023_x86_64_NVIDIA is the current EKS GPU AMI (driver + toolkit baked
#     in); AL2 GPU AMIs are deprecated. The GPU operator is therefore installed
#     with driver/toolkit disabled — it provides the device plugin, GFD labels,
#     and DCGM only.
#   - An S3 *gateway* endpoint makes weight pulls from the cache bucket bypass
#     the NAT gateway: free and fast instead of $0.045/GB through NAT.
#   - The TTL schedule (bottom) zeroes the GPU ASG N hours after apply — the
#     platform's dead-man's switch (ADR-0006).

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # The hardware profile map. Adding a GPU = adding a row (+ its kustomization
  # in platform/serving/gpus/<key>/). Nothing else changes. node_count is the
  # capacity that backs the profile's parallelism (ADR-0002: parallelism
  # travels with its hardware) — l4x4's PP=4 is 4 nodes × 1 GPU, sized to fit
  # the 32-vCPU G-quota (4× g6.2xlarge = 32; a single g6.12xlarge would need 48).
  gpu_profiles = {
    t4   = { instance_type = "g4dn.2xlarge", node_count = 1 } # 1x T4  16GB, Turing — no hw FP8
    l4   = { instance_type = "g6.2xlarge", node_count = 1 }   # 1x L4  24GB, Ada    — hw FP8
    l4x4 = { instance_type = "g6.2xlarge", node_count = 4 }   # 4x L4 across 4 nodes — PP=4 (Phase 2)
  }
  gpu_instance_type = local.gpu_profiles[var.gpu_profile].instance_type
  gpu_node_count    = coalesce(var.gpu_desired_size, local.gpu_profiles[var.gpu_profile].node_count)

  # Weights cache bucket: created by infra/bootstrap (persistent, ADR-0005);
  # referenced here by its deterministic name.
  weights_bucket = "gpu-inference-weights-${data.aws_caller_identity.current.account_id}"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.cluster_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = local.azs
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # one NAT keeps cost down; teardown removes it

  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
}

# S3 gateway endpoint: model weights from the cache bucket never touch the NAT.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  cluster_endpoint_public_access = true

  # Single-operator, ephemeral cluster: the identity that runs terraform IS the
  # administrator (module default is false — correct for org clusters with
  # explicit access_entries; wrong for this one, and the omission cost a
  # debugging round: kubectl gets 401 with no access entry at all).
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Provider default_tags cover everything TERRAFORM creates, but instances the
  # ASG launches later (and their EBS roots/ENIs) are tagged from the launch
  # template's tag_specifications — which default_tags cannot reach. Passing
  # tags here makes the module propagate them there, so even dynamically
  # launched capacity is visible to the orphan sweep. No untaggable dark matter.
  tags = {
    Project   = "gpu-inference"
    Ephemeral = "true"
    ManagedBy = "terraform"
    Pool      = "aws"
  }

  eks_managed_node_groups = {
    # Untainted landing zone for everything that is not the model server:
    # CoreDNS, GPU-operator controllers, chat, Prometheus/Grafana.
    system = {
      instance_types = ["t3.medium"]
      desired_size   = 2
      min_size       = 1
      max_size       = 3
    }

    gpu = {
      instance_types = [local.gpu_instance_type]
      ami_type       = "AL2023_x86_64_NVIDIA" # driver + container toolkit in the AMI
      desired_size   = local.gpu_node_count
      min_size       = 0 # scale-to-zero ready; TTL schedule uses this
      # max must never be below desired or the apply fails — follow the profile.
      max_size       = max(4, local.gpu_node_count)
      # The default 20GiB root cannot hold the vLLM image (~10GB unpacked)
      # plus an HF weights cache — kubelet evicts the pod mid-image-pull
      # (observed live: 'no space left on device', DiskPressure taint).
      # NOTE: the module's `disk_size` shorthand is SILENTLY IGNORED when it
      # creates a custom launch template (its default) — block_device_mappings
      # is the only path that actually sizes the volume. 100GiB gp3 ≈ $0.01/hr.
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            delete_on_termination = true
          }
        }
      }

      labels = {
        # GFD sets this too once the operator runs; setting it at the node
        # group means scheduling works even before/without the operator.
        "nvidia.com/gpu.present" = "true"
      }
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "present"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }
}

# GPU nodes read (and, for cache warming, write) the weights bucket using the
# node role. Deliberate Phase-1 trade-off: this is a single-tenant, ephemeral
# cluster — node-role scoping to ONE bucket is acceptable; IRSA/Pod Identity is
# the Phase-3 hardening step and is noted in docs/phases.md.
resource "aws_iam_role_policy" "gpu_weights_cache" {
  name = "weights-cache-rw"
  role = module.eks.eks_managed_node_groups["gpu"].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${local.weights_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${local.weights_bucket}/*"
      }
    ]
  })
}

# --- TTL: the dead-man's switch (ADR-0006) ---------------------------------
# Implemented in up.sh (aws autoscaling put-scheduled-update-group-action),
# NOT as a Terraform resource, for two deliberate reasons:
#   1. A TF resource keyed on timestamp() produces a perpetual plan diff, and
#      one keyed on the node group's ASG name cannot be evaluated when the ASG
#      attribute is empty (e.g. a node group imported after a launch failure).
#   2. The switch should re-arm on every *platform up*, not every *apply* —
#      it is a lifecycle property, and up.sh owns the lifecycle.
# var.ttl_hours feeds up.sh through the ttl_hours output below.
