package main

secure_greenfield_hcl := `
resource "aws_vpc" "deployment" {}
resource "aws_subnet" "public_egress" {}
resource "aws_internet_gateway" "deployment" {}
resource "aws_route_table" "public_egress" {}
resource "aws_route" "default_ipv4" {}
resource "aws_route_table_association" "public_egress" {}
resource "aws_security_group" "host" {
  ingress = []
  egress = []
}
resource "aws_vpc_security_group_egress_rule" "https" {
  ip_protocol = "tcp"
  from_port = 443
  to_port = 443
  cidr_ipv4 = "0.0.0.0/0"
}
data "aws_ssm_parameter" "al2023_arm64" {}
data "aws_iam_policy_document" "host_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "host" {
  assume_role_policy = data.aws_iam_policy_document.host_assume_role.json
}
resource "aws_iam_instance_profile" "host" {
  role = aws_iam_role.host.name
}
resource "aws_iam_role_policy_attachment" "ssm" {
  role = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
resource "aws_instance" "host" {
  iam_instance_profile = aws_iam_instance_profile.host.name
  metadata_options {
    http_tokens = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted = true
    delete_on_termination = true
  }
}
resource "aws_ebs_volume" "data" {
  encrypted = true
}
resource "aws_volume_attachment" "data" {}
`

test_greenfield_secure_contract_is_allowed if {
	config := parse_config("hcl2", secure_greenfield_hcl)

	count(deny_greenfield) == 0 with input as config
}

test_greenfield_preexisting_admin_instance_profile_is_denied if {
	mutated := replace(secure_greenfield_hcl, "iam_instance_profile = aws_iam_instance_profile.host.name", `iam_instance_profile = "preexisting-admin"`)
	config := parse_config("hcl2", mutated)

	"Greenfield host and instance profile must bind to the reviewed IAM role chain" in deny_greenfield with input as config
}

test_greenfield_instance_profile_to_unreviewed_role_is_denied if {
	mutated := replace(secure_greenfield_hcl, "role = aws_iam_role.host.name", `role = "preexisting-admin-role"`)
	config := parse_config("hcl2", mutated)

	"Greenfield host and instance profile must bind to the reviewed IAM role chain" in deny_greenfield with input as config
}

test_greenfield_wildcard_trust_principal_is_denied if {
	mutated := replace(secure_greenfield_hcl, `type        = "Service"
      identifiers = ["ec2.amazonaws.com"]`, `type        = "*"
      identifiers = ["*"]`)
	config := parse_config("hcl2", mutated)

	"Greenfield host trust policy must be the reviewed EC2 assume-role document" in deny_greenfield with input as config
}

test_greenfield_role_raw_trust_policy_is_denied if {
	mutated := replace(secure_greenfield_hcl, "assume_role_policy = data.aws_iam_policy_document.host_assume_role.json", `assume_role_policy = jsonencode({ Statement = [] })`)
	config := parse_config("hcl2", mutated)

	"Greenfield IAM role must reference only the reviewed trust policy document" in deny_greenfield with input as config
}

test_greenfield_module_block_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
module "hidden" {
  source = "./hidden"
}`, [secure_greenfield_hcl]))

	"Greenfield module blocks are forbidden" in deny_greenfield with input as config
}

test_greenfield_unexpected_external_data_source_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
data "external" "hidden" {
  program = ["true"]
}`, [secure_greenfield_hcl]))

	"Greenfield data sources must match the reviewed allowlist and cardinality" in deny_greenfield with input as config
}

test_greenfield_extra_reviewed_data_source_name_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
data "aws_ssm_parameter" "extra" {}`, [secure_greenfield_hcl]))

	"Greenfield data sources must match the reviewed allowlist and cardinality" in deny_greenfield with input as config
}

test_greenfield_singleton_data_source_count_is_denied if {
	mutated := replace(secure_greenfield_hcl, `data "aws_ssm_parameter" "al2023_arm64" {}`, `data "aws_ssm_parameter" "al2023_arm64" {
  count = 1
}`)
	config := parse_config("hcl2", mutated)

	"Greenfield singleton data sources must not use count or for_each" in deny_greenfield with input as config
}

test_greenfield_secure_combined_documents_are_allowed if {
	config := parse_config("hcl2", secure_greenfield_hcl)
	combined := [{"path": "secure.tf", "contents": config}]

	count(deny_greenfield) == 0 with input as combined
}

test_greenfield_malicious_combined_document_is_denied if {
	config := parse_config("hcl2", secure_greenfield_hcl)
	malicious := parse_config("hcl2", `module "hidden" { source = "./hidden" }`)
	combined := [
		{"path": "secure.tf", "contents": config},
		{"path": "malicious.tf", "contents": malicious},
	]

	"Greenfield module blocks are forbidden" in deny_greenfield with input as combined
}

test_greenfield_administrator_attachment_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
resource "aws_iam_role_policy_attachment" "admin" {
  role = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}`, [secure_greenfield_hcl]))

	"Greenfield must contain exactly one of each reviewed resource type" in deny_greenfield with input as config
	"Greenfield IAM attachment must use the reviewed host role and SSM policy" in deny_greenfield with input as config
}

