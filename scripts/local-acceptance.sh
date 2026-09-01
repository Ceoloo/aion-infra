#!/usr/bin/env bash
# ============================================================================
# local-acceptance.sh — run the deployment SEQUENCE against a real PostgreSQL,
# Docker-free (amendment §30, contract §5).
# ============================================================================
# Exercises the provider-neutral deploy sequence end-to-end using host Node and
# the real built runtime artifact — the SAME entrypoints every provider profile
# runs, minus the container/SSH wrappers:
#
#   apply migrations (migrator identity)  → node dist/migrate.js
#   → start runtime (app identity)        → node dist/index.js
#   → readiness check                     → GET /health/ready
#   → smoke test                          → scripts/smoke-test.sh (committed)
#
# This is the local/no-Docker proof of the same flow providers/vps/scripts/
# deploy.sh performs via docker compose. It NEVER receives the migration URL in
# the runtime step.
#
# Required env:
#   MIGRATION_DATABASE_URL   DDL role URL (migrate step only)
#   DATABASE_URL             app role URL (runtime step)
# Optional: PORT (default 8090), GIT_SHA (default 'local'), AION_ENVIRONMENT.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

: "${MIGRATION_DATABASE_URL:?set MIGRATION_DATABASE_URL}"
: "${DATABASE_URL:?set DATABASE_URL}"
PORT="${PORT:-8090}"
export GIT_SHA="${GIT_SHA:-local}"
export SERVICE_VERSION="${SERVICE_VERSION:-0.1.0}"
export BUILD_TIME="${BUILD_TIME:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
export AION_ENVIRONMENT="${AION_ENVIRONMENT:-staging}"
export DATABASE_SSL="${DATABASE_SSL:-false}"

echo "[acceptance] building runtime artifact"
( cd runtime && npm run build >/dev/null 2>&1 )
# The migrate entrypoint reads dist/sql/grants.sql; ship it as the image does.
mkdir -p runtime/dist/sql && cp runtime/sql/grants.sql runtime/dist/sql/grants.sql

echo "[acceptance] 1/4 migrate (migrator identity, fail-closed)"
( cd runtime && MIGRATION_DATABASE_URL="$MIGRATION_DATABASE_URL" DATABASE_SSL="$DATABASE_SSL" \
    node dist/migrate.js )

echo "[acceptance] 2/4 start runtime (app identity — NO migration URL)"
( cd runtime && env -u MIGRATION_DATABASE_URL \
    DATABASE_URL="$DATABASE_URL" PORT="$PORT" RUN_SMOKE_ON_BOOT=true \
    node dist/index.js >"$ROOT/.acceptance-runtime.log" 2>&1 & echo $! >"$ROOT/.acceptance.pid" )
RT_PID="$(cat "$ROOT/.acceptance.pid")"
cleanup() { kill -TERM "$RT_PID" 2>/dev/null || true; wait "$RT_PID" 2>/dev/null || true; rm -f "$ROOT/.acceptance.pid"; }
trap cleanup EXIT

echo "[acceptance] 3/4 readiness"
ready=0
for _ in $(seq 1 40); do
  sleep 0.3
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health/ready" || echo 000)"
  [ "$code" = "200" ] && { ready=1; break; }
done
[ "$ready" = 1 ] || { echo "[acceptance] NOT READY"; cat "$ROOT/.acceptance-runtime.log"; exit 1; }
echo "[acceptance]     ready (HTTP 200)"

echo "[acceptance] 4/4 smoke test (committed scripts/smoke-test.sh)"
URL="http://127.0.0.1:${PORT}" EXPECTED_SHA="$GIT_SHA" scripts/smoke-test.sh

echo "[acceptance] boot self-check result:"
grep -o 'boot_smoke_passed' "$ROOT/.acceptance-runtime.log" | head -1 || true
echo "[acceptance] PASS — migrate → deploy → readiness → smoke"
