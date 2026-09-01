variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "environment" {
  type        = string
  description = "Environment name (staging | production)."
}

variable "runtime_service_name" {
  type        = string
  description = "Cloud Run runtime service name to monitor."
}

variable "database_instance_name" {
  type        = string
  description = "Cloud SQL instance name to monitor."
}

variable "notification_email" {
  type        = string
  description = "Ops email for alerts. Empty string disables alert wiring (still validates/plans)."
  default     = ""
}

variable "log_retention_days" {
  type        = number
  description = "Retention for the _Default log bucket."
  default     = 30
}

variable "log_bucket_location" {
  type        = string
  description = "Location of the _Default log bucket (usually 'global')."
  default     = "global"
}