test_greenfield_inline_role_policy_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
resource "aws_iam_role_policy" "inline" {
  role = aws_iam_role.host.id
  policy = "{}"
}`, [secure_greenfield_hcl]))

	"Greenfield resource types must match the reviewed allowlist" in deny_greenfield with input as config
}

test_greenfield_standalone_iam_policy_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
resource "aws_iam_policy" "extra" {
  policy = "{}"
}`, [secure_greenfield_hcl]))

	"Greenfield resource types must match the reviewed allowlist" in deny_greenfield with input as config
}

test_greenfield_unexpected_iam_resource_type_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
resource "aws_iam_user" "extra" {
  name = "extra"
}`, [secure_greenfield_hcl]))

	"Greenfield resource types must match the reviewed allowlist" in deny_greenfield with input as config
}

test_greenfield_second_conforming_instance_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
resource "aws_instance" "extra" {
  metadata_options {
    http_tokens = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted = true
    delete_on_termination = true
  }
}`, [secure_greenfield_hcl]))

	"Greenfield must contain exactly one of each reviewed resource type" in deny_greenfield with input as config
}

test_greenfield_duplicated_singleton_is_denied if {
	config := parse_config("hcl2", sprintf(`%s
resource "aws_vpc" "extra" {}`, [secure_greenfield_hcl]))

	"Greenfield must contain exactly one of each reviewed resource type" in deny_greenfield with input as config
}

test_greenfield_singleton_count_is_denied if {
	counted := replace(secure_greenfield_hcl, `resource "aws_route" "default_ipv4" {}`, `resource "aws_route" "default_ipv4" {
  count = 1
}`)
	config := parse_config("hcl2", counted)

	"Greenfield singleton resources must not use count or for_each" in deny_greenfield with input as config
}

test_greenfield_singleton_for_each_is_denied if {
	iterated := replace(secure_greenfield_hcl, `resource "aws_subnet" "public_egress" {}`, `resource "aws_subnet" "public_egress" {
  for_each = { only = true }
}`)
	config := parse_config("hcl2", iterated)

	"Greenfield singleton resources must not use count or for_each" in deny_greenfield with input as config
}

test_greenfield_attachment_to_unreviewed_role_is_denied if {
	unreviewed_role := replace(secure_greenfield_hcl, "role = aws_iam_role.host.name", "role = aws_iam_role.other.name")
	config := parse_config("hcl2", unreviewed_role)

	"Greenfield IAM attachment must use the reviewed host role and SSM policy" in deny_greenfield with input as config
}

test_greenfield_ingress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_security_group" "host" {
  ingress {
    protocol = "tcp"
    from_port = 22
    to_port = 22
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress = []
}
`)

	"Greenfield security groups must have zero ingress rules" in deny_greenfield with input as config
}

test_greenfield_non_https_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_vpc_security_group_egress_rule" "bad" {
  ip_protocol = "tcp"
  from_port = 80
  to_port = 80
  cidr_ipv4 = "0.0.0.0/0"
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_ssh_key_is_denied if {
	config := parse_config("hcl2", `
resource "aws_instance" "host" {
  key_name = "forbidden"
}
`)

	"Greenfield instances must not set key_name" in deny_greenfield with input as config
}

test_greenfield_inline_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_security_group" "host" {
  ingress = []
  egress {
    protocol = "tcp"
    from_port = 443
    to_port = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
}
`)

	"Greenfield security groups must have zero inline egress rules" in deny_greenfield with input as config
}

