# VPS Execution Readiness Audit — 2026-09-20

Scope: Hostinger VPS "Aionempire" (`/opt/aion` reference runtime deployment).
Read-only discovery + one authorized P0 fix. This is a snapshot, not a
continuous audit — see "Not run" at the end for what this does *not* cover.

## Executive verdict

**Ready for internal pilot, with specific limitations.**

The durable-execution schema, approval-gate mechanics, and GHL adapter plane
are real and present real production data (92 executions, 373 events, 16
approvals recorded since 2026-09-07). But the runtime that serves all of it
had been **completely down for 6 days** until this session's fix, with no
alert firing. The previously reported "$1,500 realized business value" proof
is **not present in canonical storage** (see below) — treat it as a local
proof result only, not production evidence, until re-run and confirmed
persisted.

## P0 fixed this session

**`aion-aion-runtime-1` was crash-looping continuously since creation
(2026-09-14T17:21:39Z), 7,899+ restarts, exit 1 every time:**
`config_invalid: AION_GATEWAY_API_KEYS must be valid JSON`. External
`https://runtime.srv1655818.hstgr.cloud/health/ready` was returning HTTP 404
— i.e. zero real uptime for the whole business-trigger→adapter-action path
for ~6 days, undetected.

**Root cause (fully reconstructed from repo history + on-box timestamps):**
1. `aion-infra` PR #11 ("Track A", merged `2026-09-14T17:04:32Z`) added
   `AION_GATEWAY_API_KEYS: ${AION_GATEWAY_API_KEYS:?set AION_GATEWAY_API_KEYS in .env}`
   as a hard-required var to `providers/vps/docker-compose.yml` (ADR-005
   identity plane / bearer auth).
2. Per the runbook's own documented procedure, this required a manual step
   on the VPS: copy the new compose file, hand-edit `/opt/aion/.env` with a
   real JSON array of `{token, principalId, kind, actorId, tenantIds, roles}`
   objects, then redeploy. This was done at `17:12–17:22` UTC the same day
   (`.env.bak.trackA.20260914171201`, compose file mtime `17:14:49`, final
   `.env` write `17:21:37`, container created `17:21:39`).
3. The JSON value typed/pasted into `.env` at that time was malformed. The
   container baked that broken value in at creation and has retried it,
   unchanged, every ~60s since — Docker's `unless-stopped` restart policy
   keeps a container alive by re-running its *frozen* creation-time config;
   it does not re-read `.env`.
4. At some later point the value in `/opt/aion/.env` **was corrected** —
   confirmed live: as of this session it is valid JSON (412 chars, `docker
   compose config --format json` round-trips it cleanly). But nobody ever
   ran `docker compose up -d aion-runtime` (or `deploy.sh`) again to apply
   it. The safe path, `deploy.sh`, has its own health-gated auto-rollback
   (30×2s wait, revert to previous image on failure) that would have caught
   this in ~60s — it was not used for this specific change, only the
   documented manual `.env` edit was, and the redeploy step was missed.

**Fix applied:** `cd /opt/aion && docker compose up -d aion-runtime`
(recreate only this container from the current, already-valid `.env`; no
image change, no migration, no other container touched).

**Validation:**
- `docker inspect` → `Health.Status=healthy`, `RestartCount=0`.
- `curl https://runtime.srv1655818.hstgr.cloud/health/ready` →
  `{"status":"ready","database":"up",...}` HTTP 200.
- Logs show clean `startup` → `listening` → `200 GET /health/ready`, no
  further `config_invalid`.
- Running revision: `git_sha=eb36cfb63b33587fc79840ba064d63be92106892`,
  `service_version=0.2.1` (note: differs from the `cdb622959...` SHA
  recorded as the 2026-09-08 GHL go-live milestone — a newer/different
  deploy happened since; not investigated further this session).

**Rollback (not needed, kept for record):** `docker compose stop
aion-runtime` returns to the prior (already non-functional) state —
symmetric risk, since there was no working state to regress from.

**Gap this exposes:** nothing paged anyone for 6 days. There is no
container-health or restart-count alerting on this box. Recommended P1
(not yet implemented): alert when a container's `RestartCount` climbs
past a small threshold in a short window, and/or a periodic external
`/health/ready` check from off-box.

## Durable execution schema — real, in use, partially empty

