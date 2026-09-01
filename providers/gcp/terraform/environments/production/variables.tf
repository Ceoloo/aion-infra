variable "project_id" {
  type        = string
  description = "GCP project ID for PRODUCTION (separate from staging)."
}

variable "region" {
  type        = string
  description = "GCP region."
  default     = "us-central1"
}

variable "database_tier" {
  type        = string
  description = "Cloud SQL tier for production (smallest production-sensible default)."
  default     = "db-custom-2-7680" # 2 vCPU / 7.5 GB
}

variable "app_password" {
  type        = string
  description = "Password for the aion_app role."
  sensitive   = true
}

variable "migrator_password" {
  type        = string
  description = "Password for the aion_migrator role."
  sensitive   = true
}

variable "image" {
  type        = string
  description = "Runtime image (…/aion-runtime:<sha>). Placeholder for plan; set by pipeline."
  default     = "ghcr.io/ceoloo/aion-runtime:latest"
}

variable "service_version" {
  type    = string
  default = "0.1.0"
}

variable "git_sha" {
  type    = string
  default = "unknown"
}

variable "build_time" {
  type    = string
  default = "unknown"
}

variable "notification_email" {
  type        = string
  description = "Ops alert email. Empty disables alert wiring."
  default     = ""
}

variable "invoker_members" {
  type        = list(string)
  description = "Authenticated IAM members allowed to invoke the runtime."
  default     = []
}
