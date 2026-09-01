mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }
}

run "creates_one_isolated_public_egress_network" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
  }

  assert {
    condition     = aws_vpc.deployment.cidr_block == "10.64.0.0/16"
    error_message = "Exactly one dedicated VPC is required."
  }

  assert {
    condition     = aws_subnet.public_egress.cidr_block == "10.64.0.0/24" && aws_subnet.public_egress.map_public_ip_on_launch
    error_message = "Exactly one public-egress subnet is required."
  }

  assert {
    condition     = aws_subnet.public_egress.availability_zone == "eu-north-1a"
    error_message = "The subnet must colocate the host and data volume in eu-north-1a."
  }

  assert {
    condition     = aws_internet_gateway.deployment.tags.Deployment == var.deployment_id && aws_route_table.public_egress.tags.Deployment == var.deployment_id
    error_message = "Exactly one internet gateway and public route table are required."
  }

  assert {
    condition     = aws_route.default_ipv4.destination_cidr_block == "0.0.0.0/0"
    error_message = "The public-egress route table must have one IPv4 default route."
  }

  assert {
    condition     = aws_route_table_association.public_egress.subnet_id == aws_subnet.public_egress.id
    error_message = "The subnet must have exactly one route-table association."
  }
}
