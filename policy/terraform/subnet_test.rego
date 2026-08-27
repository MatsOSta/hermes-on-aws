package main

test_compliant_workload_subnet_is_allowed if {
	config := parse_config("hcl2", `
		resource "aws_subnet" "workload_a" {
			map_public_ip_on_launch = false
			tags = {
				Tier = "workload"
			}
		}
	`)

	count(deny) == 0 with input as config
}

test_public_workload_subnet_is_denied if {
	config := parse_config("hcl2", `
		resource "aws_subnet" "workload_a" {
			map_public_ip_on_launch = true
			tags = {
				Tier = "workload"
			}
		}
	`)

	deny == {
		"Workload subnet \"workload_a\" violates the platform architecture: map_public_ip_on_launch must be false",
	} with input as config
}

test_workload_subnet_without_public_ip_setting_is_denied if {
	config := parse_config("hcl2", `
		resource "aws_subnet" "workload_a" {
			tags = {
				Tier = "workload"
			}
		}
	`)

	deny == {
		"Workload subnet \"workload_a\" violates the platform architecture: map_public_ip_on_launch must be false",
	} with input as config
}

test_edge_subnet_is_not_denied if {
	config := parse_config("hcl2", `
		resource "aws_subnet" "edge_a" {
			map_public_ip_on_launch = true
			tags = {
				Tier = "edge"
			}
		}
	`)

	count(deny) == 0 with input as config
}
