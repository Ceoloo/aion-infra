# ============================================================================
# PRODUCTION environment composition.
# ============================================================================
# Same architecture as staging (aion-infra §44 — do not maintain radically
# different architectures) differing ONLY where safety requires it: a separate
# project + secrets + database, HA database, deletion protection, PITR, longer
# retention, a minimum warm instance, and a human release gate.
#
# The human gate for production is enforced at the PIPELINE boundary (a GitHub
# Environment protection rule requiring manual approval — .github/workflows/
# deploy.yml, docs/deployment.md), never by an AI worker deciding to deploy
# (aion-infra §24–25, §64; aion-docs/governance/human-gates.md). Terraform apply
# to production is likewise gated in CI.

locals {
  environment = "production"
  name_prefix = "aion-prod"
}

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

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "${local.name_prefix}-runtime"
  display_name = "AION production runtime (least-privileged app identity)"
}

resource "google_service_account" "migration" {
  project      = var.project_id
  account_id   = "${local.name_prefix}-migrator"
  display_name = "AION production migration job identity"
}

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

  # Production: HA, deletion protection, PITR, longer backup retention.
  tier                           = var.database_tier
  availability_type              = "REGIONAL"
  point_in_time_recovery         = true
  transaction_log_retention_days = 7
  deletion_protection            = true
  retained_backups               = 30

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

  # A warm instance avoids cold-start on the production path; still bounded.
  min_instances         = 1
  max_instances         = 4
  allow_unauthenticated = false
  invoker_members       = var.invoker_members
  deletion_protection   = true
}

module "observability" {
  source                 = "../../modules/observability"
  project_id             = var.project_id
  environment            = local.environment
  runtime_service_name   = module.runtime.service_name
  database_instance_name = module.database.instance_name
  notification_email     = var.notification_email
  log_retention_days     = 60
}
