# PR #13 — merge readiness (2026-09-20)

**Not merged, nothing deployed by this document.** Sections: tracked-vs-deployed reconciliation, host-only items,
review-thread disposition, secret/identifier check, CI, and merge notes.

## 1. Tracked configuration vs what is deployed (sha256 comparison at PR head `617f5bf`)
| Tracked file | Deployed at | Result |
|---|---|---|
| `providers/vps/scripts/{monitor-runtime,validate-env,deploy}.sh` | `/opt/aion/scripts/` | identical |
| `providers/vps/scripts/{backup,restore,bootstrap-server}.sh` (from `main`) | `/opt/aion/scripts/` | identical to `main` |
| `providers/vps/scripts/report-stale-approvals.sh`, `report-unclassified-missions.sh` | — | **not installed** (run from the repo clone when needed) |
| `providers/vps/backup/*.sh` (7 files) | `/opt/aion-backup/bin/` | identical |
| `providers/vps/system/aion-{monitor,backup-runtime-db,backup-config}.{service,timer}`, `aion-backup-alert@.service` | `/etc/systemd/system/` | identical; monitor + runtime-db + config timers **enabled** |
| `providers/vps/system/aion-backup.{service,timer}` | — | **not installed, not enabled** (legacy S3 path; see below) |
| `providers/vps/docker-compose.yml` | `/opt/aion/docker-compose.yml` | identical (resource limits, log rotation, `stop_grace_period`); `main`'s compose differs by those 44 lines |
| `.env.example` key names vs `/opt/aion/.env` key names | | same 32 names both sides (names only; values never read into this doc) |

**Review-fix commit (this push) puts the repo ahead of the host** for: `scripts/{monitor-runtime,deploy,bootstrap-server,report-stale-approvals}.sh`,
`backup/{common,alert-on-failure,backup-aion-config,restore-rehearsal-aion,restore-test-aion-runtime}.sh`. The host runs the previous
(working, verified) versions. Installing them is a copy of nine files + no service restart (the timers re-read scripts each run);
it needs your go-ahead. Until then, "installed == tracked" holds only for the previous head.

## 2. Host-only state (intentionally not in git)
| Item | Why not tracked | Recovery coverage |
|---|---|---|
| `/opt/aion/.env`, `/opt/aion/.env.monitor` (0600) | secrets | in the daily encrypted config backup |
| `/root/.backup-secrets/` (GPG key/passphrase, B2 key, ntfy topic, rclone config) | secrets; excluded from the backup on purpose | **off-host copy unconfirmed** (`recovery-kit.md`) |
| `/etc/sudoers.d/aion-deploy`, `/docker/traefik/docker-compose.yml` | host-specific | in the config backup |
| `/opt/aion-backup/bin/{backup-config,backup-n8n,backup-postgres,backup-volumes,prune-*,restore-test*,run-backup}.*` and units `aion-backup-{db,full}.*` | legacy from 2026-08/09 (disabled since 2026-09-02) | not tracked; left untouched |
| `/opt/aion/{ol-metrics.schema.sql,backup,bin,env,system,legacy,_src_reference_stale,PROVENANCE}` | pre-existing host artefacts | not tracked; not reviewed here |
| Compose backups `/opt/aion/docker-compose.yml.bak.*` | rollback copies | the `pre-limits` copy is the rollback for the resource rollout |
| `/root/aion-rollout-20260920/` (evidence, clones) | working area | disposable after this pass |
| B2 bucket contents; ntfy topic | external | see `recovery-kit.md` |

## 2b. Also in this PR since the first review pass (docs/SQL only — nothing installed or applied)
`docs/kpi-decision-package.md`, `docs/stale-approval-disposition.md` (rewritten: per-approval review + production authorization-path finding), `docs/aion-runtime-pr46-merge-readiness.md`,
`docs/offhost-key-custody.md`; `sql/ol-metrics-reconciled{,-rollback}.sql` extended (audit trail, `classify_mission`, `classification_health`) and re-tested on a scratch restore — **still unapplied**.