`aion-postgres-1` → database `aion_data`, owned by `aion_migrator`, `aion_app`
granted. 16 tables present (`missions`, `runs`, `executions`, `approvals`,
`events`, `external_side_effects`, `outcomes`, `telemetry_records`,
`services`, `actors`, `workflows`, `autonomy_grants`, `evaluation_results`,
`revenue_sessions`, `implementation_cases`, `schema_migrations`), plus an
`ol_metrics` schema (`mission_context`, `mission_interventions`).

Live row counts (as of this session): `executions`=92, `runs`=92,
`events`=373, `approvals`=16, `missions`=10, `external_side_effects`=53,
`telemetry_records`=285, `services`=32. **Zero rows** in `outcomes`,
`revenue_sessions`, `autonomy_grants`, `evaluation_results`,
`implementation_cases`.

**Cost accounting is real but abstract, as designed.**
`executions.cost` is `jsonb`, default `{"units": 0}`; observed values are
small integers (`{"units": 4-5, "tokens": 60-100, "provider": "ghl"}`) —
these are literally called "units," not currency. There is no
actual-provider-dollar-cost field anywhere in this schema.

**The reported $1,500 realized-value proof is not in canonical storage.**
`executions.revenue_attributed` (numeric) is `NULL` on every row inspected,
including all rows with nonzero cost. `outcomes` — the only table with a
`value`/`currency` pair and a `status IN (pending, realized, failed,
unknown)` — has **zero rows total**, system-wide. Whatever produced the
"$1,500" figure either wrote it somewhere non-canonical (a local
script/log, not this database), or the row was written and later cleaned
up, or it was never persisted. **Conclusion: do not report the $1,500 or
the 4-cost-unit figure as production evidence.** It should be re-run
against this schema and confirmed to land in `outcomes`/
`executions.revenue_attributed` before being cited as a real result.

**Stuck/abandoned work found:** one execution
(`exe_5eb37872-a21d-4e4d-a64b-0ffb804b5918`, autonomy `L2`) has sat in
`awaiting_approval` since `2026-09-12 01:12:50`, its approval
(`apr_63a095b9...`) still `pending`. Two more approvals from `2026-09-08`
(`apr_46feebb7...`, `apr_c7e02e9f...`) are also still `pending`. No
automatic timeout/escalation observed for stale pending approvals — worth a
P1/P2 follow-up (expire or escalate approvals past an age threshold).

**Activity gap:** the most recent `executions`/`missions`/`approvals`
activity before this session was `2026-09-12 01:12:50` — i.e. real
production activity had already stopped ~2 days *before* the 9/14 crash
loop began, and stayed at zero for the full 6-day outage. Not
investigated further this session (could be intentional pause, could be a
separate issue — flag for the next slice).

## Infrastructure inventory (read-only)

- **OS:** Ubuntu 24.04.4 LTS (`noble`), kernel `6.8.0-124-generic`, in
  Ubuntu's standard support window.
- **Capacity:** 2 vCPU, 7.8 GiB RAM (1.6 GiB used, 6.2 GiB available at
  snapshot time), 4 GiB swap (500 MiB used), 96 GB root disk at **37% used**
  (62 GB free), inode usage 6%. CPU steal ~0.5–1% (average of 3×1s
  samples) — minor shared-host contention, not currently a bottleneck.
  Uptime 73 days.
- **Docker:** 29.5.3 / Compose v5.1.4. Running: `aion-aion-runtime-1`
  (fixed this session), `aion-postgres-1` (healthy, 13d up,
  `127.0.0.1`-only), `aion-revenue-copilot-1` (healthy, 11d up),
  `immich-vvpd-*` (4 containers, healthy, 5w up), `traefik-traefik-1`
  (healthy, 2w up). No resource limits (`Memory=0`, `NanoCpus=0`) and
  default unbounded `json-file` logging (no `max-size`/`max-file`) on
  `aion-runtime` and `revenue-copilot` — **P2, recommend adding both**
  (safe, reversible, but requires one more container recreate — held for a
  separate approval since the service is now healthy).
- **Firewall (UFW):** active, default-deny inbound. Open: `22` (SSH),
  `80`/`443` (Traefik), `53902` (immich — documented in the rule comment as
  Docker-published, bypasses UFW enforcement by design, kept for
  visibility only). `aion-runtime` and `revenue-copilot` are **not**
  published to the host at all — reachable only via the Traefik Docker
  network. Good isolation posture, no change needed.
