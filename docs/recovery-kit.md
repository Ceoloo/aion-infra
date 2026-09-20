# Recovery coverage — what a DB restore does and does not recover (2026-09-20)

A successful `aion_data` restore proves the **data** is recoverable. It does not prove the **host** is. This is the
audited state of everything needed to rebuild the `/opt/aion` deployment on a fresh machine.

## Coverage matrix

| Needed to recover | Backed up? | Where / gap |
|---|---|---|
| `aion_data` (executions, approvals, events, outcomes…) | **Yes** — hourly, encrypted, off-host, restore-proven | B2 `db/`, 48 h window; **no long-term daily/weekly tier yet** |
| Postgres roles `aion_app` / `aion_migrator` + password hashes | **No** — `pg_dump -d aion_data` excludes globals | Recreatable from `init-roles.sh` + `.env` passwords, but only if `.env` survives |
| `/opt/aion/.env` (DB passwords, gateway tokens, GHL PIT, OpenRouter key, image pins) | **No** — `/opt/aion` was created 2026-09-03; the last `full/` snapshot is 2026-09-02, and that tier's timer is disabled | **Only copy is on this host.** Most serious gap |
| `.env.monitor`, `docker-compose.yml`, `system/`, `traefik/`, `scripts/`, `bin/` | No (compose/scripts/units are in git; the on-box copies are not) | Compose on the box = PR #13 branch, not `main` |
| systemd units, `/etc/sudoers.d/aion-deploy` | No (units in git; sudoers reproducible via `bootstrap-server.sh`) | — |
| Traefik compose + Let's Encrypt volume | Legacy `full/` tier only, **disabled since 2026-09-02** | Certs are re-issuable via ACME; compose is Hostinger-provisioned, not in git |
| Backup **decryption key** + passphrase | On this host only (`/root/.backup-secrets/`) | **Off-host copy unverifiable from here** |
| B2 application key, rclone config, ntfy topic | On this host only | B2 keys re-mintable via Backblaze login; ntfy topic replaceable |
| GitHub Actions secrets (`VPS_HOST/USER/SSH_KEY`), DNS, Hostinger account/snapshots | Outside this host | Not inspectable here |

## Prepared fix (not installed): `providers/vps/backup/backup-aion-config.sh`
Encrypts `/opt/aion` config + secrets, the DR scripts, systemd units, sudoers, Traefik compose and a
`pg_dumpall --globals-only` roles dump into `b2:…/config-aion/<stamp>/` (own prefix, newest 30 kept; never touches
`full/` or `db/`). Modes: `dry-run` (metadata only), `local-verify`, `run`.
**Tested 2026-09-20:** dry-run lists 22 existing paths and reads no contents; `local-verify` built the archive,
GPG-encrypted it, decrypted it with the offline key in a throwaway keyring, and matched the expected 45-entry listing
exactly (including `roles-globals.sql`), then shredded everything — nothing uploaded, no residue. **`run` (upload)
is untested and not scheduled** — it needs your go-ahead (it puts the `.env` secrets, GPG-encrypted, into B2, the
same trust model the legacy config backup used).

It deliberately excludes `/root/.backup-secrets`: keys that unlock a backup cannot live only inside that backup.

## Out-of-band recovery kit (only you can hold this — please confirm each)
1. **GPG private key + its passphrase**, stored *separately from each other*, off this host. Today the key
   (`PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc`) and its passphrase memo sit in the same directory on the same
   disk, so the passphrase adds no protection here, and losing the host loses every backup. If neither is copied
   out, the backups are unrecoverable. *Unverified.*
2. **Backblaze login** (to mint a new application key for bucket `aion-prod-backups-ceoloo`).
3. **GitHub** access to `Ceoloo/aion-infra` + `aion-runtime` (compose, scripts, image pins) and **GHCR** pull access.
4. **Hostinger** login (VPS, snapshots) and the **DNS** provider for `runtime.srv1655818.hstgr.cloud`.
5. Provider consoles to **regenerate** GHL PIT, OpenRouter key and gateway tokens if `.env` is lost (the gateway
   tokens must then be re-distributed to Copilot and the Operator Console).

Note the tension to decide: the August DR doc says to delete the private key from the VPS after copying it out, but
the restore drills read it from the VPS. If you delete it, drills need the key supplied at run time.

## Fresh-host rebuild order (what the kit enables)
Docker + `bootstrap-server.sh` → restore `/opt/aion` from `config-aion/` (needs kit items 1–2) → start Postgres, let
`init-roles.sh` create roles (or load `roles-globals.sql`) → `pg_restore` the latest `db/` dump → `deploy.sh`
(migrate, roll, readiness) → Traefik → DNS. **Not yet rehearsed end-to-end.**
