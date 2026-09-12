#!/usr/bin/env bash
# ============================================================================
# verify-p0-runtime-readiness.sh — non-destructive P0 revenue-path readiness.
# ============================================================================
# Probes the live Runtime (OPS-001: Traefik → aion-runtime:8080 → Postgres)
# and prints a secrets-boundary / CORS checklist WITHOUT printing secret values.
# Does NOT deploy, migrate, restart containers, or mutate infrastructure.
#
# Required:
#   URL                  Runtime base URL (e.g. https://runtime.aionsystems.ai)
#
# Optional:
#   TOKEN                Bearer token for authenticated probes (GCP identity token)
#   CHECK_SERVICES=1     Also GET /v1/services (expects JSON; 401/403 OK if auth
#                        required — proves the route exists)
#   CORS_ORIGIN          If set, OPTIONS /v1/services with this Origin and assert
#                        Access-Control-Allow-Origin echoes it
#   COPILOT_URL          If set, also probe Copilot /health/live + /health/ready
#   ENV_FILE             Path to a local env file — only presence of keys is
#                        checked (values never printed). Use a redacted copy or
#                        the server's /opt/aion/.env when you have access.
#   STRICT_ENV=1         Fail if ENV_FILE / process env is missing required keys
#                        for the Runtime path (GHL_*, DATABASE_URL, AION_CORS_ORIGINS)
#
# Usage:
#   URL=https://runtime.example scripts/verify-p0-runtime-readiness.sh
#   URL=… CHECK_SERVICES=1 CORS_ORIGIN=https://aion-operator-console.vercel.app \
#     scripts/verify-p0-runtime-readiness.sh
# ============================================================================
set -euo pipefail

URL="${URL:?set URL to the Runtime base URL (no trailing slash preferred)}"
URL="${URL%/}"
TOKEN="${TOKEN:-}"
CHECK_SERVICES="${CHECK_SERVICES:-0}"
CORS_ORIGIN="${CORS_ORIGIN:-}"
COPILOT_URL="${COPILOT_URL:-}"
COPILOT_URL="${COPILOT_URL%/}"
ENV_FILE="${ENV_FILE:-}"
STRICT_ENV="${STRICT_ENV:-0}"

PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$1"; WARN=$((WARN + 1)); }
info() { printf '  \033[36mINFO\033[0m  %s\n' "$1"; }

if [[ -z "${TOKEN}" ]] && command -v gcloud >/dev/null 2>&1; then
  TOKEN="$(gcloud auth print-identity-token 2>/dev/null || true)"
fi
auth=()
[[ -n "${TOKEN}" ]] && auth=(-H "Authorization: Bearer ${TOKEN}")

TMPDIR_HC="$(mktemp -d)"
trap 'rm -rf "${TMPDIR_HC}"' EXIT
BODY="${TMPDIR_HC}/body"

http_get() {
  local path="$1"
  local code
  # curl may still write %{http_code}=000 on connect failure and exit non-zero;
  # do not append another 000 via `|| echo`.
  code="$(curl -sS -o "${BODY}" -w '%{http_code}' --connect-timeout 10 --max-time 30 \
    "${auth[@]}" "${URL}${path}" 2>/dev/null)" || true
  [[ -z "${code}" ]] && code=000
  printf '%s' "${code}"
}

echo "== AION P0 Runtime readiness (non-destructive) =="
echo "   target: ${URL}"
echo

# ── 1) Health probes ─────────────────────────────────────────────────────────
echo "-- Health"
code_live="$(http_get /health/live)"
if [[ "${code_live}" == "200" ]]; then
  ok "GET /health/live → 200"
else
  bad "GET /health/live → HTTP ${code_live} (expected 200)"
fi

code_ready="$(http_get /health/ready)"
if [[ "${code_ready}" == "200" ]]; then
  ok "GET /health/ready → 200 (DB reachable)"
else
  bad "GET /health/ready → HTTP ${code_ready} (expected 200; 503 = DB down)"
fi

