output "runtime_url" {
  description = "HTTPS URL of the staging runtime."
  value       = module.runtime.service_uri
}

output "image_repository" {
  description = "Artifact Registry repository for staging images."
  value       = module.runtime.image_repository
}

output "migrate_job_name" {
  description = "Cloud Run migration job name."
  value       = module.runtime.migrate_job_name
}

output "database_instance" {
  description = "Cloud SQL instance name."
  value       = module.database.instance_name
}

output "database_connection_name" {
  description = "Cloud SQL connection name (project:region:instance)."
  value       = module.database.connection_name
}

output "runtime_service_account" {
  description = "Runtime service account email."
  value       = google_service_account.runtime.email
}
