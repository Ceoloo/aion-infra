variable "project_id" {
  type        = string
  description = "GCP project that holds the seed resources (state buckets, WIF pool, CI SAs)."
}

variable "region" {
  type        = string
  description = "Location for the state buckets."
  default     = "us-central1"
}

variable "state_bucket_prefix" {
  type        = string
  description = "Globally-unique prefix for state bucket names, e.g. aion-ceoloo."
}

variable "github_repository" {
  type        = string
  description = "owner/repo permitted to assume CI identities via OIDC."
  default     = "Ceoloo/aion-infra"
}
