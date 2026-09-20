# Off-host key custody — what to do, how to prove it (2026-09-20)

Do this yourself, on your own machine. **Never paste the private key or the passphrase into chat, tickets or this repo.** I never need to see either;
you confirm by comparing **public** values (a fingerprint and a hash) below.

## What must exist off this host (and where)
| Secret | Where it is now | Off-host requirement |
|---|---|---|
| Backup **private key** (`/root/.backup-secrets/PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc`; passphrase-protected — it is an iterated/salted, AES-protected OpenPGP secret key) | this host only | one copy in a password-manager *attachment* or encrypted volume, plus one offline copy (encrypted USB or printed/`paperkey`) in a different physical place |
| Key **passphrase** (`PRIVATE_KEY_PASSPHRASE.txt`) | this host, next to the key (so today it adds no protection) | stored **separately from the key**: a different vault/entry or a sealed paper copy — never the same place as the key file |
| Backblaze login / a way to mint a new application key | your account | account recovery codes stored off-host |
| GHCR/GitHub access, Hostinger + DNS logins | your accounts | not inspectable from here |

Why two places: the key file alone is useless without the passphrase (it is encrypted), and the passphrase alone is useless without the key. Stored together they are one secret.

## Steps (run on your workstation; only *public* values are ever displayed)
1. **Fetch the key over SSH, straight to a file** (not through a terminal you paste from):
   `scp root@<vps>:/root/.backup-secrets/PRIVATE_KEY_SAVE_OFFSITE_THEN_DELETE.asc ./aion-backup-private.asc`
2. **Fetch the passphrase into your password manager without echoing it to chat**, e.g. view it on your own terminal only and copy it into the manager entry:
   `ssh root@<vps> "sed -n 's/^Passphrase:[[:space:]]*//p' /root/.backup-secrets/PRIVATE_KEY_PASSPHRASE.txt"`
   Put it in a *different* vault/entry from the key file. (Optional hardening: on your machine run `gpg --change-passphrase` on an imported copy and store that new passphrase instead — the VPS
   drills then need the old one; see "decision" below.)
3. **Prove you hold the right key — fingerprint (public).** Expected backup key fingerprint: `1BDEDA89 2D92F447 A4FC74A8 EB3ECECD B9716729`
   `gpg --show-keys --with-fingerprint ./aion-backup-private.asc` must show that fingerprint.
4. **Prove you can decrypt — end-to-end custody check (public values).** A small ciphertext, encrypted to the backup key, was placed on the host:
   `scp root@<vps>:/root/aion-rollout-20260920/custody/custody-check.gpg .`
   Import in a **throwaway keyring** and decrypt (you will be prompted for the passphrase locally):
   ```
   export GNUPGHOME=$(mktemp -d) && gpg --import ./aion-backup-private.asc
   gpg --decrypt custody-check.gpg | sha256sum        # expect: d38921c1008e… (full value in /root/aion-rollout-20260920/custody/expected.sha256)
   rm -rf "$GNUPGHOME"; unset GNUPGHOME
   ```
   Matching hash ⇒ the key file *and* the stored passphrase together decrypt a backup-key ciphertext, from outside this host. Tell me only "matches"/"does not match".
5. **Optional, stronger:** with a *read-only* B2 key on your machine, download one `config-aion/<stamp>/` object and decrypt it the same way. That also proves the B2 side; skip it if the check in step 4 passed.
6. Record where each piece lives (names of the vault entries, not their contents) in your own notes.

## Decision only you can make
The August DR note says "copy the key off the VPS, then delete it here"; the verify/rehearsal/restore drills read it *from* the VPS. Options:
- **Keep the key + passphrase on the VPS as well** (status quo): drills stay automatic; a compromised host exposes every backup (mitigated only by the key being passphrase-protected — but the passphrase is beside it).
- **Remove both from the VPS after step 4 passes**: strongest protection of the backups; the drills then need the key supplied at run time (a small script change I can make and test).
- **Remove only the passphrase**: the drills would prompt; the key blob alone is not usable.
Backups keep working in every option — they only need the *public* key.

## Evidence classes (do not conflate)
| Class | Evidence | Status |
|---|---|---|
| **Database recovery** | hourly encrypted DB dump → B2; restored into a clean Postgres, fingerprints identical, roles/hashes/ACLs identical; both roles log in | **Rehearsed** 3×, 18/18 |
| **Config recovery** | daily encrypted `/opt/aion` config archive + roles/globals → B2; verified by decrypt with the offline key, scope-checked, hash-identical to live | **Rehearsed** (archive contents; not extracted onto a new host) |
| **Custody of the key/passphrase off-host** | steps above | **Unproven until you run step 4** |
| **Full-host rebuild** (bootstrap on new VPS, restore to disk, `validate-env`, `deploy.sh` with GHCR, Traefik/DNS/ACME, timers) | `recovery-kit.md` §"Clean-host restoration sequence" steps 1,2,4,7,8,9,10 | **Documented, untested** |
Until step 4 is done and the untested steps have been rehearsed, full-host recovery is **not** declared covered.
