mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }
}

run "permits_only_https_egress_and_no_ingress" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
  }

  assert {
    condition     = length(aws_security_group.host.ingress) == 0
    error_message = "The host security group must have zero ingress rules."
  }

  assert {
    condition     = length(aws_security_group.host.egress) == 0
    error_message = "The host security group must have no unmanaged inline egress rules."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.https.ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.https.from_port == 443 && aws_vpc_security_group_egress_rule.https.to_port == 443 && aws_vpc_security_group_egress_rule.https.cidr_ipv4 == "0.0.0.0/0"
    error_message = "The sole egress rule must allow only IPv4 TCP/443."
  }
}
