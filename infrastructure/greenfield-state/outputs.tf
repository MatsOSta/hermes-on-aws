output "state_bucket_name" {
  description = "Deployment-dedicated S3 bucket for backend configuration."
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "Deployment-dedicated KMS key ARN for backend configuration."
  value       = aws_kms_key.state.arn
}

output "aws_region" {
  description = "Reviewed backend region."
  value       = var.aws_region
}
