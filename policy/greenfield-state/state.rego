package main

resources(resource_type) := object.get(object.get(input, "resource", {}), resource_type, {})

data_sources(data_type) := object.get(object.get(input, "data", {}), data_type, {})

required_resource_types := {
	"aws_s3_bucket",
	"aws_kms_key",
	"aws_kms_alias",
	"aws_s3_bucket_versioning",
	"aws_s3_bucket_ownership_controls",
	"aws_s3_bucket_public_access_block",
	"aws_s3_bucket_server_side_encryption_configuration",
	"aws_s3_bucket_policy",
}

required_data_types := {
	"aws_caller_identity",
	"aws_iam_policy_document",
}

deny_state contains "State foundation must contain exactly one of each required resource type" if {
	some resource_type in required_resource_types
	count(resources(resource_type)) != 1
}

deny_state contains "State foundation must not contain unexpected resource types" if {
	some resource_type
	object.get(input, "resource", {})[resource_type]
	not resource_type in required_resource_types
}

deny_state contains "State foundation must not contain unexpected data source types" if {
	some data_type
	object.get(input, "data", {})[data_type]
	not data_type in required_data_types
}

deny_state contains "State bucket must block every public access path" if {
	some name
	some block in resources("aws_s3_bucket_public_access_block")[name]
	not valid_public_access_block(block)
}

valid_public_access_block(block) if {
	block.block_public_acls == true
	block.block_public_policy == true
	block.ignore_public_acls == true
	block.restrict_public_buckets == true
}

deny_state contains "State bucket versioning must be enabled" if {
	some name
	some versioning in resources("aws_s3_bucket_versioning")[name]
	not valid_versioning(versioning)
}

valid_versioning(versioning) if {
	count(versioning.versioning_configuration) == 1
	versioning.versioning_configuration[0].status == "Enabled"
}

deny_state contains "State bucket must enforce bucket-owner ownership" if {
	some name
	some ownership in resources("aws_s3_bucket_ownership_controls")[name]
	not valid_ownership(ownership)
}

valid_ownership(ownership) if {
	count(ownership.rule) == 1
	ownership.rule[0].object_ownership == "BucketOwnerEnforced"
}

deny_state contains "State bucket must use its KMS key and bucket keys" if {
	some name
	some encryption in resources("aws_s3_bucket_server_side_encryption_configuration")[name]
	not valid_encryption(encryption)
}

valid_encryption(encryption) if {
	count(encryption.rule) == 1
	rule := encryption.rule[0]
	rule.bucket_key_enabled == true
	count(rule.apply_server_side_encryption_by_default) == 1
	defaults := rule.apply_server_side_encryption_by_default[0]
	defaults.sse_algorithm == "aws:kms"
	defaults.kms_master_key_id == "${aws_kms_key.state.arn}"
}

# Structural TLS policy validation via aws_iam_policy_document.
# Only fires when an aws_s3_bucket_policy resource is present (i.e. main.tf).
# The policy document must exist as exactly one data source named "tls_only",
# contain exactly one statement that is Deny/*-principal/s3:*/bucket+bucket-prefix/SecureTransport=false.

deny_state contains "State bucket TLS policy must be a structurally validated aws_iam_policy_document" if {
	# Only enforce when this root has a bucket policy (avoids false positives on partial files)
	count(resources("aws_s3_bucket_policy")) > 0
	not valid_tls_data_source
}

valid_tls_data_source if {
	docs := data_sources("aws_iam_policy_document")
	tls_entries := object.get(docs, "tls_only", [])
	count(tls_entries) == 1
	doc := tls_entries[0]
	stmt_list := doc.statement
	count(stmt_list) == 1
	stmt := stmt_list[0]
	stmt.effect == "Deny"
	count(stmt.principals) == 1
	principal := stmt.principals[0]
	principal.type == "*"
	principal.identifiers == ["*"]
	stmt.actions == ["s3:*"]
	count(stmt.resources) == 2
	"${aws_s3_bucket.state.arn}" in stmt.resources
	"${aws_s3_bucket.state.arn}/*" in stmt.resources
	count(stmt.condition) == 1
	cond := stmt.condition[0]
	cond.test == "Bool"
	cond.variable == "aws:SecureTransport"
	cond.values == ["false"]
}

deny_state contains "State bucket policy must reference only the approved TLS policy document" if {
	some name
	some pol in resources("aws_s3_bucket_policy")[name]
	pol.policy != "${data.aws_iam_policy_document.tls_only.json}"
}

deny_state contains "State KMS key must be symmetric, rotating, and delayed-deletion" if {
	some name
	some key in resources("aws_kms_key")[name]
	not valid_kms_key(key)
}

valid_kms_key(key) if {
	key.key_usage == "ENCRYPT_DECRYPT"
	key.customer_master_key_spec == "SYMMETRIC_DEFAULT"
	key.enable_key_rotation == true
	key.deletion_window_in_days > 0
}

deny_state contains "State bucket and KMS key must prevent destruction" if {
	some resource_type in {"aws_s3_bucket", "aws_kms_key"}
	some name
	some resource in resources(resource_type)[name]
	not destruction_protected(resource)
}

destruction_protected(resource) if {
	count(resource.lifecycle) == 1
	resource.lifecycle[0].prevent_destroy == true
}
