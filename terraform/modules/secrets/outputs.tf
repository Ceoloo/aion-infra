# Secret IDs are referenced by the runtime + migration jobs. VALUES are never
# output (aion-infra §14: "no plaintext secret outputs").

output "database_url_secret_id" {
  description = "Secret Manager secret ID for the runtime connection string."
  value       = google_secret_manager_secret.database_url.secret_id
}

output "migration_database_url_secret_id" {
  description = "Secret Manager secret ID for the migration connection string."
  value       = google_secret_manager_secret.migration_database_url.secret_id
}
