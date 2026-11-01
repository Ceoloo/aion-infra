# Legacy Supabase island (`qbahthzqvxytfgobgtxa`)

Operational home for hotfixes against the live AION EMPIRE SYSTEM Supabase
project. Nightly backups already live under `providers/vps/backup/`.

The canonical long-term owner of these RPCs is
`AION-Sys/Ceoloo-aion-revenue-copilot` (`supabase/migrations/`). Cursor agents
currently cannot push there (403). Until write access exists, land ledger SQL
here, apply on the VPS with the backup role connection, then mirror upstream.

## AIO-116 / AIO-117 / AIO-118

| Issue | Fix |
| --- | --- |
| [AIO-116](https://linear.app/aion-empire/issue/AIO-116) | `revex_log_attested_send` — human-attested email/call logging that agents can record without bypassing `gmail.send` prohibition |
| [AIO-117](https://linear.app/aion-empire/issue/AIO-117) | `revex_mark_collected` raises on unknown id, is idempotent on re-collect, returns jsonb |
| [AIO-118](https://linear.app/aion-empire/issue/AIO-118) | Draft rows resolve on later non-draft outreach; view hardened; one-time backfill |

### Local proof (no live secrets)

```bash
cd providers/supabase-legacy
./test/run-ledger-fix-tests.sh
```

Requires local Postgres 16+ and `psql` on `PATH`. Creates and drops a disposable database.

### Live apply (maintainer on VPS)

1. Take a fresh dump (`aion-backup-supabase.service` or manual `pg_dump`).
2. Capture live definitions for comparison:

```bash
./scripts/capture-live-revex-defs.sh   # uses SUPABASE_DB_URL from env or --env-file
```

3. Review `migrations/20261101193000_aio116_117_118_revex_ledger_fixes.sql`.
   If live `revex_log_outreach` arity differs from the migration comment block,
   adjust before apply.
4. Apply once as the migration role (Session pooler URI in
   `/root/.backup-secrets/supabase-db.env` on the VPS):

```bash
./scripts/apply-migration.sh migrations/20261101193000_aio116_117_118_revex_ledger_fixes.sql
```

5. Mirror the same SQL into
   `AION-Sys/Ceoloo-aion-revenue-copilot/supabase/migrations/` when push access
   is available so the island is versioned again.
6. Comment evidence on AIO-116/117/118 and close when CEO waits shrink and
   touches/revenue.collected behave.

**Do not** put this schema into `aion-data` — that repo is the greenfield
control-plane SoR (ADR-001 / ADR-015).
