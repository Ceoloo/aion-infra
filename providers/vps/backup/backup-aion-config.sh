#!/bin/bash
# Encrypted off-host backup of the /opt/aion DEPLOYMENT: config + secrets, DR scripts, systemd units, sudoers,
# Traefik compose, and the Postgres ROLES (with password hashes).
#
# Why: pg_dump of one database omits roles, and /opt/aion/.env (DB passwords, gateway tokens, GHL/OpenRouter keys,
# image pins) was in no backup. Grants/ownership live inside the aion_data dump (custom format keeps ACLs) and are
# re-applied by the migrate step; restoring roles first is what makes them land.
#
# NO PLAINTEXT ARTIFACT TOUCHES DISK: tar and pg_dumpall stream straight into GPG (public-key encryption to the
# backup recipient). Only ciphertext is ever staged. Two objects per run, under b2:<bucket>/config-aion/<stamp>/ :
#   aion-config.tar.gpg       (allow-listed paths only)
#   roles-globals.sql.gpg     (pg_dumpall --globals-only: roles, memberships, SCRAM password hashes)
#
# Modes:
#   dry-run              (default) metadata only — path/size/mode, no contents read, nothing written
#   local-verify         build ciphertext, verify recipient + scope via the OFFLINE key in a throwaway keyring, shred
#   run                  build -> encrypt -> upload -> sha256 readback -> prune (newest 30) -> notify
#   verify <stamp>       download from B2 -> recipient check -> decrypt (offline key, throwaway keyring) -> scope check
#                        -> roles present -> archived .env matches the live .env (hash compare) ; prints names/counts only
# Excluded by design: /root/.backup-secrets (keys that unlock a backup cannot live only inside that backup).
# Separate prefix: never touches the legacy full/ archive or db/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
umask 077
MODE="${1:-dry-run}"; STAMP="${2:-cfg_$RUN_STAMP}"; PREFIX="config-aion/${STAMP}"; KEEP=30
PGC="${PG_CONTAINER:-aion-postgres-1}"
FPR="$(cat "$GPG_RECIPIENT_FILE")"

ITEMS=(/opt/aion/.env /opt/aion/.env.monitor /opt/aion/docker-compose.yml /opt/aion/system /opt/aion/traefik
       /opt/aion/scripts /opt/aion/bin /opt/aion/ol-metrics.schema.sql /opt/aion/PROVENANCE
       /etc/sudoers.d/aion-deploy /docker/traefik/docker-compose.yml /opt/aion-backup/bin /opt/aion-backup/DISASTER_RECOVERY.md)
for f in /etc/systemd/system/aion-*.service /etc/systemd/system/aion-*.timer; do [ -e "$f" ] && ITEMS+=("$f"); done
EXIST=(); REL=()
for p in "${ITEMS[@]}"; do if [ -e "$p" ]; then EXIST+=("$p"); REL+=("${p#/}"); else log_warn "absent, skipping: $p"; fi; done

CT_CFG="$STAGING_DIR/aion-config-${STAMP}.tar.gpg"; CT_ROLES="$STAGING_DIR/roles-globals-${STAMP}.sql.gpg"
cleanup() { rm -f "$CT_CFG" "$CT_ROLES" 2>/dev/null; [ -n "${OFFT:-}" ] && teardown_offline_keyring; }
trap cleanup EXIT

