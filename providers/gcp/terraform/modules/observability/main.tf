# ============================================================================
# Observability module — minimal, provider-native (aion-infra §27, §30, §40).
# ============================================================================
# Cloud Run and Cloud SQL emit logs and metrics to Cloud Logging / Monitoring
# with no agent to run. This module adds only what Phase 3 needs on top:
#
#   * a log bucket with a sane RETENTION period (not "forever");
#   * a small set of BASIC alerts (aion-infra §30): runtime unavailable / crash
#     looping, database unavailable, and backup failure;
#   * an email notification channel.
#
# No dashboards platform, no SIEM, no pager fabric — those are out of scope.
# Structured application logs are emitted by the runtime itself (JSON to stdout,
# picked up natively by Cloud Logging) — see docs/observability.md.

locals {
  labels = {
    environment = var.environment
    managed_by  = "terraform"
    component   = "aion-observability"
  }
  # Alerts are only wired when a notification target is configured, so a bare
  # `plan` (no email) still validates and applies cleanly.
  channels = var.notification_email == "" ? [] : [google_monitoring_notification_channel.email[0].id]
}

# Log retention: replace the _Default bucket's retention with an explicit,
# bounded window per environment (aion-infra §40).
resource "google_logging_project_bucket_config" "default" {
  project        = var.project_id
  location       = var.log_bucket_location
  bucket_id      = "_Default"
  retention_days = var.log_retention_days
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.notification_email == "" ? 0 : 1
  project      = var.project_id
  display_name = "AION ${var.environment} — ops email"
  type         = "email"
  labels = {
    email_address = var.notification_email
  }
}

# ── Runtime unavailable / crash-looping ─────────────────────────────────────
resource "google_monitoring_alert_policy" "runtime_down" {
  count        = length(local.channels) == 0 ? 0 : 1
  project      = var.project_id
  display_name = "AION ${var.environment} — runtime unavailable"
  combiner     = "OR"

  conditions {
    display_name = "No successful requests / instances"
    condition_absent {
      filter   = "resource.type = \"cloud_run_revision\" AND resource.labels.service_name = \"${var.runtime_service_name}\" AND metric.type = \"run.googleapis.com/container/instance_count\""
      duration = "300s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
}

# ── Database unavailable ────────────────────────────────────────────────────
resource "google_monitoring_alert_policy" "database_down" {
  count        = length(local.channels) == 0 ? 0 : 1
  project      = var.project_id
  display_name = "AION ${var.environment} — database unavailable"
  combiner     = "OR"

  conditions {
    display_name = "Cloud SQL instance not up"
    condition_threshold {
      filter          = "resource.type = \"cloudsql_database\" AND resource.labels.database_id = \"${var.project_id}:${var.database_instance_name}\" AND metric.type = \"cloudsql.googleapis.com/database/up\""
      comparison      = "COMPARISON_LT"
      threshold_value = 1
      duration        = "180s"
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MIN"
      }
    }
  }

  notification_channels = local.channels
  alert_strategy {
    auto_close = "1800s"
  }
}

# ── Backup failure ──────────────────────────────────────────────────────────
# A log-based alert: Cloud SQL emits a backup-failure log entry we key on.
resource "google_monitoring_alert_policy" "backup_failed" {
  count        = length(local.channels) == 0 ? 0 : 1
  project      = var.project_id
  display_name = "AION ${var.environment} — database backup failed"
  combiner     = "OR"

  conditions {
    display_name = "Backup failure log entry"
    condition_matched_log {
      filter = "resource.type=\"cloudsql_database\" AND resource.labels.database_id=\"${var.project_id}:${var.database_instance_name}\" AND severity>=ERROR AND textPayload:\"backup\""
    }
  }

  notification_channels = local.channels
  alert_strategy {
    notification_rate_limit {
      period = "3600s"
    }
    auto_close = "1800s"
  }
}
