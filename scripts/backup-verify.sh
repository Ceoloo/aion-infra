#!/usr/bin/env bash
# ============================================================================
# backup-verify.sh — verify backups exist AND a restore actually works.
# ============================================================================
# "Backups enabled" is NOT proof of recoverability (aion-infra §31–32, §65).
# This script:
#   1. lists automated backups for the instance and checks recency;
#   2. (RESTORE mode) clones the instance's latest backup into an ISOLATED
#      target instance, connects, and asserts the canonical schema is present —
#      then tears the target down. It NEVER restores over production (§32).
#
# Live verification needs cloud credentials + quota; without them this documents
# the exact tested procedure (see docs/backup-recovery.md).
#
# Usage:
#   PROJECT_ID=... INSTANCE=aion-prod-pg scripts/backup-verify.sh            # check recency
#   MODE=restore PROJECT_ID=... INSTANCE=aion-prod-pg REGION=us-central1 \
#       scripts/backup-verify.sh                                            # clone-restore + validate
set -euo pipefail

: "${PROJECT_ID:?set PROJECT_ID}"
: "${INSTANCE:?set INSTANCE (Cloud SQL instance name)}"
MODE="${MODE:-check}"
REGION="${REGION:-us-central1}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"   # a daily backup must be <~26h old

echo "[backup] latest backups for ${INSTANCE}"
gcloud sql backups list --instance "${INSTANCE}" --project "${PROJECT_ID}" \
  --sort-by '~windowStartTime' --limit 5

latest_id="$(gcloud sql backups list --instance "${INSTANCE}" --project "${PROJECT_ID}" \
  --sort-by '~windowStartTime' --limit 1 --format 'value(id)')"
latest_time="$(gcloud sql backups list --instance "${INSTANCE}" --project "${PROJECT_ID}" \
  --sort-by '~windowStartTime' --limit 1 --format 'value(windowStartTime)')"
[[ -z "${latest_id}" ]] && { echo "NO BACKUPS FOUND" >&2; exit 1; }

# Recency guard.
if command -v date >/dev/null; then
  age_h=$(( ( $(date -u +%s) - $(date -u -d "${latest_time}" +%s) ) / 3600 ))
  echo "[backup] latest backup ${latest_id} is ${age_h}h old (threshold ${MAX_AGE_HOURS}h)"
  (( age_h > MAX_AGE_HOURS )) && { echo "BACKUP STALE" >&2; exit 1; }
fi

if [[ "${MODE}" != "restore" ]]; then
  echo "[backup] recency check PASS (run with MODE=restore to validate a real restore)"
  exit 0
fi

# ── Restore into an ISOLATED target and validate schema ─────────────────────
TARGET="${INSTANCE}-restorecheck-$(date -u +%Y%m%d%H%M%S)"
echo "[backup] creating isolated restore target ${TARGET}"
gcloud sql instances create "${TARGET}" --project "${PROJECT_ID}" --region "${REGION}" \
  --database-version POSTGRES_16 --tier db-custom-1-3840 --no-assign-ip
echo "[backup] restoring backup ${latest_id} into ${TARGET}"
gcloud sql backups restore "${latest_id}" \
  --restore-instance "${TARGET}" --backup-instance "${INSTANCE}" --project "${PROJECT_ID}"

echo "[backup] validating canonical schema on ${TARGET}"
# Expect the 7 canonical tables to be present.
COUNT="$(gcloud sql connect "${TARGET}" --user postgres --project "${PROJECT_ID}" --quiet <<'SQL' | tail -1
SELECT count(*) FROM information_schema.tables
 WHERE table_schema='public'
   AND table_name IN ('actors','missions','runs','approvals','events','telemetry_records','outcomes');
SQL
)"
echo "[backup] canonical tables found: ${COUNT} (expected 7)"

echo "[backup] tearing down restore target ${TARGET}"
gcloud sql instances delete "${TARGET}" --project "${PROJECT_ID}" --quiet

[[ "${COUNT}" == *7* ]] || { echo "RESTORE VALIDATION FAILED" >&2; exit 1; }
echo "[backup] RESTORE VERIFICATION PASS"
