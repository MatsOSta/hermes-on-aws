package main

test_greenfield_secure_contract_is_allowed if {
	config := parse_config("hcl2", `
variable "deployment_id" {
  validation { condition = can(regex("^hms-[a-f0-9]{12}$", var.deployment_id)) }
}
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
resource "aws_instance" "host" {
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
`)

	count(deny_greenfield) == 0 with input as config
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
