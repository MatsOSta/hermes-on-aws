resource "aws_security_group" "host" {
  name        = "${var.deployment_id}-host"
  description = "No ingress; HTTPS-only IPv4 egress"
  vpc_id      = aws_vpc.deployment.id

  ingress = []
  egress  = []

  tags = {
    Name       = "${var.deployment_id}-host"
    Deployment = var.deployment_id
  }
}

# Public HTTPS is the only allowed path for SSM and package access.
#trivy:ignore:AWS-0104:exp:2027-02-28
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.host.id
  description       = "HTTPS egress"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}
