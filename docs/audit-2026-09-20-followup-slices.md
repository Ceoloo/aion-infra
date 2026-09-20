# Follow-up slices — 2026-09-20 (after aion-infra#12)

Continuation of `docs/audit-2026-09-20-vps-execution-readiness.md`. First
slice (runtime failure detection) is implemented, tested, and live. This
document covers what was resolved outright, what was prepared but not
applied, and what remains a plan.

## Explicitly resolved: which store is canonical

**Production Runtime uses local PostgreSQL only (Mode A). It does not use
Supabase.** Confirmed directly, not inferred:

- `/opt/aion/.env`: `DATABASE_URL` and `MIGRATION_DATABASE_URL` both resolve
  to `postgres:5432/aion_data` — `postgres` is the compose-internal hostname
  for the `aion-postgres-1` container on this same host. Zero `SUPABASE_*`
  vars exist anywhere in `/opt/aion/.env`.
- `aion_data` (owned by `aion_migrator`, app role `aion_app`) holds the
  canonical tables: `missions`, `runs`, `executions`, `approvals`, `events`,
  `external_side_effects`, `outcomes`, `telemetry_records`, `services`,
  `actors`, `workflows`, `autonomy_grants`, `evaluation_results`,
  `revenue_sessions`, `schema_migrations`, plus `ol_metrics.*`. **This is
  the only store `aion-runtime` writes to for execution state** — there is
  no dual-write, no second sink.
