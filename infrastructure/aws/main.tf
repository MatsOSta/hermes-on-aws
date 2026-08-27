terraform {
  required_version = ">= 1.11, < 2.0"

  backend "s3" {
    bucket       = "platform-engineering-lab-tofu-state-450895596262-eu-north-1"
    key          = "aws/terraform.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1"
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "platform_lab" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  instance_tenancy     = "default"

  tags = {
    Name        = "platform-engineering-lab"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_subnet" "edge_a" {
  vpc_id                  = aws_vpc.platform_lab.id
  cidr_block              = "10.42.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name        = "platform-engineering-lab-edge-a"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Tier        = "edge"
  }
}

resource "aws_subnet" "edge_b" {
  vpc_id                  = aws_vpc.platform_lab.id
  cidr_block              = "10.42.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name        = "platform-engineering-lab-edge-b"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Tier        = "edge"
  }
}

resource "aws_subnet" "workload_a" {
  vpc_id                  = aws_vpc.platform_lab.id
  cidr_block              = "10.42.10.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name        = "platform-engineering-lab-workload-a"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Tier        = "workload"
  }
}

resource "aws_subnet" "workload_b" {
  vpc_id                  = aws_vpc.platform_lab.id
  cidr_block              = "10.42.11.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name        = "platform-engineering-lab-workload-b"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Tier        = "workload"
  }
}

resource "aws_route_table" "edge" {
  vpc_id = aws_vpc.platform_lab.id

  tags = {
    Name        = "platform-engineering-lab-edge"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Tier        = "edge"
  }
}

resource "aws_route_table" "workload" {
  vpc_id = aws_vpc.platform_lab.id

  tags = {
    Name        = "platform-engineering-lab-workload"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Tier        = "workload"
  }
}

resource "aws_internet_gateway" "platform_lab" {
  vpc_id = aws_vpc.platform_lab.id

  tags = {
    Name        = "platform-engineering-lab"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_route" "edge_default_ipv4" {
  route_table_id         = aws_route_table.edge.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.platform_lab.id
}

resource "aws_route_table_association" "edge_a" {
  subnet_id      = aws_subnet.edge_a.id
  route_table_id = aws_route_table.edge.id
}

resource "aws_route_table_association" "edge_b" {
  subnet_id      = aws_subnet.edge_b.id
  route_table_id = aws_route_table.edge.id
}

resource "aws_route_table_association" "workload_a" {
  subnet_id      = aws_subnet.workload_a.id
  route_table_id = aws_route_table.workload.id
}

resource "aws_route_table_association" "workload_b" {
  subnet_id      = aws_subnet.workload_b.id
  route_table_id = aws_route_table.workload.id
}

output "aws_account_id" {
  description = "AWS account ID for the authenticated caller."
  value       = data.aws_caller_identity.current.account_id
}
