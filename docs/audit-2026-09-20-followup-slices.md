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

## Revenue proof re-run — DONE, and the $1,500/4-units/3-gates mystery is solved

**Executed against an isolated database, not production** — per the
original mission's own Phase 5 wording ("first run... in an isolated
environment"), not the live `aion_data`. Deliberately not run against
production this session: it starts its own separate host-process Runtime
instance (not the containerized production one) and there was no reason to
risk writing into the canonical store when the isolated run already
answers the open question conclusively (below).

**Found the actual source of the script:** `aion-runtime`'s `main`
(cloned at `6eb2b79`, three commits ahead of the currently-deployed
`eb36cfb6`) has `scripts/revenue-workflow-durable-proof.sh` /
`npm run proof:revenue-workflow` — a self-contained Lead→Opportunity→
Note/Task→3×R2-gate→restart→outcome proof, using `FakeGhlBackend` (no real
GHL calls) whenever `GHL_*` env vars are unset.

**Setup:** vendored `@aion/core`+`@aion/data` (`node scripts/setup-deps.mjs`),
`npm ci`, isolated disposable `postgres:16-alpine` (roles `aion_migrator`/
`aion_app`, matching `providers/vps/system/init-roles.sh`), ran
`npm run proof:revenue-workflow` against it.

**Result: PASS A–J, green, exactly reproducing the reported milestone —
and proving it's a fixture, not a measurement:**
```
[PASS D] stage update parked approvalId=apr_724657ce... (handoff written)
[proof-rw] restart Runtime (PASS E)
[PASS E] restart preserved approval; stage executed
[PASS G] Outcome realized outcomeId=out_f4ace91d... value=1500 USD
[PASS H] cost units=4; attributed=1500; scopeCost=4
[TELEMETRY] Did a human intervene?     YES (3 gates)
[TELEMETRY] What business value?       1500 USD (attributed EV 1500)
```
Verified in the isolated database afterward (not just trusting stdout):
```sql
SELECT outcome_id, status, outcome_type, value, currency FROM outcomes;
-- out_f4ace91d...: realized | revenue_qualified | 1500 | USD  ✅
SELECT execution_id, revenue_attributed FROM executions WHERE revenue_attributed IS NOT NULL;
-- 2 rows, both revenue_attributed = 1500  ✅
SELECT approval_id, status, risk_level, reason FROM approvals;
-- 3 rows, all risk_level='R2', all status='granted':
--   crm.contact.update, crm.opportunity.create, crm.opportunity.update  ✅ (the "3 R2 gates")
```

**Conclusion, now evidence-backed rather than circumstantial:**
1. **The pipeline mechanics are real** — when run correctly, this exact
   workflow DOES produce a `status='realized'` `outcomes` row with a
   populated `value`/`currency`, AND `executions.revenue_attributed`
   populated. The schema/persistence design is not the gap.
2. **The "$1,500 / 4 cost units / 3 R2 gates" figures are a deterministic
   fixture built into the proof script itself** (`FakeGhlBackend`), not a
   measurement of any real business transaction — this run reproduced the
   identical numbers on demand, confirming they're scripted, not observed.
3. **The original milestone almost certainly ran in an ephemeral/local
   database like this one, not the persistent production `aion_data`** —
   this is now the most likely explanation for why `outcomes` has zero
   rows and `revenue_attributed` is NULL everywhere in production: the
   proof was never run *against* production in the first place, not that
   it ran there and the result went missing.
4. The 3 approvals found stale in production (`apr_c7e02e9f...`,
   `apr_46feebb7...`, `apr_63a095b9...` — see below) are a **separate,
   real, unrelated finding** — those are genuine `pre_ol_validation`/
   `OL-001` mission approvals sitting unresolved in production, not
   remnants of this fixture-based proof (this proof's approval IDs are
   freshly generated each run and never touch production).

**Cleanup:** the isolated Postgres container was removed immediately after
capture. Confirmed zero residue in production — `aion-postgres-1`
`StartedAt` unchanged throughout, `SELECT count(*) FROM outcomes` on
production still returns 0.

