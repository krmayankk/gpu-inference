output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.region
}

output "weights_bucket" {
  description = "S3 weights cache (created by infra/bootstrap). up.sh publishes this to the cluster as the pool-context ConfigMap."
  value       = local.weights_bucket
}

output "gpu_instance_type" {
  value = local.gpu_instance_type
}

output "gpu_node_group" {
  description = "EKS node group name; up.sh resolves its ASG to arm the TTL switch."
  value       = module.eks.eks_managed_node_groups["gpu"].node_group_id
}

output "ttl_hours" {
  value = var.ttl_hours
}
