variable "region" {
  type        = string
  description = "AWS region."
  default     = "us-east-1"
}

variable "environment" {
  type        = string
  description = "Environment name (staging | production)."
  default     = "staging"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names."
  default     = "aion-staging"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

# ── Database ────────────────────────────────────────────────────────────────
variable "db_instance_class" {
  type        = string
  description = "RDS instance class (smallest production-sensible)."
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "multi_az" {
  type        = bool
  description = "RDS Multi-AZ (true for production)."
  default     = false
}

variable "deletion_protection" {
  type        = bool
  description = "RDS deletion protection (true for production)."
  default     = false
}

variable "backup_retention_days" {
  type        = number
  description = "Automated backup retention (enables PITR when > 0)."
  default     = 7
}

# ── Credentials (injected; never committed) ─────────────────────────────────
variable "app_password" {
  type        = string
  description = "aion_app role password."
  sensitive   = true
}

variable "migrator_password" {
  type        = string
  description = "aion_migrator (master) role password."
  sensitive   = true
}

# ── Runtime ─────────────────────────────────────────────────────────────────
variable "image" {
  type        = string
  description = "Runtime image (…/aion-runtime:<sha>). Placeholder for plan."
  default     = "ghcr.io/ceoloo/aion-runtime:latest"
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "certificate_arn" {
  type        = string
  description = "ACM cert ARN for HTTPS on the ALB. Empty = HTTP-only (dev/plan)."
  default     = ""
}

variable "github_repository" {
  type        = string
  description = "owner/repo allowed to assume the CI deploy role via OIDC."
  default     = "Ceoloo/aion-infra"
}

variable "service_version" {
  type    = string
  default = "0.1.0"
}

variable "git_sha" {
  type    = string
  default = "unknown"
}
