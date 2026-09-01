variable "project_id" {
  type        = string
  description = "GCP project ID owning the database."
}

variable "environment" {
  type        = string
  description = "Environment name (staging | production)."
}

variable "region" {
  type        = string
  description = "GCP region for the Cloud SQL instance."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to resource names."
}

variable "network_id" {
  type        = string
  description = "VPC network ID the private IP attaches to."
}

variable "private_vpc_connection" {
  type        = string
  description = "Service-networking connection ID (ordering dependency)."
}

variable "database_name" {
  type        = string
  description = "Application database name."
  default     = "aion_data"
}

# ── Sizing ──────────────────────────────────────────────────────────────────
variable "tier" {
  type        = string
  description = "Cloud SQL machine tier. Smallest production-sensible by default."
  default     = "db-custom-1-3840" # 1 vCPU / 3.75 GB
}

variable "availability_type" {
  type        = string
  description = "ZONAL (staging) or REGIONAL/HA (production)."
  default     = "ZONAL"
}

variable "disk_size_gb" {
  type        = number
  description = "Initial data disk size in GB (autoresize is enabled)."
  default     = 10
}

# ── Backups / recovery ──────────────────────────────────────────────────────
variable "point_in_time_recovery" {
  type        = bool
  description = "Enable PITR (WAL archiving). True for production."
  default     = true
}

variable "transaction_log_retention_days" {
  type        = number
  description = "Days of WAL retained for PITR (1–7 for Cloud SQL Postgres)."
  default     = 7
}

variable "retained_backups" {
  type        = number
  description = "Number of automated backups retained."
  default     = 7
}

variable "backup_start_time" {
  type        = string
  description = "Daily automated-backup start time (UTC, HH:MM)."
  default     = "03:00"
}

variable "backup_location" {
  type        = string
  description = "Backup storage location (region or multi-region). Null = provider default."
  default     = null
}

# ── Maintenance ─────────────────────────────────────────────────────────────
variable "maintenance_window_day" {
  type        = number
  description = "Maintenance day of week (1=Mon .. 7=Sun)."
  default     = 7
}

variable "maintenance_window_hour" {
  type        = number
  description = "Maintenance hour (0–23 UTC)."
  default     = 4
}

# ── Protection ──────────────────────────────────────────────────────────────
variable "deletion_protection" {
  type        = bool
  description = "Deletion protection (API + terraform destroy). True for production."
  default     = true
}

# ── Roles / credentials (never committed; injected from secret material) ─────
variable "app_user" {
  type        = string
  description = "Least-privileged application (DML) role name."
  default     = "aion_app"
}

variable "app_password" {
  type        = string
  description = "Application role password (sensitive; injected, never committed)."
  sensitive   = true
}

variable "migrator_user" {
  type        = string
  description = "Migration/admin (DDL) role name."
  default     = "aion_migrator"
}

variable "migrator_password" {
  type        = string
  description = "Migrator role password (sensitive; injected, never committed)."
  sensitive   = true
}
