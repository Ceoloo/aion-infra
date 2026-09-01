variable "project_id" {
  type        = string
  description = "GCP project ID owning the secrets."
}

variable "environment" {
  type        = string
  description = "Environment name (staging | production)."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to secret IDs."
}

variable "database_url" {
  type        = string
  description = "Runtime connection string (aion_app role). Injected; never committed."
  sensitive   = true
}

variable "migration_database_url" {
  type        = string
  description = "Migration connection string (aion_migrator role). Injected; never committed."
  sensitive   = true
}

variable "runtime_service_account_email" {
  type        = string
  description = "Service account allowed to read DATABASE_URL."
}

variable "migration_service_account_email" {
  type        = string
  description = "Service account allowed to read MIGRATION_DATABASE_URL."
}
