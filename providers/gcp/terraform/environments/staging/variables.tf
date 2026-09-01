variable "project_id" {
  type        = string
  description = "GCP project ID for STAGING (separate from production)."
}

variable "region" {
  type        = string
  description = "GCP region."
  default     = "us-central1"
}

# ── Injected credentials (never committed) ──────────────────────────────────
# Supplied via TF_VAR_app_password / TF_VAR_migrator_password from CI secret
# material, or an untracked *.auto.tfvars. See docs/security.md.
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

# ── Release / deploy inputs (set by the pipeline) ───────────────────────────
variable "image" {
  type        = string
  description = "Runtime image (…/aion-runtime:<sha>). Defaults to an inert placeholder for plan."
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
  description = "Authenticated IAM members allowed to invoke the runtime (e.g. CI smoke-test SA)."
  default     = []
}
