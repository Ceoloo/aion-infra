# Deployment

The release pipeline and its human gates (aion-infra §24–26). Infrastructure is
declarative; releases are controlled; production is deliberate.

## Pipelines

The runtime **image** is built and published by the
[aion-runtime](https://github.com/Ceoloo/aion-runtime) repo (ADR-002).
aion-infra **consumes** it and builds nothing.

| Workflow | Trigger | Does |
|---|---|---|
| `validate.yml` | every PR + push to `main` | fmt, validate, tfsec (advisory), infra portability + verify, gitleaks, staging plan (if cloud auth configured) — **always runs, provider-independent** |
| `deploy-gcp.yml` (staging) | push to `main` **and GCP configured** | resolve immutable image → apply infra → migrate job → roll service → smoke |
| `deploy-gcp.yml` (production) | manual dispatch, `main` only **and GCP configured** | **required-reviewer approval** → same steps with prod identity |
| `deploy-vps.yml` | manual dispatch | resolve immutable image → SSH → pull → migrate → roll → readiness → smoke |

Both GCP environments deploy through the same `gcp-deploy` composite action, so
they behave identically (aion-infra §44).

### Readiness gate (provider dormant until configured)

The GCP deploy jobs carry an `if` guard requiring
`vars.GCP_WORKLOAD_IDENTITY_PROVIDER` **and** the per-environment CI
service-account var to be set. Until GCP is configured the jobs are **skipped**
(not failed), so an unprovisioned provider produces no noisy red runs and a
genuine failure is unambiguous. Setting the vars reactivates GCP with no code
change. `validate.yml` is **never** gated — credential-free checks run regardless.

### Immutable release (no bare `:latest`)

Deployments resolve and persist an **immutable** runtime reference
`ghcr.io/ceoloo/aion-runtime:<runtime-commit-sha>` (the `resolve` job/step reads
aion-runtime's `main` HEAD SHA, or you pin one via the `runtime_image` dispatch
input). `:latest` remains as convenience metadata but is never the deployed
reference — so rollback is deterministic and `/health`'s `git_sha` answers
"exactly which runtime is this?".

## Release steps (per environment)

1. **Resolve immutable image** — `ghcr.io/ceoloo/aion-runtime:<sha>` (from the
   aion-runtime main HEAD, or an explicit pin). aion-infra builds no image.
2. **Apply infrastructure** — `terraform apply` (idempotent; the image is ignored
   by Terraform so this never fights the rollout).
3. **Migrate (before deploy)** — point the migration job at that image and
   `execute --wait`. A failed migration returns non-zero and **stops the deploy**
   (§18, §46, §63); the currently-serving revision stays up.
4. **Roll the service** — `gcloud run services update --image <…:sha>`; Cloud Run
   shifts traffic only after the startup probe (`/health/ready`) passes.
5. **Smoke test** — `scripts/smoke-test.sh` verifies reachability, health, and
   that the deployed SHA matches (§45).

## The production human gate (§25, §64 — hard exit criterion)

Production release requires deliberate human authorization; **no AI worker
deploys production on its own**. Two independent controls:

1. **GitHub Environment protection** — the `production` environment has a
   *required reviewers* rule. The deploy job pauses until a human approves. This
   is the human gate (aion-docs/governance/human-gates.md); configure it under
   **Settings → Environments → production → Required reviewers**.
2. **Trusted ref only** — production deploys refuse any ref but `main` (§26),
   reinforced by the OIDC provider's `attribute.ref` binding to `main`
   (bootstrap module).

Production Terraform `apply` runs only inside this gated, `main`-only job, so
destructive infra changes also require the same human approval.

## Bootstrap (one-time, minimal — §10)

Remote state can't store the resources that create it, so `bootstrap` runs with a
**local backend**, by a human, once:

```bash
cd providers/gcp/terraform/environments/bootstrap
terraform init                       # local backend
terraform apply \
  -var project_id=<seed-project> \
  -var state_bucket_prefix=<globally-unique-prefix> \
  -var github_repository=Ceoloo/aion-infra
```

It creates the two state buckets, the GitHub OIDC pool/provider, and the CI
service accounts. Wire the outputs into GitHub repo **variables**
(`GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_CI_SERVICE_ACCOUNT_*`,
`GCP_TFSTATE_BUCKET_*`, `GCP_PROJECT_*`) and **secrets**
(`*_APP_DB_PASSWORD`, `*_MIGRATOR_DB_PASSWORD`). Optionally migrate the bootstrap
state into a bucket afterward.

## First environment apply

```bash
cd providers/gcp/terraform/environments/staging
terraform init -backend-config="bucket=<staging-tfstate-bucket>"
TF_VAR_app_password=... TF_VAR_migrator_password=... \
  terraform apply -var project_id=<staging-project>
```

Then the pipeline builds an image, runs the migration job, and rolls the service.

## Rollback (§47)

Because aion-data migrations are forward-only, prefer **restore previous runtime
+ forward-fix schema** over restoring the database:

- **Runtime rollback**: redeploy the previous image SHA
  (`gcloud run services update --image <prev-sha>`) — instant, no DB change.
- **Infra rollback**: revert the Terraform change and `apply`.
- **Schema**: never assume reversibility; write a forward migration. Restore the
  database only for genuine data loss/corruption
  ([backup-recovery.md](backup-recovery.md)).

## Failure behavior (§46)

| Failure | Behavior |
|---|---|
| DB unavailable at boot | runtime starts but `/health/ready` is 503; Cloud Run withholds traffic |
| Required config missing | runtime fails fast, exits non-zero, never serves |
| Migration fails | job exits non-zero; deploy halts; previous revision keeps serving |
| Deploy (service roll) fails | previous revision keeps serving; smoke fails loudly |
| Production apply partially fails | Terraform reports; re-run is idempotent; human gate already passed for the attempt |