# ---- checks that never expose contents ------------------------------------------------------------------------
# The encrypted object must have exactly ONE recipient key and it must belong to the configured backup fingerprint.
recipient_check() {
  local f="$1" kids pk n
  kids="$(gpg --list-keys --with-colons "$FPR" 2>/dev/null | awk -F: '$1=="pub"||$1=="sub"{print toupper($5)}')"
  pk="$(gpg --list-packets "$f" 2>/dev/null | awk '/^:pubkey enc packet:/{for(i=1;i<=NF;i++) if($i=="keyid") print toupper($(i+1))}')"
  n="$(printf '%s\n' "$pk" | grep -c .)"
  [ "$n" = 1 ] && printf '%s\n' "$kids" | grep -qx "$pk" && { log_info "recipient OK: $(basename "$f") is encrypted to exactly one key, a key of fingerprint ${FPR:0:8}…${FPR: -8}"; return 0; }
  log_error "recipient CHECK FAILED for $(basename "$f") (recipients found: $n)"; return 1
}
# Reads a tar listing on stdin; every path must sit inside the allow-list and none may look like key material.
scope_check() {
  local p a ok bad=0 n=0
  while IFS= read -r p; do
    p="${p#./}"; p="${p%/}"; [ -z "$p" ] && continue; n=$((n+1)); ok=0
    for a in "${REL[@]}"; do case "$p" in "$a"|"$a"/*) ok=1 ;; esac; done
    [ "$ok" = 1 ] || { log_error "OUT OF SCOPE entry: $p"; bad=1; }
    case "$p" in *backup-secrets*|*PRIVATE*|*.asc|*id_rsa*|*id_ed25519*|*.gnupg*|*authorized_keys*) log_error "FORBIDDEN key-like entry: $p"; bad=1 ;; esac
  done
  [ "$bad" = 0 ] && { log_info "scope OK: $n entries, all inside the allow-list, no key material"; return 0; }; return 1
}
setup_offline_keyring() {
  OFFT="$(mktemp -d)"; chmod 700 "$OFFT"; echo "allow-loopback-pinentry" > "$OFFT/gpg-agent.conf"
  GNUPGHOME="$OFFT" gpg --batch --yes --import "$SECRETS_DIR/PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc" >/dev/null 2>&1 || { log_error "offline key import failed"; return 1; }
  OFFPW="$(sed -n 's/^Passphrase:[[:space:]]*//p' "$SECRETS_DIR/PRIVATE_KEY_PASSPHRASE.txt")"
}
teardown_offline_keyring() {
  GNUPGHOME="$OFFT" gpgconf --kill gpg-agent >/dev/null 2>&1; find "$OFFT" -type f -exec shred -u {} \; 2>/dev/null; rm -rf "$OFFT"; OFFT=""; OFFPW=""
}
dec() { echo "$OFFPW" | GNUPGHOME="$OFFT" gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt "$1" 2>/dev/null; }

verify_objects() {   # $1 config ciphertext  $2 roles ciphertext
  local cfg="$1" roles="$2" rc=0 c1 c2 c3 sha_a sha_l
  recipient_check "$cfg" || rc=1; recipient_check "$roles" || rc=1
  setup_offline_keyring || return 1
  dec "$cfg" | tar -t | scope_check || rc=1
  c1="$(dec "$roles" | grep -c '^CREATE ROLE aion_app\b')"; c2="$(dec "$roles" | grep -c '^CREATE ROLE aion_migrator\b')"; c3="$(dec "$roles" | grep -c "PASSWORD 'SCRAM-SHA-256")"
  if [ "$c1" -ge 1 ] && [ "$c2" -ge 1 ] && [ "$c3" -ge 2 ]; then log_info "roles OK: aion_app + aion_migrator present with SCRAM password hashes (hashes not printed)"; else log_error "roles CHECK FAILED (app=$c1 migrator=$c2 hashes=$c3)"; rc=1; fi
  sha_a="$(dec "$cfg" | tar -xOf - opt/aion/.env 2>/dev/null | sha256sum | cut -d' ' -f1)"; sha_l="$(sha256sum /opt/aion/.env | cut -d' ' -f1)"
  if [ "$sha_a" = "$sha_l" ]; then log_info "content identity OK: archived .env hash == live .env hash (compared by hash, not shown)"; else log_warn "archived .env differs from the live .env (edited since this backup?)"; rc=2; fi
  teardown_offline_keyring; return $rc
}

build_ciphertext() {   # streams; returns non-zero if any stage failed
  tar -cf - -C / "${REL[@]}" 2>>"$LOG_FILE" | gpg --batch --yes --trust-model always --recipient "$FPR" --output "$CT_CFG" --encrypt 2>>"$LOG_FILE"
  local a=("${PIPESTATUS[@]}"); [ "${a[0]}" = 0 ] && [ "${a[1]}" = 0 ] || { log_error "config archive stream failed (tar=${a[0]} gpg=${a[1]})"; return 1; }
  docker exec "$PGC" pg_dumpall -U postgres --globals-only 2>>"$LOG_FILE" | gpg --batch --yes --trust-model always --recipient "$FPR" --output "$CT_ROLES" --encrypt 2>>"$LOG_FILE"
  a=("${PIPESTATUS[@]}"); [ "${a[0]}" = 0 ] && [ "${a[1]}" = 0 ] || { log_error "roles stream failed (pg_dumpall=${a[0]} gpg=${a[1]})"; return 1; }
  [ -s "$CT_CFG" ] && [ -s "$CT_ROLES" ] || { log_error "empty ciphertext"; return 1; }
}