# ── 2) Release identity JSON at / ────────────────────────────────────────────
echo "-- Release identity"
code_root="$(http_get /)"
if [[ "${code_root}" == "200" ]]; then
  if grep -qE '"git_sha"|"service_version"' "${BODY}" 2>/dev/null; then
    # Print only non-secret release fields (truncate).
    snippet="$(tr -d '\n' < "${BODY}" | head -c 280)"
    ok "GET / → 200 JSON release identity"
    info "body: ${snippet}"
  else
    bad "GET / → 200 but body is not release JSON (missing git_sha/service_version)"
  fi
else
  bad "GET / → HTTP ${code_root} (expected 200 release JSON)"
fi

# ── 3) Optional /v1/services ─────────────────────────────────────────────────
if [[ "${CHECK_SERVICES}" == "1" ]]; then
  echo "-- Optional /v1/services"
  code_svc="$(http_get /v1/services)"
  case "${code_svc}" in
    200)
      if head -c 1 "${BODY}" | grep -q '[{\[]'; then
        ok "GET /v1/services → 200 JSON"
      else
        warn "GET /v1/services → 200 but body does not look like JSON"
      fi
      ;;
    401|403)
      ok "GET /v1/services → ${code_svc} (route present; auth required — expected without tenant headers)"
      ;;
    404)
      bad "GET /v1/services → 404 (route missing on this Runtime)"
      ;;
    000)
      bad "GET /v1/services → unreachable"
      ;;
    *)
      warn "GET /v1/services → HTTP ${code_svc} (route may exist; inspect Runtime logs)"
      ;;
  esac
else
  info "skip /v1/services (set CHECK_SERVICES=1 to probe)"
fi

# ── 4) Optional CORS preflight (Console ↔ Runtime coupling) ──────────────────
if [[ -n "${CORS_ORIGIN}" ]]; then
  echo "-- CORS preflight (Operator Console origin)"
  cors_code="$(curl -sS -o "${BODY}" -w '%{http_code}' --connect-timeout 10 --max-time 30 \
    -X OPTIONS "${URL}/v1/services" \
    -H "Origin: ${CORS_ORIGIN}" \
    -H "Access-Control-Request-Method: GET" \
    -H "Access-Control-Request-Headers: content-type,authorization,x-aion-tenant-id" \
    -D "${TMPDIR_HC}/headers" 2>/dev/null)" || true
  [[ -z "${cors_code}" ]] && cors_code=000
  acao="$(grep -i '^access-control-allow-origin:' "${TMPDIR_HC}/headers" 2>/dev/null \
    | head -1 | sed 's/[Rr]eceive.*//;s/^[^:]*:[[:space:]]*//;s/[[:space:]]*$//' || true)"
  if [[ "${cors_code}" == "000" ]]; then
    bad "OPTIONS /v1/services unreachable"
  elif [[ -n "${acao}" && "${acao}" == "${CORS_ORIGIN}" ]]; then
    ok "CORS Allow-Origin echoes ${CORS_ORIGIN} (HTTP ${cors_code})"
  elif [[ -z "${acao}" ]]; then
    bad "CORS: no Access-Control-Allow-Origin for Origin=${CORS_ORIGIN} (check AION_CORS_ORIGINS + Traefik aion-cors)"
  else
    bad "CORS: Allow-Origin='${acao}' != requested Origin='${CORS_ORIGIN}'"
  fi
else
  info "skip CORS preflight (set CORS_ORIGIN=https://…vercel.app to probe)"
fi

# ── 5) Optional Copilot health ───────────────────────────────────────────────
if [[ -n "${COPILOT_URL}" ]]; then
  echo "-- Revenue Copilot (optional profile)"
  for path in /health/live /health/ready; do
    c="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 30 \
      "${COPILOT_URL}${path}" 2>/dev/null)" || true
    [[ -z "${c}" ]] && c=000
    if [[ "${c}" == "200" ]]; then
      ok "Copilot GET ${path} → 200"
    else
      bad "Copilot GET ${path} → HTTP ${c}"
    fi
  done
else
  info "skip Copilot health (set COPILOT_URL=https://copilot… to probe)"
fi

