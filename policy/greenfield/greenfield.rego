package main

configuration_documents := [input] if {
	type_name(input) == "object"
}

configuration_documents := [document.contents |
	some document in input
	type_name(document) == "object"
	type_name(object.get(document, "contents", null)) == "object"
] if {
	type_name(input) == "array"
}

resources(resource_type) := object.union_n([object.get(object.get(document, "resource", {}), resource_type, {}) |
	some document in configuration_documents
])

data_sources(data_type) := object.union_n([object.get(object.get(document, "data", {}), data_type, {}) |
	some document in configuration_documents
])

reviewed_resource_types := {
	"aws_vpc",
	"aws_subnet",
	"aws_internet_gateway",
	"aws_route_table",
	"aws_route",
	"aws_route_table_association",
	"aws_security_group",
	"aws_vpc_security_group_egress_rule",
	"aws_iam_role",
	"aws_iam_instance_profile",
	"aws_iam_role_policy_attachment",
	"aws_instance",
	"aws_ebs_volume",
	"aws_volume_attachment",
}

reviewed_data_sources := {
	"aws_ssm_parameter":       "al2023_arm64",
	"aws_iam_policy_document": "host_assume_role",
}

resource_instance_count(resource_type) := count([resource |
	some document in configuration_documents
	some name
	some resource in object.get(object.get(document, "resource", {}), resource_type, {})[name]
])

data_source_instance_count(data_type) := count([source |
	some document in configuration_documents
	some name
	some source in object.get(object.get(document, "data", {}), data_type, {})[name]
])

deny_greenfield contains "Greenfield module blocks are forbidden" if {
	some document in configuration_documents
	count(object.get(document, "module", {})) > 0
}

deny_greenfield contains "Greenfield data sources must match the reviewed allowlist and cardinality" if {
	some document in configuration_documents
	some data_type in object.keys(object.get(document, "data", {}))
	not data_type in object.keys(reviewed_data_sources)
}

deny_greenfield contains "Greenfield data sources must match the reviewed allowlist and cardinality" if {
	some data_type, reviewed_name in reviewed_data_sources
	data_source_instance_count(data_type) != 1
}

deny_greenfield contains "Greenfield data sources must match the reviewed allowlist and cardinality" if {
	some data_type, reviewed_name in reviewed_data_sources
	some name in object.keys(data_sources(data_type))
	name != reviewed_name
}

deny_greenfield contains "Greenfield singleton data sources must not use count or for_each" if {
	some data_type in object.keys(reviewed_data_sources)
	some name
	some source in data_sources(data_type)[name]
	object.get(source, "count", null) != null
}

deny_greenfield contains "Greenfield singleton data sources must not use count or for_each" if {
	some data_type in object.keys(reviewed_data_sources)
	some name
	some source in data_sources(data_type)[name]
	object.get(source, "for_each", null) != null
}

deny_greenfield contains "Greenfield resource types must match the reviewed allowlist" if {
	some document in configuration_documents
	some resource_type in object.keys(object.get(document, "resource", {}))
	not resource_type in reviewed_resource_types
}

deny_greenfield contains "Greenfield must contain exactly one of each reviewed resource type" if {
	some resource_type in reviewed_resource_types
	resource_instance_count(resource_type) != 1
}

deny_greenfield contains "Greenfield singleton resources must not use count or for_each" if {
	some resource_type in reviewed_resource_types
	some name
	some resource in resources(resource_type)[name]
	object.get(resource, "count", null) != null
}

deny_greenfield contains "Greenfield singleton resources must not use count or for_each" if {
	some resource_type in reviewed_resource_types
	some name
	some resource in resources(resource_type)[name]
	object.get(resource, "for_each", null) != null
}

deny_greenfield contains "Greenfield IAM attachment must use the reviewed host role and SSM policy" if {
	some name
	some attachment in resources("aws_iam_role_policy_attachment")[name]
	not valid_ssm_attachment(attachment)
}

valid_ssm_attachment(attachment) if {
	attachment.role == "${aws_iam_role.host.name}"
	attachment.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

deny_greenfield contains "Greenfield host trust policy must be the reviewed EC2 assume-role document" if {
	not valid_host_assume_role_document
}

valid_host_assume_role_document if {
	docs := data_sources("aws_iam_policy_document")
	entries := object.get(docs, "host_assume_role", [])
	count(entries) == 1
	doc := entries[0]
	object.keys(doc) == {"statement"}
	count(doc.statement) == 1
	statement := doc.statement[0]
	object.keys(statement) == {"effect", "actions", "principals"}
	statement.effect == "Allow"
	statement.actions == ["sts:AssumeRole"]
	count(statement.principals) == 1
	principal := statement.principals[0]
	object.keys(principal) == {"type", "identifiers"}
	principal.type == "Service"
	principal.identifiers == ["ec2.amazonaws.com"]
}

deny_greenfield contains "Greenfield IAM role must reference only the reviewed trust policy document" if {
	some name
	some role in resources("aws_iam_role")[name]
	role.assume_role_policy != "${data.aws_iam_policy_document.host_assume_role.json}"
}

deny_greenfield contains "Greenfield host and instance profile must bind to the reviewed IAM role chain" if {
	some name
	some profile in resources("aws_iam_instance_profile")[name]
	profile.role != "${aws_iam_role.host.name}"
}

deny_greenfield contains "Greenfield host and instance profile must bind to the reviewed IAM role chain" if {
	some name
	some instance in resources("aws_instance")[name]
	instance.iam_instance_profile != "${aws_iam_instance_profile.host.name}"
}

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
