#!/usr/bin/env bash
# ============================================================================
# backup-restore-selftest.sh — prove recoverability with REAL data, Docker-free
# (amendment §14, §30; aion-infra §32, §65).
# ============================================================================
# Runs the SAME encrypt → off-host → decrypt → ISOLATED-restore → validate cycle
# the VPS scripts (providers/vps/scripts/backup.sh + restore.sh) perform, but
# using host binaries (pg_dump/psql/openssl) and a local "off-host" DIRECTORY
# standing in for remote S3-compatible storage (no object-storage endpoint is
# available in this environment). The encryption, decryption, isolated restore,
# and schema validation are REAL. It NEVER restores over the source database.
#
# Required env:
#   PGDUMP_URL         source DB URL to back up
#   BACKUP_PASSPHRASE  symmetric passphrase (openssl aes-256-cbc, pbkdf2)
#   ADMIN_URL          a superuser URL used to create/drop the isolated target DB
# Optional: BACKUP_DIR (default ./.backups), ISOLATED_DB (default aion_restorecheck)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${PGDUMP_URL:?}"; : "${BACKUP_PASSPHRASE:?}"; : "${ADMIN_URL:?}"
BACKUP_DIR="${BACKUP_DIR:-./.backups}"
ISO="${ISOLATED_DB:-aion_restorecheck}"
mkdir -p "$BACKUP_DIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
ENC="${BACKUP_DIR}/aion-${TS}.sql.gz.enc"

echo "[selftest] 1/5 dump → gzip → encrypt (off-host copy: ${ENC})"
pg_dump "$PGDUMP_URL" --no-owner --format=plain \
  | gzip -9 \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "pass:${BACKUP_PASSPHRASE}" -out "$ENC"
echo "[selftest]     encrypted backup bytes: $(wc -c <"$ENC")"

echo "[selftest] 2/5 confirm the artifact is NOT plaintext"
if head -c 512 "$ENC" | grep -qi 'CREATE TABLE\|COPY \|PostgreSQL database dump'; then
  echo "[selftest] FAIL — backup appears unencrypted" >&2; exit 1
fi
echo "[selftest]     ok (ciphertext; 'Salted__' header: $(head -c 8 "$ENC" | tr -dc 'A-Za-z_'))"

echo "[selftest] 3/5 create ISOLATED restore target: ${ISO}"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -c "DROP DATABASE IF EXISTS ${ISO};" -c "CREATE DATABASE ${ISO};" >/dev/null
# Derive the isolated DB URL from ADMIN_URL by swapping the trailing db name.
ISO_URL="$(printf '%s' "$ADMIN_URL" | sed -E "s#/[^/?]+(\?|$)#/${ISO}\1#")"

echo "[selftest] 4/5 decrypt → gunzip → restore into ${ISO}"
openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:${BACKUP_PASSPHRASE}" -in "$ENC" \
  | gunzip \
  | psql "$ISO_URL" -v ON_ERROR_STOP=1 -q >/dev/null

echo "[selftest] 5/5 validate canonical schema in the restored copy"
COUNT="$(psql "$ISO_URL" -tA -c \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('actors','missions','runs','approvals','events','telemetry_records','outcomes');")"
ROWS="$(psql "$ISO_URL" -tA -c "SELECT count(*) FROM schema_migrations;" 2>/dev/null || echo '?')"
echo "[selftest]     canonical tables: ${COUNT}/7 ; schema_migrations rows: ${ROWS}"

echo "[selftest] teardown isolated target"
psql "$ADMIN_URL" -c "DROP DATABASE IF EXISTS ${ISO};" >/dev/null

[ "$COUNT" = "7" ] || { echo "[selftest] RESTORE VALIDATION FAILED" >&2; exit 1; }
echo "[selftest] PASS — backup encrypted off-host, restored into isolated target, schema validated"
