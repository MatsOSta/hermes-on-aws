resource "aws_vpc" "deployment" {
  cidr_block           = "10.64.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name       = "${var.deployment_id}-vpc"
    Deployment = var.deployment_id
  }
}

# Public addressing is required for this single public-egress subnet; the host
# has no ingress path and outbound traffic is independently restricted.
#trivy:ignore:AWS-0164:exp:2027-02-28
resource "aws_subnet" "public_egress" {
  vpc_id                  = aws_vpc.deployment.id
  cidr_block              = "10.64.0.0/24"
  availability_zone       = "eu-north-1a"
  map_public_ip_on_launch = true

  tags = {
    Name       = "${var.deployment_id}-public-egress"
    Deployment = var.deployment_id
    Tier       = "public-egress"
  }
}

resource "aws_internet_gateway" "deployment" {
  vpc_id = aws_vpc.deployment.id

  tags = {
    Name       = "${var.deployment_id}-igw"
    Deployment = var.deployment_id
  }
}

resource "aws_route_table" "public_egress" {
  vpc_id = aws_vpc.deployment.id

  tags = {
    Name       = "${var.deployment_id}-public-egress"
    Deployment = var.deployment_id
  }
}

resource "aws_route" "default_ipv4" {
  route_table_id         = aws_route_table.public_egress.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.deployment.id
}

resource "aws_route_table_association" "public_egress" {
  subnet_id      = aws_subnet.public_egress.id
  route_table_id = aws_route_table.public_egress.id
}
