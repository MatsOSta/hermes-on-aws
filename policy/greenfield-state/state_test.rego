package main

# Secure reference configuration using the structurally validated TLS data source.
secure_config := parse_config("hcl2", `
resource "aws_s3_bucket" "state" {
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_key" "state" {
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  deletion_window_in_days  = 30
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_alias" "state" {}
resource "aws_s3_bucket_versioning" "state" {
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_ownership_controls" "state" {
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_public_access_block" "state" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
  }
}
data "aws_caller_identity" "current" {}
data "aws_iam_policy_document" "tls_only" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      "${aws_s3_bucket.state.arn}",
      "${aws_s3_bucket.state.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}
resource "aws_s3_bucket_policy" "tls_only" {
  policy = data.aws_iam_policy_document.tls_only.json
}
`)

# Valid TLS data-source shape for overlay re-use
valid_tls_doc := [{"statement": [{
	"sid":    "DenyInsecureTransport",
	"effect": "Deny",
	"principals": [{"type": "*", "identifiers": ["*"]}],
	"actions": ["s3:*"],
	"resources": [
		"${aws_s3_bucket.state.arn}",
		"${aws_s3_bucket.state.arn}/*",
	],
	"condition": [{"test": "Bool", "variable": "aws:SecureTransport", "values": ["false"]}],
}]}]

test_secure_state_foundation_is_allowed if {
	count(deny_state) == 0 with input as secure_config
}

test_missing_required_resource_is_denied if {
	config := parse_config("hcl2", `
resource "aws_s3_bucket" "state" {
  lifecycle { prevent_destroy = true }
}
`)
	"State foundation must contain exactly one of each required resource type" in deny_state with input as config
}

test_public_access_is_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_s3_bucket_public_access_block": {"state": [{
		"block_public_acls":       false,
		"block_public_policy":     true,
		"ignore_public_acls":      true,
		"restrict_public_buckets": true,
	}]}}}])
	"State bucket must block every public access path" in deny_state with input as bad
}

test_missing_versioning_is_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_s3_bucket_versioning": {"state": [{
		"versioning_configuration": [{"status": "Suspended"}],
	}]}}}])
	"State bucket versioning must be enabled" in deny_state with input as bad
}

test_non_kms_encryption_is_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_s3_bucket_server_side_encryption_configuration": {"state": [{
		"rule": [{
			"bucket_key_enabled": true,
			"apply_server_side_encryption_by_default": [{
				"sse_algorithm":     "AES256",
				"kms_master_key_id": "${aws_kms_key.state.arn}",
			}],
		}],
	}]}}}])
	"State bucket must use its KMS key and bucket keys" in deny_state with input as bad
}

test_insecure_ownership_is_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_s3_bucket_ownership_controls": {"state": [{
		"rule": [{"object_ownership": "ObjectWriter"}],
	}]}}}])
	"State bucket must enforce bucket-owner ownership" in deny_state with input as bad
}

# TLS structural tests using data-block overlays (avoids parse_config on partial HCL)

test_tls_extra_statement_is_denied if {
	extra_stmt := {
		"sid":     "ExtraAllow",
		"effect":  "Allow",
		"principals": [{"type": "AWS", "identifiers": ["arn:aws:iam::999999999999:root"]}],
		"actions":   ["s3:GetObject"],
		"resources": ["${aws_s3_bucket.state.arn}/*"],
	}
	two_stmts := [{"statement": [valid_tls_doc[0].statement[0], extra_stmt]}]
	bad := object.union_n([secure_config, {"data": {"aws_iam_policy_document": {"tls_only": two_stmts}}}])
	"State bucket TLS policy must be a structurally validated aws_iam_policy_document" in deny_state with input as bad
}

test_tls_wrong_effect_is_denied if {
	allow_doc := [{"statement": [{
		"sid":     "WrongEffect",
		"effect":  "Allow",
		"principals": [{"type": "*", "identifiers": ["*"]}],
		"actions":   ["s3:*"],
		"resources": ["${aws_s3_bucket.state.arn}", "${aws_s3_bucket.state.arn}/*"],
		"condition": [{"test": "Bool", "variable": "aws:SecureTransport", "values": ["false"]}],
	}]}]
	bad := object.union_n([secure_config, {"data": {"aws_iam_policy_document": {"tls_only": allow_doc}}}])
	"State bucket TLS policy must be a structurally validated aws_iam_policy_document" in deny_state with input as bad
}

