# ============================================================================
# Secrets module — managed secret storage (Google Secret Manager).
# ============================================================================
# The runtime and migration connection strings live in a MANAGED secret store,
# never in GitHub, Terraform state as plaintext output, or a committed .env
# (aion-infra §14; aion-docs/architecture/security-model.md "No secrets in any
# repository — ever"). Access is least-privilege:
#
#   * the RUNTIME service account may read DATABASE_URL only;
#   * the MIGRATION service account may read MIGRATION_DATABASE_URL only;
#   * nobody else is granted access here.
#
# Secret VALUES are supplied from sensitive variables (assembled from Cloud SQL
# outputs + injected passwords). They are marked sensitive so they are not
# printed in plan/apply logs. Rotation = add a new secret version + redeploy
# (docs/runbook.md → "Rotate database credentials").

locals {
  labels = {
    environment = var.environment
    managed_by  = "terraform"
    component   = "aion-secrets"
  }
}

# ── Runtime application connection (least-privileged aion_app role) ──────────
resource "google_secret_manager_secret" "database_url" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-database-url"
  labels    = local.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "database_url" {
  secret      = google_secret_manager_secret.database_url.id
  secret_data = var.database_url
}

resource "google_secret_manager_secret_iam_member" "runtime_reads_database_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.runtime_service_account_email}"
}

# ── Migration connection (aion_migrator DDL role) ───────────────────────────
resource "google_secret_manager_secret" "migration_database_url" {
  project   = var.project_id
  secret_id = "${var.name_prefix}-migration-database-url"
  labels    = local.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "migration_database_url" {
  secret      = google_secret_manager_secret.migration_database_url.id
  secret_data = var.migration_database_url
}

resource "google_secret_manager_secret_iam_member" "migrator_reads_migration_url" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.migration_database_url.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.migration_service_account_email}"
}
