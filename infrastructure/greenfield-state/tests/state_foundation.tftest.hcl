mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

run "creates_one_hardened_state_foundation" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
    aws_region    = "eu-north-1"
  }

  assert {
    condition     = aws_s3_bucket.state.bucket == "123456789012-eu-north-1-hms-0123456789ab-tofu-state"
    error_message = "The sole bucket name must use only account, region, and deployment ID."
  }

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket versioning must be enabled."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "Bucket owner enforced ownership is required."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.state.block_public_acls && aws_s3_bucket_public_access_block.state.block_public_policy && aws_s3_bucket_public_access_block.state.ignore_public_acls && aws_s3_bucket_public_access_block.state.restrict_public_buckets
    error_message = "Every S3 public access path must be blocked."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms" && one(one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default).kms_master_key_id == aws_kms_key.state.arn && one(aws_s3_bucket_server_side_encryption_configuration.state.rule).bucket_key_enabled
    error_message = "Default encryption must use the dedicated KMS key with bucket keys."
  }

  assert {
    condition     = aws_kms_key.state.key_usage == "ENCRYPT_DECRYPT" && aws_kms_key.state.customer_master_key_spec == "SYMMETRIC_DEFAULT" && aws_kms_key.state.enable_key_rotation && aws_kms_key.state.deletion_window_in_days > 0
    error_message = "The KMS key must be symmetric, rotating, and have a deletion window."
  }

  assert {
    condition     = aws_kms_alias.state.name == "alias/123456789012-eu-north-1-hms-0123456789ab-tofu-state" && aws_kms_alias.state.target_key_id == aws_kms_key.state.key_id
    error_message = "The sole KMS alias must identify the dedicated state key."
  }

  # Verify the TLS deny policy is wired to the structured aws_iam_policy_document data source.
  assert {
    condition     = aws_s3_bucket_policy.tls_only.bucket == aws_s3_bucket.state.id
    error_message = "The bucket policy must target the state bucket."
  }

  # Structural TLS contract: one statement, Deny, wildcard principal, s3:*, SecureTransport=false.
  assert {
    condition     = length(data.aws_iam_policy_document.tls_only.statement) == 1
    error_message = "The TLS policy document must contain exactly one statement."
  }

  assert {
    condition     = data.aws_iam_policy_document.tls_only.statement[0].effect == "Deny"
    error_message = "The sole TLS statement must have Effect=Deny."
  }

  assert {
    condition     = data.aws_iam_policy_document.tls_only.statement[0].actions == toset(["s3:*"])
    error_message = "The sole TLS statement must restrict s3:* actions."
  }
}
