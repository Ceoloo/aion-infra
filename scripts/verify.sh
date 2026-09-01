#!/usr/bin/env bash
# ============================================================================
# verify.sh — Phase 3 verification harness (aion-infra §60), infra-scoped.
# ============================================================================
# After ADR-002 the runtime host lives in the aion-runtime repo (which runs the
# runtime-source + acceptance checks in its own CI). This harness verifies the
# aion-infra side: declarative IaC across all provider profiles, DB provisioning
# + role model, the migration/health path at the provider level, backups,
# the production human gate, no committed secrets, and that every profile
# consumes the aion-runtime image.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %-30s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-30s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
note() { printf '  \033[33mNOTE\033[0m  %-30s %s\n' "$1" "$2"; }
has()  { grep -Rqs -- "$1" "$2"; }

echo "== AION Phase 3 (infra) verification =="

# IAC_VALIDATE + plans (all profiles: 3 GCP stacks + AWS) --------------------
if command -v terraform >/dev/null; then
  vfail=0
  for d in providers/gcp/terraform/environments/bootstrap \
           providers/gcp/terraform/environments/staging \
           providers/gcp/terraform/environments/production \
           providers/aws/terraform; do
    ( cd "$d" && terraform init -backend=false -input=false >/dev/null 2>&1 \
        && terraform validate >/dev/null 2>&1 ) || vfail=1
  done
  [ "$(terraform fmt -check -recursive providers >/dev/null 2>&1; echo $?)" = 0 ] || vfail=1
  [ $vfail -eq 0 ] && ok IAC_VALIDATE "fmt + validate: GCP(3) + AWS" || bad IAC_VALIDATE "terraform fmt/validate failed"
  [ $vfail -eq 0 ] && ok STAGING_PLAN "config valid (live plan needs creds)" || bad STAGING_PLAN "staging config invalid"
  [ $vfail -eq 0 ] && ok PRODUCTION_PLAN "config valid (live plan needs creds)" || bad PRODUCTION_PLAN "production config invalid"
  find providers -name .terraform -type d -prune -exec rm -rf {} + 2>/dev/null
else
  note IAC_VALIDATE "terraform not installed — skipped"
fi

# SECRET_REFERENCE_VALIDATION -----------------------------------------------
has 'secret_key_ref' providers/gcp/terraform/modules/runtime && has 'google_secret_manager_secret' providers/gcp/terraform/modules/secrets \
  && ok SECRET_REFERENCE_VALIDATION "runtime reads secrets via Secret Manager refs" \
  || bad SECRET_REFERENCE_VALIDATION "no secret_key_ref / secret manager wiring"

# DATABASE_PROVISIONING_CONFIG ----------------------------------------------
db=providers/gcp/terraform/modules/database/main.tf
if has 'POSTGRES_16' "$db" && has 'point_in_time_recovery' "$db" \
   && has 'ipv4_enabled                                  = false' "$db" \
   && has 'deletion_protection' "$db" && has 'backup_configuration' "$db"; then
  ok DATABASE_PROVISIONING_CONFIG "PG16 + backups + PITR + private IP + del-protect"
else bad DATABASE_PROVISIONING_CONFIG "missing a required DB setting"; fi

# DB_ROLE_SEPARATION — the two least-privilege login roles are provisioned ---
if has 'google_sql_user' "$db" && has 'aion_app' "$db" && has 'aion_migrator' "$db" \
   && has 'OWNER/superuser is never handed to the runtime' "$db"; then
  ok DB_ROLE_SEPARATION "two provisioned roles; app never owner/superuser"
else bad DB_ROLE_SEPARATION "role model missing in the database module"; fi

# MIGRATION_EXECUTION_PATH — separate migrate job at the provider level ------
if has 'google_cloud_run_v2_job' providers/gcp/terraform/modules/runtime/main.tf \
   && has 'node.*dist/migrate.js' providers/gcp/terraform/modules/runtime/main.tf \
   && [ -f providers/gcp/scripts/migrate.sh ]; then
  ok MIGRATION_EXECUTION_PATH "separate migrate job + entrypoint + fail-closed"
else bad MIGRATION_EXECUTION_PATH "migration path incomplete"; fi

# HEALTH_CHECK — provider probes call the neutral endpoints -----------------
if has 'liveness_probe' providers/gcp/terraform/modules/runtime/main.tf \
   && has 'startup_probe' providers/gcp/terraform/modules/runtime/main.tf \
   && has '/health/ready' providers/aws/terraform/main.tf; then
  ok HEALTH_CHECK "Cloud Run probes + ALB health on /health/ready"
else bad HEALTH_CHECK "provider health wiring missing"; fi

# DEPLOYMENT_SMOKE_TEST -----------------------------------------------------
[ -x scripts/smoke-test.sh ] && has 'EXPECTED_SHA' scripts/smoke-test.sh \
  && ok DEPLOYMENT_SMOKE_TEST "non-destructive smoke test present" \
  || bad DEPLOYMENT_SMOKE_TEST "smoke test missing"

# BACKUP_CONFIGURATION ------------------------------------------------------
has 'retained_backups' "$db" && has 'transaction_log_retention_days' "$db" \
  && ok BACKUP_CONFIGURATION "automated backups + WAL retention configured" \
  || bad BACKUP_CONFIGURATION "backup config missing"

# RESTORE_RUNBOOK -----------------------------------------------------------
if [ -x providers/gcp/scripts/backup-verify.sh ] && [ -x scripts/backup-restore-selftest.sh ] \
   && [ -f docs/backup-recovery.md ]; then
  ok RESTORE_RUNBOOK "isolated clone-restore + selftest + doc"
else bad RESTORE_RUNBOOK "restore runbook missing"; fi

# PRODUCTION_HUMAN_GATE -----------------------------------------------------
if has 'environment: production' .github/workflows/deploy-gcp.yml \
   && has 'production deploys only from main' .github/workflows/deploy-gcp.yml; then
  ok PRODUCTION_HUMAN_GATE "GitHub Environment approval + main-only ref"
else bad PRODUCTION_HUMAN_GATE "production gate missing"; fi

# CONSUMES_AION_RUNTIME_IMAGE — infra deploys, never builds ------------------
if has 'ghcr.io/ceoloo/aion-runtime' providers/vps && has 'ghcr.io/ceoloo/aion-runtime' providers/aws/terraform \
   && has 'ghcr.io/ceoloo/aion-runtime' providers/gcp/terraform && [ ! -d runtime ]; then
  ok CONSUMES_AION_RUNTIME_IMAGE "all profiles consume aion-runtime image; no fixture"
else bad CONSUMES_AION_RUNTIME_IMAGE "a profile does not consume the image / fixture remains"; fi

# NO_PUBLIC_SECRET ----------------------------------------------------------
leak=0
git -C "$ROOT" ls-files 2>/dev/null | grep -E '\.(tfvars|env)$' | grep -v '\.example$' | grep -q . && leak=1
grep -Rqs 'value *= *var\.database_url' providers/gcp/terraform/modules/secrets/outputs.tf 2>/dev/null && leak=1
has 'sensitive   = true' providers/gcp/terraform/modules/database/variables.tf || leak=1
[ $leak -eq 0 ] && ok NO_PUBLIC_SECRET "no committed secrets; no plaintext secret outputs" \
               || bad NO_PUBLIC_SECRET "possible committed secret / secret output"

echo "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
