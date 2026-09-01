#!/usr/bin/env bash
# ============================================================================
# health-check.sh — probe a deployed runtime's liveness + readiness.
# ============================================================================
# Non-destructive. Used after deploy and in the runbook (docs/runbook.md →
# "Check health"). Cloud Run requires an identity token for authenticated
# (non-public) services; pass one via TOKEN or let the script mint one with
# gcloud.
#
# Usage:
#   URL=https://aion-staging-runtime-xxxx.run.app scripts/health-check.sh
#   URL=... TOKEN="$(gcloud auth print-identity-token)" scripts/health-check.sh
set -euo pipefail

URL="${URL:?set URL to the runtime base URL}"
TOKEN="${TOKEN:-}"
if [[ -z "${TOKEN}" ]] && command -v gcloud >/dev/null 2>&1; then
  TOKEN="$(gcloud auth print-identity-token 2>/dev/null || true)"
fi

auth=()
[[ -n "${TOKEN}" ]] && auth=(-H "Authorization: Bearer ${TOKEN}")

probe() {
  local path="$1" expect="$2"
  local code
  code="$(curl -s -o /tmp/hc_body -w '%{http_code}' "${auth[@]}" "${URL}${path}" || echo 000)"
  echo "  GET ${path} -> HTTP ${code}"
  cat /tmp/hc_body 2>/dev/null | head -c 400; echo
  [[ "${code}" == "${expect}" ]]
}

echo "[health] ${URL}"
probe /health/live 200
probe /health/ready 200
echo "[health] OK — live and ready"
