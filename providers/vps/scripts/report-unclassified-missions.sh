#!/usr/bin/env bash
# ============================================================================
# report-unclassified-missions.sh — READ-ONLY KPI classification indicator.
# ============================================================================
# After providers/vps/sql/ol-metrics-reconciled.sql is applied, KPIs count only missions a person classified
# 'production'; a NEW mission is therefore invisible to KPIs until classified. This prints the to-do list and exits
# non-zero when any mission has waited longer than MAX_AGE_HOURS, so a timer/monitor can page on it.
# It changes nothing. Before the SQL is applied it says so and exits 0 (nothing to indicate yet).
#   exit 0 = none overdue (or SQL not applied)   1 = overdue unclassified missions   2 = could not query
# Usage: MAX_AGE_HOURS=24 ./report-unclassified-missions.sh
set -euo pipefail
MAX_AGE_HOURS="${MAX_AGE_HOURS:-24}"
CONTAINER="${POSTGRES_CONTAINER:-aion-postgres-1}"
DB="${POSTGRES_DB:-aion_data}"
DBUSER="${POSTGRES_USER:-postgres}"
[[ "${MAX_AGE_HOURS}" =~ ^[0-9]+$ ]] || { echo "MAX_AGE_HOURS must be a non-negative integer" >&2; exit 2; }
q() { docker exec "${CONTAINER}" psql -U "${DBUSER}" -d "${DB}" -X -tA -F '|' -v ON_ERROR_STOP=1 -c "$1"; }

have="$(q "SELECT to_regclass('ol_metrics.classification_health') IS NOT NULL" 2>/dev/null)" || { echo "[unclassified-missions] cannot query ${CONTAINER}/${DB}" >&2; exit 2; }
if [ "${have}" != "t" ]; then
  echo "[unclassified-missions] ol_metrics.classification_health not installed (KPI reconciliation SQL not applied) — nothing to report"
  exit 0
fi
IFS='|' read -r unclassified oldest unverified last_change < <(q "SELECT unclassified_count, coalesce(oldest_unclassified_created_at::text,''), unverified_count, coalesce(last_classification_change_at::text,'') FROM ol_metrics.classification_health")
echo "[unclassified-missions] unclassified=${unclassified} (excluded from KPIs until classified)  unverified=${unverified}  oldest_unclassified=${oldest:--}  last_classification_change=${last_change:--}"
if [ "${unclassified}" -gt 0 ]; then
  q "SELECT mission_id, created_at, status, coalesce(cohort_hint,'-'), coalesce(console_production_flag,'-'), coalesce(console_synthetic_flag,'-') FROM ol_metrics.unclassified_missions ORDER BY created_at" \
    | awk -F'|' '{printf "  %s  created=%s status=%s cohort_hint=%s console_production_flag=%s console_synthetic_flag=%s\n",$1,$2,$3,$4,$5,$6}'
  overdue="$(q "SELECT count(*) FROM ol_metrics.unclassified_missions WHERE created_at < now() - interval '${MAX_AGE_HOURS} hours'")"
  if [ "${overdue}" -gt 0 ]; then echo "[unclassified-missions] ${overdue} mission(s) unclassified for more than ${MAX_AGE_HOURS}h — classify per docs/kpi-decision-package.md"; exit 1; fi
fi
exit 0