**Not done this session:** running this same proof with `GHL_*` set against
an authorized test tenant (would exercise the real GHL adapter instead of
`FakeGhlBackend` — a materially different, higher-value proof, but a
separate scoped action with its own credential/tenant authorization, not
assumed here).

## Stale approvals — found, not touched

`providers/vps/scripts/report-stale-approvals.sh` (read-only, tested against
production this session) confirms 3 rows, all `risk_level='R2'`:

| approval_id | mission_id | requested_at | age (at time of check) |
|---|---|---|---|
| `apr_c7e02e9f-76a9-4307-9b93-23872b88f666` | `msn_30fd4f95-6e33-4a6f-aab4-6524cdbf44ad` | 2026-09-08 05:23:03 | ~289h |
| `apr_46feebb7-a24d-491b-8e7e-d742a31818db` | `msn_59c5efb6-d9eb-47ab-a70d-15607728f002` | 2026-09-08 06:37:37 | ~288h |
| `apr_63a095b9-b175-4089-8647-c95e9e28c2e1` | `msn_0e3c5c21-6bd4-4858-9232-032a399932d9` | 2026-09-12 01:12:50 | ~197h |

Each has a matching `executions` row stuck `status='awaiting_approval'`.
**None were approved, rejected, or replayed.** Sanitized summary of each
`command_snapshot` (real business identifiers shown — this is your own
system's data, not a secret; no credentials/tokens are present in any of
the three):

