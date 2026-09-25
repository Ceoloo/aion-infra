# AION Disaster Recovery v1 — clean-VPS rebuild drill (plan, 2026-09-25)

**Milestone definition.** Starting with a clean server and only documented recovery materials + offsite encrypted
backups, AION can be restored to an operational state without relying on the original VPS.
Only when this drill passes is AION stamped **RECOVERABLE — VERIFIED**: recovery of the state (already proven weekly,
see `recovery-kit.md`) *and* of the system that runs it.

## Decisions (owner, 2026-09-25)
- **Provider:** Hostinger, same as production (monthly billing; cancel within the 30-day refund window after the drill).
  Choose Ubuntu 24.04 **plain OS** (not a one-click app template) so the server is genuinely blank, x86_64, KVM 2 or larger.
- **Hostname:** `runtime.<drill-ip>.sslip.io` (no DNS change). The server's own `srvNNNN.hstgr.cloud` is not used.
- **When:** the next session the owner starts with the drill server ready.

## Owner prep checklist (before the session)
1. Hostinger: new VPS, Ubuntu 24.04 plain, root SSH enabled; note its IP.
2. Backblaze: new application key, **read-only**, bucket `aion-prod-backups-ceoloo` only; keep keyID + key in the password manager.
3. GitHub: fine-grained or classic token with `read:packages` only (GHCR pull), short expiry.
4. Password manager open: GPG key file entry + passphrase entry.
5. Vercel access to the operator-console project (for the preview deployment).

## Ground rules
1. **Nothing comes from the production VPS.** Allowed sources: GitHub (repos, GHCR images), B2 (backups), the owner's
   recovery kit (password manager: GPG key + passphrase; Backblaze, GitHub, provider logins). No `scp` from
   `srv1655818`, no copying `/root/.backup-secrets`. Anything that turns out to be needed from the old host is logged as
   an **undocumented dependency** and the drill continues only if it can be obtained another way.
2. **External side effects stay disabled** until the relevant step is verified, and some never get enabled (table below).
3. **Production is never changed by the drill.** Production DNS, the Vercel production Console, the production Supabase
   project and the B2 backup prefixes stay untouched.
4. Every operator action that is not a documented step is a **manual intervention** and is logged with its time.

## Side-effect controls (drill host)
| Risk | Control | When lifted |
|---|---|---|
| Live GHL writes (`GHL_BACKEND=live` in the restored `.env`) | set `GHL_BACKEND=fake` before the first `compose up` | never during the drill |
| Restored backup timers write to / **prune** the production B2 bucket | drill uses a **new read-only B2 application key**; `aion-backup-*` and `aion-restore-drill` timers stay disabled | never during the drill |
| 11 restored Supabase pg_cron jobs call the old project's edge functions | restore into `supabase/postgres:17.6.x` with `--network none`; `UPDATE cron.job SET active=false` **before** the container gets any network | never during the drill |
| Supabase Vault / edge functions / Slack / Discord | not recreated in container mode (Vault is per-project anyway) | only in the optional hosted-project variant, with Slack/Discord secrets left unset |
| ntfy alerts from the restored monitor | `ntfy.env` is not in the backup by design: use a new drill topic (or leave unset) | step 11 (alert test to the drill topic) |
| OpenRouter spend via copilot | copilot runs; cost is a few calls. Remove the key from the drill `.env` if even that is unwanted | — |
| Let's Encrypt | real ACME issue for the drill hostname only | step 9 |

## Infrastructure
- **Server:** x86_64 Ubuntu 24.04, 2 vCPU / 4 GB+ (prod is x86_64). Hourly-billed provider (Hetzner CX22, DigitalOcean,
  Vultr) keeps it to roughly one hour of cost. Hostinger bills monthly (refundable within 30 days).
- **Hostname:** `runtime.<drill-ip>.sslip.io` needs no DNS change and gets a real TLS certificate.
- **Console:** a Vercel **preview** deployment of the operator console with `AION_RUNTIME_URL` pointing at the drill
  runtime, and the drill runtime's `AION_CORS_ORIGINS` set to that preview origin. Production Console untouched.

## Recovery materials to prepare before the clock starts
| Item | Who | Notes |
|---|---|---|
| Drill VPS + root SSH | owner | add the drill operator's public SSH key at creation |
| GPG private key + passphrase | owner (password manager) | uploaded to the drill host's tmpfs only (`offhost-key-custody.md` "drills without host-held credentials") |
| New **read-only** B2 application key for `aion-prod-backups-ceoloo` | owner (Backblaze) | revoke after the drill |
| GHCR pull token (`read:packages`) | owner (GitHub) | revoke after the drill |
| Supabase: none for container mode | — | hosted variant needs a new free project (org limit: 2 active) |

