#!/bin/bash
# Nightly backup of the Supabase project "AION EMPIRE SYSTEM" (qbahthzqvxytfgobgtxa).
# The org is on the free plan, which has no platform backups, so this is the only copy.
# The connection string lives in /root/.backup-secrets/supabase-db.env (0600, written by
# /root/set-supabase-backup-url.sh) and reaches pg_dump through docker --env-file, so the
# password never appears on a command line. Same GPG -> B2 -> checksum pipeline as the
# other jobs (common.sh). Retention: supabase/ keeps 30 days.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

ENV_FILE="$SECRETS_DIR/supabase-db.env"
PREFIX="supabase/${RUN_STAMP}"
LABEL="supabase"
OUT="$STAGING_DIR/postgres-${LABEL}-${RUN_STAMP}.dump"

if [ ! -r "$ENV_FILE" ]; then
    alert_failure "supabase postgres" "missing $ENV_FILE — run /root/set-supabase-backup-url.sh"
    exit 1
fi

log_info "Dumping ${LABEL} (remote, pg_dump 17 in a container)..."
# Supabase runs Postgres 17; the host pg_dump is older and refuses newer servers.
if docker run --rm --env-file "$ENV_FILE" postgres:17 \
        sh -c 'exec pg_dump "$SUPABASE_DB_URL" -F c' > "$OUT" 2>>"$LOG_FILE"; then
    if [ ! -s "$OUT" ]; then
        rm -f "$OUT"
        alert_failure "supabase postgres" "dump produced an empty file. Check ${LOG_FILE}."
        exit 1
    fi
    if encrypt_upload_verify "$OUT" "${PREFIX}/postgres-${LABEL}.dump"; then
        log_info "${LABEL} backup complete"
        alert_success "supabase postgres" "dumped, encrypted, uploaded, and checksum-verified to b2:${B2_BUCKET}/${PREFIX}/postgres-${LABEL}.dump.gpg"
    else
        alert_failure "supabase postgres" "encrypt/upload/verify failed. Check ${LOG_FILE}."
        exit 1
    fi
else
    rm -f "$OUT"
    alert_failure "supabase postgres" "pg_dump failed. Check ${LOG_FILE} on the VPS."
    exit 1
fi

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
prune_window supabase 720

exit 0