case "$MODE" in
dry-run)
  log_info "DRY RUN — metadata only, no contents read, nothing written"
  for p in "${EXIST[@]}"; do printf '  %s  %s  %s\n' "$(stat -c '%A %U' "$p")" "$(du -sb "$p" | cut -f1)B" "$p"; done
  log_info "roles/globals: $(docker exec "$PGC" pg_dumpall -U postgres --globals-only 2>/dev/null | wc -l) lines would be encrypted as roles-globals.sql.gpg"
  log_info "recipient: fingerprint ${FPR:0:8}…${FPR: -8} (public key only on this host)"; exit 0 ;;
local-verify)
  build_ciphertext || exit 1
  verify_objects "$CT_CFG" "$CT_ROLES"; rc=$?
  [ "$rc" -le 2 ] && [ "$rc" != 1 ] && { log_info "LOCAL VERIFY PASS (nothing uploaded, no plaintext written)"; exit 0; }
  log_error "LOCAL VERIFY FAIL"; exit 1 ;;
verify)
  [ -n "${2:-}" ] || { log_error "usage: verify <stamp>"; exit 2; }
  D="$(mktemp -d -p "$STAGING_DIR")"; chmod 700 "$D"; trap 'rm -rf "$D"; cleanup' EXIT
  rclone_retry copyto "b2:${B2_BUCKET}/${PREFIX}/aion-config.tar.gpg" "$D/cfg.gpg" 2>>"$LOG_FILE" && rclone_retry copyto "b2:${B2_BUCKET}/${PREFIX}/roles-globals.sql.gpg" "$D/roles.gpg" 2>>"$LOG_FILE" \
    || { log_error "download from B2 failed for ${PREFIX}"; exit 1; }
  log_info "downloaded both objects from b2:${B2_BUCKET}/${PREFIX}/ ($(stat -c %s "$D/cfg.gpg") and $(stat -c %s "$D/roles.gpg") bytes, ciphertext)"
  verify_objects "$D/cfg.gpg" "$D/roles.gpg"; rc=$?; [ "$rc" = 1 ] && { log_error "B2 VERIFY FAIL"; exit 1; }
  log_info "B2 VERIFY PASS: upload -> download -> decrypt (offline key) -> scope/roles/identity checks"; exit 0 ;;
run)
  if ! build_ciphertext; then alert_failure "aion-config" "stream/encrypt failed — see $LOG_FILE"; exit 1; fi
  recipient_check "$CT_CFG" && recipient_check "$CT_ROLES" || { alert_failure "aion-config" "recipient check failed — nothing uploaded"; exit 1; }
  for pair in "$CT_CFG:${PREFIX}/aion-config.tar.gpg" "$CT_ROLES:${PREFIX}/roles-globals.sql.gpg"; do
    f="${pair%%:*}"; r="${pair#*:}"
    b2_upload "$f" "$r" && b2_verify "$f" "$r" || { alert_failure "aion-config" "upload/readback failed for ${r}"; exit 1; }
  done
  log_info "config backup uploaded and checksum-verified: b2:${B2_BUCKET}/${PREFIX}/ (2 objects)"
  rclone lsf "b2:${B2_BUCKET}/config-aion/" --dirs-only 2>>"$LOG_FILE" | sed 's#/$##' | sort | head -n -"$KEEP" | while read -r old; do
    [ -n "$old" ] && log_info "pruning config-aion/$old" && rclone purge "b2:${B2_BUCKET}/config-aion/$old" 2>>"$LOG_FILE"; done
  alert_success "aion-config" "deployment config + roles encrypted, uploaded, checksum-verified: ${PREFIX}"; exit 0 ;;
*) log_error "unknown mode: $MODE"; exit 2 ;;
esac
