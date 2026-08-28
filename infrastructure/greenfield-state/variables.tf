variable "deployment_id" {
  description = "Opaque deployment identifier."
  type        = string

  validation {
    condition     = can(regex("^hms-[a-f0-9]{12}$", var.deployment_id))
    error_message = "deployment_id must match hms-[a-f0-9]{12}."
  }
}

variable "aws_region" {
  description = "AWS region for the deployment-dedicated state foundation."
  type        = string
  default     = "eu-north-1"

  validation {
    condition     = var.aws_region == "eu-north-1"
    error_message = "aws_region must be eu-north-1."
  }
}
