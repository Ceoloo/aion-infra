#!/usr/bin/env bash
# ============================================================================
# validate-env.sh — validate /opt/aion/.env BEFORE any container recreate.
# ============================================================================
# Closes the exact gap behind the 2026-09-14 aion-runtime incident (see
# aion-infra#12): a required var (AION_GATEWAY_API_KEYS) was present but held
# malformed JSON, the container baked that in at creation, and nothing
# validated it before — or after — the recreate.
#
# Two checks, both delegated to `docker compose config` — the SAME
# dotenv/interpolation resolver that actually builds the container's
# environment — rather than re-implementing dotenv parsing by hand:
#
#   1. Presence of every required var (`${VAR:?msg}` anywhere in the compose
#      file — image, labels, environment, command). `docker compose config`
#      itself already hard-fails on any of these being unset/empty, with
#      Compose's own message naming the var — we just surface that cleanly
#      and non-zero-exit before touching any container.
#   2. JSON-shaped vars (AION_GATEWAY_API_KEYS today; extend JSON_VARS as the
#      identity/config plane grows) actually parse as JSON, checked against
#      each service's *resolved* environment map.
#
# An earlier draft of this script sourced .env with bash (`. .env`), which is
# unsafe — bash interprets `$`, backticks, and quoting inside values, and
# silently corrupted a value that is valid JSON on disk and to Compose.
# Caught by testing this script against the real, known-good production .env
# before shipping it (aion-infra#13) — do not reintroduce shell-sourcing here.
#
# Never prints a resolved secret value — only names, lengths, and pass/fail.
# Run standalone after any manual .env edit, or as a deploy.sh preflight
# (both call this).
#
# Usage:
#   cd /opt/aion && ./scripts/validate-env.sh
#   COMPOSE_FILE=/path/to/docker-compose.yml ./scripts/validate-env.sh
set -euo pipefail

COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
[ -f "${COMPOSE_FILE}" ] || { echo "[validate-env] missing ${COMPOSE_FILE}" >&2; exit 1; }
[ -f ".env" ] || { echo "[validate-env] missing .env in $(pwd)" >&2; exit 1; }

# Vars that must be valid JSON when set (grows as the identity/config plane
# grows — this is the generalized fix, not a one-off patch for one var).
JSON_VARS="AION_GATEWAY_API_KEYS"

echo "[validate-env] resolving via 'docker compose config' (the real interpolation path)"
echo "[validate-env] this alone proves every \${VAR:?...} required var is non-empty"
if ! CONFIG_JSON="$(docker compose -f "${COMPOSE_FILE}" config --format json 2>&1)"; then
  echo "[validate-env] FAIL  required-var check failed — Compose's own error:" >&2
  echo "${CONFIG_JSON}" >&2
  exit 1
fi
echo "  ok    all \${VAR:?...} required vars present and non-empty"

echo "[validate-env] checking JSON-shaped vars parse cleanly"
status=0
CONFIG_JSON="${CONFIG_JSON}" JSON_VARS="${JSON_VARS}" python3 <<'PYEOF' || status=$?
import json, os, sys

config = json.loads(os.environ["CONFIG_JSON"])
json_vars = [v for v in os.environ["JSON_VARS"].split() if v]

# Union of every service's resolved environment (don't assume which service
# declares a given var).
resolved = {}
for svc in config.get("services", {}).values():
    resolved.update(svc.get("environment") or {})

fail = False
for var in json_vars:
    val = resolved.get(var)
    if not val:
        continue  # not set anywhere as a container env var — nothing to check
    try:
        json.loads(val)
        print(f"  ok    {var} is valid JSON (len={len(val)})")
    except Exception as e:
        print(f"  FAIL  {var} is set (len={len(val)}) but is NOT valid JSON — "
              f"this is the exact class of bug that caused the 2026-09-14 outage: {e}", file=sys.stderr)
        fail = True

sys.exit(1 if fail else 0)
PYEOF

if [ "${status}" != "0" ]; then
  echo "[validate-env] FAILED — do not recreate the container until fixed" >&2
  exit 1
fi
echo "[validate-env] PASS — safe to recreate"
