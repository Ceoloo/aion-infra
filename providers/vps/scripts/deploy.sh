#!/usr/bin/env bash
# ============================================================================
# deploy.sh — deploy AION on the VPS (run on the server, in the compose dir).
# ============================================================================
# Implements the provider-neutral deployment sequence (contract §5) for the VPS:
#   pull immutable image → apply migrations (FAIL-CLOSED) → roll runtime →
#   readiness → smoke. The migration one-shot is the ONLY thing that receives
#   MIGRATION_DATABASE_URL; the long-running runtime never does.
#
# Usage (on the VPS):  cd /opt/aion && ./deploy.sh
#   Env: AION_COMPOSE_DIR (default .), AION_LOCAL_DB=1 to also start local Postgres.
set -euo pipefail
cd "${AION_COMPOSE_DIR:-.}"

[ -f .env ] || { echo "missing .env (root-owned 0600) — see .env.example" >&2; exit 1; }
# Load config for this script (compose reads .env itself for interpolation).
set -a; . ./.env; set +a
: "${MIGRATION_DATABASE_URL:?set MIGRATION_DATABASE_URL in .env}"

compose() { docker compose "$@"; }

echo "[deploy] pulling image ${AION_IMAGE}"
compose pull aion-runtime

if [ "${AION_LOCAL_DB:-0}" = "1" ]; then
  echo "[deploy] ensuring local Postgres (Mode A) is up"
  compose --profile local-db up -d postgres
  # wait for health
  for _ in $(seq 1 30); do
    [ "$(compose ps -q postgres | xargs -r docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" = healthy ] && break
    sleep 2
  done
fi

# ── Migrations FIRST, fail-closed (contract §5; §63) ────────────────────────
# A one-shot run of the SAME image with the migrate entrypoint and ONLY the
# migration credential. Non-zero exit here aborts the deploy before the runtime
# is rolled — the currently-running runtime keeps serving.
echo "[deploy] applying migrations (migrator identity)"
compose run --rm --no-deps \
  -e MIGRATION_DATABASE_URL="${MIGRATION_DATABASE_URL}" \
  -e AION_ENVIRONMENT="${AION_ENVIRONMENT:-production}" \
  -e DATABASE_SSL="${DATABASE_SSL:-true}" \
  aion-runtime node dist/migrate.js

# ── Roll the runtime + proxy ────────────────────────────────────────────────
echo "[deploy] starting runtime + proxy"
compose up -d aion-runtime caddy

# ── Readiness (contract §5) ─────────────────────────────────────────────────
echo "[deploy] waiting for readiness"
for _ in $(seq 1 30); do
  cid="$(compose ps -q aion-runtime)"
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = healthy ] && { echo "[deploy] ready"; break; }
  sleep 2
done

# ── Smoke test (in-container, provider-neutral endpoints) ───────────────────
echo "[deploy] smoke test"
compose exec -T aion-runtime node -e '
const sha=process.env.GIT_SHA;
fetch("http://127.0.0.1:8080/").then(r=>r.json()).then(b=>{
  if(!b.git_sha){throw new Error("no release info")}
  if(sha&&b.git_sha!==sha){throw new Error("SHA mismatch "+b.git_sha+" != "+sha)}
  return fetch("http://127.0.0.1:8080/health/ready");
}).then(r=>{if(!r.ok)throw new Error("not ready");console.log("smoke OK");})
 .catch(e=>{console.error("SMOKE FAIL",e.message);process.exit(1);});'

echo "[deploy] done — ${AION_IMAGE}"
