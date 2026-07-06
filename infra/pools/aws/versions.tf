terraform {
  required_version = ">= 1.6"

  # Remote state lives in the bootstrap-created bucket. Filled at init:
  #   terraform init -backend-config=bucket=<b> -backend-config=dynamodb_table=<t> ...
  # The pool's up.sh passes these from `terraform output` of infra/bootstrap.
  backend "s3" {
    key     = "pools/aws/terraform.tfstate"
    encrypt = true
  }

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
      Ephemeral = "true"
      ManagedBy = "terraform"
      Pool      = "aws"
    }
  }
}
