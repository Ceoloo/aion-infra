#!/bin/bash
# Restore drill for the aion_data (aion-runtime) backup: downloads the real
# encrypted dump from offsite B2, decrypts with the OFFLINE private key
# (imported into a throwaway keyring only, never the persistent one),
# restores into an isolated, disposable Postgres container, verifies the
# canonical schema AND representative execution/approval rows, then tears
# everything down. Never touches production aion-postgres-1.
#
# Usage: restore-test-aion-runtime.sh <stamp> [db|full]

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

STAMP="${1:?Usage: restore-test-aion-runtime.sh <stamp> [db|full]}"
MODE="${2:-db}"
WORK="/root/backups/restore-test/$RUN_STAMP"
mkdir -p "$WORK"
RESULTS=()
pass() { RESULTS+=("PASS: $1"); log_info "PASS: $1"; }
fail() { RESULTS+=("FAIL: $1"); log_error "FAIL: $1"; }

TEMP_GNUPGHOME="$WORK/gnupg-temp"
cleanup() {
    docker rm -f restore-test-aion-runtime-pg >/dev/null 2>&1 || true
    shred -u "$WORK"/*.sql "$WORK"/*.dump "$WORK"/*.gpg 2>/dev/null || true
    if [ -d "$TEMP_GNUPGHOME" ]; then
        find "$TEMP_GNUPGHOME" -type f -exec shred -u {} \; 2>/dev/null
        rm -rf "$TEMP_GNUPGHOME"
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

log_info "=== aion-runtime restore drill starting (stamp=${STAMP}, mode=${MODE}) ==="

OFFLINE_KEY="$SECRETS_DIR/PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc"
if [ ! -f "$OFFLINE_KEY" ]; then
    log_error "Offline private key not found at $OFFLINE_KEY"
    exit 1
fi
mkdir -m 700 -p "$TEMP_GNUPGHOME"
echo "allow-loopback-pinentry" > "$TEMP_GNUPGHOME/gpg-agent.conf"
export GNUPGHOME="$TEMP_GNUPGHOME"
gpgconf --kill gpg-agent >>"$LOG_FILE" 2>&1 || true
gpg --batch --yes --import "$OFFLINE_KEY" >>"$LOG_FILE" 2>&1
gpg --list-secret-keys >>"$LOG_FILE" 2>&1 || { log_error "key import failed"; exit 1; }
log_info "Offline private key imported into a THROWAWAY keyring ($TEMP_GNUPGHOME) only — never the persistent one"
KEY_PASSPHRASE="$(sed -n 's/^Passphrase:[[:space:]]*//p' "$SECRETS_DIR/PRIVATE_KEY_PASSPHRASE.txt")"

REMOTE="b2:${B2_BUCKET}/${MODE}/${STAMP}/postgres-aion-runtime.dump.gpg"
log_info "Downloading ${REMOTE} from offsite B2..."
if rclone_retry copy "$REMOTE" "$WORK/" 2>>"$LOG_FILE"; then
    pass "backup downloaded from offsite B2 storage (real offsite leg, not local staging)"
else
    fail "could not download backup from B2"
fi

ENC="$WORK/postgres-aion-runtime.dump.gpg"
DEC="$WORK/postgres-aion-runtime.dump"
if [ -f "$ENC" ]; then
    if echo "$KEY_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
        --output "$DEC" --decrypt "$ENC" 2>>"$LOG_FILE"; then
        pass "GPG decrypt succeeded (tamper/integrity check passed)"
    else
        fail "GPG decrypt failed"
    fi
else
    fail "downloaded file not found: $ENC"
fi

if [ -s "$DEC" ]; then
    docker rm -f restore-test-aion-runtime-pg >/dev/null 2>&1 || true
    docker run -d --rm --name restore-test-aion-runtime-pg \
        -e POSTGRES_PASSWORD=restoretest -e POSTGRES_USER=postgres -e POSTGRES_DB=aion_data \
        postgres:16-alpine >/dev/null 2>>"$LOG_FILE"
    # TCP (-h 127.0.0.1), not the unix socket: the entrypoint's temporary init server listens on the socket only, so a socket check can pass just before the real restart and lose the restore (seen 2026-09-20).
    tries=0
    until docker exec restore-test-aion-runtime-pg pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; do
        sleep 1; tries=$((tries+1))
        if [ "$tries" -gt 30 ]; then fail "restore-test-aion-runtime-pg never became ready"; break; fi
    done

    docker cp "$DEC" restore-test-aion-runtime-pg:/tmp/restore.dump 2>>"$LOG_FILE"
    if docker exec restore-test-aion-runtime-pg pg_restore -U postgres -d aion_data --no-owner --no-acl /tmp/restore.dump >>"$LOG_FILE" 2>&1; then
        pass "pg_restore completed cleanly into an isolated container"
    else
        fail "pg_restore returned errors — a partial restore is not certified as restorable (see $LOG_FILE)"
    fi

    # Schema check — the 7 canonical tables the durable-execution contract requires.
    SCHEMA_COUNT=$(docker exec restore-test-aion-runtime-pg psql -U postgres -d aion_data -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('actors','missions','runs','approvals','events','telemetry_records','outcomes');" 2>>"$LOG_FILE")
    if [ "${SCHEMA_COUNT:-0}" = "7" ]; then
        pass "canonical schema restored: 7/7 tables present"
    else
        fail "canonical schema incomplete: ${SCHEMA_COUNT:-0}/7 tables present"
    fi

    ALL_TABLES=$(docker exec restore-test-aion-runtime-pg psql -U postgres -d aion_data -tAc \
        "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';" 2>>"$LOG_FILE")
    log_info "Total public tables restored: ${ALL_TABLES:-0} (production baseline: 16)"

    # Representative execution/approval record check — real rows, not just
    # table existence, and log a fingerprint (id + status) rather than any
    # payload content.
    EXEC_COUNT=$(docker exec restore-test-aion-runtime-pg psql -U postgres -d aion_data -tAc \
        "SELECT count(*) FROM executions;" 2>>"$LOG_FILE")
    APPR_COUNT=$(docker exec restore-test-aion-runtime-pg psql -U postgres -d aion_data -tAc \
        "SELECT count(*) FROM approvals;" 2>>"$LOG_FILE")
    SAMPLE_EXEC=$(docker exec restore-test-aion-runtime-pg psql -U postgres -d aion_data -tAc \
        "SELECT execution_id || ':' || status FROM executions ORDER BY created_at DESC LIMIT 1;" 2>>"$LOG_FILE")
    SAMPLE_APPR=$(docker exec restore-test-aion-runtime-pg psql -U postgres -d aion_data -tAc \
        "SELECT approval_id || ':' || status FROM approvals ORDER BY requested_at DESC LIMIT 1;" 2>>"$LOG_FILE")

    if [ "${EXEC_COUNT:-0}" -gt 0 ]; then
        pass "executions restored: ${EXEC_COUNT} rows (most recent: ${SAMPLE_EXEC})"
    else
        fail "executions table restored empty"
    fi
    if [ "${APPR_COUNT:-0}" -gt 0 ]; then
        pass "approvals restored: ${APPR_COUNT} rows (most recent: ${SAMPLE_APPR})"
    else
        fail "approvals table restored empty"
    fi
else
    fail "decrypted dump is empty or missing — skipping restore"
fi

log_info "=== aion-runtime restore drill report (stamp=${STAMP}) ==="
for r in "${RESULTS[@]}"; do log_info "$r"; done
FAIL_COUNT=$(printf '%s\n' "${RESULTS[@]}" | grep -c '^FAIL' || true)
echo "TOTAL: $((${#RESULTS[@]} - FAIL_COUNT)) passed, $FAIL_COUNT failed" | tee -a "$LOG_FILE"
[ "$FAIL_COUNT" -gt 0 ] && exit 1
exit 0
