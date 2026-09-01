output "staging_state_bucket" {
  description = "GCS bucket for staging Terraform state."
  value       = google_storage_bucket.tfstate["staging"].name
}

output "production_state_bucket" {
  description = "GCS bucket for production Terraform state."
  value       = google_storage_bucket.tfstate["production"].name
}

output "workload_identity_provider" {
  description = "Full resource name of the GitHub OIDC provider (for google-github-actions/auth)."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "ci_service_account_staging" {
  description = "CI service account email for staging."
  value       = google_service_account.ci["staging"].email
}

output "ci_service_account_production" {
  description = "CI service account email for production."
  value       = google_service_account.ci["production"].email
}