test_tls_wrong_principal_is_denied if {
	named_principal_doc := [{"statement": [{
		"sid":     "NamedPrincipal",
		"effect":  "Deny",
		"principals": [{"type": "AWS", "identifiers": ["arn:aws:iam::123456789012:root"]}],
		"actions":   ["s3:*"],
		"resources": ["${aws_s3_bucket.state.arn}", "${aws_s3_bucket.state.arn}/*"],
		"condition": [{"test": "Bool", "variable": "aws:SecureTransport", "values": ["false"]}],
	}]}]
	bad := object.union_n([secure_config, {"data": {"aws_iam_policy_document": {"tls_only": named_principal_doc}}}])
	"State bucket TLS policy must be a structurally validated aws_iam_policy_document" in deny_state with input as bad
}

test_tls_wrong_resources_is_denied if {
	wrong_resources_doc := [{"statement": [{
		"sid":     "WrongResources",
		"effect":  "Deny",
		"principals": [{"type": "*", "identifiers": ["*"]}],
		"actions":   ["s3:*"],
		"resources": ["arn:aws:s3:::wrong-bucket", "arn:aws:s3:::wrong-bucket/*"],
		"condition": [{"test": "Bool", "variable": "aws:SecureTransport", "values": ["false"]}],
	}]}]
	bad := object.union_n([secure_config, {"data": {"aws_iam_policy_document": {"tls_only": wrong_resources_doc}}}])
	"State bucket TLS policy must be a structurally validated aws_iam_policy_document" in deny_state with input as bad
}

test_tls_wrong_condition_variable_is_denied if {
	wrong_cond_doc := [{"statement": [{
		"sid":     "WrongCondition",
		"effect":  "Deny",
		"principals": [{"type": "*", "identifiers": ["*"]}],
		"actions":   ["s3:*"],
		"resources": ["${aws_s3_bucket.state.arn}", "${aws_s3_bucket.state.arn}/*"],
		"condition": [{"test": "Bool", "variable": "aws:MultiFactorAuthPresent", "values": ["false"]}],
	}]}]
	bad := object.union_n([secure_config, {"data": {"aws_iam_policy_document": {"tls_only": wrong_cond_doc}}}])
	"State bucket TLS policy must be a structurally validated aws_iam_policy_document" in deny_state with input as bad
}

test_missing_tls_data_source_is_denied if {
	# Config where the policy document exists but is named differently (not tls_only)
	bad := {
		"resource": secure_config.resource,
		"data": {
			"aws_caller_identity": {"current": [{}]},
			"aws_iam_policy_document": {"not_tls_only": valid_tls_doc},
		},
	}
	"State bucket TLS policy must be a structurally validated aws_iam_policy_document" in deny_state with input as bad
}

test_tls_policy_wrong_reference_is_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_s3_bucket_policy": {"tls_only": [{
		"policy": "{\"Statement\":[{\"Effect\":\"Deny\"}]}",
	}]}}}])
	"State bucket policy must reference only the approved TLS policy document" in deny_state with input as bad
}

test_unexpected_resource_type_is_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_iam_role": {"unexpected": [{}]}}}])
	"State foundation must not contain unexpected resource types" in deny_state with input as bad
}

test_unsafe_kms_settings_are_denied if {
	bad := object.union_n([secure_config, {"resource": {"aws_kms_key": {"state": [{
		"key_usage":                "SIGN_VERIFY",
		"customer_master_key_spec": "SYMMETRIC_DEFAULT",
		"enable_key_rotation":      true,
		"deletion_window_in_days":  30,
		"lifecycle":                [{"prevent_destroy": true}],
	}]}}}])
	"State KMS key must be symmetric, rotating, and delayed-deletion" in deny_state with input as bad
}

test_missing_destruction_protection_is_denied if {
	config := parse_config("hcl2", `
resource "aws_s3_bucket" "state" {}
resource "aws_kms_key" "state" {}
`)
	"State bucket and KMS key must prevent destruction" in deny_state with input as config
}
