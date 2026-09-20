#!/usr/bin/env bash
# ============================================================================
# report-stale-approvals.sh — READ-ONLY visibility into aged approval gates.
# ============================================================================
# aion-infra#12 found 3 approvals sitting pending/awaiting_approval for 8-12
# days with no timeout or escalation. This script only reports; it never
# approves, rejects, or replays anything — that decision belongs to the
# mission owner (see the audit doc: never auto-approve or replay those 3
# specific executions).
#
# Usage:
#   DATABASE_URL=<a READ-capable aion_app URL> ./report-stale-approvals.sh
#   Or run against the local Mode-A Postgres from the host:
#     docker exec aion-postgres-1 psql -U aion_app -d aion_data -f - < report-stale-approvals.sh (no — see below)
#
# Simplest on the VPS (reuses the running aion-postgres-1 container, no new
# credentials needed):
#   STALE_HOURS=24 ./report-stale-approvals.sh
set -euo pipefail

STALE_HOURS="${STALE_HOURS:-24}"
CONTAINER="${POSTGRES_CONTAINER:-aion-postgres-1}"
DB="${POSTGRES_DB:-aion_data}"
USER="${POSTGRES_USER:-postgres}"

# STALE_HOURS is operator-set (not external/untrusted input); validate it is
# a plain integer before interpolating into SQL.
[[ "${STALE_HOURS}" =~ ^[0-9]+$ ]] || { echo "STALE_HOURS must be a positive integer" >&2; exit 1; }

echo "[report-stale-approvals] approvals older than ${STALE_HOURS}h still pending/awaiting (read-only)"
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "
SELECT
  a.approval_id,
  a.status,
  a.risk_level,
  a.mission_id,
  a.requested_at,
  ROUND(EXTRACT(EPOCH FROM (now() - a.requested_at)) / 3600.0, 1) AS age_hours,
  e.status AS execution_status
FROM approvals a
LEFT JOIN executions e ON e.approval_id = a.approval_id
WHERE a.status = 'pending'
  AND a.requested_at < now() - interval '${STALE_HOURS} hours'
ORDER BY a.requested_at ASC;
"

echo
echo "[report-stale-approvals] executions stuck awaiting_approval (their approval row, if any, above)"
docker exec "${CONTAINER}" psql -U "${USER}" -d "${DB}" -c "
SELECT execution_id, status, autonomy_level, approval_id, mission_id, created_at
FROM executions
WHERE status = 'awaiting_approval'
ORDER BY created_at ASC;
"

echo
echo "[report-stale-approvals] this script changed nothing. Resolve per mission owner, never by direct SQL:"
echo "  A raw UPDATE of approvals leaves the run and execution at awaiting_approval and skips the audit event."
echo "  Use the runtime's decision route, as the verified human approver (only after reviewing the command_snapshot):"
echo "    POST /v1/approvals/<approvalId>/decision   {\"approve\":false,\"decidedBy\":\"<operator actor id>\",\"note\":\"<why>\"}"
echo "  See docs/stale-approval-disposition.md."