## 3. Review threads (12; all were unresolved) — disposition
| # | Reviewer | Where | Finding | Disposition |
|---|---|---|---|---|
| 1 | gitleaks | `.env.backup.example:25` | `generic-api-key` on a `<placeholder>` | **Fixed**: example reworded (no placeholder value, marked legacy) + `.gitleaksignore` for that one historical fingerprint; local gitleaks 8.24.3 over `main..HEAD`: no leaks |
| 2 | codex P1 | `monitor-runtime.sh` | fresh host lacks `jq` | **Fixed**: `bootstrap-server.sh` installs `jq` |
| 3, 7 | codex P1 / coderabbit | `deploy.sh` | `.env` sourced (shell-parsed, exported) before the Compose preflight | **Fixed**: preflight runs first; scalars read as literal text, never sourced/exported. Tested with a synthetic `.env` containing `$(…)`/backticks/JSON — nothing executed, values literal, `.env` still wins over caller env |
| 4 | coderabbit | `common.sh`, `alert-on-failure.sh` | curl without `--fail`: HTTP 4xx/5xx counted as delivered | **Fixed** (`-sS --fail`; the OnFailure path now logs and exits non-zero) |
| 5 | coderabbit | `common.sh` | `rclone_retry` returned `$?` of the `if` | **Fixed** (status captured from the failed command) |
| 6 | coderabbit | `restore-test-aion-runtime.sh` | non-zero `pg_restore` only warned | **Fixed**: now fails the drill |
| 8 | coderabbit | `monitor-runtime.sh` | failed delivery still recorded as alerted (page lost for up to 30 min) | **Fixed**, tested: webhook returning 500 → retried every poll, state not advanced; on success state advances once, no duplicate |
| 9 | coderabbit | `report-stale-approvals.sh` | printed a raw `UPDATE approvals` hint | **Fixed**: hint now points to `POST /v1/approvals/<id>/decision` (already the documented route in `stale-approval-disposition.md`) |
| 10 | coderabbit | `backup-aion-config.sh` | `rc=2` could overwrite a failure; both callers treat 2 as pass | **Fixed**: hash pipeline failure is `rc=1`; `2` only when nothing else failed. `local-verify` re-run: PASS |
| 11 | coderabbit | `restore-rehearsal-aion.sh` | passwords via `PGPASSWORD` | **Fixed**: 0600 passfile inside the throwaway container, removed after each probe; TCP/SCRAM still exercised |
| 12 | coderabbit | `restore-rehearsal-aion.sh` | archived file absent on host silently skipped | **Fixed**: counted as a difference → rehearsal fails |

Threads are resolved on GitHub only after you have looked at the fixes (not resolved by me).
Not re-run after the fixes: the full B2 rehearsal (`restore-rehearsal-aion.sh`) and restore drill — they read the *installed* copies,
which are unchanged. Run them after installing (§1).

## 4. Secrets and customer identifiers in the proposed tree
Exact-value scan (live secret values, CRM record/contact ids, customer names loaded into memory only; nothing printed) over all 123
files of the proposed tree: **0 hits**. Over every line *added* by the PR's commits: **4 hits, all in one early commit (`7cb7c82`)**
that the branch head has since redacted. History was not rewritten (your instruction). Consequence: if the PR is merged with a
*merge commit* or *rebase*, that commit lands on `main`. **Squash-merge** keeps it off `main`; GitHub still serves the PR head
commit via `refs/pull/13/head` until GitHub support purges it — a visibility/history decision left to you.

## 5. CI (PR head after this push)
See the PR checks; before this push: `IaC static security scan`, `infra portability + verification`, `terraform fmt · validate` passed;
`no committed secrets` failed on item 1 above; `terraform plan (staging)` skipped (no WIF configured).

## 6. Merge notes
- PR #12 (audit doc) is clean and also edits `docs/runbook.md`; merge **#12 first**, then rebase/merge #13 (a squash of #13 onto updated main).
- `docs/audit-2026-09-20-followup-slices.md` references #12's audit document.
- No production action follows from merging: units/scripts are already live; merging only makes git match the host (plus the fixes in §1).
