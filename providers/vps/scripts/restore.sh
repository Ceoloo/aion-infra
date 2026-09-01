#!/usr/bin/env bash
# ============================================================================
# restore.sh — restore an encrypted off-host backup into an ISOLATED target.
# ============================================================================
# Answers the critical question: can AION actually restore its durable state?
# It NEVER restores over the live database (aion-infra §32). It pulls one backup
# object, decrypts it, and restores into a SEPARATE, disposable Postgres
# container, then validates the canonical schema is present.
#
# Required env: same S3_* + BACKUP_PASSPHRASE as backup.sh, plus:
#   BACKUP_KEY   the object key to restore (e.g. aion-20260901T030000Z.sql.gz.enc)
set -euo pipefail
: "${BACKUP_KEY:?}"; : "${BACKUP_PASSPHRASE:?}"; : "${S3_BUCKET:?}"; : "${S3_ENDPOINT:?}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"; docker rm -f aion-restore-check >/dev/null 2>&1 || true' EXIT

echo "[restore] downloading ${BACKUP_KEY}"
docker run --rm -v "${TMP}:/data" -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY \
  amazon/aws-cli:2 s3 cp "s3://${S3_BUCKET}/${BACKUP_KEY}" "/data/backup.enc" \
  --endpoint-url "${S3_ENDPOINT}"

echo "[restore] decrypting"
openssl enc -d -aes-256-cbc -pbkdf2 -pass "pass:${BACKUP_PASSPHRASE}" \
  -in "${TMP}/backup.enc" | gunzip > "${TMP}/restore.sql"

echo "[restore] starting ISOLATED target Postgres"
docker run -d --name aion-restore-check -e POSTGRES_PASSWORD=restore -e POSTGRES_DB=aion_restore \
  postgres:16-alpine >/dev/null
for _ in $(seq 1 30); do
  docker exec aion-restore-check pg_isready -U postgres >/dev/null 2>&1 && break; sleep 1
done

echo "[restore] loading dump into isolated target"
docker cp "${TMP}/restore.sql" aion-restore-check:/restore.sql
docker exec aion-restore-check psql -U postgres -d aion_restore -q -f /restore.sql >/dev/null

echo "[restore] validating canonical schema"
COUNT="$(docker exec aion-restore-check psql -U postgres -d aion_restore -tA -c \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('actors','missions','runs','approvals','events','telemetry_records','outcomes');")"
echo "[restore] canonical tables found: ${COUNT} (expected 7)"
[ "${COUNT}" = "7" ] || { echo "RESTORE VALIDATION FAILED" >&2; exit 1; }
echo "[restore] RESTORE VERIFICATION PASS (isolated target destroyed on exit)"
