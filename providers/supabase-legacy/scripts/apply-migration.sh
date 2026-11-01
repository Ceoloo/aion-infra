#!/usr/bin/env bash
# Apply one SQL migration against the legacy Supabase island.
# Requires an explicit confirmation token so this is never a casual footgun.
#
#   CONFIRM_LEGACY_SUPABASE_APPLY=qbahthzqvxytfgobgtxa \
#     SUPABASE_DB_URL='...' \
#     ./apply-migration.sh migrations/20261101193000_aio116_117_118_revex_ledger_fixes.sql
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATION="${1:?path to migration .sql required}"

if [[ "$MIGRATION" != /* ]]; then
  MIGRATION="$ROOT/$MIGRATION"
fi
[[ -f "$MIGRATION" ]] || { echo "missing migration: $MIGRATION" >&2; exit 1; }

ENV_FILE="${SUPABASE_DB_ENV_FILE:-}"
if [[ -n "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

: "${SUPABASE_DB_URL:?set SUPABASE_DB_URL}"
: "${CONFIRM_LEGACY_SUPABASE_APPLY:?set CONFIRM_LEGACY_SUPABASE_APPLY=qbahthzqvxytfgobgtxa}"

if [[ "$CONFIRM_LEGACY_SUPABASE_APPLY" != "qbahthzqvxytfgobgtxa" ]]; then
  echo "CONFIRM_LEGACY_SUPABASE_APPLY must equal the project ref qbahthzqvxytfgobgtxa" >&2
  exit 1
fi

echo "Applying $(basename "$MIGRATION") to legacy Supabase..."
psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f "$MIGRATION"
echo "Applied OK"
