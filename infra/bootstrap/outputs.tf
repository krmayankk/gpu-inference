output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "lock_table" {
  value = aws_dynamodb_table.locks.name
}

output "weights_bucket" {
  value = aws_s3_bucket.weights.id
}

output "region" {
  description = "Where the backend + weights buckets live. Pools pin their backend config to THIS region regardless of where the cluster runs."
  value       = var.region
}
