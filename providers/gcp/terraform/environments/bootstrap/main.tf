# ============================================================================
# BOOTSTRAP — the minimal seed that resolves the remote-state chicken-and-egg.
# ============================================================================
# This is the ONE stack that runs with a LOCAL backend (aion-infra §10: "If
# remote state provisioning creates a bootstrap problem, document the minimal
# bootstrap procedure"). It creates:
#
#   * two GCS buckets for Terraform state (staging + production, SEPARATED),
#     versioned, uniform-access, public-access-prevented, encrypted at rest;
#   * a Workload Identity Federation pool + GitHub OIDC provider, so GitHub
#     Actions authenticate with SHORT-LIVED tokens and NO stored cloud keys
#     (aion-infra §50);
#   * per-environment CI service accounts the pipeline impersonates.
#
# Run once, by a human, from a workstation/CI with owner on the seed project.
# See docs/deployment.md → "Bootstrap". After apply, migrate this stack's own
# state into one of the buckets if desired (optional; documented).

# ── Remote state buckets (separated per environment) ────────────────────────
resource "google_storage_bucket" "tfstate" {
  for_each = toset(["staging", "production"])

  project                     = var.project_id
  name                        = "${var.state_bucket_prefix}-${each.value}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    component   = "aion-tfstate"
    environment = each.value
    managed_by  = "terraform"
  }
}

# ── GitHub OIDC → keyless CI auth ───────────────────────────────────────────
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "aion-github-pool"
  display_name              = "AION GitHub Actions"
  description               = "Keyless OIDC federation for CI/CD (aion-infra §50)."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only THIS repository may mint tokens against this provider.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# ── CI service accounts (one per environment) ───────────────────────────────
resource "google_service_account" "ci" {
  for_each = toset(["staging", "production"])

  project      = var.project_id
  account_id   = "aion-ci-${each.value}"
  display_name = "AION CI/CD (${each.value}) — impersonated via GitHub OIDC"
}

# Staging CI may be assumed from any branch; production CI ONLY from main or a
# release tag (aion-infra §26 — production originates only from trusted refs).
resource "google_service_account_iam_member" "wif_staging" {
  service_account_id = google_service_account.ci["staging"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_service_account_iam_member" "wif_production" {
  service_account_id = google_service_account.ci["production"].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.ref/refs/heads/main"
}
