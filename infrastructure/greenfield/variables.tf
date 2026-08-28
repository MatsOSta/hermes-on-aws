variable "deployment_id" {
  description = "Opaque deployment identifier."
  type        = string

  validation {
    condition     = can(regex("^hms-[a-f0-9]{12}$", var.deployment_id))
    error_message = "deployment_id must match hms-[a-f0-9]{12}."
  }
}
