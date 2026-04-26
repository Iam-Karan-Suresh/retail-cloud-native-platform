# =============================================================================
# TERRAFORM REMOTE STATE INFRASTRUCTURE
# =============================================================================
# This file creates the S3 bucket for state storage and DynamoDB for locking.
# After applying this, you can configure the 'backend' block in versions.tf.
# =============================================================================

# 1. S3 Bucket for State Storage
# =============================================================================
resource "aws_s3_bucket" "terraform_state" {
  bucket = "retail-app-tf-state-${local.account_id}-${random_string.suffix.result}"

  # Prevent accidental deletion of the state bucket
  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "Terraform State Storage"
  })
}

# Enable versioning for state recovery (Required for Terraform backends)
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Enable server-side encryption by default (Security best practice)
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block all public access to the state bucket (Strict security)
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.terraform_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 2. DynamoDB Table for State Locking
# =============================================================================
# Terraform uses DynamoDB to handle state locking to prevent multiple users
# from running terraform apply simultaneously and corrupting the state.
# =============================================================================
resource "aws_dynamodb_table" "terraform_locks" {
  name         = "retail-app-tf-locks-${random_string.suffix.result}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = merge(local.common_tags, {
    Name = "Terraform State Locking Table"
  })
}

# =============================================================================
# HOW TO USE THIS BACKEND (After running terraform apply)
# =============================================================================
# Once these resources are created, add the following to your versions.tf:
#
# terraform {
#   backend "s3" {
#     bucket         = "retail-app-tf-state-<ACCOUNT_ID>-<SUFFIX>"
#     key            = "state/terraform.tfstate"
#     region         = "us-east-1"
#     dynamodb_table = "retail-app-tf-locks-<SUFFIX>"
#     encrypt        = true
#   }
# }
# =============================================================================
