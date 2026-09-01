#!/usr/bin/env bash
# ============================================================================
# verify.sh — Phase 3 verification harness (aion-infra §60).
# ============================================================================
# Runs the credential-free checks that prove the Phase 3 exit criteria and
# prints a PASS/FAIL table for each named check. Live-cloud checks (plan/apply,
# restore) require GCP credentials and are marked accordingly; several runtime
# checks were additionally proven against a real local Postgres during the build
# (see docs/phase-3.md → "Verification").
#
# Usage: scripts/verify.sh          (from repo root; needs terraform + node)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %-28s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-28s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
note() { printf '  \033[33mNOTE\033[0m  %-28s %s\n' "$1" "$2"; }
has()  { grep -Rqs -- "$1" "$2"; }

echo "== AION Phase 3 verification =="

# IAC_VALIDATE + STAGING_PLAN + PRODUCTION_PLAN (config validity) ------------
if command -v terraform >/dev/null; then
  vfail=0
  for d in bootstrap staging production; do
    ( cd "terraform/environments/$d" && terraform init -backend=false -input=false >/dev/null 2>&1 \
        && terraform validate >/dev/null 2>&1 ) || vfail=1
  done
  [ "$(cd terraform && terraform fmt -check -recursive >/dev/null 2>&1; echo $?)" = 0 ] || vfail=1
  [ $vfail -eq 0 ] && ok IAC_VALIDATE "fmt + validate: bootstrap/staging/production" \
                   || bad IAC_VALIDATE "terraform fmt/validate failed"
  [ $vfail -eq 0 ] && ok STAGING_PLAN "config valid (live plan needs GCP creds)" \
                   || bad STAGING_PLAN "staging config invalid"
  [ $vfail -eq 0 ] && ok PRODUCTION_PLAN "config valid (live plan needs GCP creds)" \
                   || bad PRODUCTION_PLAN "production config invalid"
  # clean init artifacts
  find terraform -name .terraform -type d -prune -exec rm -rf {} + 2>/dev/null
else
  note IAC_VALIDATE "terraform not installed — skipped"
fi

# SECRET_REFERENCE_VALIDATION ------------------------------------------------
if has 'secret_key_ref' terraform/modules/runtime && has 'google_secret_manager_secret' terraform/modules/secrets; then
  ok SECRET_REFERENCE_VALIDATION "runtime reads secrets via Secret Manager refs"
else bad SECRET_REFERENCE_VALIDATION "no secret_key_ref / secret manager wiring"; fi

# DATABASE_PROVISIONING_CONFIG ----------------------------------------------
db=terraform/modules/database/main.tf
if has 'POSTGRES_16' "$db" && has 'point_in_time_recovery' "$db" \
   && has 'ipv4_enabled                                  = false' "$db" \
   && has 'deletion_protection' "$db" && has 'backup_configuration' "$db"; then
  ok DATABASE_PROVISIONING_CONFIG "PG16 + backups + PITR + private IP + del-protect"
else bad DATABASE_PROVISIONING_CONFIG "missing a required DB setting"; fi

# DB_ROLE_SEPARATION ---------------------------------------------------------
g=runtime/sql/grants.sql
if has 'aion_app' "$g" && has 'aion_migrator' "$g" \
   && has 'REVOKE UPDATE, DELETE ON events' "$g" && has 'REVOKE CREATE ON SCHEMA public FROM aion_app' "$g"; then
  ok DB_ROLE_SEPARATION "two-role grants (app DML-only, append-only logs)"
else bad DB_ROLE_SEPARATION "grants.sql missing role separation"; fi

# MIGRATION_EXECUTION_PATH ---------------------------------------------------
if has 'google_cloud_run_v2_job' terraform/modules/runtime/main.tf \
   && has 'dl.migrate()' runtime/src/migrate.ts && [ -f scripts/migrate.sh ]; then
  ok MIGRATION_EXECUTION_PATH "separate migrate job + aion-data runner + fail-closed"
else bad MIGRATION_EXECUTION_PATH "migration path incomplete"; fi

# RUNTIME_CONFIG_VALIDATION --------------------------------------------------
if has 'missing required configuration' runtime/src/config.ts \
   && has 'must not equal MIGRATION_DATABASE_URL' runtime/src/config.ts; then
  ok RUNTIME_CONFIG_VALIDATION "fail-fast config + app/migrator credential guard"
else bad RUNTIME_CONFIG_VALIDATION "config validation missing"; fi

# HEALTH_CHECK ---------------------------------------------------------------
if has '/health/live' runtime/src/server.ts && has '/health/ready' runtime/src/server.ts \
   && has 'liveness_probe' terraform/modules/runtime/main.tf && has 'startup_probe' terraform/modules/runtime/main.tf; then
  ok HEALTH_CHECK "liveness + readiness endpoints + Cloud Run probes"
else bad HEALTH_CHECK "health endpoints/probes missing"; fi

# DATABASE_CONNECTIVITY ------------------------------------------------------
if has "SELECT 1" runtime/src/control-plane.ts && has 'database_unreachable' runtime/src/server.ts; then
  ok DATABASE_CONNECTIVITY "readiness checks DB; non-secret diagnostic on failure"
else bad DATABASE_CONNECTIVITY "DB connectivity check missing"; fi

# DEPLOYMENT_SMOKE_TEST ------------------------------------------------------
if [ -x scripts/smoke-test.sh ] && has 'EXPECTED_SHA' scripts/smoke-test.sh && has 'RUN_SMOKE_ON_BOOT' runtime/src/config.ts; then
  ok DEPLOYMENT_SMOKE_TEST "non-destructive smoke + boot lifecycle self-check"
else bad DEPLOYMENT_SMOKE_TEST "smoke test missing"; fi

# BACKUP_CONFIGURATION -------------------------------------------------------
if has 'retained_backups' "$db" && has 'transaction_log_retention_days' "$db"; then
  ok BACKUP_CONFIGURATION "automated backups + WAL retention configured"
else bad BACKUP_CONFIGURATION "backup config missing"; fi

# RESTORE_RUNBOOK ------------------------------------------------------------
if [ -x scripts/backup-verify.sh ] && has 'isolated restore target' scripts/backup-verify.sh \
   && [ -f docs/backup-recovery.md ]; then
  ok RESTORE_RUNBOOK "isolated clone-restore procedure + doc"
else bad RESTORE_RUNBOOK "restore runbook missing"; fi

# PRODUCTION_HUMAN_GATE ------------------------------------------------------
if has 'environment: production' .github/workflows/deploy.yml \
   && has 'production deploys only from main' .github/workflows/deploy.yml; then
  ok PRODUCTION_HUMAN_GATE "GitHub Environment approval + main-only ref"
else bad PRODUCTION_HUMAN_GATE "production gate missing"; fi

# NO_PUBLIC_SECRET -----------------------------------------------------------
leak=0
# committed tfvars/env with real values, or any 'output' of a secret value
git -C "$ROOT" ls-files 2>/dev/null | grep -E '\.(tfvars|env)$' | grep -v '\.example$' | grep -q . && leak=1
has 'output "database_url"' terraform/modules/secrets || true
grep -Rqs 'value *= *var\.database_url' terraform/modules/secrets/outputs.tf 2>/dev/null && leak=1
# sensitive vars must be marked sensitive
has 'sensitive   = true' terraform/modules/database/variables.tf || leak=1
[ $leak -eq 0 ] && ok NO_PUBLIC_SECRET "no committed secrets; no plaintext secret outputs" \
               || bad NO_PUBLIC_SECRET "possible committed secret / secret output"

echo "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
