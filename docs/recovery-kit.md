# Recovery — what is covered, what was proven, what is not (updated 2026-09-25)

**Full-host recovery is NOT declared covered yet.** Every data tier (runtime DB hourly + daily, deployment config,
Supabase) is backed up, encrypted, off-host, restore-tested, and re-tested automatically every week. Key custody off
this host was proven on 2026-09-25. What still stops the declaration is the clean-VPS rebuild drill
(`docs/dr-drill-v1.md`): until a blank server has been turned into a working AION from the recovery kit and B2 alone,
the state is proven recoverable but the system that runs it is not.

## Coverage matrix
| Needed to recover | State | Evidence / gap |
|---|---|---|
| `aion_data` (data, ownership, ACLs) | **Backed up hourly** (48 h window) **+ daily 02:35 UTC** (`daily/`, 30 days); GPG, B2 | rehearsed (below); both tiers restore-tested weekly |
| Supabase "AION EMPIRE SYSTEM" (`qbahthzqvxytfgobgtxa`; free plan = no platform backups) | **Backed up nightly 02:50 UTC** (`supabase/`, 30 days); `pg_dump` 17 → GPG → B2 | restore-tested 2026-09-25 and weekly (see "Supabase recovery") |
| Postgres roles + password hashes, memberships | **Backed up daily** (`roles-globals.sql.gpg`) | rehearsed: hashes identical; both roles log in with the archived `.env` passwords |
| Grants / default privileges / schema ACLs | **Inside the `aion_data` dump** (custom format keeps ACLs); restored after roles | 198 table grants, 2,253 column grants, 3 default-ACL rows, schema/db ACLs, 20 ownership rows identical to production |
| `/opt/aion/.env`, `.env.monitor`, compose, `system/ traefik/ scripts/ bin/`, `/opt/aion-backup/bin`, systemd units (`aion-*.service/.timer/.path`), sudoers, `/docker/traefik/docker-compose.yml` | **Backed up daily and on every change** (policy below) | 2026-09-25: all 53 regular files hash-identical to live |
| Let's Encrypt cert volume | Legacy `full/` tier only, **disabled since 2026-09-02** | re-issuable via ACME; not backed up |
| Backup **decryption key + passphrase** | on this host **and** off-host, key and passphrase in separate password-manager entries | **custody proven 2026-09-25** (owner decrypted `custody-check.gpg` off-host; full sha256 matched). Owner chose to keep the host copy too, so drills stay automatic |
| B2 application key, rclone config, ntfy topic | this host only | B2 key re-mintable via Backblaze login; ntfy topic replaceable |
| GitHub Actions secrets, DNS, Hostinger account/snapshots | outside this host | not inspectable |

## How the config backup is built (`providers/vps/backup/backup-aion-config.sh`, timer `aion-backup-config.timer`, daily 03:40 UTC)
- **No plaintext artifact touches disk.** `tar` and `pg_dumpall --globals-only` stream directly into GPG (public-key
  encryption to the backup fingerprint); only ciphertext is ever staged, and it is removed on exit. Two objects per run
  under `b2:…/config-aion/<stamp>/`, newest 30 kept; the legacy `full/` and `db/` prefixes are never touched.
- **Excluded by design:** `/root/.backup-secrets` — keys that unlock a backup cannot live only inside that backup.
- Modes: `dry-run` (metadata only), `local-verify`, `run`, `verify <stamp>`.
- **Checks that never print contents:** *recipient* (each object has exactly one recipient key, and it belongs to the
  configured fingerprint — read from the packet header without decrypting); *scope* (every archive path inside the
  allow-list, nothing key-like); *roles* (`aion_app` + `aion_migrator` present with SCRAM hashes, counted not shown);
  *identity* (archived `.env` hash equals the live `.env` hash). The recipient and scope checks were **negative-tested**:
  a ciphertext for a different key, and a listing containing key material and out-of-scope paths, are both refused.
- Logging carries paths, counts and hashes of ciphertext only. The passphrase is read into a shell variable for the
  throwaway keyring and never echoed; the throwaway keyring is shredded on exit.

## Verified 2026-09-20 (real B2, real objects)
1. `run` (manual) and `run` **through the systemd unit**: encrypt → upload → sha256 readback, both objects, exit 0.
2. `verify` on both stamps: download from B2 → recipient OK → decrypt with the offline key (throwaway keyring) → scope OK
   (44 / 49 entries) → roles OK → `.env` identity OK.
