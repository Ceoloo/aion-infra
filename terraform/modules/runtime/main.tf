# ============================================================================
# Runtime module — Cloud Run service, migration job, and image registry.
# ============================================================================
# The simplest managed hosting that safely runs the Node.js AION runtime
# (aion-infra §19–22): serverless containers, no VM to patch, no Kubernetes.
#
#   * google_cloud_run_v2_service "runtime" — the long-running host. Connects to
#     the PRIVATE Cloud SQL instance via Direct VPC egress, reads only its own
#     DATABASE_URL secret, runs as the least-privileged runtime SA, and exposes
#     liveness/readiness probes. It NEVER receives migration credentials.
#   * google_cloud_run_v2_job "migrate" — a separate, one-shot job that applies
#     aion-data migrations using the migration SA + MIGRATION_DATABASE_URL. Run
#     before the service is deployed (migration-before-deploy, aion-infra §18).
#   * google_artifact_registry_repository — immutable images tagged by commit SHA
#     (aion-infra §21). The runtime and migration job run the SAME image.
#
# Managed TLS is automatic on the *.run.app endpoint (aion-infra §36). Release
# metadata (GIT_SHA / SERVICE_VERSION / BUILD_TIME) is injected as env so the
# running commit is identifiable (aion-infra §22).

locals {
  labels = {
    environment = var.environment
    managed_by  = "terraform"
    component   = "aion-runtime"
  }

  # Release metadata surfaced through the runtime's /health and logs.
  release_env = {
    AION_ENVIRONMENT = var.environment
    NODE_ENV         = "production"
    LOG_LEVEL        = var.log_level
    SERVICE_VERSION  = var.service_version
    GIT_SHA          = var.git_sha
    BUILD_TIME       = var.build_time
    PORT             = tostring(var.container_port)
  }
}

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.name_prefix}-images"
  format        = "DOCKER"
  description   = "Immutable AION runtime images (tagged by commit SHA)."
  labels        = local.labels
}

# ── The long-running runtime service ────────────────────────────────────────
resource "google_cloud_run_v2_service" "runtime" {
  project             = var.project_id
  name                = "${var.name_prefix}-runtime"
  location            = var.region
  ingress             = var.ingress
  deletion_protection = var.deletion_protection
  labels              = local.labels

  template {
    service_account = var.runtime_service_account_email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # Direct VPC egress: reach the private Cloud SQL IP without a connector.
    # Only private ranges leave via the VPC; everything else uses the default.
    vpc_access {
      network_interfaces {
        subnetwork = var.subnet_id
      }
      egress = "PRIVATE_RANGES_ONLY"
    }

    containers {
      image = var.image

      ports {
        container_port = var.container_port
      }

      dynamic "env" {
        for_each = local.release_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # DATABASE_URL is injected from Secret Manager at start — never baked into
      # the image, never a plaintext env in state (aion-infra §14, §20).
      env {
        name = "DATABASE_URL"
        value_source {
          secret_key_ref {
            secret  = var.database_url_secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # Readiness: fails when the service cannot safely accept work (e.g. DB
      # unreachable) so Cloud Run withholds traffic (aion-infra §29, §62).
      startup_probe {
        http_get {
          path = "/health/ready"
          port = var.container_port
        }
        initial_delay_seconds = 5
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 6
      }

      # Liveness: cheap, no dependency work — restarts a wedged process only.
      liveness_probe {
        http_get {
          path = "/health/live"
          port = var.container_port
        }
        initial_delay_seconds = 10
        period_seconds        = 30
        timeout_seconds       = 3
        failure_threshold     = 3
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Image tag is advanced by the deploy pipeline, not by Terraform, so a
      # plan does not fight the last deployed revision.
      template[0].containers[0].image,
    ]
  }
}

# ── One-shot migration job (separate identity + credential) ─────────────────
resource "google_cloud_run_v2_job" "migrate" {
  project             = var.project_id
  name                = "${var.name_prefix}-migrate"
  location            = var.region
  deletion_protection = false
  labels              = local.labels

  template {
    template {
      service_account = var.migration_service_account_email
      max_retries     = 0 # a failed migration must not silently retry (§46, §63)
      timeout         = "600s"

      vpc_access {
        network_interfaces {
          subnetwork = var.subnet_id
        }
        egress = "PRIVATE_RANGES_ONLY"
      }

      containers {
        image   = var.image
        command = ["node", "dist/migrate.js"]

        dynamic "env" {
          for_each = local.release_env
          content {
            name  = env.key
            value = env.value
          }
        }

        # The migration job — and ONLY it — receives the DDL credential.
        env {
          name = "MIGRATION_DATABASE_URL"
          value_source {
            secret_key_ref {
              secret  = var.migration_database_url_secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      template[0].template[0].containers[0].image,
    ]
  }
}

# ── Who may invoke the runtime ──────────────────────────────────────────────
# Deny-by-default: invocation requires an authenticated identity with
# roles/run.invoker. Public (unauthenticated) access is opt-in and OFF by
# default — smoke tests use an identity token (scripts/smoke-test.sh).
resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.runtime.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "invokers" {
  for_each = toset(var.invoker_members)
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.runtime.name
  role     = "roles/run.invoker"
  member   = each.value
}
