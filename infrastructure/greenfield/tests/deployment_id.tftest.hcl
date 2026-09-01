mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ec2.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
    }
  }
}

run "accepts_opaque_deployment_id" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
  }
}

run "rejects_personally_identifying_deployment_id" {
  command = plan

  variables {
    deployment_id = "hms-alice-email"
  }

  expect_failures = [var.deployment_id]
}

run "rejects_uppercase_deployment_id" {
  command = plan

  variables {
    deployment_id = "hms-0123456789AB"
  }

  expect_failures = [var.deployment_id]
}

run "rejects_wrong_length_deployment_id" {
  command = plan

  variables {
    deployment_id = "hms-0123456789a"
  }

  expect_failures = [var.deployment_id]
}