3. **Recovery rehearsal** `restore-rehearsal-aion.sh <config-stamp> <db-stamp>`: from B2 objects only, into a brand-new
   isolated Postgres — roles first (streamed), database owned by the migrator, `pg_restore` with ownership + ACLs,
   then compared with production: roles/attributes/password-hash md5, memberships, all grants, default privileges,
   schema/db ACLs, ownership, and the data fingerprint (row counts, schema hash, content checksums) all **identical**;
   `aion_app` and `aion_migrator` **log in over TCP (scram) with the passwords from the archived `.env`**; `aion_app`
   cannot run DDL. **18/18 on three consecutive runs.**
   Honest history: the first run reported 16/17 — a **vacuous** PASS (the default-privileges comparison errored on both
   sides and empty equalled empty) and one **unexplained** FAIL (`aion_app` DDL "not denied"). The comparison helper now
   fails on any SQL error or empty result, and the DDL probe records what actually happened; the FAIL did not reproduce in
   three later runs with two probe forms, and its cause was not determined.

## Policy: every production config change triggers a fresh encrypted config backup
Any change to production `.env`, secrets, compose, Traefik, DR scripts or `aion-*` systemd units must be followed by a
config backup, not left for the daily 03:40 run. Why: on 2026-09-25 the newest config backup predated the GHL PIT rotation
by 18 h, so a restore at that moment would have brought back a **revoked** token.
**Enforced, not remembered:** `aion-backup-config-onchange.path` watches the same allow-list as `backup-aion-config.sh`
and starts `aion-backup-config.service` on any change (limit 6 runs / 10 min). Tested: a change produced an encrypted,
checksum-verified `config-aion/<stamp>/` within seconds. Manual equivalent: `systemctl start aion-backup-config.service`.
Retention is the newest 30 config backups by count, so a burst of edits shortens the history window.

## Weekly restore validation (permanent)
`aion-restore-drill.timer` (Sun 04:30 UTC) → `run-restore-drills.sh`, against the newest objects in B2:
1. runtime hourly + config — `restore-rehearsal-aion.sh <config> <db>` (clean-host rebuild, compared with production, 18 checks)
2. runtime daily — `restore-test-aion-runtime.sh <daily> daily`
3. Supabase — `restore-test-supabase.sh <stamp>` (isolated, no network, compared with live, 9 checks)

Success is recorded silently in `/var/lib/aion-backup/restore-drills.json` (last 52 runs, `last_success`). Any failure →
`alert_failure` (ntfy, high) **and** a non-zero exit, so `OnFailure=aion-backup-alert@` fires as the independent path.
All three are read-only against production and shred their plaintext. Runtime ~75 s. The config comparison is strict:
a file changed since the newest config backup FAILS the drill; the policy above keeps that from happening silently.
Wrong or missing stamps fail (rclone exits 0 on a missing source; the scripts check for an empty download).

## Supabase recovery
Restore target must match the live Postgres version (17.6 on 2026-09-25; the drill fails on a mismatch). Drill evidence
2026-09-25: 234/234 tables, 230 row-count-identical, 4 continuously-written log tables only grew since the dump; functions
109, RLS policies 113, RLS-enabled tables 192, triggers 64, views 48, cron jobs 11 identical; md5 of `auth.users` (incl.
password hashes), migration history and cron definitions identical.
Procedure (new Supabase project, or the `supabase/postgres` image):
1. **Before the target has any network access / before the project can make outbound calls**, be ready to pause cron:
   the dump carries **11 pg_cron jobs** that call the edge functions of the **old** project URL via `pg_net`, and they
   start firing the moment `cron.job` is restored (observed in the drill: 2 jobs fired within minutes).
2. Create roles missing on a fresh target: `supabase_realtime_admin`, `supabase_functions_admin` (NOLOGIN).
3. `pg_restore --clean --if-exists` as the admin role, then immediately `UPDATE cron.job SET active = false;`.
4. Recreate the event trigger `ensure_rls` (needs superuser; it fails to restore otherwise).
5. **Vault secrets do not survive**: they are encrypted with a per-project pgsodium key. Recreate `edge_internal_token`
   (and any other Vault secret) and point cron job URLs at the new project before re-enabling jobs one by one.
6. Redeploy the 31 edge functions and set their secrets (project secret key "default", LEEP/Slack/ingest keys).