- The separate Supabase project (`qbahthzqvxytfgobgtxa`, "AION EMPIRE
  SYSTEM") belongs to an **unrelated system** — `/root/AION` +
  `/root/aion-company-os`, driven by root cron, with its own `revenue_*`
  schema. It has no relationship to `/opt/aion` or `aion_data`. Do not
  conflate the two when reasoning about "the" canonical store — there are
  two canonical stores, for two different systems, on the same box.

**Did the earlier local proof (the "$1,500 / 4 cost units / 3 R2 gates"
milestone) use this database?** Not fully resolved — what's confirmed:
`aion_data.outcomes` has zero rows system-wide and `executions.
revenue_attributed` is NULL on every row, so if the proof ran against this
database, its outcome-recording step never completed or was cleaned up
without a trace. What's newly relevant: **this session found 3 real
`approvals` rows, all `risk_level='R2'`, all still `pending`/
`awaiting_approval`, dated 2026-09-08 and 2026-09-12** — plausibly remnants
of that exact proof run, left mid-flight rather than completed and swept.
This is circumstantial, not confirmed (no `metadata` tag or run label ties
them to "the" proof specifically). **Do not resolve this by guessing** —
either trace it via `aion-runtime`'s own test/CI logs from that date, or
treat the milestone as needing a clean re-run (below) and stop trying to
retroactively validate the old one.

## Re-running the revenue proof against canonical storage

Plan (not executed this session — would create real rows in production
`aion_data`, which needs the same care as any other production write):

1. Identify the exact mission/workflow the original proof used (check
   `aion-runtime`'s test suite / CI artifacts for the run that produced the
   "$1,500" figure — this determines whether it's re-runnable as-is or
   needs updating for schema drift since then).
2. Run it against `aion_data` via the **same path a real caller would use**
   (the `/v1/...` HTTP surface through the Execution Gateway, not a direct
   DB write) so the proof actually exercises approval gates, not just
   schema inserts.
3. After it completes, verify placement, not just "no error":
   ```sql
   SELECT outcome_id, run_id, status, outcome_type, value, currency
   FROM outcomes WHERE run_id = '<the run>';
   SELECT execution_id, revenue_attributed, cost
   FROM executions WHERE run_id = '<the run>';
   ```
   A real pass means `outcomes` gets a `status='realized'` row with a
   `value`/`currency`, AND/OR `executions.revenue_attributed` is non-NULL
   for the relevant execution — not just "the script exited 0".
4. Tag every row this produces (e.g. a `metadata.label` or a dedicated
   `source_system` value) so it is unambiguously identifiable and
   removable — same discipline as the P8F synthetic-canary convention
   already used elsewhere in AION (tag, verify, clean up, reconfirm zero
   residue).
5. Report the result as exactly what it is: a **synthetic proof result**
   with real persistence, not realized business revenue. Per this mission's
   own instruction — do not describe $1,500 (old or re-run) as realized
   revenue without actual business evidence (a real GHL opportunity, a real
   payment, something external to AION's own database) backing it.

**Status: plan only. Not run.** Needs the mission/workflow identification
step (1) before it can proceed, and should go through the same review as
any other production-writing action.

## Stale approvals — found, not touched

`providers/vps/scripts/report-stale-approvals.sh` (read-only, tested against
production this session) confirms 3 rows, all `risk_level='R2'`:

| approval_id | mission_id | requested_at | age (at time of check) |
|---|---|---|---|
| `apr_c7e02e9f-76a9-4307-9b93-23872b88f666` | `msn_30fd4f95-6e33-4a6f-aab4-6524cdbf44ad` | 2026-09-08 05:23:03 | ~289h |
| `apr_46feebb7-a24d-491b-8e7e-d742a31818db` | `msn_59c5efb6-d9eb-47ab-a70d-15607728f002` | 2026-09-08 06:37:37 | ~288h |
| `apr_63a095b9-b175-4089-8647-c95e9e28c2e1` | `msn_0e3c5c21-6bd4-4858-9232-032a399932d9` | 2026-09-12 01:12:50 | ~197h |

Each has a matching `executions` row stuck `status='awaiting_approval'`.
**Per this mission's instruction, none were approved, rejected, or
replayed.** The mission owner should review each `command_snapshot` (not
done here — that requires business judgment this session doesn't have) and
resolve via the `UPDATE approvals ...` pattern in the runbook. No timeout/
escalation mechanism exists yet for approvals that age out — a real P1/P2,
not designed or implemented this session (would need product input: what
should happen to an R2 action nobody approved in N days — auto-expire?
escalate to whom? — that's a policy decision, not an infra one).

## Resource limits + bounded logging — prepared, not applied

`providers/vps/docker-compose.yml` now carries `deploy.resources.limits`
and `logging.options` (bounded `json-file`, 10MB × 3 files) for
`aion-runtime`, `revenue-copilot`, and `postgres`. Validated:

- YAML parses; `docker compose config` resolves cleanly against the real
  production `.env` (dry run only — confirmed via `--project-directory
  /opt/aion`, nothing was applied to the running containers).
- Limits sized from a real measured baseline taken this session (idle):
  `aion-runtime` ~23MiB RSS/0% CPU → capped at 512M/1.0 CPU;
  `revenue-copilot` ~32MiB/0% → 512M/0.5 CPU; `postgres` ~33MiB/0% → 1G/1.0
  CPU. All have large headroom over observed usage — these are safety
  backstops against a runaway process on a 7.8GB-RAM/2-vCPU host with
  `immich` also resident, not a tight production sizing (no load test has
  been run — see the main audit's Phase 3 gap).

**Not applied** — every one of these 3 containers is currently healthy;
applying the change means `docker compose up -d` recreating all three,
which is a production-service restart under this mission's own rule 5 and
needs the same explicit approval as the original crash-loop fix.

**Exact change, impact, validation, rollback, if approved:**
- Command: `cd /opt/aion && docker compose up -d aion-runtime revenue-copilot postgres`
  (after `scp`-ing the updated `docker-compose.yml` from this PR onto the
  box, per the existing "sync compose labels before image roll" procedure).
- Impact: brief reconnect/restart of all 3 (seconds, not minutes — same
  class of change as any other container recreate); no image change, no
  migration.
- Validation: `docker inspect --format '{{.State.Health.Status}}'` on all 3
  → `healthy`; `curl .../health/ready` → 200; `docker stats` shows the new
  limits are in effect (`MEM USAGE / LIMIT` column changes from `7.755GiB`
  to the new per-container cap).
- Rollback: `git checkout` the previous `docker-compose.yml` on the box,
  `docker compose up -d` again — same symmetry as any other compose change,
  no data involved.

## Backups — prepared, not activated (needs a storage decision)

`backup.sh`/`restore.sh` already existed and work; `system/aion-backup.
{service,timer}` and `.env.backup.example` are new this session (not
installed on the box — see `docs/runbook.md` "Enable off-host backups" for
the exact activation steps once R2, or any S3-compatible storage, has
credentials). This is a genuine recurring-cost decision (new cloud storage
spend) and stays with the operator per this mission's rule 5 — prepared as
a ready-to-run PR, not executed.
