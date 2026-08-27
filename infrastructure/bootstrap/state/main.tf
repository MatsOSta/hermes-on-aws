terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  profile = "platform-lab"
  region  = "eu-north-1"
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "platform-engineering-lab-tofu-state-${data.aws_caller_identity.current.account_id}-eu-north-1"
}

resource "aws_s3_bucket" "tofu_state" {
  bucket = local.state_bucket_name

  tags = {
    Name        = local.state_bucket_name
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tofu_state" {
  bucket = aws_s3_bucket.tofu_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 is deliberate for this low-cost lab; revisit customer-managed KMS if requirements justify it.
#trivy:ignore:AWS-0132:exp:2027-02-24
resource "aws_s3_bucket_server_side_encryption_configuration" "tofu_state" {
  bucket = aws_s3_bucket.tofu_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tofu_state" {
  bucket = aws_s3_bucket.tofu_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
