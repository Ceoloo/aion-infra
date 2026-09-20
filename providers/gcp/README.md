# GCP deployment profile

> **STATUS (2026-09-20): NOT DEPLOYED FROM THIS REPO AND NOT SUPPORTED for the current runtime image until the configuration below is wired.**
> The deploy workflow is dormant (it runs only when `GCP_WORKLOAD_IDENTITY_PROVIDER` / CI service-account variables exist; none are set on this repo, and no GCP plan has run in CI). Whether an environment was ever created by hand is not
> knowable from the repo. The runtime now refuses to start in `AION_ENVIRONMENT=production` without an explicit CRM backend choice (`GHL_BACKEND=live` + `GHL_API_KEY`/`GHL_LOCATION_ID`), and
> requires the identity plane (`AION_AUTH_MODE=required` + `AION_GATEWAY_API_KEYS`). This profile wires **neither** (it passes only `AION_ENVIRONMENT`, DB URLs and release metadata), so a production deployment of a current image would not start.
> Before using it: add secret-backed `GHL_API_KEY`, `GHL_LOCATION_ID`, `GHL_BACKEND=live`, `AION_GATEWAY_API_KEYS` (and `AION_AUTH_MODE=required`) to the runtime service, then boot-check the image with that configuration.
> Staging (`AION_ENVIRONMENT=staging`) also needs the identity keys (auth is required off-local); only its CRM backend keeps the legacy fallback (no credentials → fake), which is not a production-equivalent test.


**GCP is one supported deployment implementation of the AION runtime — not an
architectural dependency of AION.** The AION workload (Core + Data + runtime
artifact) is defined by [`contracts/deployment-contract.md`](../../contracts/deployment-contract.md);
this profile is one way to satisfy that contract with Google Cloud's native
services. AION can move to the [VPS](../vps/README.md) or [AWS](../aws/README.md)
profile without any change to aion-core, aion-data, or the runtime image.

Provider-specific technologies below (Cloud Run, Cloud SQL, Secret Manager,
Cloud Logging, GCS, Workload Identity Federation) appear **only** inside this
profile. They never leak into the runtime contract.

## Mapping (contract capability → GCP service)

| Contract capability | GCP implementation |
|---|---|
| Runtime hosting | **Cloud Run** (serverless containers, managed TLS) |
| Container image | **Artifact Registry** |
| PostgreSQL 16 | **Cloud SQL** for PostgreSQL (private IP) |
| Secret injection | **Secret Manager** → env at start |
| Structured logs | stdout/stderr → **Cloud Logging** (native) |
| Health/readiness | Cloud Run probes call `/health/live`, `/health/ready` |
| Backups / PITR | Cloud SQL automated backups + point-in-time recovery |
| CI identity | GitHub Actions → **Workload Identity Federation** (keyless) |
| Remote IaC state | **GCS** buckets, separated per environment |
| Human prod gate | GitHub Environment required reviewers |

## Layout

```
providers/gcp/
├── README.md            (this file)
├── terraform/
│   ├── modules/   networking · database · secrets · runtime · observability
│   └── environments/  bootstrap · staging · production   (separated state)
└── scripts/       migrate.sh · backup-verify.sh   (gcloud-based)
```

## Usage

Bootstrap once, then per-environment apply. Full walkthrough (unchanged by the
portability amendment): [`docs/deployment.md`](../../docs/deployment.md),
[`docs/database.md`](../../docs/database.md),
[`docs/backup-recovery.md`](../../docs/backup-recovery.md),
[`docs/runbook.md`](../../docs/runbook.md).

```bash
# bootstrap (state buckets, OIDC/WIF, CI identities)
cd providers/gcp/terraform/environments/bootstrap && terraform init && terraform apply …

# an environment
cd providers/gcp/terraform/environments/staging
terraform init -backend-config="bucket=<staging-tfstate>"
TF_VAR_app_password=… TF_VAR_migrator_password=… terraform apply -var project_id=<proj>

# migrations + backup verification
PROJECT_ID=<proj> providers/gcp/scripts/migrate.sh staging
PROJECT_ID=<proj> INSTANCE=aion-staging-pg providers/gcp/scripts/backup-verify.sh
```

CI/CD: [`.github/workflows/validate.yml`](../../.github/workflows/validate.yml)
and [`.github/workflows/deploy-gcp.yml`](../../.github/workflows/deploy-gcp.yml)
(via the `gcp-deploy` composite action).

## Status

**SUPPORTED MANAGED DEPLOYMENT PROFILE.** Defined declaratively and statically
validated; the same runtime image and aion-data migrations are used as every
other profile. Live provisioning requires GCP credentials (see
[`docs/phase-3.md`](../../docs/phase-3.md)).