test_greenfield_missing_imdsv2_is_denied if {
	config := parse_config("hcl2", `
resource "aws_instance" "host" {
  root_block_device {
    encrypted = true
    delete_on_termination = true
  }
}
`)

	"Greenfield instances must require IMDSv2 with hop limit 1" in deny_greenfield with input as config
}

test_greenfield_insecure_root_device_is_denied if {
	config := parse_config("hcl2", `
resource "aws_instance" "host" {
  metadata_options {
    http_tokens = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    encrypted = false
    delete_on_termination = false
  }
}
`)

	"Greenfield root devices must be encrypted and deleted on termination" in deny_greenfield with input as config
}

test_greenfield_unencrypted_data_volume_is_denied if {
	config := parse_config("hcl2", `
resource "aws_ebs_volume" "data" {
  encrypted = false
}
`)

	"Greenfield EBS volumes must be encrypted" in deny_greenfield with input as config
}

test_greenfield_standalone_ingress_rule_is_denied if {
	config := parse_config("hcl2", `
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  ip_protocol = "tcp"
  from_port = 22
  to_port = 22
  cidr_ipv4 = "0.0.0.0/0"
}
`)

	"Greenfield standalone ingress rules are forbidden" in deny_greenfield with input as config
}

test_greenfield_legacy_ingress_rule_is_denied if {
	config := parse_config("hcl2", `
resource "aws_security_group_rule" "ssh" {
  type = "ingress"
  protocol = "tcp"
  from_port = 22
  to_port = 22
  cidr_blocks = ["0.0.0.0/0"]
}
`)

	"Greenfield standalone ingress rules are forbidden" in deny_greenfield with input as config
}

test_greenfield_legacy_non_https_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_security_group_rule" "http" {
  type = "egress"
  protocol = "tcp"
  from_port = 80
  to_port = 80
  cidr_blocks = ["0.0.0.0/0"]
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_null_ssh_key_is_allowed if {
	config := parse_config("hcl2", `
resource "aws_instance" "host" {
  key_name = null
}
`)

	not "Greenfield instances must not set key_name" in deny_greenfield with input as config
}

test_greenfield_default_security_group_is_denied if {
	config := parse_config("hcl2", `
resource "aws_default_security_group" "default" {
  ingress = []
  egress = []
}
`)

	"Greenfield default security groups must not be managed" in deny_greenfield with input as config
}

test_greenfield_launch_template_is_denied if {
	config := parse_config("hcl2", `
resource "aws_launch_template" "host" {
  name = "unsupported"
}
`)

	"Greenfield hosts must use the reviewed aws_instance shape" in deny_greenfield with input as config
}

test_greenfield_launch_configuration_is_denied if {
	config := parse_config("hcl2", `
resource "aws_launch_configuration" "host" {
  name = "unsupported"
}
`)

	"Greenfield hosts must use the reviewed aws_instance shape" in deny_greenfield with input as config
}

test_greenfield_ipv6_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_vpc_security_group_egress_rule" "ipv6" {
  ip_protocol = "tcp"
  from_port = 443
  to_port = 443
  cidr_ipv6 = "::/0"
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_prefix_list_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_vpc_security_group_egress_rule" "prefix" {
  ip_protocol = "tcp"
  from_port = 443
  to_port = 443
  prefix_list_id = "pl-0123456789abcdef0"
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_referenced_security_group_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_vpc_security_group_egress_rule" "peer" {
  ip_protocol = "tcp"
  from_port = 443
  to_port = 443
  referenced_security_group_id = "sg-0123456789abcdef0"
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_combined_ipv4_and_peer_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_vpc_security_group_egress_rule" "peer" {
  ip_protocol = "tcp"
  from_port = 443
  to_port = 443
  cidr_ipv4 = "0.0.0.0/0"
  referenced_security_group_id = "sg-0123456789abcdef0"
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_legacy_peer_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_security_group_rule" "peer" {
  type = "egress"
  protocol = "tcp"
  from_port = 443
  to_port = 443
  cidr_blocks = ["0.0.0.0/0"]
  source_security_group_id = "sg-0123456789abcdef0"
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}

test_greenfield_legacy_self_egress_is_denied if {
	config := parse_config("hcl2", `
resource "aws_security_group_rule" "self" {
  type = "egress"
  protocol = "tcp"
  from_port = 443
  to_port = 443
  cidr_blocks = ["0.0.0.0/0"]
  self = true
}
`)

	"Greenfield egress rules must be IPv4 TCP/443 only" in deny_greenfield with input as config
}
