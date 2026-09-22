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

**The review fixes put the repo ahead of the host** by 8 changed scripts and 2 new read-only scripts (10 files), plus a one-line compose change (`GHL_BACKEND` passthrough, not yet on the host).
The host runs the previous, verified versions. `docs/host-update-batch-2026-09-20.md` has the exact snapshot/install/verify/rollback commands, a per-script disruption table, and the validation already done on staged copies.
Installing the 10 scripts restarts nothing; the compose line needs a runtime recreate and is a separate approval. Until installed, "installed == tracked" holds only for the earlier head `617f5bf`.

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

## 4. Secrets and customer identifiers in the proposed tree (and what a squash does NOT fix)
Exact-value scan (live secret values, CRM record/contact ids, customer names loaded into memory only; nothing printed) over all 123
files of the proposed tree: **0 hits**. Over every line *added* by the PR's commits: **4 hits, all in one early commit (`7cb7c82`)**
that the branch head has since redacted. History was not rewritten (your instruction). Consequence: if the PR is merged with a
*merge commit* or *rebase*, that commit lands on `main`. A squash merge keeps `main`'s history free of it, **but it does not remove the identifiers from existing public history**: the PR branch, its commits, the PR page/diff and `refs/pull/13/head` stay publicly fetchable (also after the branch is deleted) until GitHub support purges them. The same identifiers are already in `main` history of five public repos (`exposure-review-2026-09-20.md`). Removing them needs a decision I have not taken: a history rewrite and/or visibility change (both explicitly off the table so far) plus a GitHub cached-view purge request.

## 5. CI (final; PR head `3d5c259` when checked, later pushes are docs only)
`no committed secrets` **passes** (was the failing check), `infra portability + verification` pass, `terraform fmt · validate` pass, CodeRabbit pass, `terraform plan (staging)` skipped (no WIF configured). `IaC static security scan` passes too — every check on the head is green or skipped. GitHub reports `mergeStateStatus: CLEAN`. **Unresolved review threads:** the 12 original threads are fixed in the repo but still open on GitHub, plus 5 new CodeRabbit threads on the later commits, all now addressed in code (scratch-credential note documented; passfile escaping; `.env` authority in `deploy.sh`; exit-code normalisation; rollback→re-apply). I did not resolve any thread on GitHub.

## 6. Merge notes
- **PR #12 is not required for #13, and need not be merged for ordering.** #13's branch already contains #12's only commit (`710af12`, ancestor of the #13 head): its audit doc is byte-identical in #13, and its `runbook.md` section is a subset of #13's. Merging #13 delivers everything in #12; #12 would then be redundant (close it as superseded, or merge it first only if you want its commit to land separately — no dependency either way).
- #12's contents are safe: the exact-value secret/identifier scan over its commit message, diff, PR title/body and comments found 0 hits (2 files: the audit doc and a runbook section).
- `docs/audit-2026-09-20-followup-slices.md` references #12's audit document, which #13 also contains.
- **Cleanup PRs stay separate from runtime behaviour:** the four cleanup PRs (aion-docs #65, aion-core #26, aion-products #30, aion-runtime #47) touch only fixtures/tests/proof defaults/docs — `#47`: `fake-ghl-backend.ts` (one fixture string), `ghl-phase-ab-proof-matrix.ts`, and the two live-proof scripts; `#30`: sample-preset text in `NewMission.tsx` (renames the sample-preset handler). Runtime behaviour changes live only in aion-runtime #46 (backend policy/proof guard) and #48 (approval identity). #47 and #46 both edit the two live-proof scripts, and #46 and #48 both edit `package.json`'s script list: whichever merges second needs a trivial rebase.
- No production action follows from merging: units/scripts are already live; merging only makes git match the host (plus the fixes in §1).
