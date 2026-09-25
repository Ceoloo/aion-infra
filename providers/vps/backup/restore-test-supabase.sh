#!/bin/bash
# Restore drill for the Supabase project "AION EMPIRE SYSTEM" (qbahthzqvxytfgobgtxa).
# Downloads the real encrypted dump from B2, decrypts it with the offline key in a
# throwaway keyring (RAM only, /dev/shm), restores it into Supabase's own Postgres image
# with NO NETWORK (the dump carries pg_cron jobs that call production edge functions),
# then compares it with the live project using read-only queries. Tears everything down.
#
# Usage: restore-test-supabase.sh [stamp]      (default: newest supabase/<stamp>/ in B2)
#
# Known, expected restore differences (not failures; see recovery notes in the report):
#   - event trigger public ensure_rls: needs superuser; the local image's postgres role is not one
#   - vault secrets restore but cannot be decrypted (pgsodium root key is per project)

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
umask 077

IMAGE="supabase/postgres:17.6.1.176"   # match the live server_version (17.6); bump when Supabase upgrades
C=restore-test-supabase-pg
ENV_FILE="$SECRETS_DIR/supabase-db.env"
# Tables the live project writes to continuously; they may only have grown since the dump.
DRIFT_TABLES="cron.job_run_details public.agent_heartbeats public.airtable_sync_logs public.worker_runs"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); log_info "PASS: $*"; }
no() { FAIL=$((FAIL+1)); log_error "FAIL: $*"; }

W="$(mktemp -d -p /dev/shm supa-drill.XXXXXX)"; chmod 700 "$W"
G="$W/gnupg"; mkdir -m 700 "$G"
cleanup() {
    docker rm -f "$C" >/dev/null 2>&1
    GNUPGHOME="$G" gpgconf --kill gpg-agent >/dev/null 2>&1
    find "$W" -type f -exec shred -u {} \; 2>/dev/null; rm -rf "$W"
    unset KEYPW
}
trap cleanup EXIT

STAMP="${1:-$(rclone lsf "b2:${B2_BUCKET}/supabase/" --dirs-only 2>>"$LOG_FILE" | sort | tail -1 | tr -d /)}"
[ -n "$STAMP" ] || { no "no supabase/ backups found in B2"; exit 1; }
log_info "=== supabase restore drill: supabase/${STAMP} -> isolated ${IMAGE} (no network) ==="

require_restore_key || exit 1
[ -r "$ENV_FILE" ] || { no "missing $ENV_FILE (needed for the read-only comparison with live)"; exit 1; }

rclone_retry copyto "b2:${B2_BUCKET}/supabase/${STAMP}/postgres-supabase.dump.gpg" "$W/s.gpg" 2>>"$LOG_FILE"
[ -s "$W/s.gpg" ] || { no "backup object missing or empty in B2: supabase/${STAMP} (wrong stamp?)"; exit 1; }
ok "downloaded supabase/${STAMP} from B2 ($(stat -c %s "$W/s.gpg") bytes ciphertext)"

echo "allow-loopback-pinentry" > "$G/gpg-agent.conf"
GNUPGHOME="$G" gpg --batch --yes --import "$RESTORE_KEY_FILE" >/dev/null 2>&1 || { no "offline key import failed"; exit 1; }
KEYPW="$(read_restore_passphrase)"
if echo "$KEYPW" | GNUPGHOME="$G" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 \
        --output "$W/s.dump" --decrypt "$W/s.gpg" 2>>"$LOG_FILE" && [ -s "$W/s.dump" ]; then
    ok "decrypted with the offline key (throwaway keyring, RAM only)"
else
    no "decrypt failed"; exit 1
fi
shred -u "$W/s.gpg"

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" --network none -e POSTGRES_PASSWORD="$(head -c 24 /dev/urandom | base64)" \
    -v "$W:/w:ro" "$IMAGE" >/dev/null 2>>"$LOG_FILE" || { no "could not start $IMAGE"; exit 1; }
for i in $(seq 1 90); do docker exec "$C" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break; sleep 2; done
sleep 5   # the image runs its init migrations before the final restart
docker exec "$C" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 || { no "restore target never became ready"; exit 1; }
[ "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$C")" = none ] && ok "restore target running with NO network (cron/pg_net cannot reach production)" \
    || { no "restore target has network access — aborting before restore"; exit 1; }