**1–2. `apr_c7e02e9f...` and `apr_46feebb7...`** (2026-09-08, ~5 min apart)
— capability `crm.opportunity.create`, actor cohort `pre_ol_validation`,
`productionEconomic: false`. Both create a generically-named GHL
opportunity (`"L2A opportunity <timestamp>"`, no real contact/client
attached in the payload) as part of the `lead-to-appointment-v1` workflow
template, from the Operator Console. Read as **pre-launch validation
runs** — smoke-testing the workflow before the real OL-001 cohort, not
real customer actions. **Assessment: very likely stale/superseded** — if
OL-001 has since progressed (it has: approval #3 below is `missionOrdinal:
1` of a `cohortTarget: 100`), whatever these were validating already
happened. Recommend the mission owner reject/expire both rather than
approve, but confirm before acting — this is a judgment call, not
inferred with certainty.

**3. `apr_63a095b9...`** (2026-09-12) — capability `crm.opportunity.update`,
actor cohort `OL-001`, **`productionEconomic: true`**, `missionOrdinal: 1`
of `cohortTarget: 100`. Would update a real GHL opportunity
(a real GHL opportunity — id, contact and client names redacted from this public repo; see
production `approvals.command_snapshot`) to `stage: fdd0844f…`, `status: open`, `value: 500`.
**Notable: this is the same GHL opportunity ID used as the test target in
the 2026-09-08 GHL live acceptance gate** (see
[[project-aion-ghl-live-crm]]) — its real current state in GHL may no
longer match what this 8+ day old snapshot assumes. **Assessment: do not
approve on the strength of this snapshot alone** — the mission owner
should check the opportunity's actual current state in GHL directly before
deciding whether this update is still correct, redundant, or now wrong.

No timeout/escalation mechanism exists yet for approvals that age out — a
real P1/P2, not designed or implemented this session (needs a policy
decision — auto-expire after N days? escalate to whom? — not an infra
question).

## Resource limits + bounded logging — APPLIED 2026-09-20 (both stages passed; evidence in [rollout-2026-09-20.md](rollout-2026-09-20.md))

> The plan below is kept as written; it was executed as planned. Where reality differed (postgres stopped with an explicit `-t 60`, intake paused 22 s, restore-drill race found and fixed) see the rollout doc.

`providers/vps/docker-compose.yml` now carries `deploy.resources.limits`
and `logging.options` (bounded `json-file`, 10MB × 3 files) for
`aion-runtime`, `revenue-copilot`, and `postgres`, plus an explicit
`stop_grace_period: 60s` for `postgres` (previously unset, defaulting to
Docker's own 10s — see "Graceful shutdown" below).

### Exact diff (per service)

```diff
  aion-runtime:
    ...
    stop_grace_period: 30s
+   deploy:
+     resources:
+       limits:
+         cpus: "1.0"
+         memory: 512M
+   logging:
+     driver: json-file
+     options:
+       max-size: "10m"
+       max-file: "3"
    networks: [internal, traefik]

  revenue-copilot:
    ...
    stop_grace_period: 30s
+   deploy:
+     resources:
+       limits:
+         cpus: "0.5"
+         memory: 512M
+   logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
    networks: [internal, traefik]

  postgres:
    ...
    healthcheck: { ... }
+   stop_grace_period: 60s
    networks: [internal]
+   deploy:
+     resources:
+       limits:
+         cpus: "1.0"
+         memory: 1G
+   logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
```

Full exact diff: `git diff` in aion-infra PR #13 against `/opt/aion/docker-compose.yml`.

### Memory/CPU limits — measured usage + headroom (fresh snapshot, 2026-09-20)

| Container | Measured (idle, live) | Proposed limit | Headroom |
|---|---|---|---|
| `aion-aion-runtime-1` | 29.5MiB / 3.7% CPU | 512M / 1.0 CPU | ~17x memory |
| `aion-revenue-copilot-1` | 32.0MiB / 0% CPU | 512M / 0.5 CPU | ~16x memory |
| `aion-postgres-1` | 33.5MiB / 2.8% CPU | 1G / 1.0 CPU | ~30x memory |

Host: 7.8GiB RAM total, 6.1GiB available at snapshot time. Immich (already
capped from the 2026-08-11 hardening pass: 768M+1G+128M) + Traefik (256M) +
these 3 new caps = ~4.15G worst-case combined hard ceiling if every
container simultaneously hit its cap — leaves ~3.6G for the OS, well within
capacity. These are safety backstops sized for headroom, not a tight
production sizing — no load test has been run (Phase 3 gap, main audit).

### Graceful shutdown — confirmed and newly hardened

- **aion-runtime / revenue-copilot**: the deployment contract
  (`contracts/deployment-contract.md`) documents "Drains and exits `0` on
  `SIGTERM`" as the required image behavior. Not independently re-verified
  against the running image's source this session (would need
  aion-runtime's source or an active-load drain test); `stop_grace_period:
  30s` (already set, unchanged) gives it real time to do so before Docker
  escalates to `SIGKILL`.
- **postgres**: `docker stop` sends `SIGTERM`, which vanilla Postgres
  treats as **Fast Shutdown** — forces clients off but always completes a
  clean checkpoint first (not corrupting; not as graceful as Smart
  Shutdown, which is `SIGINT`, but safe). Previously no explicit
  `stop_grace_period` was set (Docker's own 10s default) — **newly added:
  60s**, so a checkpoint under real load has headroom to complete before
  `SIGKILL` would ever fire.
- **Volume preservation**: `aion_pgdata` is a named Docker volume
  (confirmed via `docker volume inspect`, `Mountpoint /var/lib/docker/
  volumes/aion_pgdata/_data`, 68MB). A container recreate replaces only the
  container, never the volume — `docker compose up -d postgres` re-attaches
  the same volume by name. Confirmed unaffected by any of this session's
  container recreates so far (StartedAt only changes on the containers
  actually recreated, volume Mountpoint/CreatedAt is unchanged throughout).

### Active executions — checked live, zero in flight

```sql
SELECT status, count(*) FROM executions GROUP BY status;
-- awaiting_approval: 3, denied: 1, failed: 13, succeeded: 75 — no
-- 'running'/'in_progress'/'executing' rows exist right now.
SELECT state, count(*) FROM runs GROUP BY state;
-- same picture: awaiting_approval / completed / denied / failed only.
```

**Zero executions are currently mid-flight** — a recreate today would drain
nothing. This is a point-in-time fact, not a standing guarantee: re-run
this check immediately before actually applying the change, since new work
could arrive between now and approval.

### Sequencing — services CAN be updated separately, and should be

Recommend **two separate actions, not one**:

1. **`aion-runtime` + `revenue-copilot` together** (stateless, no volume,
   already-proven recreate pattern from the crash-loop fix): lower risk,
   can go first.
2. **`postgres` separately**, in its own deliberate window, **immediately
   preceded by a fresh on-demand backup** (`/opt/aion-backup/bin/
   backup-aion-runtime.sh db` — now built and verified, takes ~2s) — the
   one container in this change where a mistake has real durable-state
   consequences, so it gets its own moment and its own fresh safety net,
   not bundled into the same action as the two stateless services.

### Rollback — explicit file snapshot, not a blanket git operation

`/opt/aion` on the VPS is a plain directory (files arrive via `scp` from
CI/deploy, per the existing "sync compose labels" procedure) — it is
**not** a git checkout, and there is other, unrelated in-progress state on
this box that a blanket `git checkout`/`git clean` anywhere near it must
never touch. Rollback here means a plain file snapshot:

```bash
# Before applying:
cp /opt/aion/docker-compose.yml /opt/aion/docker-compose.yml.bak.pre-limits.$(date -u +%Y%m%d%H%M%S)
scp providers/vps/docker-compose.yml root@<vps>:/opt/aion/docker-compose.yml   # or local edit if already on-box

# Apply (step 1, stateless services):
cd /opt/aion && docker compose up -d aion-runtime revenue-copilot

# Validate:
docker inspect --format '{{.State.Health.Status}}' aion-aion-runtime-1 aion-revenue-copilot-1   # both -> healthy
curl -s https://runtime.srv1655818.hstgr.cloud/health/ready   # -> 200
docker stats --no-stream aion-aion-runtime-1 aion-revenue-copilot-1   # MEM USAGE / LIMIT shows the new caps, not 7.755GiB

# Apply (step 2, postgres — separate action, fresh backup first):
/opt/aion-backup/bin/backup-aion-runtime.sh db
cd /opt/aion && docker compose up -d postgres

# Validate:
docker inspect --format '{{.State.Health.Status}}' aion-postgres-1   # -> healthy
docker exec aion-postgres-1 psql -U postgres -d aion_data -c "SELECT count(*) FROM executions;"   # -> 92 (or current count), proves the volume survived

# Rollback (either step, if validation fails):
cp /opt/aion/docker-compose.yml.bak.pre-limits.<timestamp> /opt/aion/docker-compose.yml
cd /opt/aion && docker compose up -d <affected service(s)>
```

No data operation is involved in rollback — it only ever re-applies a
saved file and recreates a container, exactly symmetric with the forward
change.

## Backups — DONE: an existing, approved, working destination was found and used

No new credentials were needed. `/opt/aion-backup/` (built 2026-08-11, for
the retired legacy stack, timers disabled 2026-09-02 — see
[[project_vps_infra_standardization]]) already has a fully working,
previously-verified offsite pipeline: **Backblaze B2** (bucket
`aion-prod-backups-ceoloo`, via `rclone` remote `b2:`), **GPG encryption**
(RSA4096, public-key-only on the box — the private key can decrypt nothing
from this host, by design), and **ntfy.sh** success/failure alerting. The
August setup doc flagged the B2 account's download cap as exhausted,
blocking restores — **confirmed fixed this session** (a real object was
downloaded and read back before touching anything else).

**Canonical DB + volume, precisely identified:** database `aion_data` in
container `aion-postgres-1`, backed by named Docker volume `aion_pgdata`
(`/var/lib/docker/volumes/aion_pgdata/_data`, 68MB, confirmed via `docker
volume inspect`).

**What was built** (new, minimal, additive — the existing pipeline's other
modules for Immich/n8n/config/Traefik-certs were deliberately left
untouched, out of this mission's AION-execution scope):
- `/opt/aion-backup/bin/backup-aion-runtime.sh` — dumps `aion_data` from
  `aion-postgres-1`, reusing the existing `common.sh` (GPG encrypt → B2
  `rclone rcat` → SHA256 checksum verify) unchanged.
- `/opt/aion-backup/bin/restore-test-aion-runtime.sh` — downloads the real
  encrypted object from B2 (not local staging), decrypts with the
  **offline** private key into a throwaway keyring, restores into an
  isolated, disposable `postgres:16-alpine` container, verifies schema +
  representative rows, tears everything down.
- `aion-backup-runtime-db.service`/`.timer` — hourly, **live and enabled**.
- A retention prune scoped to `db/` only (48h flat window) — deliberately
  **not** wired to the shared `prune-backups.sh`, since that script also
  GFS-prunes `full/`, which holds the legacy Immich/config/n8n snapshots
  from Aug–Sep that are outside this mission's scope to delete.

**Evidence — full cycle run twice, real offsite storage, real restore:**
1. `backup-aion-runtime.sh db` run manually → dump, GPG-encrypt, upload to
   `b2:aion-prod-backups-ceoloo/db/20260920_063256_manual/`, checksum
   verified. Exit 0.
2. `restore-test-aion-runtime.sh 20260920_063256_manual db` → **downloaded
   from B2** (the real offsite leg, proving the previously-broken download
   path now works), decrypted, restored into an isolated container:
   **6/6 checks passed** — schema 7/7 canonical tables, 16/16 total tables
   (matches production), 92 `executions` rows restored (most recent:
   `exe_5eb37872...:awaiting_approval` — a real, recognizable execution
   record, not just a row count), 16 `approvals` rows restored (most
   recent: `apr_63a095b9...:pending`). Isolated container + all decrypted
   files + throwaway keyring shredded and removed on exit; production
   `aion-postgres-1` untouched throughout (`StartedAt` unchanged).
3. Re-run through the **actual installed systemd unit**
   (`systemctl start aion-backup-runtime-db.service`) → same result, exit
   0 — confirms scheduled runs will behave identically to the manual test.
4. Retention verified live: dry-run listed 48 stale `db/` entries (all
   >415h old, from the retired Aug 31–Sep 2 legacy backups); pruning them
   removed only those, leaving the 2 new stamps; `full/`'s 16 entries
   (unrelated legacy Immich/config/n8n snapshots) confirmed **untouched**
   before and after (`rclone lsf .../full/ | wc -l` → 16, unchanged).

**Retention / encryption / schedule summary:**
| | |
|---|---|
| Encryption | GPG RSA4096, recipient `1BDEDA892D92F447A4FC74A8EB3ECECDB9716729` ("AION Backups"); private key never on the persistent keyring (confirmed: `gpg --list-secret-keys` against `/root/.backup-secrets/gnupg` returns empty) |
| Offsite destination | Backblaze B2, bucket `aion-prod-backups-ceoloo`, `db/` prefix |
| Schedule | Hourly, `aion-backup-runtime-db.timer`, **enabled and live** |
| Retention | 48h flat window on `db/` (long-term history is a design gap noted below — this module has no `full/`-equivalent daily tier yet) |
| Last successful backup (as of this report) | `db/20260920_063539_verify2/` — real, verified, still within retention |
| Last successful restore test | same session, 6/6 checks passed, real B2 download leg exercised |
| Alerting | reuses the existing `notify()`/`alert_success`/`alert_failure` → ntfy.sh, **topic already configured from August** — this ran for real during testing (a real ntfy push fired on the successful backup). This is the pipeline's own pre-existing, already-approved notification path, separate from the NEW `aion-monitor` alert-destination decision in the next section. |

**One real gap, not fixed this session:** this module only has an hourly
`db/`-tier backup (48h retention) — there is no `full/`-tier long-term
daily/weekly/monthly snapshot of `aion_data` yet, unlike the legacy
system's GFS-retained `full/` tier. For a database this size (68MB) that's
cheap to add later (a second daily timer + the existing `prune_gfs_prefix`
function pointed at a new prefix, e.g. `full-aion-runtime/`, to avoid
mixing with the legacy `full/` GFS bucket) — flagged as a small, clearly
-scoped follow-up, not built this session to keep this change reviewable.
