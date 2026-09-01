#!/usr/bin/env bash
# ============================================================================
# backup.sh — encrypted, off-host PostgreSQL backup for the VPS (Mode A).
# ============================================================================
# A backup stored only on the same VPS is NOT sufficient (aion-infra §14). This
# takes a compressed pg_dump, encrypts it, and uploads it OFF the server to a
# configurable S3-compatible destination (no vendor is hardwired). Runs from
# cron/systemd-timer (see providers/vps/system/).
#
# Required env (root-owned 0600 file, e.g. /opt/aion/.env.backup):
#   PGDUMP_URL        postgres URL to dump from (a read-capable role)
#   BACKUP_PASSPHRASE symmetric encryption passphrase (age/gpg)
#   S3_ENDPOINT       S3-compatible endpoint (AWS S3, Backblaze B2, MinIO, …)
#   S3_BUCKET         destination bucket
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY   credentials for that endpoint
# Optional: RETENTION_DAYS (default 14)
set -euo pipefail

: "${PGDUMP_URL:?}"; : "${BACKUP_PASSPHRASE:?}"; : "${S3_BUCKET:?}"; : "${S3_ENDPOINT:?}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="aion-${TS}.sql.gz.enc"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

echo "[backup] dumping database"
docker run --rm --network host -e PGDUMP_URL="$PGDUMP_URL" postgres:16-alpine \
  sh -c 'pg_dump "$PGDUMP_URL" --no-owner --format=plain' | gzip -9 \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "pass:${BACKUP_PASSPHRASE}" -out "${TMP}/${FILE}"

echo "[backup] uploading OFF-HOST to s3://${S3_BUCKET}/${FILE}"
# aws-cli honors AWS_* env + --endpoint-url; the endpoint decides the vendor.
docker run --rm -v "${TMP}:/data" \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  amazon/aws-cli:2 s3 cp "/data/${FILE}" "s3://${S3_BUCKET}/${FILE}" \
  --endpoint-url "${S3_ENDPOINT}"

echo "[backup] pruning remote copies older than ${RETENTION_DAYS}d"
CUTOFF="$(date -u -d "-${RETENTION_DAYS} days" +%Y%m%d 2>/dev/null || echo 00000000)"
docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY amazon/aws-cli:2 \
  s3 ls "s3://${S3_BUCKET}/" --endpoint-url "${S3_ENDPOINT}" | awk '{print $4}' | while read -r key; do
    d="$(echo "$key" | sed -n 's/^aion-\([0-9]\{8\}\).*/\1/p')"
    [ -n "$d" ] && [ "$d" -lt "$CUTOFF" ] && \
      docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY amazon/aws-cli:2 \
        s3 rm "s3://${S3_BUCKET}/${key}" --endpoint-url "${S3_ENDPOINT}" || true
  done

echo "[backup] complete: ${FILE}"
