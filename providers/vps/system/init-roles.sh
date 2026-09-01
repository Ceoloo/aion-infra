#!/usr/bin/env bash
# ============================================================================
# init-roles.sh — first-boot creation of the two least-privilege DB roles.
# ============================================================================
# Runs ONCE, inside the postgres container's docker-entrypoint-initdb.d, only
# for Mode A (local DB). It creates the SAME two roles every provider uses —
# aion_app (DML) and aion_migrator (DDL) — so the two-role model holds on a VPS
# exactly as on Cloud SQL / RDS. Table-level privileges (append-only logs, no
# DDL for app) are applied later by the migrate step from grants.sql shipped in
# the aion-runtime image (ADR-002), NOT here.
#
# Passwords come from the environment (AION_APP_PASSWORD / AION_MIGRATOR_PASSWORD),
# injected from the root-owned 0600 .env — never hardcoded.
set -euo pipefail

: "${AION_APP_PASSWORD:?}"
: "${AION_MIGRATOR_PASSWORD:?}"
DB="${POSTGRES_DB:-aion_data}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${DB}" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aion_migrator') THEN
    CREATE ROLE aion_migrator LOGIN PASSWORD '${AION_MIGRATOR_PASSWORD}';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'aion_app') THEN
    CREATE ROLE aion_app LOGIN PASSWORD '${AION_APP_PASSWORD}';
  END IF;
END
\$\$;

-- The migrator owns the schema so it can run DDL and later shape grants.
GRANT ALL ON SCHEMA public TO aion_migrator;
ALTER DATABASE ${DB} OWNER TO aion_migrator;
SQL

echo "[init-roles] aion_app + aion_migrator created; migrator owns ${DB}"
