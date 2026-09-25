#!/bin/bash
# Backs up the CURRENT canonical AION execution database: aion_data on
# container aion-postgres-1 (Mode A, /opt/aion). Distinct from this
# directory's existing backup-postgres.sh, which targets the retired
# aion-postgres/aion_memory DB (deleted 2026-09-02 — that line is now
# dead but left as-is, out of scope to remove here) plus the still-live
# Immich DB, which this script does not touch.
#
# Reuses the same common.sh (GPG encrypt -> B2 rclone rcat -> checksum
# verify) already proven end-to-end for this box on 2026-08-11.
#
# Usage: backup-aion-runtime.sh <db|full> <run-stamp>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

MODE="${1:-db}"          # db | daily | full — only affects the B2 destination prefix
STAMP="${2:-$RUN_STAMP}"
PREFIX="${MODE}/${STAMP}"

CONTAINER="aion-postgres-1"
DB="aion_data"
PGUSER="postgres"
LABEL="aion-runtime"

FAILED=0
OUT="$STAGING_DIR/postgres-${LABEL}-${STAMP}.sql"

log_info "Dumping ${LABEL} (${DB} in ${CONTAINER})..."
if docker exec "$CONTAINER" pg_dump -U "$PGUSER" -d "$DB" -F c > "$OUT" 2>>"$LOG_FILE"; then
    if [ ! -s "$OUT" ]; then
        log_error "${LABEL} dump produced an empty file"
        FAILED=1
    elif encrypt_upload_verify "$OUT" "${PREFIX}/postgres-${LABEL}.dump"; then
        log_info "${LABEL} backup complete"
        alert_success "aion-runtime postgres (${MODE})" "aion_data dumped, encrypted, uploaded, and checksum-verified to b2:${B2_BUCKET}/${PREFIX}/postgres-${LABEL}.dump.gpg"
    else
        FAILED=1
    fi
else
    log_error "pg_dump failed for ${LABEL}"
    rm -f "$OUT"
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    alert_failure "aion-runtime postgres (${MODE})" "aion_data dump/encrypt/upload/verify failed. Check ${LOG_FILE} on the VPS."
    exit 1
fi

# Retention: db/ flat 48h window only (deliberately NOT the shared
# prune-backups.sh, which also GFS-prunes full/ — that prefix holds the
# legacy Immich/config/n8n snapshots from Aug-Sep, outside this mission's
# scope. Pruning db/ is safe: those are hourly point-in-time dumps with no
# long-term retention claim by design (full/ dumps cover long-term
# history), and this only touches directories THIS script creates plus any
# equally-stale db/ entries already past their intended 48h lifetime).
prune_window() {   # prune_window <prefix> <max-age-hours>
    local prefix="$1" max_age_hours="$2"
    local stamps now_epoch
    stamps=$(rclone lsf "b2:${B2_BUCKET}/${prefix}/" --dirs-only 2>>"$LOG_FILE") || return 0
    [ -z "$stamps" ] && return 0
    now_epoch=$(date -u +%s)
    while IFS= read -r stamp; do
        stamp="${stamp%/}"
        [ -z "$stamp" ] && continue
        local stamp_epoch age_hours
        stamp_epoch=$(date -u -d "${stamp:0:8} ${stamp:9:2}:${stamp:11:2}:${stamp:13:2}" +%s 2>/dev/null) || continue
        age_hours=$(( (now_epoch - stamp_epoch) / 3600 ))
        if [ "$age_hours" -gt "$max_age_hours" ]; then
            log_info "Pruning expired ${prefix}/${stamp} (age ${age_hours}h)"
            rclone purge "b2:${B2_BUCKET}/${prefix}/${stamp}" 2>>"$LOG_FILE" \
                || log_warn "failed to prune ${prefix}/${stamp}"
        fi
    done <<< "$stamps"
}

# db/ keeps 48h of hourly dumps; daily/ (MODE=daily, aion-backup-runtime-daily.timer)
# keeps 30 days so a problem noticed late still has a clean copy to restore.
if [ "$MODE" = "daily" ]; then
    prune_window daily 720
else
    prune_window db 48
fi

exit 0
