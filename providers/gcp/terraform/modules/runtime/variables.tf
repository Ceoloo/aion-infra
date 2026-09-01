variable "project_id" {
  type        = string
  description = "GCP project ID owning the runtime."
}

variable "environment" {
  type        = string
  description = "Environment name (staging | production)."
}

variable "region" {
  type        = string
  description = "GCP region for Cloud Run + Artifact Registry."
}

variable "name_prefix" {
  type        = string
  description = "Prefix applied to resource names."
}

variable "subnet_id" {
  type        = string
  description = "Subnet used for Cloud Run Direct VPC egress to the private DB."
}

variable "image" {
  type        = string
  description = "aion-runtime image to run. The :latest default is a PLAN-ONLY placeholder; deploys inject an immutable ghcr.io/ceoloo/aion-runtime:<sha> (ADR-002)."
  default     = "ghcr.io/ceoloo/aion-runtime:latest"
}

# ── Identities ──────────────────────────────────────────────────────────────
variable "runtime_service_account_email" {
  type        = string
  description = "Least-privileged runtime SA. Reads DATABASE_URL; no migration/admin rights."
}

variable "migration_service_account_email" {
  type        = string
  description = "Migration SA used only by the migrate job. Reads MIGRATION_DATABASE_URL."
}

# ── Secret references ────────────────────────────────────────────────────────
variable "database_url_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the runtime connection string."
}

variable "migration_database_url_secret_id" {
  type        = string
  description = "Secret Manager secret ID holding the migration connection string."
}

# ── Release metadata (surfaced via /health + logs) ──────────────────────────
variable "service_version" {
  type        = string
  description = "Semantic/service version string."
  default     = "0.1.0"
}

variable "git_sha" {
  type        = string
  description = "Commit SHA of the running release."
  default     = "unknown"
}

variable "build_time" {
  type        = string
  description = "Build timestamp (RFC3339)."
  default     = "unknown"
}

# ── Sizing / behavior ────────────────────────────────────────────────────────
variable "container_port" {
  type        = number
  description = "Port the runtime listens on."
  default     = 8080
}

variable "cpu" {
  type        = string
  description = "CPU limit per instance."
  default     = "1"
}

variable "memory" {
  type        = string
  description = "Memory limit per instance."
  default     = "512Mi"
}

variable "min_instances" {
  type        = number
  description = "Minimum instances (0 = scale to zero, cheapest)."
  default     = 0
}

variable "max_instances" {
  type        = number
  description = "Maximum instances (bounds cost)."
  default     = 2
}

variable "log_level" {
  type        = string
  description = "Runtime log level."
  default     = "info"
}

variable "ingress" {
  type        = string
  description = "Cloud Run ingress setting."
  default     = "INGRESS_TRAFFIC_ALL"
}

variable "allow_unauthenticated" {
  type        = bool
  description = "Bind allUsers as run.invoker (public). OFF by default — deny-by-default."
  default     = false
}

variable "invoker_members" {
  type        = list(string)
  description = "IAM members granted roles/run.invoker (authenticated callers, e.g. CI smoke-test SA)."
  default     = []
}

variable "deletion_protection" {
  type        = bool
  description = "Cloud Run deletion protection (true for production)."
  default     = false
}
