#!/usr/bin/env bash
# ============================================================================
# smoke-test.sh — non-destructive post-deploy verification (aion-infra §45).
# ============================================================================
# Verifies, without triggering external or destructive actions:
#   1. runtime reachable;
#   2. /health/live and /health/ready return OK (DB reachable);
#   3. the service reports the EXPECTED release SHA (matches what we deployed);
#   4. the schema migration version is the expected one (optional, if psql +
#      a read-only connection are available).
#
# The controlled Core-lifecycle proof runs INSIDE the runtime at boot
# (RUN_SMOKE_ON_BOOT) using a low-risk R0 capability and identifiable test data;
# this script asserts the externally observable signals.
#
# Usage:
#   URL=https://... EXPECTED_SHA=<git-sha> scripts/smoke-test.sh
set -euo pipefail

URL="${URL:?set URL}"
EXPECTED_SHA="${EXPECTED_SHA:-}"
TOKEN="${TOKEN:-}"
if [[ -z "${TOKEN}" ]] && command -v gcloud >/dev/null 2>&1; then
  TOKEN="$(gcloud auth print-identity-token 2>/dev/null || true)"
fi
auth=()
[[ -n "${TOKEN}" ]] && auth=(-H "Authorization: Bearer ${TOKEN}")

fail() { echo "SMOKE FAIL: $1" >&2; exit 1; }

echo "[smoke] 1) runtime reachable + live"
curl -sf "${auth[@]}" "${URL}/health/live" >/dev/null || fail "not reachable / not live"

echo "[smoke] 2) readiness (DB reachable)"
curl -sf "${auth[@]}" "${URL}/health/ready" >/dev/null || fail "not ready (DB?)"

echo "[smoke] 3) release SHA"
body="$(curl -sf "${auth[@]}" "${URL}/")" || fail "release endpoint unreachable"
running_sha="$(printf '%s' "${body}" | sed -n 's/.*"git_sha":"\([^"]*\)".*/\1/p')"
echo "         running git_sha=${running_sha}"
if [[ -n "${EXPECTED_SHA}" && "${running_sha}" != "${EXPECTED_SHA}" ]]; then
  fail "running SHA ${running_sha} != expected ${EXPECTED_SHA}"
fi

echo "[smoke] 4) schema version (optional)"
if [[ -n "${READONLY_DATABASE_URL:-}" ]] && command -v psql >/dev/null 2>&1; then
  latest="$(psql "${READONLY_DATABASE_URL}" -tA -c \
    'SELECT max(version) FROM schema_migrations;' 2>/dev/null || echo '')"
  echo "         latest applied migration=${latest:-<unavailable>}"
  [[ -n "${EXPECTED_MIGRATION:-}" && "${latest}" != "${EXPECTED_MIGRATION}" ]] && \
    fail "schema version ${latest} != expected ${EXPECTED_MIGRATION}"
else
  echo "         skipped (no READONLY_DATABASE_URL / psql)"
fi

echo "[smoke] PASS"
