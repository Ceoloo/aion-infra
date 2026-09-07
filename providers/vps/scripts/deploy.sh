#!/usr/bin/env bash
# ============================================================================
# deploy.sh — deploy AION on the VPS (run on the server, in the compose dir).
# ============================================================================
# Implements the provider-neutral deployment sequence (contract §5) for the VPS:
#   pull immutable image → apply migrations (FAIL-CLOSED) → roll runtime →
#   readiness → smoke. The migration one-shot is the ONLY thing that receives
#   MIGRATION_DATABASE_URL; the long-running runtime never does.
#
# OPS-001 edge: Traefik on the host routes AION_DOMAIN → aion-runtime:8080.
# This script does NOT start a second edge proxy. Optional legacy Caddy:
#   AION_EDGE=caddy ./scripts/deploy.sh
#
# Usage (on the VPS):  cd /opt/aion && ./deploy.sh
#   Env: AION_COMPOSE_DIR (default .), AION_LOCAL_DB=1 to also start local Postgres.
set -euo pipefail
cd "${AION_COMPOSE_DIR:-.}"

[ -f .env ] || { echo "missing .env (root-owned 0600) — see .env.example" >&2; exit 1; }
# Load config for this script (compose reads .env itself for interpolation).
set -a; . ./.env; set +a
: "${MIGRATION_DATABASE_URL:?set MIGRATION_DATABASE_URL in .env}"
: "${AION_DOMAIN:?set AION_DOMAIN in .env}"
: "${AION_IMAGE:?set AION_IMAGE in .env}"

compose() { docker compose "$@"; }

EDGE="${AION_EDGE:-traefik}"
TRAEFIK_NET="${AION_TRAEFIK_NETWORK:-traefik}"

if [ "${EDGE}" = "traefik" ]; then
  if ! docker network inspect "${TRAEFIK_NET}" >/dev/null 2>&1; then
    echo "[deploy] missing Docker network '${TRAEFIK_NET}'" >&2
    echo "         Host Traefik must expose this network. Set AION_TRAEFIK_NETWORK" >&2
    echo "         to the network name Traefik uses (e.g. traefik, proxy, web)." >&2
    exit 1
  fi
  echo "[deploy] edge=traefik network=${TRAEFIK_NET} host=${AION_DOMAIN}"
elif [ "${EDGE}" = "caddy" ]; then
  echo "[deploy] edge=caddy (legacy profile — do not use next to Traefik on :443)"
else
  echo "[deploy] unknown AION_EDGE='${EDGE}' (expected traefik|caddy)" >&2
  exit 1
fi

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
echo "[deploy] applying migrations (migrator identity)"
compose run --rm --no-deps \
  -e MIGRATION_DATABASE_URL="${MIGRATION_DATABASE_URL}" \
  -e AION_ENVIRONMENT="${AION_ENVIRONMENT:-production}" \
  -e DATABASE_SSL="${DATABASE_SSL:-true}" \
  aion-runtime node dist/migrate.js

# ── Roll the runtime (+ optional legacy Caddy) ──────────────────────────────
echo "[deploy] starting runtime"
if [ "${EDGE}" = "caddy" ]; then
  compose --profile caddy up -d aion-runtime caddy
else
  # Detach from any prior caddy profile containers if present.
  compose up -d aion-runtime
  compose --profile caddy stop caddy >/dev/null 2>&1 || true
fi

# ── Readiness (contract §5) ─────────────────────────────────────────────────
echo "[deploy] waiting for readiness"
ready=0
for _ in $(seq 1 30); do
  cid="$(compose ps -q aion-runtime)"
  if [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = healthy ]; then
    echo "[deploy] ready"
    ready=1
    break
  fi
  sleep 2
done
[ "${ready}" = "1" ] || { echo "[deploy] runtime never became healthy" >&2; exit 1; }

# ── Smoke test (in-container, provider-neutral endpoints) ───────────────────
echo "[deploy] smoke test (in-container)"
compose exec -T aion-runtime node -e '
const sha=process.env.GIT_SHA;
fetch("http://127.0.0.1:8080/").then(r=>r.json()).then(b=>{
  if(!b.git_sha){throw new Error("no release info")}
  if(sha&&b.git_sha!==sha){throw new Error("SHA mismatch "+b.git_sha+" != "+sha)}
  return fetch("http://127.0.0.1:8080/health/ready");
}).then(r=>{if(!r.ok)throw new Error("not ready");console.log("smoke OK");})
 .catch(e=>{console.error("SMOKE FAIL",e.message);process.exit(1);});'

# ── Public edge probe (best-effort; DNS/TLS may lag on first boot) ──────────
if [ "${EDGE}" = "traefik" ] && [ "${AION_SKIP_PUBLIC_PROBE:-0}" != "1" ]; then
  echo "[deploy] probing https://${AION_DOMAIN}/health/live (best-effort)"
  if curl -fsS --max-time 15 "https://${AION_DOMAIN}/health/live" >/tmp/aion-live.json 2>/tmp/aion-live.err; then
    echo "[deploy] public live OK"
    cat /tmp/aion-live.json
    echo
  else
    echo "[deploy] public probe not yet OK — check DNS → Traefik → labels" >&2
    cat /tmp/aion-live.err >&2 || true
    echo "[deploy] runtime is healthy internally; fix edge before pointing Vercel at it" >&2
  fi
fi

echo "[deploy] done — ${AION_IMAGE}"
