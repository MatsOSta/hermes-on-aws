mock_provider "aws" {}

run "accepts_opaque_id_in_reviewed_region" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
    aws_region    = "eu-north-1"
  }
}

run "rejects_personally_identifying_id" {
  command = plan

  variables {
    deployment_id = "hms-alice-email"
    aws_region    = "eu-north-1"
  }

  expect_failures = [var.deployment_id]
}

run "rejects_other_region" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
    aws_region    = "us-east-1"
  }

  expect_failures = [var.aws_region]
}
