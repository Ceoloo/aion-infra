# ============================================================================
# Database module — managed PostgreSQL 16 for the AION Data workload.
# ============================================================================
# Provisions Cloud SQL for PostgreSQL compatible with aion-data's schema and
# migration runner (aion-data/docs/schema.md, migrations/). It implements the
# Phase 3 database requirements (aion-infra §11–13):
#
#   * PostgreSQL 16, encrypted at rest (Google-managed or CMEK) and in transit;
#   * automated daily backups + point-in-time recovery (WAL retention);
#   * PRIVATE IP only — no public/unauthenticated exposure;
#   * production deletion protection (instance + Terraform lifecycle);
#   * sensible maintenance window;
#   * the Phase 2 TWO-ROLE model: aion_app (DML) and aion_migrator (DDL).
#
# The database OWNER/superuser is never handed to the runtime. Login roles are
# created here; fine-grained GRANT/REVOKE (append-only events/telemetry, no DDL
# for the app role) is applied through the migration path from the canonical
# runtime/sql/grants.sql (shipped in the image, applied by the migrate job) —
# see docs/database.md. aion-data migrations remain authoritative for schema.

resource "google_sql_database_instance" "postgres" {
  project          = var.project_id
  name             = "${var.name_prefix}-pg"
  region           = var.region
  database_version = "POSTGRES_16"

  # Deletion protection is enforced in two independent places for production:
  #  - deletion_protection (this argument) blocks `terraform destroy`;
  #  - settings.deletion_protection_enabled blocks the delete at the API level.
  deletion_protection = var.deletion_protection

  settings {
    tier              = var.tier
    availability_type = var.availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.disk_size_gb
    disk_autoresize   = true

    # Blocks deletion of the instance via the Cloud SQL API itself.
    deletion_protection_enabled = var.deletion_protection

    backup_configuration {
      enabled                        = true
      start_time                     = var.backup_start_time
      point_in_time_recovery_enabled = var.point_in_time_recovery
      transaction_log_retention_days = var.transaction_log_retention_days
      location                       = var.backup_location

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
    }

    ip_configuration {
      # PRIVATE IP ONLY. Public IPv4 is disabled so the database is never
      # reachable from the internet (aion-infra §13).
      ipv4_enabled                                  = false
      private_network                               = var.network_id
      enable_private_path_for_google_cloud_services = true
      ssl_mode                                      = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = var.maintenance_window_day
      hour         = var.maintenance_window_hour
      update_track = "stable"
    }

    database_flags {
      name  = "log_min_duration_statement"
      value = "1000"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false
    }

    user_labels = {
      environment = var.environment
      managed_by  = "terraform"
      component   = "aion-data"
    }
  }

  # The private IP cannot be assigned until the service-networking peering the
  # networking module created is active.
  depends_on = [var.private_vpc_connection]

  lifecycle {
    prevent_destroy = false # overridden per-environment; see production.
  }
}

# The application database that holds the aion-data canonical schema.
resource "google_sql_database" "aion" {
  project  = var.project_id
  name     = var.database_name
  instance = google_sql_database_instance.postgres.name
}

# ── Login roles (least privilege) ───────────────────────────────────────────
# Passwords are NOT committed. They are supplied from CI/secret material via
# sensitive variables and are the values embedded in the connection-string
# secrets created by the secrets module. Rotation replaces both together.

# Runtime application role — DML only. GRANT/REVOKE narrowing is applied by
# sql/grants.sql through the migration identity (docs/database.md).
resource "google_sql_user" "app" {
  project         = var.project_id
  instance        = google_sql_database_instance.postgres.name
  name            = var.app_user
  password        = var.app_password
  deletion_policy = "ABANDON"
}

# Migration/admin role — owns the schema, holds DDL. Used ONLY by the migration
# job, never by the long-running runtime (aion-infra §16–17).
resource "google_sql_user" "migrator" {
  project         = var.project_id
  instance        = google_sql_database_instance.postgres.name
  name            = var.migrator_user
  password        = var.migrator_password
  deletion_policy = "ABANDON"
}
