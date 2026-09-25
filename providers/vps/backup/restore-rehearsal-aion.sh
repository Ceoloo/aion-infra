#!/bin/bash
# Clean-host RECOVERY REHEARSAL for the database tier: from B2 objects ONLY, rebuild roles, grants, ownership and data
# in a brand-new isolated Postgres and compare with production. Read-only against production. Never prints secrets:
# password hashes / passwords are compared by md5 or by a successful login, never shown; nothing plaintext is written.
#
#   restore-rehearsal-aion.sh <config-stamp> <db-stamp>
#     config-stamp  e.g. cfg_20260920_132200   (b2 config-aion/<stamp>/: roles-globals.sql.gpg + aion-config.tar.gpg)
#     db-stamp      e.g. 20260920_133005       (b2 db/<stamp>/postgres-aion-runtime.dump.gpg)
# Needs the OFFLINE private key (imported into a throwaway keyring only). NOT covered: OS/Docker install, image pulls,
# deploy.sh/migrate on the new host, Traefik/DNS/certs — see docs/recovery-kit.md.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
umask 077
CS="${1:?config-stamp}"; DS="${2:?db-stamp}"
require_restore_key || exit 1
C=aion-rehearsal-pg; PROD="${PG_CONTAINER:-aion-postgres-1}"
D="$(mktemp -d -p "$STAGING_DIR")"; chmod 700 "$D"
PASS=0; FAIL=0; ok() { PASS=$((PASS+1)); log_info "PASS: $*"; }; no() { FAIL=$((FAIL+1)); log_error "FAIL: $*"; }
OFFT="$(mktemp -d)"; chmod 700 "$OFFT"
cleanup() { docker rm -f "$C" >/dev/null 2>&1; GNUPGHOME="$OFFT" gpgconf --kill gpg-agent >/dev/null 2>&1; find "$OFFT" "$D" -type f -exec shred -u {} \; 2>/dev/null; rm -rf "$OFFT" "$D"; unset OFFPW APPPW MIGPW; }
trap cleanup EXIT
echo "allow-loopback-pinentry" > "$OFFT/gpg-agent.conf"
GNUPGHOME="$OFFT" gpg --batch --yes --import "$RESTORE_KEY_FILE" >/dev/null 2>&1 || { log_error "offline key import failed"; exit 1; }
OFFPW="$(read_restore_passphrase)"
dec() { echo "$OFFPW" | GNUPGHOME="$OFFT" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt "$1" 2>/dev/null; }

log_info "=== rehearsal: config-aion/$CS + db/$DS -> clean isolated Postgres ==="
for o in "config-aion/$CS/roles-globals.sql.gpg:$D/roles.gpg" "config-aion/$CS/aion-config.tar.gpg:$D/cfg.gpg" "db/$DS/postgres-aion-runtime.dump.gpg:$D/db.gpg"; do
  rclone_retry copyto "b2:${B2_BUCKET}/${o%%:*}" "${o#*:}" 2>>"$LOG_FILE" || { no "download failed: ${o%%:*}"; exit 1; }
  [ -s "${o#*:}" ] || { no "backup object missing or empty in B2: ${o%%:*} (wrong stamp?)"; exit 1; }  # rclone exits 0 on a missing source
done; ok "downloaded roles, config and database objects from B2 (ciphertext)"

docker rm -f "$C" >/dev/null 2>&1
docker run -d --name "$C" -e POSTGRES_PASSWORD="$(head -c 24 /dev/urandom | base64)" postgres:16-alpine >/dev/null 2>&1
for i in $(seq 1 60); do docker exec "$C" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 && break; sleep 1; done
docker exec "$C" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1 || { no "clean Postgres never became ready"; exit 1; }
ok "clean Postgres started (no data, no roles)"

