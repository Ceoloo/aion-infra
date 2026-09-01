output "service_name" {
  description = "Cloud Run runtime service name."
  value       = google_cloud_run_v2_service.runtime.name
}

output "service_uri" {
  description = "HTTPS URL of the runtime service (managed TLS)."
  value       = google_cloud_run_v2_service.runtime.uri
}

output "migrate_job_name" {
  description = "Cloud Run job that applies migrations."
  value       = google_cloud_run_v2_job.migrate.name
}

output "image_repository" {
  description = "Artifact Registry repository for runtime images."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
