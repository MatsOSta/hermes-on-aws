output "instance_id" {
  description = "Greenfield host identifier."
  value       = aws_instance.host.id
}

output "data_volume_id" {
  description = "Disposable data volume identifier."
  value       = aws_ebs_volume.data.id
}

output "vpc_id" {
  description = "Dedicated VPC identifier."
  value       = aws_vpc.deployment.id
}

output "subnet_id" {
  description = "Public-egress subnet identifier."
  value       = aws_subnet.public_egress.id
}
