#!/usr/bin/env bash
# ============================================================================
# portability-check.sh — cross-profile provider-neutrality (amendment §29, §37).
# ============================================================================
# After ADR-002 the runtime host lives in the aion-runtime repo, which owns the
# runtime-SOURCE portability checks (no cloud SDK, neutral logging/health/config).
# This script keeps the aion-infra-scoped invariants: all provider profiles
# consume the SAME aion-runtime image and the SAME aion-data migration entrypoint,
# aion-infra builds NO image, and provider tech stays confined to providers/.
set -uo pipefail
cd "$(dirname "$0")/.."
PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %-32s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %-32s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
absent() { ! grep -RInE "$1" $2 >/dev/null 2>&1; }
present() { grep -RqsE "$1" $2; }

IMG='ghcr.io/ceoloo/aion-runtime'
echo "== AION infra portability verification =="

# PROVIDER_NEUTRAL_RUNTIME_CONTRACT -----------------------------------------
[ -f contracts/deployment-contract.md ] && present 'provider-neutral' contracts/deployment-contract.md \
  && ok PROVIDER_NEUTRAL_RUNTIME_CONTRACT "deployment contract present" \
  || bad PROVIDER_NEUTRAL_RUNTIME_CONTRACT "deployment contract missing"

# FIXTURE_REMOVED — aion-infra no longer hosts the runtime app (ADR-002) -----
if [ ! -d runtime ] && [ "$(find . -name Dockerfile -not -path './*/node_modules/*' 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  ok FIXTURE_REMOVED "no runtime/ app and no Dockerfile in aion-infra"
else bad FIXTURE_REMOVED "aion-infra still contains a runtime app / Dockerfile"; fi

# INFRA_BUILDS_NO_IMAGE — pipelines consume, never build ---------------------
if absent 'docker build|build-push-action|context: runtime' .github; then
  ok INFRA_BUILDS_NO_IMAGE "no image build in aion-infra CI (consumes only)"
else bad INFRA_BUILDS_NO_IMAGE "an aion-infra workflow builds an image"; fi

# CONSUMES_AION_RUNTIME_IMAGE — every profile references the one image -------
vps=$(present "$IMG" providers/vps && echo 1 || echo 0)
aws=$(present "$IMG" providers/aws/terraform && echo 1 || echo 0)
gcp=$(present "$IMG" providers/gcp/terraform && echo 1 || echo 0)
if [ "$vps$aws$gcp" = "111" ]; then
  ok CONSUMES_AION_RUNTIME_IMAGE "VPS + AWS + GCP all reference $IMG"
else bad CONSUMES_AION_RUNTIME_IMAGE "a profile does not reference the aion-runtime image (vps=$vps aws=$aws gcp=$gcp)"; fi

# SAME_AION_DATA_MIGRATIONS — every profile runs the migrate entrypoint ------
if present 'node dist/migrate.js' providers/vps/scripts/deploy.sh \
   && present 'node.*dist/migrate.js' providers/aws/terraform/main.tf \
   && present 'node.*dist/migrate.js' providers/gcp/terraform/modules/runtime/main.tf; then
  ok SAME_AION_DATA_MIGRATIONS "all profiles run the aion-runtime migrate entrypoint"
else bad SAME_AION_DATA_MIGRATIONS "a profile forks migrations"; fi

# PROVIDER_NEUTRAL_HEALTH — same endpoints wired by every profile ------------
gcp_h=$(present '/health/(live|ready)' providers/gcp/terraform/modules/runtime/main.tf && echo 1 || echo 0)
aws_h=$(present '/health/ready' providers/aws/terraform/main.tf && echo 1 || echo 0)
vps_h=$(present '/health/(ready|live)' providers/vps && echo 1 || echo 0)
[ "$gcp_h$aws_h$vps_h" = "111" ] \
  && ok PROVIDER_NEUTRAL_HEALTH "same /health endpoints wired by all profiles" \
  || bad PROVIDER_NEUTRAL_HEALTH "health endpoints diverge across profiles"

# GCP_PROFILE_ISOLATED — provider tech confined to providers/ ----------------
absent 'google_[a-z]|aws_[a-z]|@google-cloud|@aws-sdk' contracts \
  && ok PROVIDER_TECH_CONFINED "no provider TF identifiers/SDKs in the contract" \
  || bad PROVIDER_TECH_CONFINED "provider tech leaked into the contract"

# Profiles present ----------------------------------------------------------
[ -f providers/vps/docker-compose.yml ] && ok VPS_DEPLOYMENT_PROFILE "compose + proxy + scripts" || bad VPS_DEPLOYMENT_PROFILE "VPS incomplete"
[ -f providers/aws/terraform/main.tf ] && ok AWS_DEPLOYMENT_MAPPING "AWS terraform + architecture" || bad AWS_DEPLOYMENT_MAPPING "AWS incomplete"
[ -d providers/gcp/terraform ] && ok GCP_DEPLOYMENT_PROFILE "GCP terraform present" || bad GCP_DEPLOYMENT_PROFILE "GCP incomplete"

echo "== $PASS passed, $FAIL failed =="
[ $FAIL -eq 0 ]