RS() { docker exec -i "$C" psql -X -U supabase_admin -d postgres -tA "$@"; }
LV() { docker run --rm -i --env-file "$ENV_FILE" postgres:17 sh -c 'PGOPTIONS="-c default_transaction_read_only=on" psql -X "$SUPABASE_DB_URL" -tA'; }

# The drill is only meaningful if the restore target runs the same Postgres version as live.
LIVE_V="$(echo 'show server_version' | LV 2>>"$LOG_FILE" | awk '{print $1}')"
IMG_V="$(RS -c 'show server_version' 2>>"$LOG_FILE" | awk '{print $1}')"
if [ -n "$LIVE_V" ] && [ "$LIVE_V" = "$IMG_V" ]; then ok "restore target Postgres $IMG_V matches live $LIVE_V"
else no "version mismatch: live=${LIVE_V:-unknown} image=${IMG_V:-unknown} — bump IMAGE in $0 (supabase/postgres tags on Docker Hub)"; fi

# Roles that exist on hosted Supabase but not in the local image; without them only ownership statements fail.
RS -c "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_realtime_admin') THEN CREATE ROLE supabase_realtime_admin NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='supabase_functions_admin') THEN CREATE ROLE supabase_functions_admin NOLOGIN; END IF;
END \$\$;" >/dev/null 2>>"$LOG_FILE"

docker exec "$C" sh -c 'pg_restore -U supabase_admin -d postgres --clean --if-exists /w/s.dump > /tmp/restore.log 2>&1'
# Stop the restored cron jobs at once (belt and braces: there is no network anyway).
RS -c "UPDATE cron.job SET active = false;" >/dev/null 2>&1
ERRS="$(docker exec "$C" sh -c 'grep -A3 "^pg_restore: error" /tmp/restore.log' 2>/dev/null)"
NERR="$(printf '%s\n' "$ERRS" | grep -c '^pg_restore: error' || true)"
UNEXPECTED="$(printf '%s\n' "$ERRS" | grep '^pg_restore: error' | grep -v -E 'ensure_rls|Superuser owned event trigger' | grep -c . || true)"
if [ "$UNEXPECTED" = 0 ]; then
    ok "pg_restore finished; $NERR error(s), all known (event trigger ensure_rls needs superuser — recreate it by hand on a real restore)"
else
    no "pg_restore: $UNEXPECTED unexpected error(s) of $NERR — errors copied to $LOG_FILE"
    printf '%s\n' "$ERRS" >> "$LOG_FILE"
fi

# 1) row counts for every table in the schemas that hold AION data
cat > "$W/gen.sql" <<'EOF'
select format('select %L||''|''||count(*) from %I.%I;', n.nspname||'.'||c.relname, n.nspname, c.relname)
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where c.relkind in ('r','p') and n.nspname in ('public','auth','storage','event_memory','radar','vault','cron','supabase_migrations','realtime') order by 1;
EOF
STAMP_TS="${STAMP:0:4}-${STAMP:4:2}-${STAMP:6:2} ${STAMP:9:2}:${STAMP:11:2}:${STAMP:13:2}+00"
RS < "$W/gen.sql" > "$W/q_r.sql"; LV < "$W/gen.sql" > "$W/q_l.sql"
RS < "$W/q_r.sql" 2>>"$LOG_FILE" | sort > "$W/restored.txt"
LV < "$W/q_l.sql" 2>>"$LOG_FILE" | sort > "$W/live.txt"
# the restored pg_cron may have logged a few local (failed) runs before it was switched off
LOCAL_CRON="$(RS -c "select count(*) from cron.job_run_details where start_time >= '$STAMP_TS'" 2>/dev/null)"
NR=$(wc -l < "$W/restored.txt"); NL=$(wc -l < "$W/live.txt")
if [ "$NR" -gt 0 ] && [ "$NR" = "$NL" ]; then ok "all $NL live tables exist in the restore"; else no "table count restored=$NR live=$NL"; fi
EXACT=0; GREW=0; BAD=""
while IFS='|' read -r t r l; do
    [ "$t" = cron.job_run_details ] && r=$((r - ${LOCAL_CRON:-0}))
    if [ "$r" = "$l" ]; then EXACT=$((EXACT+1))
    elif [[ " $DRIFT_TABLES " == *" $t "* ]] && [ "$r" != MISSING ] && [ "$l" != MISSING ] && [ "$r" -le "$l" ]; then GREW=$((GREW+1)); log_info "drift (live wrote after the dump): $t restored=$r live=$l"
    else BAD="$BAD $t(restored=$r,live=$l)"; fi
