mock_provider "aws" {
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-mockedarm64"
    }
  }

  mock_resource "aws_instance" {
    defaults = {
      key_name = null
    }
  }
}

run "creates_ssm_managed_arm64_host_and_encrypted_storage" {
  command = plan

  variables {
    deployment_id = "hms-0123456789ab"
  }

  assert {
    condition     = data.aws_ssm_parameter.al2023_arm64.name == "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
    error_message = "The AMI must come from the public AL2023 ARM64 SSM parameter."
  }

  assert {
    condition     = aws_instance.host.ami == data.aws_ssm_parameter.al2023_arm64.value && startswith(aws_instance.host.instance_type, "t4g.")
    error_message = "The sole host must use the SSM-selected ARM64 AL2023 AMI and an ARM instance type."
  }

  assert {
    condition     = aws_instance.host.metadata_options[0].http_tokens == "required" && aws_instance.host.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 must be required with hop limit 1."
  }

  assert {
    condition     = aws_instance.host.key_name == null
    error_message = "The host must not configure an SSH key."
  }

  assert {
    condition     = aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" && aws_instance.host.iam_instance_profile == aws_iam_instance_profile.host.name
    error_message = "Administration must use the dedicated profile with only the SSM core policy."
  }

  assert {
    condition     = aws_instance.host.root_block_device[0].encrypted && aws_instance.host.root_block_device[0].delete_on_termination
    error_message = "The encrypted root device must be deleted with the disposable host."
  }

  assert {
    condition     = aws_ebs_volume.data.encrypted && aws_ebs_volume.data.tags.Disposable == "true"
    error_message = "The dedicated data volume must be encrypted and explicitly disposable."
  }

  assert {
    condition     = !aws_volume_attachment.data.force_detach && !aws_volume_attachment.data.skip_destroy
    error_message = "Normal destroy must safely detach and delete the disposable data volume."
  }
}
