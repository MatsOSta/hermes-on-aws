mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }
}

run "permits_reviewed_egress_and_no_ingress" {
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
    error_message = "The HTTPS egress rule must allow only IPv4 TCP/443."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region1.ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region1.from_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region1.to_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region1.cidr_ipv4 == "198.41.192.0/24"
    error_message = "Cloudflare region 1 TCP egress must be bounded to port 7844 and the reviewed IPv4 range."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region2.ip_protocol == "tcp" && aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region2.from_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region2.to_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_tcp_region2.cidr_ipv4 == "198.41.200.0/24"
    error_message = "Cloudflare region 2 TCP egress must be bounded to port 7844 and the reviewed IPv4 range."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region1.ip_protocol == "udp" && aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region1.from_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region1.to_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region1.cidr_ipv4 == "198.41.192.0/24"
    error_message = "Cloudflare region 1 UDP egress must be bounded to port 7844 and the reviewed IPv4 range."
  }

  assert {
    condition     = aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region2.ip_protocol == "udp" && aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region2.from_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region2.to_port == 7844 && aws_vpc_security_group_egress_rule.cloudflare_tunnel_udp_region2.cidr_ipv4 == "198.41.200.0/24"
    error_message = "Cloudflare region 2 UDP egress must be bounded to port 7844 and the reviewed IPv4 range."
  }
}
