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
# Two host-Traefik topologies (see providers/vps/README.md):
#   external (default): Traefik runs on its OWN Docker network — that network
#     must already exist; we only attach to it.
#   not external:       Traefik runs with `network_mode: host` (e.g. the
#     Hostinger box) and joins no Docker network. AION then OWNS the edge
#     bridge; a host-network Traefik still routes to the container's IP on it,
#     so we create the bridge here if it is missing.
TRAEFIK_NET_EXTERNAL="${AION_TRAEFIK_NETWORK_EXTERNAL:-true}"

if [ "${EDGE}" = "traefik" ]; then
  if docker network inspect "${TRAEFIK_NET}" >/dev/null 2>&1; then
    :
  elif [ "${TRAEFIK_NET_EXTERNAL}" = "true" ]; then
    echo "[deploy] missing Docker network '${TRAEFIK_NET}'" >&2
    echo "         Traefik runs on its own Docker network — set AION_TRAEFIK_NETWORK" >&2
    echo "         to that name (e.g. traefik, proxy, web). If instead Traefik runs" >&2
    echo "         network_mode: host, set AION_TRAEFIK_NETWORK_EXTERNAL=false and" >&2
    echo "         AION owns the edge bridge (created automatically)." >&2
    exit 1
  else
    echo "[deploy] creating AION-owned edge bridge '${TRAEFIK_NET}' (host-network Traefik)"
    docker network create --driver bridge "${TRAEFIK_NET}" >/dev/null
  fi
  echo "[deploy] edge=traefik network=${TRAEFIK_NET} external=${TRAEFIK_NET_EXTERNAL} host=${AION_DOMAIN}"
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

# ── Record the currently-serving revision so a bad roll can be reverted ─────
# Migration failure already aborts BEFORE this point (previous container keeps
# serving). This covers the other case: the new container starts but fails
# readiness or smoke — we must not leave the bad revision serving (§46, §47).
PREV_CID="$(compose ps -q aion-runtime 2>/dev/null || true)"
PREV_IMAGE=""
PREV_GIT_SHA=""
if [ -n "${PREV_CID}" ]; then
  PREV_IMAGE="$(docker inspect -f '{{.Config.Image}}' "${PREV_CID}" 2>/dev/null || true)"
  PREV_GIT_SHA="$( { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "${PREV_CID}" 2>/dev/null \
                    | sed -n 's/^GIT_SHA=//p' | head -n1; } || true )"
  echo "[deploy] previous runtime: ${PREV_IMAGE:-<unknown>} (GIT_SHA=${PREV_GIT_SHA:-<unknown>})"
fi

roll_runtime() {  # $1 = image ref to run
  AION_IMAGE="$1" compose up -d aion-runtime
}

wait_healthy() {
  for _ in $(seq 1 30); do
    cid="$(compose ps -q aion-runtime)"
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$cid" 2>/dev/null)" = healthy ] && return 0
    sleep 2
  done
  return 1
}

rollback() {
  echo "[deploy] ROLLBACK — restoring ${PREV_IMAGE:-<none>}" >&2
  if [ -n "${PREV_IMAGE}" ] && [ "${PREV_IMAGE}" != "${AION_IMAGE}" ]; then
    # Put .env back so a later manual `docker compose up` does not re-deploy the
    # bad revision (the caller/workflow set these to the new image).
    sed -i "s#^AION_IMAGE=.*#AION_IMAGE=${PREV_IMAGE}#" .env
    sed -i "s#^GIT_SHA=.*#GIT_SHA=${PREV_GIT_SHA:-${PREV_IMAGE##*:}}#" .env
    roll_runtime "${PREV_IMAGE}" || true
    if wait_healthy; then
      echo "[deploy] rollback restored a healthy previous revision (${PREV_IMAGE})" >&2
    else
      echo "[deploy] rollback did NOT reach healthy — MANUAL INTERVENTION REQUIRED" >&2
    fi
  else
    echo "[deploy] no distinct previous image to roll back to — leaving current state" >&2
  fi
  exit 1
}

# ── Roll the runtime (+ optional legacy Caddy) ──────────────────────────────
echo "[deploy] starting runtime → ${AION_IMAGE}"
if [ "${EDGE}" = "caddy" ]; then
  compose --profile caddy up -d aion-runtime caddy
else
  compose up -d aion-runtime
  # Detach any prior caddy-profile container if present.
  compose --profile caddy stop caddy >/dev/null 2>&1 || true
fi

# ── Readiness (contract §5) ─────────────────────────────────────────────────
echo "[deploy] waiting for readiness"
wait_healthy || { echo "[deploy] runtime never became healthy" >&2; rollback; }
echo "[deploy] ready"

# ── Smoke test (in-container, provider-neutral endpoints) ───────────────────
echo "[deploy] smoke test (in-container)"
compose exec -T aion-runtime node -e '
const sha=process.env.GIT_SHA;
fetch("http://127.0.0.1:8080/").then(r=>r.json()).then(b=>{
  if(!b.git_sha){throw new Error("no release info")}
  if(sha&&b.git_sha!==sha){throw new Error("SHA mismatch "+b.git_sha+" != "+sha)}
  return fetch("http://127.0.0.1:8080/health/ready");
}).then(r=>{if(!r.ok)throw new Error("not ready");console.log("smoke OK");})
 .catch(e=>{console.error("SMOKE FAIL",e.message);process.exit(1);});' || rollback

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
