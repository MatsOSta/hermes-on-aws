# Public HTTPS egress is temporarily required for SSM/bootstrap and must be revisited when Hermes sandbox egress isolation is implemented.
#trivy:ignore:AWS-0104:exp:2026-10-01
resource "aws_security_group" "agent_host" {
  name        = "platform-engineering-lab-agent-host"
  description = "Outbound HTTPS access for the Hermes agent host"
  vpc_id      = aws_vpc.platform_lab.id

  egress {
    description = "HTTPS to AWS Systems Manager and package repositories"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "platform-engineering-lab-agent-host"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

data "aws_iam_policy_document" "agent_host_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent_host" {
  name               = "platform-engineering-lab-agent-host"
  assume_role_policy = data.aws_iam_policy_document.agent_host_trust.json

  tags = {
    Name        = "platform-engineering-lab-agent-host"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_iam_role_policy_attachment" "agent_host_ssm" {
  role       = aws_iam_role.agent_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "agent_host" {
  name = "platform-engineering-lab-agent-host"
  role = aws_iam_role.agent_host.name

  tags = {
    Name        = "platform-engineering-lab-agent-host"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

resource "aws_instance" "agent_host" {
  # Resolved from /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.18-arm64.
  ami                         = "ami-0b50f26215e9a0e77"
  instance_type               = "t4g.medium"
  subnet_id                   = aws_subnet.edge_a.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.agent_host.id]
  iam_instance_profile        = aws_iam_instance_profile.agent_host.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard"
  }

  tags = {
    Name        = "platform-engineering-lab-agent-host"
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
    Workload    = "Hermes"
  }
}