## Runtime hostname change (every full-host recovery)
Production runs on the free Hostinger name `runtime.srv1655818.hstgr.cloud` (copilot: `copilot.runtime.srv1655818.hstgr.cloud`),
which belongs to that server. A recovered server has a different name, so a recovery **always** changes the runtime URL.
Decision 2026-09-25: accept this ($0) rather than buy a domain (AION owns no domain today). Update, in order:
1. `/opt/aion/.env`: `AION_DOMAIN`, `COPILOT_DOMAIN`, `AION_RUNTIME_URL` (copilot → runtime) → the new server's names;
   `AION_CORS_ORIGINS` stays (it is the Console's origin, not the runtime's).
2. `/opt/aion/.env.monitor`: `HEALTH_URL`.
3. `/docker/traefik/.env`: `ACME_EMAIL` is `aion.systems.empire@gmail.com` since 2026-09-25 (was the undeliverable `admin@srv1655818.hstgr.cloud`); keep it. The file is in the config backup since 2026-09-25 (Traefik will not start without it).
4. `deploy.sh` / compose up → Traefik issues certificates for the new names.
5. Vercel project `aion-operator-console`: env `RUNTIME_URL` (server-side BFF proxy target) → new URL; redeploy production.
6. `aion-runtime` `scripts/lib/production-ids.json` → add the new host to `runtimeHosts`, so the proof guard keeps
   refusing to run proofs against production.
7. The config backup runs automatically on the `.env` change (on-change policy); confirm a new `config-aion/<stamp>/`.

## Clean-host restoration sequence
Steps marked ✅ were rehearsed; ⬜ are documented but **untested**.
0. **Recovery kit in hand** (below). Without the private key nothing else works.
1. Provision Ubuntu 24.04; run `providers/vps/scripts/bootstrap-server.sh` (Docker, ufw 22/80/443, `/opt/aion`, deploy user). ⬜
2. Install `rclone` + `gpg`; create a new B2 application key; import the **private key into a throwaway keyring only**. ⬜
3. Fetch the newest `config-aion/<stamp>/` and `db/<stamp>/`; decrypt by streaming. ✅
4. Extract config to `/opt/aion`, `/etc/systemd/system`, `/etc/sudoers.d`, `/docker/traefik`; run `validate-env.sh` on the
   restored `.env`/compose. ⬜ (files proven byte-identical by hash; restore-to-disk and validate on a new host not run)
5. Start Postgres on an empty volume; load `roles-globals.sql`; `CREATE DATABASE aion_data OWNER aion_migrator`;
   `pg_restore` the dump (ownership + ACLs). ✅
6. Compare `db-fingerprint.sh` and grants to expectations; confirm both roles log in. ✅
7. `deploy.sh` with the digest-pinned image: migrate (a no-op on a restored DB) → roll → readiness → smoke. ⬜ (needs GHCR
   auth and the image on the new host)
8. Traefik (compose restored from the archive); **runtime hostname change** (section above); ACME issue. ⬜
9. Re-enable timers (monitor, backups) and confirm an alert reaches ntfy. ⬜
10. If the old host may have been compromised: rotate every secret in `.env` (see `exposure-review-2026-09-20.md`). ⬜

**Objectives:** RPO by cadence: runtime DB ≤ 1 h, Supabase ≤ 24 h, config = last change (on-change policy). RTO for a
full host is unknown until `docs/dr-drill-v1.md` is run.

## Recovery kit — what only you can hold (please confirm each)
1. **GPG private key + passphrase, stored separately from each other and off this host.** ✅ Confirmed 2026-09-25
   (custody check matched; key file and passphrase in separate password-manager entries). Decision: the host copy is
   kept as well so the weekly drills run unattended; trade-off accepted by the owner (root on this host could decrypt
   every backup).
2. Backblaze login (to mint a new key for the backup bucket).
3. GitHub access to the org's repos and **GHCR** pull access (image digests are pinned in `.env`).
4. Hostinger login (VPS, snapshots) and the DNS provider for the runtime hostname.
5. Provider consoles to regenerate the GHL token, OpenRouter key and gateway tokens if `.env` is lost.

Step-by-step, with a public-value proof you can run yourself: `docs/offhost-key-custody.md`.

**Full-host recovery is declared covered only after `docs/dr-drill-v1.md` passes.**
