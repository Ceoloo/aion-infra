# Database

Managed PostgreSQL for the AION Data workload: **Cloud SQL for PostgreSQL 16**,
provisioned by the `database` Terraform module. It is compatible with aion-data's
schema and migration runner; aion-data's migrations remain **authoritative** for
shape — this repo forks no schema (aion-infra §11).

## Configuration

| Requirement (§11) | How |
|---|---|
| PostgreSQL 16 | `database_version = "POSTGRES_16"` |
| Encrypted at rest | Google-managed encryption (CMEK optional, not required Phase 3) |
| Encrypted in transit | `ssl_mode = ENCRYPTED_ONLY`; clients use `sslmode=require` |
| Automated backups | `backup_configuration.enabled = true`, daily at `03:00` UTC |
| Point-in-time recovery | `point_in_time_recovery_enabled = true`, WAL retained `transaction_log_retention_days` (default 7) |
| Production deletion protection | `deletion_protection` + `deletion_protection_enabled` (both true in prod) |
| Maintenance window | Sunday 04:00 UTC, `stable` track |
| Staging/production separation | separate projects, instances, and credentials |
| No public access | `ipv4_enabled = false`, private IP only |

Staging is smaller (`db-custom-1-3840`, zonal, no deletion protection so it is
rebuildable); production is HA (`REGIONAL`, `db-custom-2-7680`, deletion
protection on, 30 retained backups).

## Roles (two-role least privilege)

Created by Terraform (`google_sql_user`); privileges shaped by
[`runtime/sql/grants.sql`](../runtime/sql/grants.sql):

- **`aion_app`** — runtime DML. `SELECT/INSERT/UPDATE` on canonical tables,
  `UPDATE` only where operational state is mutable (`runs`, `missions`,
  `approvals`, `actors`, `outcomes`). **No DDL. No UPDATE/DELETE on `events` or
  `telemetry_records`** (append-only facts).
- **`aion_migrator`** — DDL/admin, owns the schema and the `schema_migrations`
  ledger. Used only by the migration job.

Passwords are never committed; they are injected via `TF_VAR_*` and become the
values inside the Secret Manager connection strings.

## Migrations (aion-infra §18)

AION Data's own runner is authoritative — **no second migration system is
invented here**. Flow, enforced by the pipeline:

```
validate release
   ↓
migration JOB (migrator identity)
   ↓  1. apply pending aion-data migrations   (runtime/src/migrate.ts → dl.migrate())
   ↓  2. apply aion-infra grants.sql          (least-privilege privileges)
   ↓  (any failure → non-zero exit → deploy HALTS; existing runtime intact)
deploy runtime (new image)
   ↓
health check → smoke test
```

- **Migration-before-deploy**: Phase 2 migration `0001` is backward-safe
  (additive), so applying schema before rolling the new runtime is safe.
- **Fail-closed**: a failed migration stops the deploy before the service is
  updated (§46, §63) — verified locally (see [phase-3.md](phase-3.md)).
- **Forward-only**: aion-data migrations are forward-only; rollback philosophy is
  "restore previous runtime + forward-fix schema" (see
  [backup-recovery.md](backup-recovery.md) and aion-infra §47).

### Applying migrations

- **CI**: the migration Cloud Run job runs automatically before each deploy.
- **Manual/local**: `providers/gcp/scripts/migrate.sh <env>` (cloud) or
  `MODE=local MIGRATION_DATABASE_URL=... providers/gcp/scripts/migrate.sh local`.

## Connection strings

Assembled by Terraform from the instance private IP + injected passwords and
stored in Secret Manager (never printed):

```
postgresql://aion_app:<pw>@<private-ip>:5432/aion_data?sslmode=require        # runtime
postgresql://aion_migrator:<pw>@<private-ip>:5432/aion_data?sslmode=require    # migrate job
```

## Backups & recovery

See [backup-recovery.md](backup-recovery.md) for retention, PITR, RPO/RTO, and
the restore-verification procedure.
