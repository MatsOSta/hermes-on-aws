resource "aws_security_group" "host" {
  name        = "${var.deployment_id}-host"
  description = "No ingress; HTTPS-only IPv4 egress"
  vpc_id      = aws_vpc.deployment.id

  ingress = []

  tags = {
    Name       = "${var.deployment_id}-host"
    Deployment = var.deployment_id
  }
}

# Public HTTPS is the only allowed path for SSM and package access.
#trivy:ignore:AWS-0104:exp:2027-02-28
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "Outbound HTTPS only"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Cloudflare Tunnel uses QUIC (UDP) with HTTP/2 (TCP) fallback on port 7844.
# Keep this egress bounded to Cloudflare's documented global tunnel endpoint
# ranges; security groups are stateful, so no matching ingress rule is needed.
resource "aws_vpc_security_group_egress_rule" "cloudflare_tunnel_tcp_region1" {
  security_group_id = aws_security_group.host.id
  description       = "Cloudflare Tunnel HTTP2 region 1"
  ip_protocol       = "tcp"
  from_port         = 7844
  to_port           = 7844
  cidr_ipv4         = "198.41.192.0/24"
}

resource "aws_vpc_security_group_egress_rule" "cloudflare_tunnel_tcp_region2" {
  security_group_id = aws_security_group.host.id
  description       = "Cloudflare Tunnel HTTP2 region 2"
  ip_protocol       = "tcp"
  from_port         = 7844
  to_port           = 7844
  cidr_ipv4         = "198.41.200.0/24"
}

resource "aws_vpc_security_group_egress_rule" "cloudflare_tunnel_udp_region1" {
  security_group_id = aws_security_group.host.id
  description       = "Cloudflare Tunnel QUIC region 1"
  ip_protocol       = "udp"
  from_port         = 7844
  to_port           = 7844
  cidr_ipv4         = "198.41.192.0/24"
}

resource "aws_vpc_security_group_egress_rule" "cloudflare_tunnel_udp_region2" {
  security_group_id = aws_security_group.host.id
  description       = "Cloudflare Tunnel QUIC region 2"
  ip_protocol       = "udp"
  from_port         = 7844
  to_port           = 7844
  cidr_ipv4         = "198.41.200.0/24"
}
