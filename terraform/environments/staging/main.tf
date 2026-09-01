# ============================================================================
# STAGING environment composition.
# ============================================================================
# Wires the modules into a complete, separately-credentialed staging stack
# (aion-docs/architecture/environments.md). Staging is useful, not ceremonial:
# it runs real migrations, a real deploy, health + smoke tests against a real
# (smaller, non-HA) database — but never shares secrets or the database with
# production (aion-infra §43, §67).
#
# Service accounts (identities) are defined HERE because they are shared across
# the secrets and runtime modules; keeping them in the composition avoids a
# module cycle and keeps each module single-purpose (aion-infra §16–17, §49).

locals {
  environment = "staging"
  name_prefix = "aion-staging"
}

# ── Enable the APIs this stack uses (idempotent) ────────────────────────────
resource "google_project_service" "services" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "servicenetworking.googleapis.com",
    "compute.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
  ])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ── Identities (least privilege) ────────────────────────────────────────────
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "${local.name_prefix}-runtime"
  display_name = "AION staging runtime (least-privileged app identity)"
}

resource "google_service_account" "migration" {
  project      = var.project_id
  account_id   = "${local.name_prefix}-migrator"
  display_name = "AION staging migration job identity"
}

# Runtime may write logs + metrics only. It gets DB access via its DATABASE_URL
# secret (secrets module) — no project-level database or admin role.
resource "google_project_iam_member" "runtime_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_metrics" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "migration_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.migration.email}"
}

# ── Modules ─────────────────────────────────────────────────────────────────
module "networking" {
  source      = "../../modules/networking"
  project_id  = var.project_id
  environment = local.environment
  region      = var.region
  name_prefix = local.name_prefix

  depends_on = [google_project_service.services]
}

module "database" {
  source                 = "../../modules/database"
  project_id             = var.project_id
  environment            = local.environment
  region                 = var.region
  name_prefix            = local.name_prefix
  network_id             = module.networking.network_id
  private_vpc_connection = module.networking.private_vpc_connection

  # Staging: smaller, zonal, still backed up + PITR, but no deletion protection
  # so the environment can be torn down and rebuilt cheaply (aion-infra §48).
  tier                   = "db-custom-1-3840"
  availability_type      = "ZONAL"
  point_in_time_recovery = true
  deletion_protection    = false
  retained_backups       = 7

  app_password      = var.app_password
  migrator_password = var.migrator_password
}

module "secrets" {
  source      = "../../modules/secrets"
  project_id  = var.project_id
  environment = local.environment
  name_prefix = local.name_prefix

  database_url           = "postgresql://${module.database.app_user}:${var.app_password}@${module.database.private_ip_address}:5432/${module.database.database_name}?sslmode=require"
  migration_database_url = "postgresql://${module.database.migrator_user}:${var.migrator_password}@${module.database.private_ip_address}:5432/${module.database.database_name}?sslmode=require"

  runtime_service_account_email   = google_service_account.runtime.email
  migration_service_account_email = google_service_account.migration.email
}

module "runtime" {
  source      = "../../modules/runtime"
  project_id  = var.project_id
  environment = local.environment
  region      = var.region
  name_prefix = local.name_prefix
  subnet_id   = module.networking.subnet_id

  runtime_service_account_email    = google_service_account.runtime.email
  migration_service_account_email  = google_service_account.migration.email
  database_url_secret_id           = module.secrets.database_url_secret_id
  migration_database_url_secret_id = module.secrets.migration_database_url_secret_id

  image           = var.image
  service_version = var.service_version
  git_sha         = var.git_sha
  build_time      = var.build_time

  min_instances         = 0
  max_instances         = 2
  allow_unauthenticated = false
  invoker_members       = var.invoker_members
  deletion_protection   = false
}

module "observability" {
  source                 = "../../modules/observability"
  project_id             = var.project_id
  environment            = local.environment
  runtime_service_name   = module.runtime.service_name
  database_instance_name = module.database.instance_name
  notification_email     = var.notification_email
  log_retention_days     = 30
}
