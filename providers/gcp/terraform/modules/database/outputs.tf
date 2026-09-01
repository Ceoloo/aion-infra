output "instance_name" {
  description = "Cloud SQL instance name."
  value       = google_sql_database_instance.postgres.name
}

output "connection_name" {
  description = "Instance connection name (project:region:instance) for the connector."
  value       = google_sql_database_instance.postgres.connection_name
}

output "private_ip_address" {
  description = "Private IP of the instance (VPC-internal only)."
  value       = google_sql_database_instance.postgres.private_ip_address
}

output "database_name" {
  description = "Application database name."
  value       = google_sql_database.aion.name
}

output "app_user" {
  description = "Application (DML) role name."
  value       = google_sql_user.app.name
}

output "migrator_user" {
  description = "Migration (DDL) role name."
  value       = google_sql_user.migrator.name
}
