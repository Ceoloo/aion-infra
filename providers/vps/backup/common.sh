#!/bin/bash
# Shared helpers for AION backup jobs: logging, alerting, encryption, upload.
# Sourced by run-backup.sh and the individual module scripts.

set -uo pipefail

BACKUP_ROOT="/root/backups"
STAGING_DIR="$BACKUP_ROOT/staging"
LOG_DIR="/opt/aion-backup/logs"
SECRETS_DIR="/root/.backup-secrets"
GNUPGHOME="$SECRETS_DIR/gnupg"
export GNUPGHOME
GPG_RECIPIENT_FILE="$SECRETS_DIR/gnupg/fingerprint.txt"

[ -f "$SECRETS_DIR/b2.env" ] && source "$SECRETS_DIR/b2.env"
[ -f "$SECRETS_DIR/ntfy.env" ] && source "$SECRETS_DIR/ntfy.env"

RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_STAMP="$(date -u +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/backup-${RUN_STAMP}.log"
mkdir -p "$LOG_DIR" "$STAGING_DIR"

# --- logging ---------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$msg" | tee -a "$LOG_FILE" >&2
}
log_info()  { log "INFO"  "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERROR" "$@"; }

# --- alerting ----------------------------------------------------------------
# notify <priority: default|high> <title> <message>
notify() {
    local priority="$1"; local title="$2"; local message="$3"
    if [ -z "${NTFY_TOPIC:-}" ]; then
        log_warn "NTFY_TOPIC not set, skipping push notification: $title"
        return 0
    fi
    curl -s --max-time 15 \
        -H "Title: ${title}" \
        -H "Priority: ${priority}" \
        -d "${message}" \
        "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null \
        || log_warn "Failed to send ntfy notification (network issue?) — see $LOG_FILE for the real failure"
}

alert_failure() {
    local job="$1"; local detail="$2"
    log_error "FAILURE in $job: $detail"
    notify "high" "AION Backup FAILED: $job" "$detail"$'\n'"Host: $(hostname)"$'\n'"Log: $LOG_FILE"
}

alert_success() {
    local job="$1"; local detail="$2"
    notify "default" "AION Backup OK: $job" "$detail"
}

# --- encryption --------------------------------------------------------------
# gpg_encrypt <plaintext-file> -> writes <plaintext-file>.gpg, deletes plaintext
gpg_encrypt() {
    local infile="$1"
    local recipient
    recipient="$(cat "$GPG_RECIPIENT_FILE")"
    if [ ! -f "$infile" ]; then
        log_error "gpg_encrypt: input file missing: $infile"
        return 1
    fi
    gpg --batch --yes --trust-model always \
        --recipient "$recipient" \
        --output "${infile}.gpg" \
        --encrypt "$infile"
    local rc=$?
    if [ $rc -ne 0 ]; then
        log_error "gpg encryption failed for $infile"
        return $rc
    fi
    shred -u "$infile" 2>/dev/null || rm -f "$infile"
    echo "${infile}.gpg"
}

# --- upload --------------------------------------------------------------
# b2_upload <local-file> <remote-subpath>
# rclone_retry <rclone-args...>
# B2/network calls occasionally hit a transient blip (observed: sporadic
# HTTP 403 with an empty/undecodable body on backend auth, which clears up
# on retry). Retry a few times with backoff before giving up for real.
rclone_retry() {
    local attempt rc
    for attempt in 1 2 3; do
        if rclone "$@"; then
            return 0
        fi
        rc=$?
        log_warn "rclone attempt $attempt failed (rc=$rc): rclone $* — retrying..."
        sleep $((attempt * 3))
    done
    return "$rc"
}

b2_upload() {
    local local_file="$1"
    local remote_subpath="$2"
    if [ -z "${B2_BUCKET:-}" ]; then
        log_error "B2_BUCKET not configured"
        return 1
    fi
    # Deliberately `rcat` (unconditional streaming PUT) rather than
    # `copyto`/`copy`: those check the destination first (existence/hash),
    # and that pre-check has been observed to fail with 403 once the
    # account's B2 download-transaction cap is exhausted -- which would
    # otherwise block *new* backups too, not just restores. Destination
    # paths are always unique (timestamp-based), so there's never anything
    # to compare against anyway.
    # Retry loop is hand-rolled (not rclone_retry) so each attempt reopens
    # the file via a fresh `<` redirection at offset 0 -- reusing one
    # stdin fd across retries would resume from wherever a failed attempt
    # left the read pointer, silently truncating the upload.
    local attempt
    for attempt in 1 2 3; do
        if rclone rcat "b2:${B2_BUCKET}/${remote_subpath}" < "$local_file" 2>>"$LOG_FILE"; then
            return 0
        fi
        log_warn "b2_upload attempt $attempt failed for ${remote_subpath} — retrying..."
        sleep $((attempt * 3))
    done
    return 1
}

b2_verify() {
    local local_file="$1"
    local remote_subpath="$2"
    local local_sum remote_sum
    local_sum=$(sha256sum "$local_file" | awk '{print $1}')
    remote_sum=$(rclone_retry cat "b2:${B2_BUCKET}/${remote_subpath}" 2>>"$LOG_FILE" | sha256sum | awk '{print $1}')
    if [ "$local_sum" != "$remote_sum" ]; then
        log_error "Integrity check FAILED for ${remote_subpath}: local=$local_sum remote=$remote_sum"
        return 1
    fi
    log_info "Integrity verified for ${remote_subpath} (sha256 $local_sum)"
    return 0
}

# encrypt_upload_verify <plaintext-file> <remote-subpath-without-.gpg>
# Encrypts, uploads, verifies checksum, cleans up local staging copy.
encrypt_upload_verify() {
    local plainfile="$1"
    local remote_subpath="$2"
    local encfile
    encfile=$(gpg_encrypt "$plainfile") || return 1
    if ! b2_upload "$encfile" "${remote_subpath}.gpg"; then
        log_error "Upload failed for $encfile"
        return 1
    fi
    if ! b2_verify "$encfile" "${remote_subpath}.gpg"; then
        return 1
    fi
    rm -f "$encfile"
    return 0
}