- **Reverse proxy:** host Traefik (not a container-network peer — runs with
  `network_mode: host`), Let's Encrypt HTTP-01 via `admin@srv1655818.hstgr.cloud`,
  routes `runtime.srv1655818.hstgr.cloud` → `aion-runtime:8080`.
  `runtime.aionsystems.ai` DNS not yet cut over (per existing runbook notes).
- **Scheduled jobs:** root crontab has 2 lines — these belong to a
  **separate, older system** (`/root/aion-company-os/aion-scheduler.sh
  tick` every 5 min; `/root/AION/scripts/run-revenue-projector.sh` every
  1 min against a remote Supabase project) — **not** the `/opt/aion`
  runtime audited here. Do not conflate the two; see "Two AION systems"
  below. Hermes has its own separate cron (`~/.hermes/cron/jobs.json`, 7
  LLM-prompt-driven jobs) reading Supabase/Airtable directly.
- **Backups:** `/opt/aion-backup/` exists (`DISASTER_RECOVERY.md`, scripts,
  logs) but its timers were deliberately disabled 2026-09-02 (targets were
  the now-deleted legacy Postgres/n8n). **No active backup coverage for
  `/opt/aion` or `aion-postgres-1` was found** (no systemd timer, no cron
  entry). This is a live P1 gap — `aion_pgdata` (66 MB, real execution
  history) has no confirmed backup path.
- **Repos:** `Ceoloo/aion-runtime`, `aion-infra`, `aion-core`, `aion-data`,
  `aion-docs`, `aion-products`, `aion-action-engine`, `AION-Wealth-OS`,
  `aion-desks` all exist on GitHub (confirmed via `gh repo list`). None are
  checked out on this VPS — deployment is image-based (`ghcr.io/ceoloo/
  aion-runtime@sha256:...`) via `scripts/deploy.sh`, not a git checkout on
  the box. `aion-infra` itself is also not checked out on the box (this
  audit is the first doc committed there from an on-box session).

### Two AION systems on this box — do not conflate

1. **`/opt/aion`** — the reference runtime this audit covers: containerized
   (`aion-runtime`, `aion-postgres-1`, `aion-revenue-copilot-1`), deployed
   from `ghcr.io/ceoloo/aion-runtime` images, local Postgres (`aion_data`)
   is the canonical execution store, fronted by Traefik. This is the
   GHL-adapter / Execution Gateway plane referenced in the mission's
   "reported prior milestone."
2. **`/root/AION` + `/root/aion-company-os`** — an older, non-containerized
   system driven by root cron + Hermes, writing to a **different, remote**
   Supabase project (`qbahthzqvxytfgobgtxa`, "AION EMPIRE SYSTEM") via its
   own `revenue_leads`/`revenue_*` schema (the lead-intelligence /
   human-review-gate work tracked in a separate audit thread). It has no
   relationship to `/opt/aion`'s Postgres or execution tables.

Any future work should state explicitly which of the two it targets.

## Not run this session (explicitly, not invented)

- Phase 3 (bounded performance/capacity testing) — NOT RUN. No synthetic
  load test executed; only a live snapshot (CPU/mem/steal) was taken.
- Phase 5 full acceptance matrix (restart/replay/dedup/backup-restore/GHL
  fixture proof) — NOT RUN. The one concrete gap found (stale
  `awaiting_approval` executions) came from passive inspection, not an
  active test.
- GHL Contact→Opportunity→Note/Task (AIO-17) live or fixture proof — NOT
  RUN this session. `GHL_API_KEY` presence was not re-checked; the PIT
  rotation flagged as outstanding in prior session memory
  (`project-aion-ghl-live-crm`) was not verified or acted on.
- Backup restore test — NOT RUN (no backup exists to restore, per above).
- The log-rotation and resource-limit `docker-compose.yml` hardening
  described above is drafted but **not applied** — applying it requires
  recreating an already-healthy `aion-runtime` container, which needs the
  same approval gate as any other production-service restart.

## Recommended next slice

1. **Add container-health/restart alerting** (P1) — smallest action that
   would have caught this specific outage in minutes instead of 6 days.
2. **Re-arm backup coverage for `/opt/aion`** (P1) — `aion_pgdata` has zero
   backup path right now.
3. **Re-run the revenue-workflow proof against this exact schema** and
   confirm the value lands in `outcomes`/`executions.revenue_attributed`
   before citing it as evidence again.
4. **Resolve or expire the 3 stale pending approvals** (`apr_63a095b9`,
   `apr_46feebb7`, `apr_c7e02e9f`) — decide reject/approve/expire per
   mission owner, not silently.
