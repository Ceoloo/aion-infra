# Host update batch — exact installation plan (PROPOSED, nothing installed)

Repo commit `3d5c259` (PR #13 branch). Staged, hash-verified copies are in `/root/aion-rollout-20260920/staging-host-update/` (`candidate.sha256`).

## A. Script batch — no service disruption (10 files)
All are plain files replaced **atomically** (`install … .new && mv -f`): a running instance keeps its old inode; the next timer run picks up the new file. No unit changes ⇒ no `daemon-reload`, no timer reschedule, no container restart.
| File (host path) | Change vs host | Used by | Runs when | Disruption |
|---|---|---|---|---|
| `/opt/aion/scripts/monitor-runtime.sh` (5c1f19d5a25f) | alert delivery retried until it succeeds; state advances only on delivery | `aion-monitor.timer` (every 60 s) | continuously | none — atomic swap between runs |
| `/opt/aion-backup/bin/common.sh` (aff428741cf2) | `--fail` on alert curl, `rclone_retry` status, run-time key lookup helpers | sourced by every backup script | hourly :05, daily 03:40 | none if not swapped mid-run; install outside those windows |
| `/opt/aion-backup/bin/alert-on-failure.sh` (10590b19adb3) | `--fail`; logs + exits 1 when undelivered | `OnFailure=` handler | only on a failed backup unit | none |
| `/opt/aion-backup/bin/backup-aion-config.sh` (21bb5537f5eb) | verify strictness; key via `AION_RESTORE_KEY_DIR` | `aion-backup-config.timer` (`run`); manual `verify`/`local-verify` | daily 03:40 UTC | none outside the window |
| `/opt/aion-backup/bin/restore-rehearsal-aion.sh` (20227a153227) | passfile logins (escaped), missing files fail, key via run-time dir | manual | never scheduled | none |
| `/opt/aion-backup/bin/restore-test-aion-runtime.sh` (aebd77d1c531) | `pg_restore` failure fails the drill; key via run-time dir | manual | never scheduled | none |
| `/opt/aion/scripts/deploy.sh` (e77ac9349476) | validate first; `.env` never sourced/exported and authoritative over inherited vars | `sudo -n deploy.sh` from CI/operator | only during a deploy | none — but do not install while a deploy is running |
| `/opt/aion/scripts/bootstrap-server.sh` (01a444785211) | installs `jq` | fresh-host provisioning | never on this host | none |
| `/opt/aion/scripts/report-stale-approvals.sh` (a5d678eabe86) | **new** (read-only) | manual | — | none |
| `/opt/aion/scripts/report-unclassified-missions.sh` (279c8c326ddb) | **new** (read-only) | manual | — | none |
Unchanged and untouched: `backup-aion-runtime.sh`, `db-fingerprint.sh`, `validate-env.sh`, every unit file, timer schedule, `.env*`, sudoers, compose, containers.

**Window:** any minute except `:04–:07` (hourly DB backup, ~10 s runtime) and `03:38–03:48` (config backup). Do not `systemctl start` any of the three services to "test" — the validation below never does.

### Snapshot → install → verify → rollback (run as root)
```
S=/root/host-snapshots/20260920-host-update; mkdir -p -m 700 $S
FILES="/opt/aion/scripts/monitor-runtime.sh /opt/aion/scripts/deploy.sh /opt/aion/scripts/bootstrap-server.sh \
 /opt/aion-backup/bin/common.sh /opt/aion-backup/bin/alert-on-failure.sh /opt/aion-backup/bin/backup-aion-config.sh \
 /opt/aion-backup/bin/restore-rehearsal-aion.sh /opt/aion-backup/bin/restore-test-aion-runtime.sh"
for f in $FILES; do cp -a --parents "$f" $S/; done                      # keeps mode/owner/mtime
sha256sum $FILES > $S/manifest.sha256; stat -c '%a %U:%G %n' $FILES > $S/perms.txt
systemctl list-timers 'aion-*' --no-pager > $S/timers-before.txt
# preconditions: staged files still match the approved hashes
( cd /root/aion-rollout-20260920/staging-host-update && sha256sum -c candidate.sha256 )
# install (0755 root:root = the host's current mode/owner for these files); new report scripts are added the same way
ST=/root/aion-rollout-20260920/staging-host-update
inst(){ install -m 0755 -o root -g root "$1" "$2.new" && mv -f "$2.new" "$2"; }
inst $ST/aion/scripts/monitor-runtime.sh /opt/aion/scripts/monitor-runtime.sh
inst $ST/aion/scripts/deploy.sh /opt/aion/scripts/deploy.sh
inst $ST/aion/scripts/bootstrap-server.sh /opt/aion/scripts/bootstrap-server.sh
inst $ST/aion/scripts/report-stale-approvals.sh /opt/aion/scripts/report-stale-approvals.sh
inst $ST/aion/scripts/report-unclassified-missions.sh /opt/aion/scripts/report-unclassified-missions.sh
for f in common alert-on-failure backup-aion-config restore-rehearsal-aion restore-test-aion-runtime; do inst $ST/aion-backup/bin/$f.sh /opt/aion-backup/bin/$f.sh; done
# verify: hashes, modes, syntax, timers unchanged, and the next monitor run succeeds
( cd / && sed 's#  \./aion/#  opt/aion/#; s#  \./aion-backup/#  opt/aion-backup/#' $ST/candidate.sha256 | sha256sum -c )
for f in /opt/aion/scripts/*.sh /opt/aion-backup/bin/*.sh; do bash -n "$f" || echo "SYNTAX $f"; done
diff <(systemctl list-timers 'aion-*' --no-pager | awk '{print $NF}') <(awk '{print $NF}' $S/timers-before.txt) >/dev/null && echo timers-unchanged
journalctl -u aion-monitor.service --since "-3min" --no-pager | tail -3     # next scheduled run: exit 0, no error lines
```
**Rollback (any time, ~seconds):** `cd $S && for f in $(awk '{print $2}' manifest.sha256); do install -m 0755 -o root -g root ".$f" "$f.new" && mv -f "$f.new" "$f"; done && sha256sum -c manifest.sha256` (the two new report scripts: `rm` them).
Skipped from the `cp -a --parents` list on purpose: the two new files (no prior version).

### Validation already done on the staged copies (no timer/service triggered, no state shared)
- `bash -n` all 10; hash-identical to the committed files. (`shellcheck` is not installed on the host.)
- Monitor: own `STATE_FILE`, fake container, local webhook returning 500 then 200 → retried each poll, state advanced once on success, no duplicate. Alert handler: 500 → exit 1, 200 → exit 0. `rclone_retry` keeps exit 7 / returns 0.
- `deploy.sh`: with a real-shaped `.env` plus a value containing `$(…)` and inherited shell variables that would shadow `.env`: validated with Compose, nothing executed, stopped at the network check (no pull, no roll, no containers changed); missing `AION_DOMAIN` → refused by the preflight first.
- Config backup `local-verify` (host creds, run-time creds from tmpfs, absent creds → clear failure); **B2 `verify`** of the latest config stamp; **clean-host rehearsal 18/18** and **restore drill (db, 92 executions / 16 approvals restored, 7/7 tables)** — all run from the staged scripts with the decryption credentials supplied at run time from tmpfs (shredded afterwards). Run at 15:06–15:08 UTC, after the hourly backup finished; none writes to B2.
- Not exercisable without side effects: the real `run` mode of the two backup scripts and a live alert delivery to ntfy (they are unchanged in behaviour on success; their next scheduled runs are the proof — check the journal after 16:05 and 03:40).

## B. Changes that DO affect running processes (separate approvals, in this order)
1. **Explicit backend — env + compose (runtime recreate, ~10 s):** add `GHL_BACKEND=live` to `/opt/aion/.env` (back up `.env` first) and install the tracked compose (`docker-compose.yml`, 9371ab4bd1ff; diff vs host = one comment + `GHL_BACKEND: ${GHL_BACKEND:-}`), then `docker compose up -d --no-deps aion-runtime`.
   Safe with the **current image** (it ignores the variable). Rollback: restore the saved `.env` + `docker-compose.yml.bak.*` and recreate.
2. **New image** (after merging aion-runtime PRs #46 and #48; CI builds and boot-certifies it) through `deploy.sh` with the digest; automatic rollback on failed readiness.
3. **Operator-actor registration** (data) — `sql/register-operator-actor.sql`, only after you confirm the identity (see `stale-approval-disposition.md`). One INSERT; rollback SQL provided.