# ── 6) Env presence checklist (never print values) ───────────────────────────
echo "-- Required env vars (names only — values NEVER printed)"
cat <<'EOF'
  Runtime (aion-runtime) must receive:
    DATABASE_URL              app role (aion_app) — DML only; NEVER migrator
    AION_ENVIRONMENT          local|staging|production
    AION_CORS_ORIGINS         exact Console (+ optional Copilot) origins, comma-separated
    GHL_API_KEY               GoHighLevel PIT (secret) — Runtime only
    GHL_LOCATION_ID           GHL location (config)
    GHL_API_VERSION           e.g. 2021-07-28 (config)
  Migration one-shot ONLY (never long-running Runtime):
    MIGRATION_DATABASE_URL    migrator role (aion_migrator) — DDL
  Revenue Copilot profile (optional; OpenRouter stays OFF Runtime):
    OPENROUTER_API_KEY        secret — Copilot only
    OPENROUTER_MODEL          config
    AION_RUNTIME_URL          durable Runtime base for /v1/commands
    COPILOT_IMAGE / COPILOT_DOMAIN
  Browser (Vercel Operator Console) — PUBLIC build-time only:
    VITE_AION_RUNTIME_URL     → Runtime HTTPS URL
    VITE_* never carries GHL_*, OPENROUTER_*, or DATABASE_* secrets
EOF

presence_source=""
declare -A PRESENT=()

mark_present() {
  local key="$1"
  PRESENT["${key}"]=1
}

if [[ -n "${ENV_FILE}" ]]; then
  if [[ ! -f "${ENV_FILE}" ]]; then
    bad "ENV_FILE=${ENV_FILE} not found"
  else
    presence_source="ENV_FILE"
    # Parse KEY=… lines; record key names only.
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[[:space:]]*# ]] && continue
      [[ "${line}" =~ ^[[:space:]]*$ ]] && continue
      if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)= ]]; then
        mark_present "${BASH_REMATCH[1]}"
      fi
    done < "${ENV_FILE}"
    info "checking key presence from ENV_FILE (values not shown)"
  fi
else
  presence_source="process-env"
  for k in DATABASE_URL MIGRATION_DATABASE_URL AION_CORS_ORIGINS \
           GHL_API_KEY GHL_LOCATION_ID GHL_API_VERSION \
           OPENROUTER_API_KEY OPENROUTER_MODEL AION_RUNTIME_URL \
           AION_ENVIRONMENT COPILOT_IMAGE; do
    if [[ -n "${!k:-}" ]]; then
      mark_present "${k}"
    fi
  done
  info "checking key presence from process environment (set ENV_FILE=/path for file check)"
fi

check_key() {
  local key="$1" role="$2" required="$3"
  if [[ -n "${PRESENT[${key}]:-}" ]]; then
    ok "env ${key} present (${role}) [${presence_source}]"
  elif [[ "${required}" == "1" && "${STRICT_ENV}" == "1" ]]; then
    bad "env ${key} MISSING (${role}) — required under STRICT_ENV=1"
  elif [[ "${required}" == "1" ]]; then
    warn "env ${key} not visible here (${role}) — confirm on host / secret store"
  else
    info "env ${key} not visible (${role}, optional)"
  fi
}

echo "-- Env presence results"
check_key DATABASE_URL "Runtime app role" 1
check_key MIGRATION_DATABASE_URL "migrate job only" 1
check_key AION_CORS_ORIGINS "Traefik CORS allowlist" 1
check_key AION_ENVIRONMENT "Runtime" 1
check_key GHL_API_KEY "Runtime CRM (secret)" 1
check_key GHL_LOCATION_ID "Runtime CRM config" 1
check_key GHL_API_VERSION "Runtime CRM config" 0
check_key OPENROUTER_API_KEY "Copilot only (secret)" 0
check_key OPENROUTER_MODEL "Copilot config" 0
check_key AION_RUNTIME_URL "Copilot → Runtime" 0
check_key COPILOT_IMAGE "Copilot profile" 0

echo
echo "== ${PASS} passed, ${FAIL} failed, ${WARN} warnings =="
echo "   Reminder: migrate-before-roll; do NOT AI-auto-deploy production."
if [[ "${FAIL}" -ne 0 ]]; then
  echo "P0 READINESS FAIL" >&2
  exit 1
fi
echo "P0 READINESS OK"
exit 0
