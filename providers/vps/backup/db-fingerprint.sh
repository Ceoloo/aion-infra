#!/bin/bash
# usage: db-fingerprint.sh [container] [database] — deterministic fingerprint (exact row counts, schema hash, content
# checksums of executions/approvals, parked approvals). Prints no row contents; used to prove restores/rollouts lost nothing.
# deterministic DB fingerprint: exact counts + schema hash + key rows (no payload content)
CT="${1:-aion-postgres-1}"; DB="${2:-aion_data}"
Q() { docker exec "$CT" psql -U postgres -d "$DB" -tA -c "$1"; }
echo "## exact row counts"
for t in $(Q "SELECT schemaname||'.'||relname FROM pg_stat_user_tables ORDER BY 1"); do echo "$t $(Q "SELECT count(*) FROM $t")"; done
echo "## schema hash (columns+types)"; Q "SELECT md5(string_agg(table_schema||'.'||table_name||'.'||column_name||':'||data_type, ',' ORDER BY table_schema,table_name,ordinal_position)) FROM information_schema.columns WHERE table_schema IN ('public','ol_metrics')"
echo "## migrations"; Q "SELECT count(*) FROM schema_migrations"
echo "## approvals by status"; Q "SELECT status||':'||count(*) FROM approvals GROUP BY status ORDER BY 1"
echo "## parked approvals"; Q "SELECT approval_id||' '||status||' '||risk_level FROM approvals WHERE status='pending' ORDER BY approval_id"
echo "## executions by status"; Q "SELECT status||':'||count(*) FROM executions GROUP BY status ORDER BY 1"
echo "## latest execution"; Q "SELECT execution_id||' '||status||' '||created_at FROM executions ORDER BY created_at DESC, execution_id LIMIT 1"
echo "## content checksum of executions+approvals ids/status"; Q "SELECT md5(string_agg(execution_id||status, ',' ORDER BY execution_id)) FROM executions"; Q "SELECT md5(string_agg(approval_id||status, ',' ORDER BY approval_id)) FROM approvals"
