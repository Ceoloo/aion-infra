#!/usr/bin/env bash
# ============================================================================
# monitor-runtime.sh — detect aion-runtime failure independently of the
# runtime itself, so an outage pages an operator instead of running silently.
# ============================================================================
# Built in response to the 2026-09-14 incident (aion-infra#12): aion-runtime
# crash-looped for ~6 days with zero alerting. This script is meant to be run
# on a short interval BY THE HOST (systemd timer — see providers/vps/system/
# aion-monitor.{service,timer}), not inside any AION container, so it has no
# dependency on aion-runtime being up, reachable, or even existing.
#
# Two independent checks, each with its own debounce/dedup state:
#   1. container  — `docker inspect` on the target container: missing, not
#                    running, unhealthy, or restart-count climbing on the
#                    SAME container instance (a recreate — new Created
#                    timestamp — resets the counter baseline, it does not
#                    reset to "everything is fine").
#   2. external   — HTTP GET of the public health endpoint (through Traefik,
#                    the same path a real caller uses). Separate from #1 so a
#                    DB-down 503 (container fine, dependency not) is
#                    distinguishable from the container itself being down.
# A third condition — the monitor being UNABLE to observe (e.g. the Docker
# socket itself is unreachable) — is reported as its own failure, not
# silently treated as "container is fine".
#
# State (survives restarts, and container recreation is detected and does
# NOT falsely count as "still failing since before"):
#   STATE_FILE (default /var/lib/aion-monitor/state.json)
#
# Config — all via env, normally sourced by the systemd unit from
# /opt/aion/.env.monitor (root 0600; separate from /opt/aion/.env so this
# has no access to deploy/runtime secrets):
#   CONTAINER_NAME        default aion-aion-runtime-1
#   HEALTH_URL             e.g. https://runtime.srv1655818.hstgr.cloud/health/ready
#   BAD_THRESHOLD          consecutive bad polls before alerting (default 3)
#   GOOD_THRESHOLD         consecutive good polls before recovery notice (default 2)
#   RESTART_JUMP_THRESHOLD RestartCount jump within one poll, same instance,
#                          treated as a crash-loop signal even if momentarily
#                          "running" (default 2)
#   RE_ALERT_SECONDS       re-notify cadence while an incident stays open
#                          (default 1800 = 30 min; 0 disables repeats)
#   ALERT_WEBHOOK_URL      POST target for notifications. Unset = log-only
#                          (no external send) — this is a valid, honest
#                          state, not an error, until a destination is
#                          authorized.
#   ALERT_FORMAT           slack (default) | ntfy | raw — payload shape
#
# Never prints secret values (there are none in this script's inputs beyond
# the webhook URL itself, which is only ever used as a curl target, never
# logged).
set -uo pipefail  # deliberately NOT -e: one failed check must not kill the
                   # process before it evaluates/logs the OTHER check.

CONTAINER_NAME="${CONTAINER_NAME:-aion-aion-runtime-1}"
HEALTH_URL="${HEALTH_URL:-}"
STATE_FILE="${STATE_FILE:-/var/lib/aion-monitor/state.json}"
BAD_THRESHOLD="${BAD_THRESHOLD:-3}"
GOOD_THRESHOLD="${GOOD_THRESHOLD:-2}"
RESTART_JUMP_THRESHOLD="${RESTART_JUMP_THRESHOLD:-2}"
RE_ALERT_SECONDS="${RE_ALERT_SECONDS:-1800}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_FORMAT="${ALERT_FORMAT:-slack}"

NOW="$(date -u +%s)"
NOW_ISO="$(date -u -Iseconds)"

mkdir -p "$(dirname "${STATE_FILE}")"
[ -f "${STATE_FILE}" ] || echo '{}' > "${STATE_FILE}"

log() {  # log level message operation [extra_json]
  local level="$1" message="$2" operation="$3" extra="${4:-}"
  [ -z "${extra}" ] && extra='{}'
  jq -nc --arg ts "${NOW_ISO}" --arg level "${level}" --arg service "aion-monitor" \
    --arg message "${message}" --arg operation "${operation}" --argjson extra "${extra}" \
    '{timestamp:$ts, level:$level, service:$service, message:$message, operation:$operation} + $extra'
}

