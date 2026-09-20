#!/bin/bash
# Encrypted off-host backup of the /opt/aion DEPLOYMENT (config + secrets + DB roles).
# Closes the gap found 2026-09-20: the aion_data dump alone does not recover a host — pg_dump of one database
# omits roles (aion_app/aion_migrator + password hashes), and /opt/aion/.env (DB passwords, gateway tokens,
# GHL/OpenRouter keys, image pins) was in no backup at all.
#
# Modes:
#   dry-run        (default) metadata only: which paths exist/size/mode + roles line count. Reads no file contents.
#   local-verify   build -> GPG-encrypt (public key) -> decrypt with the OFFLINE key in a throwaway keyring ->
#                  compare file list -> shred. Nothing leaves the host.
#   run            build -> encrypt -> upload to b2:<bucket>/config-aion/<stamp>/ -> sha256 readback -> keep newest 30.
# Deliberately NOT included: /root/.backup-secrets (GPG private key, B2 keys) — storing the keys that unlock a
# backup inside that backup is circular; those belong in an out-of-band recovery kit (docs/recovery-kit.md).
# Deliberately separate prefix (config-aion/): never touches the legacy full/ GFS archive or db/.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
umask 077
MODE="${1:-dry-run}"; STAMP="${2:-$RUN_STAMP}"; PREFIX="config-aion/${STAMP}"; KEEP=30
PGC="${PG_CONTAINER:-aion-postgres-1}"

ITEMS=(/opt/aion/.env /opt/aion/.env.monitor /opt/aion/docker-compose.yml /opt/aion/system /opt/aion/traefik
       /opt/aion/scripts /opt/aion/bin /opt/aion/ol-metrics.schema.sql /opt/aion/PROVENANCE
       /etc/sudoers.d/aion-deploy /docker/traefik/docker-compose.yml /opt/aion-backup/bin /opt/aion-backup/DISASTER_RECOVERY.md)
for f in /etc/systemd/system/aion-*.service /etc/systemd/system/aion-*.timer; do [ -e "$f" ] && ITEMS+=("$f"); done

EXIST=(); for p in "${ITEMS[@]}"; do [ -e "$p" ] && EXIST+=("$p") || log_warn "absent, skipping: $p"; done

if [ "$MODE" = dry-run ]; then
  log_info "DRY RUN — metadata only, no contents read, nothing written"
  for p in "${EXIST[@]}"; do printf '  %s  %s  %s\n' "$(stat -c '%A %U' "$p")" "$(du -sb "$p" | cut -f1)B" "$p"; done
  log_info "roles/globals: $(docker exec "$PGC" pg_dumpall -U postgres --globals-only 2>/dev/null | wc -l) lines (would be included as roles-globals.sql)"
  log_info "excluded by design: /root/.backup-secrets (circular — see docs/recovery-kit.md)"; exit 0
fi

WORK="$STAGING_DIR/config-aion-${STAMP}"; mkdir -p "$WORK"; ARCH="$STAGING_DIR/aion-config-${STAMP}.tar"
docker exec "$PGC" pg_dumpall -U postgres --globals-only > "$WORK/roles-globals.sql" 2>>"$LOG_FILE" || { alert_failure "aion-config" "pg_dumpall --globals-only failed"; rm -rf "$WORK"; exit 1; }
[ -s "$WORK/roles-globals.sql" ] || { alert_failure "aion-config" "roles dump empty"; rm -rf "$WORK"; exit 1; }
REL=(); for p in "${EXIST[@]}"; do REL+=("${p#/}"); done
tar -cf "$ARCH" -C / "${REL[@]}" -C "$WORK" roles-globals.sql 2>>"$LOG_FILE" || { alert_failure "aion-config" "tar failed"; shred -u "$WORK"/* "$ARCH" 2>/dev/null; rm -rf "$WORK"; exit 1; }
shred -u "$WORK"/roles-globals.sql; rm -rf "$WORK"
EXPECTED="$(tar -tf "$ARCH" | sort)"

if [ "$MODE" = local-verify ]; then
  ENC="$(gpg_encrypt "$ARCH")" || { log_error "encrypt failed"; exit 1; }          # deletes plaintext
  T="$(mktemp -d)"; export GNUPGHOME="$T"; echo "allow-loopback-pinentry" > "$T/gpg-agent.conf"
  gpg --batch --yes --import "$SECRETS_DIR/PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc" >/dev/null 2>&1
  PW="$(sed -n 's/^Passphrase:[[:space:]]*//p' "$SECRETS_DIR/PRIVATE_KEY_PASSPHRASE.txt")"
  GOT="$(echo "$PW" | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 0 --decrypt "$ENC" 2>/dev/null | tar -t | sort)"
  find "$T" -type f -exec shred -u {} \; ; rm -rf "$T"; shred -u "$ENC"
  if [ -n "$GOT" ] && [ "$GOT" = "$EXPECTED" ]; then log_info "LOCAL VERIFY PASS: encrypted archive decrypts and lists exactly the expected $(echo "$EXPECTED" | wc -l) entries (incl. roles-globals.sql); nothing uploaded"; exit 0
  else log_error "LOCAL VERIFY FAIL: decrypted listing differs from expected"; exit 1; fi
fi

[ "$MODE" = run ] || { log_error "unknown mode: $MODE"; shred -u "$ARCH"; exit 2; }
if encrypt_upload_verify "$ARCH" "${PREFIX}/aion-config.tar"; then
  log_info "config backup complete: b2:${B2_BUCKET}/${PREFIX}/aion-config.tar.gpg"
  alert_success "aion-config" "/opt/aion deployment config + roles encrypted, uploaded and checksum-verified to ${PREFIX}"
else alert_failure "aion-config" "encrypt/upload/verify failed — see $LOG_FILE"; exit 1; fi
# retention: newest $KEEP only, this prefix only
rclone lsf "b2:${B2_BUCKET}/config-aion/" --dirs-only 2>>"$LOG_FILE" | sed 's#/$##' | sort | head -n -"$KEEP" | while read -r old; do
  [ -n "$old" ] && log_info "pruning config-aion/$old" && rclone purge "b2:${B2_BUCKET}/config-aion/$old" 2>>"$LOG_FILE"; done
exit 0
