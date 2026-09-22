# Recovery — what is covered, what was proven, what is not (2026-09-20)

**Full-host recovery is NOT declared covered.** The database tier and the deployment-config tier are now backed up,
encrypted, off-host, and rehearsed. Two things stop the declaration: the off-host custody of the decryption key
(only you can confirm) and the untested clean-host steps listed below.

## Coverage matrix
| Needed to recover | State | Evidence / gap |
|---|---|---|
| `aion_data` (data, ownership, ACLs) | **Backed up hourly**, GPG-encrypted, B2, 48 h window | rehearsed (below). No long-term daily/weekly tier |
| Postgres roles + password hashes, memberships | **Backed up daily** (`roles-globals.sql.gpg`) | rehearsed: hashes identical; both roles log in with the archived `.env` passwords |
| Grants / default privileges / schema ACLs | **Inside the `aion_data` dump** (custom format keeps ACLs); restored after roles | 198 table grants, 2,253 column grants, 3 default-ACL rows, schema/db ACLs, 20 ownership rows identical to production |
| `/opt/aion/.env`, `.env.monitor`, compose, `system/ traefik/ scripts/ bin/`, `/opt/aion-backup/bin`, systemd units, sudoers, `/docker/traefik/docker-compose.yml` | **Backed up daily** (`aion-config.tar.gpg`, 49 allow-listed entries) | scope-checked; all 39 regular files hash-identical to live |
| Let's Encrypt cert volume | Legacy `full/` tier only, **disabled since 2026-09-02** | re-issuable via ACME; not backed up |
| Backup **decryption key + passphrase** | on this host only | **off-host copy unverified — needs your confirmation** |
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
8. Traefik (compose restored from the archive), DNS for the runtime hostname, ACME re-issue. ⬜
9. Re-enable timers (monitor, backups) and confirm an alert reaches ntfy. ⬜
10. If the old host may have been compromised: rotate every secret in `.env` (see `exposure-review-2026-09-20.md`). ⬜

**Objectives (not yet measured end to end):** RPO ≤ 1 h data, ≤ 24 h config. RTO for a full host is unknown.

## Recovery kit — what only you can hold (please confirm each)
1. **GPG private key + passphrase, stored separately from each other and off this host.** Today the key
   (`PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc`) and its passphrase memo sit in one directory on one disk, so the passphrase
   adds no protection here and losing the host loses every backup. *Unverified.* Note the tension: the August DR doc says
   to delete the key from the VPS after copying it out, but `verify`, the drills and the rehearsal read it from the VPS.
   If you remove it, they need the key supplied at run time — decide which you want.
2. Backblaze login (to mint a new key for the backup bucket).
3. GitHub access to the org's repos and **GHCR** pull access (image digests are pinned in `.env`).
4. Hostinger login (VPS, snapshots) and the DNS provider for the runtime hostname.
5. Provider consoles to regenerate the GHL token, OpenRouter key and gateway tokens if `.env` is lost.

Step-by-step, with a public-value proof you can run yourself: `docs/offhost-key-custody.md`.

**I will not mark full-host recovery covered until you confirm item 1.**