## Sequence (each step: start/end UTC, result, interventions, new dependencies)
Clock **starts** at first SSH into the blank server and **stops** when step 13 passes.
1. **Blank VPS → prerequisites.** `git clone` aion-infra from GitHub; `providers/vps/scripts/bootstrap-server.sh`
   (Docker, ufw 22/80/443, `/opt/aion`, deploy user); install `rclone`, `gpg`, `postgresql-client`.
2. **Backup retrieval.** rclone remote with the read-only B2 key; list `config-aion/`, `db/`, `daily/`, `supabase/`;
   pick the newest stamps; record their ages (actual RPO).
3. **Key in RAM.** Throwaway keyring in `/dev/shm` from the owner-supplied key; passphrase typed, never stored on disk.
4. **Config restore.** Stream-decrypt `aion-config.tar.gpg` to `/opt/aion`, `/opt/aion-backup/bin`, `/etc/systemd/system`,
   `/etc/sudoers.d`, `/docker/traefik`. Then drill overrides: `GHL_BACKEND=fake`, `AION_DOMAIN`/`COPILOT_DOMAIN`/
   `AION_RUNTIME_URL` → drill hostname, `AION_CORS_ORIGINS` → Console preview origin. Run `validate-env.sh`. Keep every
   restored `aion-backup-*`/`aion-restore-drill` unit **disabled**.
5. **Runtime DB restore.** Postgres 16 on an empty volume → `roles-globals.sql` → `CREATE DATABASE aion_data OWNER
   aion_migrator` → `pg_restore` (ownership + ACLs) → `db-fingerprint.sh` equals the backup's fingerprint.
6. **Supabase recovery procedure.** `recovery-kit.md` "Supabase recovery": `supabase/postgres:17.6.x` with `--network none`,
   missing roles, `pg_restore --clean --if-exists`, **pause all 11 cron jobs**, recreate `ensure_rls`, then (and only then)
   attach a network. Checks: table count, row counts, object counts vs the backup.
7. **Services deployed.** GHCR login; `deploy.sh` with the digest-pinned `AION_IMAGE` / `COPILOT_IMAGE` from the restored
   `.env`: migrate (no-op on a restored DB) → up → readiness.
8. **Traefik.** Restored `/docker/traefik` compose up; router for the drill hostname.
9. **DNS/TLS.** Drill hostname resolves to the drill IP; ACME certificate issued; `https://` valid chain.
10. **Health checks.** readiness 200, `/v1` smoke, logs free of errors; `crm_backend` reports `fake`.
11. **Authentication.** `AION_AUTH_MODE=required`: request without key → 401, wrong key → 401, restored gateway key → 200.
    Alert path: monitor → drill ntfy topic delivers.
12. **Console.** Vercel preview against the drill runtime loads, authenticates, lists missions/approvals from the restored DB.
13. **Runtime mission/approval path.** Submit a mission (fake GHL) → approval requested → approve → execution recorded
    with `execution_id` + tenant; the same records visible in the Console. Pre-existing approvals from the backup present.

**Teardown:** shred `/dev/shm` key material, destroy the VPS, revoke the drill B2 key and GHCR token, delete the Vercel
preview and any drill DNS record. Production untouched: confirm prod readiness and last backup timestamps afterwards.

## The four numbers
| Metric | Definition | Target |
|---|---|---|
| **RTO** | first SSH on the blank server → step 13 passes (wall clock, incl. waiting for humans) | record; aim ≤ 2 h for v1 |
| **RPO** | by cadence: runtime DB ≤ 1 h, Supabase ≤ 24 h, config = last change; plus the *actual* age of each stamp at step 2 | ≤ 1 h / ≤ 24 h / 0 |
| **Manual interventions** | operator actions not scripted in a documented step (the expected owner inputs — key, B2 key, GHCR token — are counted separately as "planned inputs") | record; each one becomes a script or a doc line |
| **Undocumented dependencies** | anything needed that `recovery-kit.md` / this doc did not list | 0 after fixes; each one found is added to the recovery kit |

Known before the drill (counted as found by planning, not by the drill): production's hostname
`runtime.srv1655818.hstgr.cloud` is a free, Hostinger-provided name bound to that server and cannot move. Owner decision
(2026-09-25): keep it ($0) and treat the URL change as a documented recovery step — see "Runtime hostname change" in
`recovery-kit.md`. The drill executes that step and records its duration. Revisit if AION buys a domain.

## Pass criteria → stamp
All 13 steps pass with production untouched and no material taken from the original VPS. Record the four numbers,
fold every intervention and dependency back into `recovery-kit.md`, then stamp **AION RECOVERABLE — VERIFIED (DR v1,
<date>)** in `recovery-kit.md`.

## Results log (fill in during the drill)
| Step | Start | End | Result | Interventions | New dependencies |
|---|---|---|---|---|---|
| 1 | | | | | |
