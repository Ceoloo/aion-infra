#!/usr/bin/env bash
# Dump live revex function/view definitions for pre-apply review.
# Usage:
#   SUPABASE_DB_URL='postgresql://...' ./capture-live-revex-defs.sh
#   ./capture-live-revex-defs.sh --env-file /root/.backup-secrets/supabase-db.env
set -euo pipefail

ENV_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) ENV_FILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a; source "$ENV_FILE"; set +a
fi

: "${SUPABASE_DB_URL:?set SUPABASE_DB_URL or pass --env-file}"

OUT_DIR="${REVEX_CAPTURE_DIR:-./captures/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT_DIR"

psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -At <<SQL >"$OUT_DIR/revex_defs.sql"
select '-- ' || p.proname || E'\n' || pg_get_functiondef(p.oid) || E';\n'
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
   and p.proname in (
     'revex_log_outreach',
     'revex_mark_collected',
     'revex_log_attested_send',
     'revex_bump_daily',
     'revex_emit_event',
     'revex_actor_has_prohibition',
     'revex_resolve_open_drafts'
   )
 order by p.proname, p.oid;

select E'\n-- view revex_ceo_waiting_on_human\n' || pg_get_viewdef('public.revex_ceo_waiting_on_human'::regclass, true) || E';\n';
SQL

echo "Wrote $OUT_DIR/revex_defs.sql"
