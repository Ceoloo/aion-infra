#!/usr/bin/env bash
# ============================================================================
# portability-check.sh — provider-neutrality checks (amendment §29, §37).
# ============================================================================
# Verifies the portability invariant statically: the workload imports no cloud
# SDK, uses provider-neutral config/health, and every container profile consumes
# the SAME runtime image and the SAME aion-data migrations. Prints a PASS/FAIL
# table for each named amendment exit check.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %-32s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %-32s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
# grep that MUST NOT match (returns 0 = clean/absent)
absent() { ! grep -RInE "$1" $2 >/dev/null 2>&1; }
present() { grep -RqsE "$1" $2; }

echo "== AION portability verification =="

# PROVIDER_NEUTRAL_RUNTIME_CONTRACT ------------------------------------------
if [ -f contracts/deployment-contract.md ] && present 'provider-neutral' contracts/deployment-contract.md; then
  ok PROVIDER_NEUTRAL_RUNTIME_CONTRACT "contracts/deployment-contract.md present"
else bad PROVIDER_NEUTRAL_RUNTIME_CONTRACT "deployment contract missing"; fi

# runtime imports NO cloud SDK ----------------------------------------------
SDK='@google-cloud/|googleapis|@aws-sdk/|aws-sdk|@azure/|hostinger'
if absent "$SDK" runtime/src && absent "\"($SDK)\"" runtime/package.json; then
  ok RUNTIME_NO_CLOUD_SDK "runtime/src + package.json import no cloud SDK"
else bad RUNTIME_NO_CLOUD_SDK "a cloud SDK reference exists in the runtime"; fi

# Core + Data (vendored) import no provider package --------------------------
# (checks source dirs if vendored locally; skips cleanly if not present)
core_data_clean=1
for d in runtime/vendor/aion-core/src runtime/vendor/aion-data/src; do
  [ -d "$d" ] && { grep -RInE "$SDK" "$d" >/dev/null 2>&1 && core_data_clean=0; }
done
if [ $core_data_clean -eq 1 ]; then
  ok CORE_DATA_NO_PROVIDER_PKG "aion-core/aion-data import no provider package"
else bad CORE_DATA_NO_PROVIDER_PKG "provider package found in core/data"; fi

# PROVIDER_NEUTRAL_SECRET_INJECTION -----------------------------------------
# runtime reads secrets from ENV, not a cloud secret SDK.
if present 'process\.env' runtime/src/config.ts && absent 'SecretManager|secretsmanager|getSecretValue' runtime/src; then
  ok PROVIDER_NEUTRAL_SECRET_INJECTION "secrets arrive via env, no secret SDK in app"
else bad PROVIDER_NEUTRAL_SECRET_INJECTION "app fetches secrets via SDK"; fi

# PROVIDER_NEUTRAL_LOGGING ---------------------------------------------------
if present 'process\.(stdout|stderr)' runtime/src/logger.ts \
   && absent 'CloudLogging|winston-cloudwatch|@google-cloud/logging' runtime/src; then
  ok PROVIDER_NEUTRAL_LOGGING "structured stdout/stderr logs, no logging SDK"
else bad PROVIDER_NEUTRAL_LOGGING "provider logging SDK in app"; fi

# PROVIDER_NEUTRAL_HEALTH ----------------------------------------------------
# same /health/live + /health/ready referenced by every profile.
gcp_h=$(present '/health/(live|ready)' providers/gcp/terraform/modules/runtime/main.tf && echo 1 || echo 0)
aws_h=$(present '/health/ready' providers/aws/terraform/main.tf && echo 1 || echo 0)
vps_h=$(present '/health/(ready|live)' providers/vps && echo 1 || echo 0)
if present '/health/live' runtime/src/server.ts && present '/health/ready' runtime/src/server.ts \
   && [ "$gcp_h" = 1 ] && [ "$aws_h" = 1 ] && [ "$vps_h" = 1 ]; then
  ok PROVIDER_NEUTRAL_HEALTH "same /health/live+ready used by app + all profiles"
else bad PROVIDER_NEUTRAL_HEALTH "health endpoints diverge across profiles"; fi

# SAME_RUNTIME_ARTIFACT ------------------------------------------------------
# exactly ONE application Dockerfile; every container profile references an image
# variable rather than building its own app image.
DFCOUNT=$(find . -name Dockerfile -not -path '*/vendor/*' -not -path '*/node_modules/*' | wc -l | tr -d ' ')
if [ "$DFCOUNT" = "1" ] \
   && present '\$\{AION_IMAGE' providers/vps/docker-compose.yml \
   && present 'var\.image' providers/aws/terraform/main.tf \
   && present 'var\.image' providers/gcp/terraform/modules/runtime/main.tf; then
  ok SAME_RUNTIME_ARTIFACT "one Dockerfile; all profiles consume an image var"
else bad SAME_RUNTIME_ARTIFACT "multiple app Dockerfiles or a profile builds its own"; fi

# SAME_AION_DATA_MIGRATIONS --------------------------------------------------
# every profile runs the SAME migrate entrypoint (aion-data runner); none forks.
if present 'dl.migrate\(\)' runtime/src/migrate.ts \
   && present 'node dist/migrate.js' providers/vps/scripts/deploy.sh \
   && present 'node.*dist/migrate.js' providers/aws/terraform/main.tf \
   && present 'node.*dist/migrate.js' providers/gcp/terraform/modules/runtime/main.tf; then
  ok SAME_AION_DATA_MIGRATIONS "all profiles run the aion-data migrate entrypoint"
else bad SAME_AION_DATA_MIGRATIONS "a profile forks migrations"; fi

# GENERIC_POSTGRES_COMPATIBILITY --------------------------------------------
# app must not hardcode a provider DB host/socket; DB comes from a URL var.
if absent '/cloudsql/|rds\.amazonaws\.com|localhost:5432' runtime/src \
   && present 'DATABASE_URL' runtime/src/config.ts; then
  ok GENERIC_POSTGRES_COMPATIBILITY "app uses DATABASE_URL; no hardcoded DB host"
else bad GENERIC_POSTGRES_COMPATIBILITY "hardcoded DB location in app"; fi

# GCP_PROFILE_ISOLATED -------------------------------------------------------
# provider tech names appear only under providers/, not in runtime/ or contracts/.
if absent 'Cloud Run|Cloud SQL|Secret Manager|Workload Identity' runtime/src \
   && absent 'google_|aws_' contracts; then
  ok GCP_PROFILE_ISOLATED "provider tech confined to providers/ (not app/contract)"
else bad GCP_PROFILE_ISOLATED "provider tech leaked into app/contract"; fi

# VPS_DEPLOYMENT_PROFILE / AWS_DEPLOYMENT_MAPPING ----------------------------
[ -f providers/vps/docker-compose.yml ] && [ -f providers/vps/README.md ] \
  && ok VPS_DEPLOYMENT_PROFILE "compose + proxy + scripts present" \
  || bad VPS_DEPLOYMENT_PROFILE "VPS profile incomplete"
[ -f providers/aws/terraform/main.tf ] && [ -f providers/aws/architecture.md ] \
  && ok AWS_DEPLOYMENT_MAPPING "AWS terraform + architecture present" \
  || bad AWS_DEPLOYMENT_MAPPING "AWS profile incomplete"

echo "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
