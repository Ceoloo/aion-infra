# Runbook

Concise, executable operational procedures (aion-infra §59). All `gcloud`
commands assume you are authenticated with an identity that holds the required
role (see [security.md](security.md)); routine steps run through CI, not by hand.

Common variables: `PROJECT_ID` (per env), `REGION=us-central1`,
`PREFIX=aion-<env>` (`aion-staging` | `aion-prod`).

## Deploy staging

Automatic on merge to `main`. Manual:

```bash
gh workflow run deploy-gcp.yml -f target=staging   # or: git push origin main
```

## Deploy production (human-gated)

```bash
gh workflow run deploy-gcp.yml -f target=production   # from main only
# → approve the 'production' Environment when GitHub requests a reviewer
```

## Run migrations

```bash
PROJECT_ID=<env-project> providers/gcp/scripts/migrate.sh <staging|production>
# local:  MODE=local MIGRATION_DATABASE_URL=... providers/gcp/scripts/migrate.sh local
```

A failed migration exits non-zero and does not proceed to deploy.

## Rollback runtime

```bash
# list revisions / images, then pin the previous SHA:
gcloud run services update ${PREFIX}-runtime \
  --project ${PROJECT_ID} --region ${REGION} \
  --image ${REGION}-docker.pkg.dev/${PROJECT_ID}/${PREFIX}-images/aion-runtime:<prev-sha>
```

Instant, no database change. For schema, write a forward-fix migration
(migrations are forward-only).

## Check health

```bash
URL="$(gcloud run services describe ${PREFIX}-runtime --project ${PROJECT_ID} \
  --region ${REGION} --format 'value(status.url)')"
URL="${URL}" scripts/health-check.sh          # mints an identity token via gcloud
```

### P0 revenue-path readiness (VPS / any HTTPS Runtime)

Non-destructive live+ready+CORS/env checklist (no deploy):

```bash
URL=https://runtime.aionsystems.ai \
  CHECK_SERVICES=1 \
  CORS_ORIGIN=https://aion-operator-console.vercel.app \
  scripts/verify-p0-runtime-readiness.sh
```

See [p0-overnight-readiness.md](p0-overnight-readiness.md). **Do not AI-auto-deploy
production** — human gate only ([deployment.md](deployment.md)).

## Inspect logs

```bash
gcloud logging read \
  'resource.type=cloud_run_revision AND resource.labels.service_name='"${PREFIX}"'-runtime' \
  --project ${PROJECT_ID} --limit 50 --format json
# readiness failures / DB drops:
gcloud logging read '… AND (jsonPayload.message="readiness_failed" OR jsonPayload.message="db_pool_error")' \
  --project ${PROJECT_ID} --limit 20
```

## Rotate database credentials

```bash
# 1. generate a new password (store in your secret manager of record / GH secret)
# 2. apply — updates the Cloud SQL user + writes a NEW Secret Manager version:
cd providers/gcp/terraform/environments/<env>
terraform init -backend-config="bucket=<env-tfstate-bucket>"
TF_VAR_app_password=<new> TF_VAR_migrator_password=<current-or-new> \
  terraform apply -var project_id=${PROJECT_ID}
# 3. roll the service so it reads version=latest:
gcloud run services update ${PREFIX}-runtime --project ${PROJECT_ID} --region ${REGION}
```

App and migrator credentials rotate independently. See [security.md](security.md) §Rotation.

## Restore database

```bash
# verify a backup is recent, then clone-restore into an ISOLATED target + validate:
PROJECT_ID=${PROJECT_ID} INSTANCE=${PREFIX}-pg MODE=restore REGION=${REGION} \
  providers/gcp/scripts/backup-verify.sh
```

Never restore over production. For a real recovery, restore to a new instance,
validate, then cut over deliberately. See [backup-recovery.md](backup-recovery.md).

## Handle a failed migration

1. The deploy already halted (job exited non-zero); the previous runtime is still
   serving — confirm with **Check health**.