notify() {  # notify title body severity(warning|critical|info)
  local title="$1" body="$2" severity="$3"
  log "$([ "${severity}" = info ] && echo info || echo error)" "${title}" "alert" \
    "$(jq -nc --arg body "${body}" --arg severity "${severity}" '{body:$body, severity:$severity}')"
  if [ -z "${ALERT_WEBHOOK_URL}" ]; then
    log "warn" "no ALERT_WEBHOOK_URL configured — alert logged only, not delivered" "alert_undelivered" "{}"
    return 0
  fi
  local ntfy_priority="default"
  [ "${severity}" = "critical" ] && ntfy_priority="high"
  local ok=1
  case "${ALERT_FORMAT}" in
    ntfy)
      # ntfy.sh wants a plain-text body + Title/Priority headers, not JSON
      # (same convention the existing /opt/aion-backup notify() uses).
      curl -fsS --max-time 10 \
        -H "Title: ${title}" -H "Priority: ${ntfy_priority}" \
        -d "${body}" "${ALERT_WEBHOOK_URL}" >/dev/null 2>&1
      ok=$?
      ;;
    raw)
      curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "${title}" --arg b "${body}" --arg ts "${NOW_ISO}" '{title:$t, body:$b, timestamp:$ts}')" \
        "${ALERT_WEBHOOK_URL}" >/dev/null 2>&1
      ok=$?
      ;;
    slack|*)
      curl -fsS --max-time 10 -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg t "${title}" --arg b "${body}" '{text: ($t + "\n" + $b)}')" \
        "${ALERT_WEBHOOK_URL}" >/dev/null 2>&1
      ok=$?
      ;;
  esac
  if [ "${ok}" = "0" ]; then
    log "info" "alert delivered" "alert_delivered" "{}"
  else
    log "error" "alert delivery FAILED (webhook unreachable/rejected)" "alert_delivery_failed" "{}"
  fi
}

state_get() { jq -r "${1} // empty" "${STATE_FILE}" 2>/dev/null; }
state_set() {  # state_set '<jq filter>' [extra jq args (--arg x y, --argjson a b), then filter is $1]
  # Filter is always the LAST arg so callers can prepend --arg/--argjson pairs.
  local tmp; tmp="$(mktemp)"
  local nargs=$#
  local filter="${@: -1}"
  jq "${@:1:$((nargs-1))}" "${filter}" "${STATE_FILE}" > "${tmp}" && mv "${tmp}" "${STATE_FILE}"
}

# ── evaluate one named check's debounced state machine ──────────────────────
# args: check_name is_bad_now(0/1) headline_if_bad headline_if_recovered
evaluate_check() {
  local name="$1" is_bad="$2" bad_headline="$3" recover_headline="$4"
  local prefix=".${name}"
  local cbad cgood active last_alert
  cbad="$(state_get "${prefix}.consecutive_bad // 0")"; cbad="${cbad:-0}"
  cgood="$(state_get "${prefix}.consecutive_good // 0")"; cgood="${cgood:-0}"
  active="$(state_get "${prefix}.alert_active // false")"; active="${active:-false}"
  last_alert="$(state_get "${prefix}.last_alert_at // 0")"; last_alert="${last_alert:-0}"

  if [ "${is_bad}" = "1" ]; then
    cbad=$((cbad + 1)); cgood=0
  else
    cgood=$((cgood + 1)); cbad=0
  fi

  state_set "${prefix}.consecutive_bad = ${cbad} | ${prefix}.consecutive_good = ${cgood}"

  if [ "${is_bad}" = "1" ] && [ "${cbad}" -ge "${BAD_THRESHOLD}" ]; then
    if [ "${active}" != "true" ]; then
      notify "AION ${name} check FAILING" "${bad_headline} (${cbad} consecutive bad polls)" "critical"
      state_set "${prefix}.alert_active = true | ${prefix}.last_alert_at = ${NOW} | ${prefix}.first_bad_at = (${prefix}.first_bad_at // ${NOW})"
    elif [ "${RE_ALERT_SECONDS}" != "0" ] && [ "$((NOW - last_alert))" -ge "${RE_ALERT_SECONDS}" ]; then
      notify "AION ${name} check STILL FAILING" "${bad_headline} (ongoing, ${cbad} consecutive bad polls)" "critical"
      state_set "${prefix}.last_alert_at = ${NOW}"
    else
      log "warn" "${bad_headline}" "${name}_check_bad" "$(jq -nc --argjson n "${cbad}" '{consecutive_bad:$n}')"
    fi
  elif [ "${is_bad}" = "0" ] && [ "${cgood}" -ge "${GOOD_THRESHOLD}" ] && [ "${active}" = "true" ]; then
    notify "AION ${name} check RECOVERED" "${recover_headline}" "info"
    state_set "${prefix}.alert_active = false | ${prefix}.first_bad_at = null"
  else
    log "info" "${name} check ok" "${name}_check_ok" "{}"
  fi
}

