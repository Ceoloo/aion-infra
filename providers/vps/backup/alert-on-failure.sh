#!/bin/bash
# Invoked by systemd's OnFailure= as a second, independent alerting path —
# catches failures the backup scripts themselves can't report (OOM kill,
# permission errors before common.sh even loads, systemd start failures).
# Takes the failed unit name as $1 (systemd passes %n).

SECRETS_DIR="/root/.backup-secrets"
[ -f "$SECRETS_DIR/ntfy.env" ] && source "$SECRETS_DIR/ntfy.env"

UNIT="${1:-unknown-unit}"

if [ -z "${NTFY_TOPIC:-}" ]; then
    logger -t aion-backup "OnFailure fired for $UNIT but NTFY_TOPIC not configured"
    exit 0
fi

curl -sS --fail --max-time 15 \
    -H "Title: AION Backup: systemd unit failed" \
    -H "Priority: high" \
    -d "Unit ${UNIT} failed to run or exited non-zero at the systemd level (not a script-reported failure). Host: $(hostname). Check: journalctl -u ${UNIT}" \
    "${NTFY_URL:-https://ntfy.sh}/${NTFY_TOPIC}" >/dev/null \
    || { logger -t aion-backup "OnFailure alert for $UNIT was NOT delivered (ntfy unreachable or rejected)"; exit 1; }
