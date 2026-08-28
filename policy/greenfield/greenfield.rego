package main

resources(resource_type) := object.get(object.get(input, "resource", {}), resource_type, {})

deny_greenfield contains "Greenfield default security groups must not be managed" if {
	count(resources("aws_default_security_group")) > 0
}

deny_greenfield contains "Greenfield hosts must use the reviewed aws_instance shape" if {
	count(resources("aws_launch_template")) > 0
}

deny_greenfield contains "Greenfield hosts must use the reviewed aws_instance shape" if {
	count(resources("aws_launch_configuration")) > 0
}

deny_greenfield contains "Greenfield security groups must have zero ingress rules" if {
	some name
	some sg in resources("aws_security_group")[name]
	count(object.get(sg, "ingress", [])) > 0
}

deny_greenfield contains "Greenfield security groups must have zero inline egress rules" if {
	some name
	some sg in resources("aws_security_group")[name]
	count(object.get(sg, "egress", [])) > 0
}

deny_greenfield contains "Greenfield standalone ingress rules are forbidden" if {
	some name
	some rule in resources("aws_vpc_security_group_ingress_rule")[name]
}

deny_greenfield contains "Greenfield standalone ingress rules are forbidden" if {
	some name
	some rule in resources("aws_security_group_rule")[name]
	rule.type == "ingress"
}

deny_greenfield contains "Greenfield egress rules must be IPv4 TCP/443 only" if {
	some name
	some rule in resources("aws_vpc_security_group_egress_rule")[name]
	not valid_https_egress(rule)
}

deny_greenfield contains "Greenfield egress rules must be IPv4 TCP/443 only" if {
	some name
	some rule in resources("aws_security_group_rule")[name]
	rule.type == "egress"
	not valid_legacy_https_egress(rule)
}

valid_https_egress(rule) if {
	rule.ip_protocol == "tcp"
	rule.from_port == 443
	rule.to_port == 443
	rule.cidr_ipv4 == "0.0.0.0/0"
	object.get(rule, "cidr_ipv6", null) == null
	object.get(rule, "prefix_list_id", null) == null
	object.get(rule, "referenced_security_group_id", null) == null
}

valid_legacy_https_egress(rule) if {
	rule.protocol == "tcp"
	rule.from_port == 443
	rule.to_port == 443
	object.get(rule, "cidr_blocks", []) == ["0.0.0.0/0"]
	object.get(rule, "ipv6_cidr_blocks", []) == []
	object.get(rule, "prefix_list_ids", []) == []
	object.get(rule, "source_security_group_id", null) == null
	object.get(rule, "self", false) == false
}

deny_greenfield contains "Greenfield instances must not set key_name" if {
	some name
	some instance in resources("aws_instance")[name]
	object.get(instance, "key_name", null) != null
}

deny_greenfield contains "Greenfield instances must require IMDSv2 with hop limit 1" if {
	some name
	some instance in resources("aws_instance")[name]
	not valid_metadata_options(instance)
}

valid_metadata_options(instance) if {
	count(instance.metadata_options) == 1
	instance.metadata_options[0].http_tokens == "required"
	instance.metadata_options[0].http_put_response_hop_limit == 1
}

deny_greenfield contains "Greenfield root devices must be encrypted and deleted on termination" if {
	some name
	some instance in resources("aws_instance")[name]
	not valid_root_device(instance)
}

valid_root_device(instance) if {
	count(instance.root_block_device) == 1
	instance.root_block_device[0].encrypted == true
	instance.root_block_device[0].delete_on_termination == true
}

deny_greenfield contains "Greenfield EBS volumes must be encrypted" if {
	some name
	some volume in resources("aws_ebs_volume")[name]
	not volume.encrypted == true
}
