package main

deny contains message if {
	some subnet_name
	some subnet in input.resource.aws_subnet[subnet_name]
	subnet.tags.Tier == "workload"
	not subnet.map_public_ip_on_launch == false

	message := sprintf(
		"Workload subnet %q violates the platform architecture: map_public_ip_on_launch must be false",
		[subnet_name],
	)
}
