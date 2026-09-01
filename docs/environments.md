# Environments

AION separates environments so work, data, and identities are isolated by stage,
and promotion to production is deliberate and governed
(aion-docs/architecture/environments.md). This document is the `aion-infra`
realization of those invariants.

## Tiers

| Tier | Purpose | Data | Infra owner |
|---|---|---|---|
| **local** | developer work | synthetic / disposable | the developer |
| **staging** | pre-production validation | non-production | `aion-infra` |
| **production** | real operation | canonical, sensitive | `aion-infra` |

### local
Not cloud infrastructure. Developers run the reference runtime against the
disposable Postgres in aion-data's `docker-compose.yml`, using `.env`
placeholders. Nothing here touches a managed service.

### staging
A complete, separately-credentialed cloud stack — useful, not ceremonial. It
runs real migrations, a real image deploy, health + smoke tests, and DB
connectivity against a **smaller, zonal** Cloud SQL instance. Deploys
automatically after a merge to `main`.

### production
The same architecture as staging, differing only where safety requires it:
**regional/HA** database, **deletion protection on**, longer backup retention, a
warm minimum instance, stricter access, and a **human release gate**.

## Isolation (how the invariants are enforced)

| Invariant | Mechanism |
|---|---|
| No cross-tier reach | Separate GCP **projects** per environment; separate VPCs; DB on private IP only |
| Separate identities & secrets | Distinct service accounts and Secret Manager secrets per project; nothing shared |
| Separate state | Distinct GCS state buckets (bootstrap creates one per environment) |
| Production data never flows down | No pipeline path copies prod data to lower tiers; lower tiers use non-prod data |
| Promotion is governed | Production deploy requires GitHub Environment reviewer approval, `main` only |

## Configuration model

Configuration is environment-specific and injected, never edited into source
(aion-infra §41):

- **project/region/email** → per-environment `terraform.tfvars` (from
  `*.tfvars.example`) or `TF_VAR_*` in CI.
- **database passwords** → `TF_VAR_app_password` / `TF_VAR_migrator_password`
  from CI secret material; never committed.
- **runtime config** → env vars set by Terraform on the Cloud Run service, with
  `DATABASE_URL` sourced from Secret Manager at start.

Never reuse production secrets in staging; never let a staging migration target
production (separate projects + separate migrator credentials make this
structural, not a matter of care).

## Adding/rebuilding an environment

1. `bootstrap` (once): create state buckets, WIF pool/provider, CI identities.
2. `terraform init -backend-config="bucket=<env>-tfstate"` in the env dir.
3. Provide `project_id` + `TF_VAR_*` passwords.
4. `terraform apply` → network, database, roles, secrets, runtime, observability.
5. Run the migration job, deploy the image, smoke test (the pipeline does this).

Staging is intentionally destroyable (`deletion_protection = false`) so it can be
rebuilt cheaply; production is not.
