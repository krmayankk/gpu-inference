variable "region" {
  description = <<-EOT
    AWS region. us-east-1: where the G/VT quota increase actually landed
    (verified via service-quotas API 2026-07: 32 vCPUs, CASE_CLOSED; us-west-2
    is 0 with a request PENDING). The quota is the region anchor — deploying
    where quota isn't is how the first apply failed. Verify before moving:
      aws service-quotas get-service-quota --service-code ec2 \
        --quota-code L-DB2E81BA --region <region>
  EOT
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "gpu-inference"
}

variable "kubernetes_version" {
  description = <<-EOT
    Keep inside EKS *standard* support — extended support bills ~6x for the
    control plane. If apply rejects this version it fails fast and cheap;
    bump here and re-apply.
  EOT
  type        = string
  default     = "1.34"
}

variable "gpu_profile" {
  description = "Hardware profile (the GPU= knob). Pool = provider; this = hardware. Must match a key in local.gpu_profiles and a platform/serving/gpus/<profile>/ kustomization."
  type        = string
  default     = "l4"

  validation {
    condition     = contains(["t4", "l4"], var.gpu_profile)
    error_message = "gpu_profile must be one of: t4, l4 (add the profile to local.gpu_profiles and platform/serving/gpus/ first)."
  }
}

variable "gpu_desired_size" {
  description = "GPU node count. 1 for Phase 1; Karpenter owns this in Phase 4."
  type        = number
  default     = 1
}

variable "ttl_hours" {
  description = <<-EOT
    Dead-man's switch (ADR-0006): the GPU node group is scheduled to zero this
    many hours after the last `terraform apply`, so a forgotten cluster stops
    burning GPU money even if `make down` never runs. Each apply extends it.
  EOT
  type        = number
  default     = 6
}
