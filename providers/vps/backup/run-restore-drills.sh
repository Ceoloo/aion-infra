#!/bin/bash
# Weekly restore validation: proves the newest backups can actually be restored, not just that they exist.
#   1. runtime hourly tier + config  -> restore-rehearsal-aion.sh <newest config-aion> <newest db>   (clean-host rebuild, compared with prod)
#   2. runtime daily tier            -> restore-test-aion-runtime.sh <newest daily> daily
#   3. Supabase                      -> restore-test-supabase.sh <newest supabase>                  (isolated, no network)
# Success is recorded silently in $STATUS_FILE (no notification). Any failure goes through alert_failure
# (ntfy, high) and a non-zero exit, so systemd's OnFailure alert fires as the independent second path.
# All drills are read-only against production and tear down their containers and plaintext.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
STATUS_DIR=/var/lib/aion-backup
STATUS_FILE="$STATUS_DIR/restore-drills.json"
mkdir -p "$STATUS_DIR"

newest() { rclone lsf "b2:${B2_BUCKET}/$1/" --dirs-only 2>>"$LOG_FILE" | sort | tail -1 | tr -d /; }
# DRILL_*_STAMP overrides exist for testing the failure path; the timer never sets them.
CFG="${DRILL_CONFIG_STAMP:-$(newest config-aion)}"; DB="${DRILL_DB_STAMP:-$(newest db)}"
DAILY="${DRILL_DAILY_STAMP:-$(newest daily)}"; SUPA="${DRILL_SUPABASE_STAMP:-$(newest supabase)}"

declare -A RC DUR
run() {   # run <name> <cmd...>
    local name="$1"; shift; local t0=$SECONDS
    log_info "--- drill $name: $* ---"
    if [ -z "${*: -1}" ]; then RC[$name]=99; log_error "drill $name: no backup found in B2"; DUR[$name]=0; return; fi
    "$@" >>"$LOG_FILE" 2>&1; RC[$name]=$?; DUR[$name]=$((SECONDS - t0))
}
run runtime_hourly_config "$SCRIPT_DIR/restore-rehearsal-aion.sh" "$CFG" "$DB"
run runtime_daily         "$SCRIPT_DIR/restore-test-aion-runtime.sh" "$DAILY" daily
run supabase              "$SCRIPT_DIR/restore-test-supabase.sh" "$SUPA"

FAILED=""; for n in runtime_hourly_config runtime_daily supabase; do [ "${RC[$n]}" = 0 ] || FAILED="$FAILED $n(rc=${RC[$n]})"; done
now="$(date -u +%FT%TZ)"
python3 - "$STATUS_FILE" "$now" "$CFG" "$DB" "$DAILY" "$SUPA" "${RC[runtime_hourly_config]}" "${RC[runtime_daily]}" "${RC[supabase]}" \
    "${DUR[runtime_hourly_config]}" "${DUR[runtime_daily]}" "${DUR[supabase]}" "$LOG_FILE" <<'EOF'
import json, sys
f, now, cfg, db, daily, supa, r1, r2, r3, d1, d2, d3, log = sys.argv[1:]
try: hist = json.load(open(f))
except Exception: hist = {"runs": []}
run = {"at": now, "ok": r1 == r2 == r3 == "0", "log": log, "drills": {
    "runtime_hourly_config": {"stamps": [cfg, db], "rc": int(r1), "seconds": int(d1)},
    "runtime_daily": {"stamp": daily, "rc": int(r2), "seconds": int(d2)},
    "supabase": {"stamp": supa, "rc": int(r3), "seconds": int(d3)}}}
hist["last"] = run
if run["ok"]: hist["last_success"] = now
hist["runs"] = (hist.get("runs", []) + [run])[-52:]
json.dump(hist, open(f, "w"), indent=2)
EOF

if [ -z "$FAILED" ]; then
    log_info "weekly restore drills PASSED (config $CFG, db $DB, daily $DAILY, supabase $SUPA)"   # silent: no notification
    exit 0
fi
alert_failure "weekly restore drill" "FAILED:$FAILED. Backups exist but did not restore cleanly — recovery is NOT currently proven. Stamps: config $CFG, db $DB, daily $DAILY, supabase $SUPA. Status: $STATUS_FILE"
exit 1
