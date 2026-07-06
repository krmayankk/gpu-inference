# Remote-state backend for the cloud pools. Uses LOCAL state itself (the bucket
# that backs remote state cannot live in the state it backs). Tiny, persistent,
# shared — the one deliberate exception to full ephemerality (ADR-0005/0006).

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "gpu-inference"
      Ephemeral = "false" # deliberately persistent; see file header
      ManagedBy = "terraform"
      Component = "tf-state-backend"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket = "gpu-inference-tfstate-${data.aws_caller_identity.current.account_id}"
  table  = "gpu-inference-tf-locks"
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "locks" {
  name         = local.table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
}

# --- Model weights cache (ADR-0005) ----------------------------------------
# The second sanctioned persistent resource: weights survive cluster teardown
# so spin-up never re-downloads what it already paid to fetch. GPU pools reach
# it through an S3 gateway endpoint (free, fast, bypasses NAT) and populate it
# via `make cache-weights` after first boot.
resource "aws_s3_bucket" "weights" {
  bucket = "gpu-inference-weights-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "weights" {
  bucket                  = aws_s3_bucket.weights.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Weights are re-fetchable from HF by definition — cap storage cost by
# expiring anything untouched for 60 days instead of hoarding dead models.
resource "aws_s3_bucket_lifecycle_configuration" "weights" {
  bucket = aws_s3_bucket.weights.id
  rule {
    id     = "expire-stale-models"
    status = "Enabled"
    filter {}
    expiration {
      days = 60
    }
  }
}