2. Read the job logs:
   ```bash
   gcloud logging read 'resource.type=cloud_run_job AND resource.labels.job_name='"${PREFIX}"'-migrate' \
     --project ${PROJECT_ID} --limit 50
   ```
3. Fix the migration in **aion-data** (schema is authoritative there), or the
   grants in the aion-runtime image's `grants.sql`. Do not hand-edit the production schema.
4. Re-run the deploy; migrations are idempotent (already-applied files are
   skipped; a changed applied file is a drift error, not a silent re-apply).

## Handle a database outage

1. `/health/ready` returns 503 and Cloud Run withholds traffic; the runtime stays
   up (it does not crash on DB loss — verified). Liveness stays 200.
2. Check the Cloud SQL instance state; alerts fire (`database unavailable`).
3. On transient loss, readiness recovers automatically when the DB returns — **no
   redeploy needed**.
4. On instance failure, restore per **Restore database** and repoint if a new
   instance is created (update `TF_VAR`/apply so the connection secret is rewritten).

## Handle a failed deployment

1. The previous revision keeps serving (Cloud Run shifts traffic only after the
   new revision passes its startup probe).
2. Inspect build/deploy logs in the failed Actions run; check `smoke-test.sh`
   output.
3. Fix forward and re-deploy, or **Rollback runtime** to the last good SHA.

## Handle a runtime crash-loop after editing `.env` (VPS)

If `aion-runtime` restarts repeatedly with `config_invalid` in its logs:

1. Diagnose without printing secrets — compare lengths/JSON-validity, not
   values:
   ```bash
   cd /opt/aion
   docker compose config --format json | python3 -c \
     "import json,sys; v=json.load(sys.stdin)['services']['aion-runtime']['environment'].get('AION_GATEWAY_API_KEYS',''); print(len(v)); json.loads(v)"
   ```
   If this parses cleanly but the container is still crash-looping, the
   **container's frozen creation-time env is stale** — `.env` was fixed
   after the container was created, but the container was never recreated
   to pick it up. Confirm via
   `docker inspect aion-aion-runtime-1 --format '{{.Created}}'` vs
   `stat -c %y .env`.
2. Fix: `docker compose up -d aion-runtime` (recreates only this
   container from the current `.env`; no image change, no migration).
   Prefer `sudo -E ./scripts/deploy.sh` when also rolling an image, since
   it health-gates and auto-rolls-back — a bare `docker compose up` does
   not.
3. Validate: `docker inspect --format '{{.State.Health.Status}}'` reaches
   `healthy`; `curl $AION_RUNTIME_URL/health/ready` returns 200; restart
   count stops climbing.
4. This class of bug (edit `.env` → forget to redeploy) is why any PR that
   adds/changes a required env var (e.g. the 2026-09-14 "Track A" PR that
   added `AION_GATEWAY_API_KEYS`) must end with an actual redeploy step
   confirmed on the box, not just a corrected file. Consider adding
   container-restart-count alerting so a repeat doesn't run silently for
   days — see `docs/audit-2026-09-20-vps-execution-readiness.md`.

## Runtime failure detection (VPS — aion-monitor)

