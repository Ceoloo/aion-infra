output "notification_channel_id" {
  description = "Email notification channel ID (empty when no email configured)."
  value       = var.notification_email == "" ? "" : google_monitoring_notification_channel.email[0].id
}

output "log_retention_days" {
  description = "Configured retention for the _Default log bucket."
  value       = google_logging_project_bucket_config.default.retention_days
}