# 1) roles first (streamed decrypt -> psql; the bootstrap 'postgres' role already exists, so exactly that CREATE errors)
ERRS="$(dec "$D/roles.gpg" | docker exec -i "$C" psql -U postgres -q 2>&1 | grep -c '^ERROR')"
[ "$ERRS" -le 1 ] && ok "roles restored from the encrypted globals dump ($ERRS expected error: bootstrap role already exists)" || no "roles restore produced $ERRS errors"
# 2) database owned by the migrator, then data + ownership + ACLs from the custom-format dump
docker exec "$C" psql -U postgres -qtA -c "CREATE DATABASE aion_data OWNER aion_migrator" >/dev/null 2>&1 && ok "database aion_data created owned by aion_migrator"
dec "$D/db.gpg" | docker exec -i "$C" pg_restore -U postgres -d aion_data 2>>"$LOG_FILE"; RRC=$?
[ "$RRC" = 0 ] && ok "pg_restore with ownership + ACLs completed cleanly" || no "pg_restore rc=$RRC"

P() { docker exec "$PROD" psql -v ON_ERROR_STOP=1 -U postgres -d aion_data -tA -c "$1"; }; R() { docker exec "$C" psql -v ON_ERROR_STOP=1 -U postgres -d aion_data -tA -c "$1"; }
cmp_q() {  # $1 label  $2 SQL  — identical on both sides AND non-empty AND no SQL error, else FAIL
  local pa pb ra rb
  pa="$(P "$2" 2>&1)"; ra=$?; pb="$(R "$2" 2>&1)"; rb=$?
  if [ "$ra" != 0 ] || [ "$rb" != 0 ]; then no "$1: the comparison query itself failed (prod rc=$ra restored rc=$rb) — not a valid check"
  elif [ -z "$pa" ]; then no "$1: query returned no rows on production — vacuous check"
  elif [ "$pa" = "$pb" ]; then ok "$1 identical to production ($(printf '%s\n' "$pa" | wc -l) rows compared)"
  else no "$1 DIFFERS from production"; fi
}
cmp_q "roles (attributes + md5 of password hash)" "SELECT rolname,rolsuper,rolcreaterole,rolcreatedb,rolcanlogin,rolreplication,rolbypassrls,rolconnlimit,md5(coalesce(rolpassword,'')) FROM pg_authid WHERE rolname NOT LIKE 'pg\_%' ORDER BY 1"
cmp_q "role memberships" "SELECT r.rolname||'>'||m.rolname FROM pg_auth_members a JOIN pg_roles r ON r.oid=a.roleid JOIN pg_roles m ON m.oid=a.member ORDER BY 1"
cmp_q "table/view/sequence GRANTS (aion_app, aion_migrator)" "SELECT grantee,table_schema,table_name,privilege_type FROM information_schema.role_table_grants WHERE grantee IN ('aion_app','aion_migrator') ORDER BY 1,2,3,4"
cmp_q "column-level and routine grants" "SELECT grantee,table_schema,table_name,column_name,privilege_type FROM information_schema.role_column_grants WHERE grantee IN ('aion_app','aion_migrator') ORDER BY 1,2,3,4,5"
cmp_q "schema + database ACLs" "SELECT 'schema '||nspname||' '||coalesce(nspacl::text,'') FROM pg_namespace WHERE nspname IN ('public','ol_metrics') UNION ALL SELECT 'db '||datname||' owner='||pg_get_userbyid(datdba) FROM pg_database WHERE datname='aion_data' ORDER BY 1"
cmp_q "default privileges" "SELECT defaclrole::regrole::text||' in '||defaclnamespace::regnamespace::text||' '||defaclobjtype::text||' '||defaclacl::text FROM pg_default_acl ORDER BY 1"
cmp_q "object ownership" "SELECT schemaname||'.'||tablename||' '||tableowner FROM pg_tables WHERE schemaname IN ('public','ol_metrics') UNION ALL SELECT schemaname||'.'||viewname||' '||viewowner FROM pg_views WHERE schemaname IN ('public','ol_metrics') ORDER BY 1"
# data identity, using the same fingerprint as the rollout
A="$("$SCRIPT_DIR/db-fingerprint.sh" "$PROD" | md5sum)"; B="$("$SCRIPT_DIR/db-fingerprint.sh" "$C" | md5sum)"
[ "$A" = "$B" ] && ok "data fingerprint (row counts, schema hash, content checksums) identical to production" || no "data fingerprint differs from production (data may have changed since db/$DS)"
# 3) the restored roles must accept the REAL passwords from the archived .env (proves hash == password), via TCP so scram applies
IP="$(docker inspect "$C" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')"
ENVF="$(dec "$D/cfg.gpg" | tar -xOf - opt/aion/.env 2>/dev/null)"
for pair in "aion_app:AION_APP_PASSWORD" "aion_migrator:AION_MIGRATOR_PASSWORD"; do
  role="${pair%%:*}"; var="${pair#*:}"; pw="$(printf '%s\n' "$ENVF" | sed -n "s/^${var}=//p" | head -1)"
  # Passfile (0600, inside the throwaway container, removed right after) instead of PGPASSWORD in a process environment.
  ok_login=0
  if [ -n "$pw" ] && printf '%s:5432:aion_data:%s:%s\n' "$IP" "$role" "$(printf '%s' "$pw" | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g')" | docker exec -i "$C" sh -c 'umask 077; cat > /tmp/.rehearsal_pgpass' \
     && docker exec -e PGPASSFILE=/tmp/.rehearsal_pgpass "$C" psql -h "$IP" -U "$role" -d aion_data -w -tAc "SELECT 1" >/dev/null 2>&1; then ok_login=1; fi
  docker exec "$C" rm -f /tmp/.rehearsal_pgpass >/dev/null 2>&1
  if [ "$ok_login" = 1 ]; then ok "$role logs in over TCP (scram) with the password from the archived .env"; else no "$role could NOT log in with the archived .env password"; fi