# ── 1) container check ───────────────────────────────────────────────────────
INSPECT="$(docker inspect "${CONTAINER_NAME}" 2>&1)"
INSPECT_RC=$?

if [ "${INSPECT_RC}" != "0" ]; then
  if echo "${INSPECT}" | grep -qi "no such object\|no such container"; then
    log "error" "container ${CONTAINER_NAME} does not exist" "container_missing" "{}"
    evaluate_check container 1 "container ${CONTAINER_NAME} is MISSING (not found by Docker)" ""
  else
    # Monitor cannot observe its target at all (daemon down, permissions,
    # etc.) — this is its own failure mode, tracked separately so it is
    # never confused with "the container is fine".
    log "error" "cannot observe ${CONTAINER_NAME} — docker inspect failed" "observe_failed" \
      "$(jq -nc --arg err "$(echo "${INSPECT}" | head -c 300)" '{error:$err}')"
    evaluate_check observe 1 "monitor cannot reach the Docker daemon to check ${CONTAINER_NAME}" "monitor can reach the Docker daemon again"
  fi
else
  evaluate_check observe 0 "" "monitor can reach the Docker daemon again"

  STATUS="$(echo "${INSPECT}" | jq -r '.[0].State.Status')"
  HEALTH="$(echo "${INSPECT}" | jq -r '.[0].State.Health.Status // "none"')"
  RESTARTS="$(echo "${INSPECT}" | jq -r '.[0].RestartCount')"
  CREATED="$(echo "${INSPECT}" | jq -r '.[0].Created')"

  PREV_CREATED="$(state_get '.container.last_created')"
  PREV_RESTARTS="$(state_get '.container.last_restart_count // 0')"; PREV_RESTARTS="${PREV_RESTARTS:-0}"

  if [ -n "${PREV_CREATED}" ] && [ "${PREV_CREATED}" != "${CREATED}" ]; then
    log "info" "container recreated (new instance) — resetting baseline" "container_recreated" \
      "$(jq -nc --arg prev "${PREV_CREATED}" --arg now "${CREATED}" '{previous_created:$prev, new_created:$now}')"
    state_set '.container.consecutive_bad = 0 | .container.consecutive_good = 0'
    PREV_RESTARTS=0
  fi

  RESTART_JUMP=$((RESTARTS - PREV_RESTARTS))
  [ "${RESTART_JUMP}" -lt 0 ] && RESTART_JUMP=0  # defensive; shouldn't happen same-instance

  BAD=0
  REASON=""
  case "${STATUS}" in
    running)
      if [ "${HEALTH}" = "unhealthy" ]; then BAD=1; REASON="running but unhealthy"; fi
      ;;
    restarting) BAD=1; REASON="stuck restarting" ;;
    exited|dead) BAD=1; REASON="status=${STATUS}" ;;
    *) BAD=1; REASON="unexpected status=${STATUS}" ;;
  esac
  if [ "${RESTART_JUMP}" -ge "${RESTART_JUMP_THRESHOLD}" ]; then
    BAD=1; REASON="${REASON:+${REASON}; }restart count jumped by ${RESTART_JUMP} since last poll (same instance)"
  fi

  state_set --arg created "${CREATED}" --argjson restarts "${RESTARTS}" \
    '.container.last_created = $created | .container.last_restart_count = $restarts'

  evaluate_check container "${BAD}" \
    "aion-runtime container ${CONTAINER_NAME}: ${REASON} (status=${STATUS} health=${HEALTH} restarts=${RESTARTS})" \
    "aion-runtime container ${CONTAINER_NAME} is running and healthy again (restarts=${RESTARTS})"
fi

# ── 2) external health-endpoint check ───────────────────────────────────────
if [ -n "${HEALTH_URL}" ]; then
  HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "${HEALTH_URL}" 2>/dev/null)"
  [ -z "${HTTP_CODE}" ] && HTTP_CODE="000"
  if [ "${HTTP_CODE}" = "200" ]; then
    evaluate_check external 0 "" "external ${HEALTH_URL} is returning 200 again"
  else
    evaluate_check external 1 "external ${HEALTH_URL} returned HTTP ${HTTP_CODE} (expected 200)" ""
  fi
else
  log "warn" "HEALTH_URL not configured — external check skipped" "external_check_skipped" "{}"
fi
