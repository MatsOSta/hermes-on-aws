resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  tags = {
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    actions = [
      "sts:AssumeRoleWithWebIdentity",
    ]

    principals {
      type = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.github_actions.arn,
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values = [
        "sts.amazonaws.com",
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:MatsOSta@112391018/platform-engineering-lab@1329830113:ref:refs/heads/master",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_identity" {
  name               = "platform-engineering-lab-github-identity"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json

  tags = {
    Project     = "platform-engineering-lab"
    Environment = "lab"
    ManagedBy   = "OpenTofu"
  }
}

data "aws_iam_policy_document" "github_actions_network_inventory_read" {
  statement {
    actions = [
      "ec2:DescribeInternetGateways",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values = [
        "eu-north-1",
      ]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_network_inventory_read" {
  name   = "platform-engineering-lab-github-network-inventory-read"
  role   = aws_iam_role.github_actions_identity.id
  policy = data.aws_iam_policy_document.github_actions_network_inventory_read.json
}

data "aws_iam_policy_document" "github_actions_tofu_plan_refresh_read" {
  statement {
    actions = [
      "iam:GetInstanceProfile",
    ]

    resources = [
      aws_iam_instance_profile.agent_host.arn,
    ]
  }

  statement {
    actions = [
      "iam:GetRolePolicy",
    ]

    resources = [
      aws_iam_role.github_actions_identity.arn,
    ]
  }

  statement {
    actions = [
      "iam:GetRole",
    ]

    resources = [
      aws_iam_role.agent_host.arn,
      aws_iam_role.github_actions_identity.arn,
    ]
  }

  statement {
    actions = [
      "iam:ListRolePolicies",
    ]

    resources = [
      aws_iam_role.agent_host.arn,
      aws_iam_role.github_actions_identity.arn,
    ]
  }

  statement {
    actions = [
      "iam:ListAttachedRolePolicies",
    ]

    resources = [
      aws_iam_role.agent_host.arn,
      aws_iam_role.github_actions_identity.arn,
    ]
  }

  statement {
    actions = [
      "iam:GetOpenIDConnectProvider",
    ]

    resources = [
      aws_iam_openid_connect_provider.github_actions.arn,
    ]
  }

  statement {
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstanceCreditSpecifications",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeTags",
      "ec2:DescribeVolumes",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values = [
        "eu-north-1",
      ]
    }
  }

  statement {
    actions = [
      "ec2:DescribeInstanceAttribute",
    ]

    resources = [
      aws_instance.agent_host.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values = [
        "eu-north-1",
      ]
    }
  }

  statement {
    actions = [
      "ec2:DescribeVpcAttribute",
    ]

    resources = [
      aws_vpc.platform_lab.arn,
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values = [
        "eu-north-1",
      ]
    }
  }
}

resource "aws_iam_role_policy" "github_actions_tofu_plan_refresh_read" {
  name   = "platform-engineering-lab-github-tofu-plan-refresh-read"
  role   = aws_iam_role.github_actions_identity.id
  policy = data.aws_iam_policy_document.github_actions_tofu_plan_refresh_read.json
}

data "aws_iam_policy_document" "github_actions_tofu_backend_access" {
  statement {
    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "arn:aws:s3:::platform-engineering-lab-tofu-state-450895596262-eu-north-1",
    ]
  }

  statement {
    actions = [
      "s3:GetObject",
    ]

    resources = [
      "arn:aws:s3:::platform-engineering-lab-tofu-state-450895596262-eu-north-1/aws/terraform.tfstate",
    ]
  }

  statement {
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]

    resources = [
      "arn:aws:s3:::platform-engineering-lab-tofu-state-450895596262-eu-north-1/aws/terraform.tfstate.tflock",
    ]
  }
}

resource "aws_iam_role_policy" "github_actions_tofu_backend_access" {
  name   = "platform-engineering-lab-github-tofu-backend-access"
  role   = aws_iam_role.github_actions_identity.id
  policy = data.aws_iam_policy_document.github_actions_tofu_backend_access.json
}