done; unset ENVF pw
# least privilege survives the restore: app can read/write data, cannot do DDL
PROBE="$(docker exec "$C" psql -U postgres -d aion_data -c "BEGIN; SET LOCAL ROLE aion_app; CREATE TABLE public.rehearsal_ddl_probe(x int); ROLLBACK;" 2>&1)"
if printf '%s' "$PROBE" | grep -q 'permission denied'; then ok "aion_app cannot run DDL (least privilege intact after restore)"; else no "aion_app DDL was NOT denied after restore — probe said: $(printf '%s' "$PROBE" | head -2 | tr '\n' ' ')"; fi
PROBE2="$(docker exec "$C" psql -U postgres -d aion_data -tAc "SET ROLE aion_app; CREATE TABLE public.rehearsal_ddl_probe2(x int)" 2>&1)"
if printf '%s' "$PROBE2" | grep -q 'permission denied'; then ok "aion_app DDL denied (second probe form, no explicit transaction)"; else no "second DDL probe form NOT denied — said: $(printf '%s' "$PROBE2" | head -2 | tr '\n' ' ')"; fi
# 4) every regular file in the config archive is byte-identical (by hash) to the live file
SAME=0; DIFF=0
while IFS= read -r f; do [ -f "/$f" ] || { DIFF=$((DIFF+1)); log_warn "archived but absent on this host: $f"; continue; }
  a="$(dec "$D/cfg.gpg" | tar -xOf - "$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"; l="$(sha256sum "/$f" | cut -d' ' -f1)"
  [ "$a" = "$l" ] && SAME=$((SAME+1)) || { DIFF=$((DIFF+1)); log_warn "archived != live: $f"; }
done < <(dec "$D/cfg.gpg" | tar -t | grep -v '/$')
[ "$SAME" = 0 ] && { no "config archive listed 0 files — vacuous check"; DIFF=1; }
[ "$DIFF" = 0 ] && ok "all $SAME archived files are identical (by hash) to the live files" || no "$DIFF archived file(s) differ from live"
log_info "=== rehearsal result: $PASS passed, $FAIL failed ==="
[ "$FAIL" = 0 ]
