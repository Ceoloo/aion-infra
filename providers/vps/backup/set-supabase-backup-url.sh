#!/usr/bin/env bash
# set-supabase-backup-url.sh — store the Supabase connection string for the nightly backup
# without it touching the screen, shell history, argv (ps) or a transcript.
#
#   bash /root/set-supabase-backup-url.sh
#
# Paste ONLY the database password (Supabase → Project Settings → Database). The script
# builds the Session-pooler URI itself and URL-encodes the password. It is tested with `select 1` before being saved, then the
# first backup runs and the nightly timer is enabled.
set -euo pipefail
umask 077
[ "$(id -u)" -eq 0 ] || { echo "run as root"; exit 1; }

DEST=/root/.backup-secrets/supabase-db.env
HOST=aws-1-us-east-2.pooler.supabase.com   # Session pooler for us-east-2 (aws-0 says "tenant not found")
read -r -s -p "Paste the Supabase DATABASE PASSWORD only (input hidden): " PW; echo
PW="${PW%$'\r'}"
[ -n "$PW" ] || { echo "empty password; nothing saved"; exit 1; }
# URL-encode the password (special characters like @ # / : % break a raw URI); via stdin, never argv
ENC="$(printf '%s' "$PW" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(),safe=""))')"
unset PW
URL="postgresql://postgres.qbahthzqvxytfgobgtxa:${ENC}@${HOST}:5432/postgres"
unset ENC

TMP="$(mktemp /root/.backup-secrets/.supabase-db.env.XXXXXX)"
printf 'SUPABASE_DB_URL=%s\n' "$URL" > "$TMP"
unset URL

echo "testing connection..."
if ! docker run --rm --env-file "$TMP" postgres:17 \
     sh -c 'psql "$SUPABASE_DB_URL" -Atqc "select 1"' >/dev/null 2>"$TMP.err"; then
  shred -u "$TMP"
  echo "connection FAILED. Nothing saved. psql said:"
  sed -E 's#//[^@]*@#//***@#g' "$TMP.err" | sort -u | head -3; rm -f "$TMP.err"
  exit 1
fi
rm -f "$TMP.err"; mv "$TMP" "$DEST"; chmod 600 "$DEST"
echo "connection OK, saved to $DEST"

echo "running the first backup (can take a minute)..."
if systemctl start aion-backup-supabase.service; then
  systemctl enable --now aion-backup-supabase.timer >/dev/null
  echo "first backup OK; nightly timer enabled (02:50 UTC)."
else
  echo "first backup FAILED — timer NOT enabled. See: journalctl -u aion-backup-supabase.service -n 50"
  exit 1
fi
