# Production changes awaiting authorization — one consolidated list (2026-09-20)

Nothing below has been applied. Each item is independent unless a dependency is stated; risk = what can go wrong on the running system.

## A. Host changes — no service disruption
| # | Change | Evidence | Rollback |
|---|---|---|---|
| A1 | Install the 10 scripts (8 changed, 2 new read-only) — `host-update-batch-2026-09-20.md` | staged copies hash-verified; monitor/alert/retry behaviour tested against local fakes; `deploy.sh` ordering tested; config verify, B2 verify, 18/18 rehearsal and DB restore drill all passed from the staged scripts | snapshot + reinstall old files (seconds) |

## B. Changes that touch running processes (in this order)
| # | Change | Risk | Evidence | Rollback |
|---|---|---|---|---|
| B1 | `GHL_BACKEND=live` in `/opt/aion/.env` + tracked compose (passthrough line) + `docker compose up -d --no-deps aion-runtime` | ~10 s runtime restart; edits a secrets file | old image ignores the var; new image boot-verified in configs A–E; 0 CRM requests at boot | restore saved `.env` + compose backup, recreate |
| B2 | Merge aion-runtime #46 and #48 (drafts; CI green), let CI build/certify the image, deploy the digest with `deploy.sh` | runtime replaced; behaviour changes: production can no longer fall back to fake CRM; approval decisions derive identity server-side and enforce tenant | candidate image booted (5 configs); 15-scenario approval suite vs `main`; 10 unit tests, 5 mutations; migrations: none | `deploy.sh` auto-rollback / previous digest |
| B3 | Register the operator approver actor: `sql/register-operator-actor.sql` (one `actors` row) | production DB write; makes the token's holder the approver of record for R2 gates | applied/refused/rolled-back on a scratch copy | `register-operator-actor-rollback.sql` (refuses if it decided anything) |
**Needs your input first:** who holds `principal_ops_console`'s token, and the actor id + display name to register (`act_human_ops_1` is only a template value).

## C. Data decisions (production DB)
| # | Change | Consequence | Evidence | Rollback |
|---|---|---|---|---|
| C1 | Apply `sql/ol-metrics-reconciled.sql` — **only after** you accept the 7 proposed classifications and the reporting consequence | `cohort_kpis` 10 → 2 missions; new missions excluded until classified; 3 missions stay unclassified (indicator exits 1 until you classify them) | fresh scratch restore; apply/rollback/re-apply ×3 sequence; permissions and append-only audit tested | `ol-metrics-reconciled-rollback.sql` (keeps evidence tables) |
| C2 | Decide the stale approvals — one at a time, each on its own evidence, through the runtime route (after B2 + B3) | closes a gate as *rejected*/execution *denied*; no CRM call | per-approval review in `stale-approval-disposition.md`; fixture rejection verified | none (a decision is final; that is the point) |

## D. Not proposed / deliberately not done
- Removing the GPG key or passphrase from the VPS — blocked until your off-host decryption check passes (complete checksum), the job inventory is accepted (no scheduled job needs them), and a run-time-credential drill is done by you.
- Enabling any live proof script or live AIO-17 — blocked pending a dedicated test location and a token scoped to it.
- Timers for `report-stale-approvals.sh` / `report-unclassified-missions.sh` (a host change; optional).
- Terraform changes for AWS/GCP (marked unsupported instead).
- Console authentication (BFF/session token) — a separate product change; the Console cannot decide in production until it exists.
- Rotating gateway tokens / the GHL token — no evidence requires it now; the earlier open PIT-rotation item stands.

## E. Repository actions (no production effect)
Merge aion-infra #13 (squash; **#12 not required**, its commit is inside #13), aion-runtime #46 and #48 (second needs a trivial `package.json` rebase), and the four cleanup PRs (aion-runtime #47 and #46 both edit the two live-proof scripts). A squash does not remove identifiers from existing public PR history.
