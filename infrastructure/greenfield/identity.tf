data "aws_iam_policy_document" "host_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "host" {
  name               = "${var.deployment_id}-host"
  assume_role_policy = data.aws_iam_policy_document.host_assume_role.json

  tags = {
    Deployment = var.deployment_id
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "host" {
  name = "${var.deployment_id}-host"
  role = aws_iam_role.host.name

  tags = {
    Deployment = var.deployment_id
  }
}