`providers/vps/scripts/monitor-runtime.sh` runs on the HOST via
`aion-monitor.timer` (every 60s), independent of `aion-runtime` itself —
it checks container state (`docker inspect`) and the external
`/health/ready` endpoint, so it still works when the runtime is fully down.
Built after the 2026-09-14 6-day silent outage (aion-infra#12); see
`docs/audit-2026-09-20-vps-execution-readiness.md` and
`docs/audit-2026-09-20-followup-slices.md`.

```bash
# check it's running and see recent findings
systemctl status aion-monitor.timer
journalctl -u aion-monitor.service -n 50 --no-pager

# one-off manual run (e.g. right after a deploy)
systemctl start aion-monitor.service && journalctl -u aion-monitor.service -n 10 --no-pager
```

Config: `/opt/aion/.env.monitor` (root 0600; see `.env.monitor.example` —
thresholds + optional `ALERT_WEBHOOK_URL`). **No alert destination is wired
by default** — until `ALERT_WEBHOOK_URL` is set, findings are detected,
debounced, and logged to the journal only; nothing pages anyone. To wire
one: set `ALERT_WEBHOOK_URL` (Slack-compatible JSON by default;
`ALERT_FORMAT=raw` for a generic `{title,body,timestamp}` payload), then
`systemctl restart aion-monitor.timer` is not even needed — the next poll
picks up the new env file automatically (`EnvironmentFile=-` is re-read
per invocation, since each run is a fresh `Type=oneshot` process).

It alerts on: container missing, stuck restarting, unhealthy, external
`/health/ready` non-200, and its own inability to reach the Docker daemon
(reported distinctly, never confused with "target is fine"). It does NOT
alert on a single blip — `BAD_THRESHOLD` consecutive bad polls required
(default 3) — and a container recreate resets its restart-count baseline
rather than treating a fresh healthy instance as still-failing.

## Validate `.env` before recreating a container (VPS)

`providers/vps/scripts/validate-env.sh` is already a `deploy.sh` preflight
— run it manually after any hand-edit of `/opt/aion/.env` too, before
`docker compose up`:

```bash
cd /opt/aion && ./scripts/validate-env.sh
```

Checks every `${VAR:?...}` required var is non-empty (via Compose's own
resolver — never re-implements dotenv parsing) and that JSON-shaped vars
(`AION_GATEWAY_API_KEYS`) actually parse. This is the direct fix for the
2026-09-14 incident: the bug wasn't that validation was hard, it's that
nothing ran it.

## Enable off-host backups (VPS — not active by default)

`providers/vps/scripts/backup.sh` / `restore.sh` already exist and work;
they need S3-compatible credentials, which nothing on the box has today.

1. Provision storage (Cloudflare R2 recommended — free egress, ~$0.015/GB-
   month): dash.cloudflare.com → R2 → create bucket → Manage API Tokens →
   token scoped to that bucket only (Object Read & Write). Endpoint is
   `https://<account_id>.r2.cloudflarestorage.com`.
2. `cp providers/vps/.env.backup.example /opt/aion/.env.backup && chmod 600
   /opt/aion/.env.backup` — fill in `PGDUMP_URL`, `BACKUP_PASSPHRASE`
   (generate with `openssl rand -base64 32`, store it OFF this box too),
   `S3_ENDPOINT`/`S3_BUCKET`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`.
3. Test once by hand: `cd /opt/aion && ./scripts/backup.sh`.
4. Install the timer: copy `providers/vps/system/aion-backup.{service,timer}`
   to `/etc/systemd/system/`, `systemctl daemon-reload && systemctl enable
   --now aion-backup.timer`.
5. **Prove restore works** (never skip this — a backup that's never been
   restored is not a backup): `BACKUP_KEY=<latest object key> ./scripts/
   restore.sh` — restores into an isolated, disposable container and
   validates the 7 canonical tables, then tears itself down. Never touches
   the live database.

## Review stale/aged approval gates (read-only)

```bash
STALE_HOURS=24 providers/vps/scripts/report-stale-approvals.sh
```

Lists `approvals` still `pending` past the age threshold and any
`executions` stuck `awaiting_approval`. **Never auto-approves, rejects, or
replays anything** — resolve manually, and only after actually reviewing
each approval's `command_snapshot`:

```bash
docker exec -it aion-postgres-1 psql -U postgres -d aion_data -c \
  "UPDATE approvals SET status='rejected', decided_by='<operator>', decided_at=now(), note='<why>' WHERE approval_id='<id>'"
```

## Human database access (break-glass)

Exceptional only (§38). Prefer read-only, authenticated, logged:

```bash
gcloud sql connect ${PREFIX}-pg --user aion_app --project ${PROJECT_ID}   # read-mostly investigation
```

Do not create shared credentials. Record why access was needed.
