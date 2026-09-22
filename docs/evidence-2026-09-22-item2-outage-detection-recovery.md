# Production evidence — outage detection & recovery (2026-09-22)

Dated evidence record for item 2 ("outage detection and recovery first").
All tests run live against production on the Hostinger VPS (`/opt/aion`),
immediately after item 1 (approval-plane repair) shipped. No test restored
over production; no test left a real incident unresolved.

## Deployment identity at time of test
- Image digest: `sha256:e3fef42f972b708990330bc6102b584e5575457314e2480af4c0cdd5241a60b0`
- Git SHA: `10de06635f18c83be38e183b20b06a1b0c092fb3` (aion-runtime, includes PR #46 + #48)
- `GHL_BACKEND=live`, `crm_backend:"live"` confirmed via `/health/ready`

## 1. Delivered alerts (real test failure + recovery)
Deployed script: `providers/vps/scripts/monitor-runtime.sh` (installed 2026-09-22
from the aion-infra#13 staged batch — see `docs/host-update-batch-2026-09-20.md`).
Alert destination: existing ntfy.sh topic (`/root/.backup-secrets/ntfy.env`),
`ALERT_FORMAT=ntfy`, `BAD_THRESHOLD=3`, `GOOD_THRESHOLD=2`, `RE_ALERT_SECONDS=1800`.

| Event | Time (UTC) | Detail |
|---|---|---|
| Test failure triggered | 08:20:25 | `docker stop aion-aion-runtime-1` (controlled, clearly a test — container fully stopped) |
| Bad poll 1/3 | 08:21:13 | `consecutive_bad=1`, no alert (debounce) |
| Bad poll 2/3 | 08:22:13 | `consecutive_bad=2`, no alert (debounce) |
| Bad poll 3/3 — **alert fires** | 08:23:16 | `alert_active=true`; container check AND external check both fire independently |
| Recovery triggered | 08:24:08 | `docker start aion-aion-runtime-1` |
| Good poll 1/2 | ~08:24:36 | `consecutive_good=1`, still `alert_active=true` (debounce) |
| Good poll 2/2 — **recovery alert fires** | 08:25:26 | `alert_active=false` for both checks |

**Delivery independently confirmed via ntfy's own API** (not just the script's
exit code — fetched `GET https://ntfy.sh/<topic>/json?poll=1`):

| ntfy message id | Unix time | Title |
|---|---|---|
| `v3A8hCw8UKoL` | 1790065396 | AION container check FAILING |
| `i7EViPL6yQJP` | 1790065396 | AION external check FAILING |
| `vNhEVcskEM6g` | 1790065526 | AION container check RECOVERED |
| `otqTUGz2zosY` | 1790065526 | AION external check RECOVERED |

**Debounce/dedup confirmed:** exactly one FAILING alert per check for the
entire incident (not one per poll despite 3 bad polls), and exactly one
RECOVERED alert per check on return to healthy. No repeat alert fired within
the test window (`RE_ALERT_SECONDS=1800` never elapsed during the ~3.5min
incident, so the no-repeat path was not separately exercised — only the
initial-alert debounce and the single-alert-per-transition dedup were).

Total container downtime: 08:20:25 → 08:24:08 (~3m43s), fully controlled.

## 2. Restart detection (planned recreate vs. crash loop)
| Event | Time (UTC) | Detail |
|---|---|---|
| Planned recreate | 08:25:57 | `docker compose up -d --force-recreate --no-deps aion-runtime` (same image) |
| Monitor's next poll | 08:26:31 | logs `container_recreated` (info, not alert): `previous_created:"2026-09-22T08:02:56.189953871Z"`, `new_created:"2026-09-22T08:25:57.480279297Z"` |
| Result | 08:26:31 | both checks immediately `ok` — **zero alerts fired** for the planned recreate |

Confirms the monitor correctly distinguishes a planned recreate (new
`Created` timestamp → baseline reset) from a crash loop (same instance,
`RestartCount` climbing — the `RESTART_JUMP_THRESHOLD` path, not exercised
today since this was a clean recreate, not a crash).

**Readiness and digest after recreate:**
```json
{"status":"ready","database":"up","git_sha":"10de06635f18c83be38e183b20b06a1b0c092fb3","crm_backend":"live"}
```
Image: `sha256:e3fef42f972b708990330bc6102b584e5575457314e2480af4c0cdd5241a60b0` — **unchanged**, confirmed via `docker inspect`.

## 3. Backup and restore drill
| Step | Time (UTC) | Result |
|---|---|---|
| Manual dated backup | 08:27:12–08:27:14 (~2s) | `db/20260922_082712_ev2-item2/postgres-aion-runtime.dump.gpg`, sha256 `64188289891aff08a72ea898efb6199d30d53483b87817cfd0a659465437ad71` |
| Backup script's own success alert | 08:27:14 (ntfy id `OhRztAEexKxP`) | "AION Backup OK: aion-runtime postgres (db)" — independent confirmation |
| Restore drill | 08:27:52–08:27:58 (~6s) | into isolated, disposable container `restore-test-aion-runtime-pg`; torn down after (trap cleanup) |

Restore drill result — **6/6 checks passed, 0 failed**:
1. PASS: backup downloaded from offsite B2 storage (real offsite leg)
2. PASS: GPG decrypt succeeded (tamper/integrity check)
3. PASS: `pg_restore` completed cleanly
4. PASS: canonical schema restored — 7/7 core tables present (16/16 total public tables, matches production baseline)
5. PASS: executions restored — 92 rows (most recent: `exe_5eb37872…:denied`)
6. PASS: approvals restored — 16 rows (most recent: `apr_63a095b9…:rejected` — this run's own item-1 disposition, confirming the backup captured today's approval-plane work)

Production `aion-postgres-1` was never touched by the restore — isolated
container only, auto-removed on completion.

## 4. Recovery ownership
See `docs/runbook.md` → "Recovery ownership & escalation (VPS)" for the full
policy (alert recipient, acknowledgment path, escalation mechanism, SLA
targets, and the exact rollback command with last-known-good digests). Summary:
- Detection target: 5 min (measured: 2m51s live)
- Acknowledgment target: 15 min (process commitment — single-operator system, no secondary on-call)
- Escalation: `aion-monitor`'s own 30-min re-alert while an incident stays open (only mechanism today)

## Open items not covered by this evidence
- `RE_ALERT_SECONDS` repeat-while-still-down path not exercised (incident was too short by design)
- `RESTART_JUMP_THRESHOLD` crash-loop-on-same-instance path not exercised (today's test was a clean stop/start and a clean recreate, not an actual crash loop)
- GPG private key off-host custody still unverified (pre-existing open item, see `docs/recovery-kit.md`)
