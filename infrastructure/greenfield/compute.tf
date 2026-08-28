data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_instance" "host" {
  ami                         = data.aws_ssm_parameter.al2023_arm64.value
  instance_type               = "t4g.medium"
  availability_zone           = "eu-north-1a"
  subnet_id                   = aws_subnet.public_egress.id
  vpc_security_group_ids      = [aws_security_group.host.id]
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.host.name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted             = true
    volume_type           = "gp3"
    volume_size           = 16
    delete_on_termination = true

    tags = {
      Name       = "${var.deployment_id}-root"
      Deployment = var.deployment_id
      Disposable = "true"
    }
  }

  tags = {
    Name       = "${var.deployment_id}-host"
    Deployment = var.deployment_id
  }
}

resource "aws_ebs_volume" "data" {
  availability_zone = "eu-north-1a"
  encrypted         = true
  type              = "gp3"
  size              = 30

  tags = {
    Name       = "${var.deployment_id}-data"
    Deployment = var.deployment_id
    Disposable = "true"
  }
}

resource "aws_volume_attachment" "data" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.data.id
  instance_id  = aws_instance.host.id
  force_detach = false
  skip_destroy = false
}
