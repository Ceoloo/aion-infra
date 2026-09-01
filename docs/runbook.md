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

## Human database access (break-glass)

Exceptional only (§38). Prefer read-only, authenticated, logged:

```bash
gcloud sql connect ${PREFIX}-pg --user aion_app --project ${PROJECT_ID}   # read-mostly investigation
```

Do not create shared credentials. Record why access was needed.