done < <(join -t'|' -a1 -a2 -e MISSING -o 0,1.2,2.2 "$W/restored.txt" "$W/live.txt")
TOTAL_ROWS=$(awk -F'|' '{s+=$2}END{print s+0}' "$W/restored.txt")
[ -z "$BAD" ] && ok "row counts: $EXACT tables identical to live, $GREW continuously-written tables only grew since the dump ($TOTAL_ROWS rows restored)" \
    || no "row counts differ:$BAD"

# 2) the logic around the data: functions, policies, triggers, views, cron jobs
cat > "$W/obj.sql" <<'EOF'
select 'functions|'||count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname in ('public','event_memory','radar');
select 'rls_policies|'||count(*) from pg_policies where schemaname in ('public','event_memory','radar','storage');
select 'rls_enabled_tables|'||count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where c.relrowsecurity and n.nspname in ('public','event_memory','radar');
select 'triggers|'||count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace where not t.tgisinternal and n.nspname in ('public','event_memory','radar','auth','storage');
select 'views|'||count(*) from pg_views where schemaname in ('public','event_memory','radar');
select 'cron_jobs|'||count(*) from cron.job;
select 'auth_users|'||count(*) from auth.users;
select 'vault_secrets|'||count(*) from vault.secrets;
EOF
RS < "$W/obj.sql" 2>>"$LOG_FILE" | sort > "$W/obj_r.txt"; LV < "$W/obj.sql" 2>>"$LOG_FILE" | sort > "$W/obj_l.txt"
if [ -s "$W/obj_l.txt" ] && cmp -s "$W/obj_r.txt" "$W/obj_l.txt"; then
    ok "database logic identical to live: $(tr '\n' ' ' < "$W/obj_l.txt")"
else
    no "database objects differ: restored=[$(tr '\n' ' ' < "$W/obj_r.txt")] live=[$(tr '\n' ' ' < "$W/obj_l.txt")]"
fi

# 3) a content check, not just counts: checksum of the owner's auth row and of the migration history
cat > "$W/sum.sql" <<'EOF'
select 'auth.users|'||md5(string_agg(id::text||coalesce(email,'')||coalesce(encrypted_password,''), ',' order by id)) from auth.users;
select 'supabase_migrations|'||md5(string_agg(version, ',' order by version)) from supabase_migrations.schema_migrations;
select 'cron.job|'||md5(string_agg(jobname||schedule||command, ',' order by jobid)) from cron.job;
EOF
RS < "$W/sum.sql" 2>>"$LOG_FILE" | sort > "$W/sum_r.txt"; LV < "$W/sum.sql" 2>>"$LOG_FILE" | sort > "$W/sum_l.txt"
if [ -s "$W/sum_l.txt" ] && cmp -s "$W/sum_r.txt" "$W/sum_l.txt"; then
    ok "content checksums identical to live (auth users incl. password hashes, migration history, cron job definitions)"
else
    no "content checksums differ: $(join -t'|' "$W/sum_r.txt" "$W/sum_l.txt" | awk -F'|' '$2!=$3{print $1}' | tr '\n' ' ')"
fi

# 4) documented limitation, checked so the report states it rather than assuming it
VS="$(RS -c "select count(*) from vault.secrets" 2>/dev/null)"
if RS -c "select decrypted_secret from vault.decrypted_secrets limit 1" >/dev/null 2>&1; then
    log_warn "NOTE: vault decrypt did not error on the restored copy — unexpected; check before relying on it"
else
    log_info "NOTE: $VS vault secret(s) restored as ciphertext only (pgsodium key is per project) — recreate them on a real restore"
fi

log_info "=== supabase restore drill result: $PASS passed, $FAIL failed (stamp ${STAMP}) ==="
[ "$FAIL" = 0 ]
