#!/usr/bin/env bash
# ============================================================================
# migrate.sh — apply AION Data migrations + aion-infra grants (aion-infra §18).
# ============================================================================
# Runs the migration JOB for an environment, using the MIGRATION identity.
# Migration-before-deploy: apply pending migrations, then the least-privilege
# grants. Fails safe: any error stops the script (and, in CI, the deploy).
#
# In CI this is the Cloud Run job (`gcloud run jobs execute`); locally it can
# run the compiled entrypoint directly. It NEVER runs as the app role and NEVER
# continues past a failed migration (§46, §63).
#
# Usage:
#   scripts/migrate.sh <staging|production>            # execute the Cloud Run job
#   MODE=local MIGRATION_DATABASE_URL=... scripts/migrate.sh local
set -euo pipefail

ENVIRONMENT="${1:-}"
MODE="${MODE:-cloud}"
REGION="${REGION:-us-central1}"

if [[ -z "${ENVIRONMENT}" ]]; then
  echo "usage: $0 <staging|production|local>" >&2
  exit 2
fi

if [[ "${MODE}" == "local" ]]; then
  : "${MIGRATION_DATABASE_URL:?set MIGRATION_DATABASE_URL for local mode}"
  echo "[migrate] local: applying migrations + grants via reference runtime entrypoint"
  ( cd "$(dirname "$0")/../../../runtime" && node dist/migrate.js )
  echo "[migrate] local complete"
  exit 0
fi

: "${PROJECT_ID:?set PROJECT_ID}"
JOB="aion-${ENVIRONMENT}-migrate"

echo "[migrate] executing Cloud Run job ${JOB} in ${PROJECT_ID}/${REGION}"
# --wait makes the CLI return the job's exit status: a failed migration yields a
# non-zero exit here, which halts the pipeline before the runtime is deployed.
gcloud run jobs execute "${JOB}" \
  --project "${PROJECT_ID}" \
  --region "${REGION}" \
  --wait
echo "[migrate] migration job succeeded for ${ENVIRONMENT}"
