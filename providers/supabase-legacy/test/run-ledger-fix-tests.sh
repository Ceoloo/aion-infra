#!/usr/bin/env bash
# Prove AIO-116/117/118 hotfixes on a disposable local Postgres database.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="${REVEX_LEDGER_TEST_DB:-revex_ledger_fix_$$}"
ADMIN_URL="${REVEX_LEDGER_DATABASE_URL:-}"

if [[ -n "$ADMIN_URL" ]]; then
  PSQL=(psql "$ADMIN_URL" -v ON_ERROR_STOP=1)
else
  # Local peer auth: connect to the maintenance DB explicitly (role DB may not exist).
  PSQL=(psql -d postgres -v ON_ERROR_STOP=1)
fi

echo "Creating disposable database ${DB_NAME}..."
"${PSQL[@]}" -c "drop database if exists ${DB_NAME};" >/dev/null
"${PSQL[@]}" -c "create database ${DB_NAME};" >/dev/null

cleanup() {
  "${PSQL[@]}" -c "drop database if exists ${DB_NAME};" >/dev/null 2>&1 || true
}
trap cleanup EXIT

DB_PSQL=("${PSQL[@]}")
# Retarget to the disposable DB.
if [[ -n "$ADMIN_URL" ]]; then
  # Replace path with /DB_NAME while preserving query string if any.
  BASE="${ADMIN_URL%%\?*}"
  QS=""
  if [[ "$ADMIN_URL" == *"?"* ]]; then QS="?${ADMIN_URL#*\?}"; fi
  # Strip trailing /dbname
  HOSTPART="$(echo "$BASE" | sed -E 's#/[^/]*$##')"
  DB_URL="${HOSTPART}/${DB_NAME}${QS}"
  DB_PSQL=(psql "$DB_URL" -v ON_ERROR_STOP=1)
else
  DB_PSQL=(psql -d "$DB_NAME" -v ON_ERROR_STOP=1)
fi

echo "Loading buggy fabric..."
"${DB_PSQL[@]}" -f "$ROOT/test/supabase-roles-shim.sql" >/dev/null
"${DB_PSQL[@]}" -f "$ROOT/test/00_buggy_fabric.sql" >/dev/null

echo "Applying hotfix migration..."
"${DB_PSQL[@]}" -f "$ROOT/migrations/20261101193000_aio116_117_118_revex_ledger_fixes.sql" >/dev/null

echo "Running assertions..."
"${DB_PSQL[@]}" -f "$ROOT/test/01_assertions.sql"

echo "PASS: AIO-116/117/118 ledger fixes"
