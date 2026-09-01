# Phase 3 — Minimum Production Infrastructure

## Scope

Phase 3 builds **the smallest secure production infrastructure foundation
required to run the existing AION Core + Data workload safely** — moving AION
from *production-quality code + local database* to a *secure, reproducible,
recoverable production environment*, and no further (aion-infra §1–2). Every
resource answers a current requirement of the Core/Data workload; nothing is
provisioned for hypothetical scale (aion-docs/engineering/principles.md #1).

## Provider decision (new, durable — draft ADR)

**Google Cloud**, single-provider, chosen for **minimum operational complexity**
for one Node.js service talking to one PostgreSQL database:

| Capability required | GCP choice | Why over alternatives |
|---|---|---|
| Managed runtime hosting | **Cloud Run** (serverless containers) | no VM to patch, no Kubernetes; scales to zero; managed TLS |
| Managed PostgreSQL 16 | **Cloud SQL** | backups, PITR, private IP, deletion protection, HA — all managed |
| Managed secrets | **Secret Manager** | per-env, IAM-scoped, versioned |
| Keyless CI auth | **Workload Identity Federation** | no long-lived cloud keys in GitHub (§50) |
| Remote IaC state | **GCS** | encrypted, versioned, native locking, per-env buckets |
| Logs/metrics/alerts | **Cloud Logging/Monitoring** | provider-native, nothing to run |

This is architecturally significant (a durable provider + hosting-model choice),
so it is recorded as a **draft ADR** for aion-docs (aion-infra §69; the content
is in the completion report — this repo does not modify aion-docs). Terraform is
the IaC tool. AWS/GCP/Azure all satisfy the capabilities; GCP + Cloud Run is the
lowest-operational-burden fit for this exact, small workload, and the design
stays portable in spirit (portable PostgreSQL, containerized runtime).

## What was built

- **Terraform**: 5 modules (`networking`, `database`, `secrets`, `runtime`,
  `observability`) composed by 3 environments (`bootstrap`, `staging`,
  `production`) with **separated remote state**.
- **Managed Postgres 16**: private IP, encrypted, daily backups + PITR,
  deletion protection (prod), maintenance window, HA (prod).
- **Two-role least privilege**: `aion_app` (DML, append-only logs, no DDL) and
  `aion_migrator` (DDL) — enforced by `runtime/sql/grants.sql`.
- **Managed secrets**: Secret Manager connection strings, least-privilege IAM,
  no plaintext outputs, documented rotation.
- **Least-privilege identities**: runtime / migration / CI / human, keyless CI
  via WIF, production CI bound to `main`.
- **Reference runtime host** (`runtime/`): boots real Core over real Data over
  Postgres; config fail-fast; health/readiness; structured JSON logs; release
  metadata; boot smoke; graceful shutdown; multi-stage non-root Dockerfile.
- **Controlled migrations**: separate Cloud Run job, aion-data's own runner,
  migration-before-deploy, fail-closed.
- **CI/CD**: `validate.yml` (fmt/validate/tfsec/typecheck/gitleaks/plan) and
  `deploy.yml` (auto staging; human-gated production).
- **Observability**: bounded log retention + basic alerts.
- **Scripts**: migrate, health-check, smoke-test, backup-verify, verify.

## What was deliberately NOT built (§3, §53–56)

Kubernetes/EKS/GKE-workloads, service mesh, Kafka/RabbitMQ, Redis, vector DBs,
warehouse/BI, Elasticsearch, multi-region active-active, global traffic routing,
agent-runtime fleets (ATLAS/Grok/Claude/Codex/Cursor/OpenClaw), GPU infra, CDN,
customer/product/CRM schema, full SOC/SIEM, VPN mesh, elaborate FinOps,
self-hosted Postgres, speculative autoscaling, zero-trust platform, multi-cloud
portability layer. None is justified by the current workload; each would be a
future mission + likely ADR.

## Verification (§60–65)

All credential-free checks are automated in `scripts/verify.sh` (**15/15 pass**).
Several were additionally proven **live against a real local PostgreSQL 16**
during the build (Docker was unavailable, so a local `postgresql-16` cluster
stood in for Cloud SQL):

| Check | Result | Evidence |
|---|---|---|
| IAC_VALIDATE | ✅ | `terraform fmt -check` + `validate` on all 3 stacks |
| STAGING_PLAN / PRODUCTION_PLAN | ✅ config valid | validate passes; live `plan` needs GCP creds |
| SECRET_REFERENCE_VALIDATION | ✅ | runtime reads `DATABASE_URL` via `secret_key_ref` |
| DATABASE_PROVISIONING_CONFIG | ✅ | PG16 + backups + PITR + private IP + deletion protection |
| DB_ROLE_SEPARATION | ✅ **live** | app role denied DDL, denied UPDATE/DELETE on `events`/`telemetry_records`; SELECT/INSERT allowed |
| MIGRATION_EXECUTION_PATH | ✅ **live** | aion-data runner applied `0001` as migrator; grants applied |
| RUNTIME_CONFIG_VALIDATION | ✅ **live** | missing `DATABASE_URL` → fail-fast exit 1; app≠migrator guard |
| HEALTH_CHECK | ✅ **live** | `/health/live` 200, `/health/ready` 200 |
| DATABASE_CONNECTIVITY | ✅ **live** | readiness 200 (DB up) → 503 (DB down) → 200 (recovered, no redeploy) |
| DEPLOYMENT_SMOKE_TEST | ✅ **live** | boot Core lifecycle (R0) completed; run persisted; SHA reported |
| BACKUP_CONFIGURATION | ✅ | automated backups + WAL retention in TF |
| RESTORE_RUNBOOK | ✅ | isolated clone-restore procedure + doc (live restore deferred) |
| PRODUCTION_HUMAN_GATE | ✅ | `environment: production` approval + `main`-only refuse |
| NO_PUBLIC_SECRET | ✅ | no committed secrets; sensitive vars; no secret outputs; gitleaks in CI |

### Required scenarios proven live

- **Staging acceptance (§61):** migrate (migrator) → app-role connect → health
  → boot smoke → structured logs — end-to-end, no manual schema creation, no
  secrets in source.
- **Database failure (§62):** with the runtime live, stopping Postgres flipped
  `/health/ready` to 503 (liveness stayed 200, process alive); restarting
  Postgres recovered readiness to 200 **without a redeploy**; failure logged a
  non-secret diagnostic (`database_unreachable`), zero credential leakage.
- **Migration failure (§63):** running the migrate entrypoint with the DDL-less
  app role failed and **exited non-zero with no partial tables**; the migrator
  identity then succeeded (exit 0). A failed migration therefore blocks the
  deploy; the existing runtime is left intact.
- **Production safety (§64):** production release requires GitHub Environment
  reviewer approval and refuses non-`main` refs — configured, hard exit
  criterion met at the pipeline boundary.

## Live verification still required (needs GCP credentials)

Honest status: **no cloud resources were provisioned** (no GCP credentials in
this build). These remain operational steps, not claims:

- `terraform plan`/`apply` against real staging + production projects;
- a real staging deploy + smoke test against a `*.run.app` URL;
- **live backup restore** into an isolated instance (`backup-verify.sh MODE=restore`);
- confirming the production Environment reviewer rule is enabled in GitHub.

The procedures for all of these are exact and test-ready.

## Costs (§39, §70)

Estimated baseline monthly cost (us-central1, list pricing; **needs live
verification** — no billing account was queried):

| Driver | Staging | Production |
|---|---|---|
| Cloud SQL (staging `db-custom-1-3840` zonal; prod `db-custom-2-7680` **regional/HA**) | ~$50–70 | ~$250–350 |
| Cloud Run (staging scale-to-zero; prod 1 warm instance, small) | ~$0–10 | ~$15–40 |
| Secret Manager | <$1 | <$1 |
| Cloud Logging/Monitoring (bounded retention) | ~$0–5 | ~$5–20 |
| Backups + WAL/PITR storage | ~$5–10 | ~$20–50 |
| Artifact Registry + egress | ~$1–5 | ~$5–15 |
| **Estimated total** | **~$60–100** | **~$300–475** |
| **Combined** | | **~$360–575 / month** |

Cost drivers are dominated by the database tier and HA. Staging is intentionally
small; production HA is the single largest line and is a deliberate safety
choice. Figures are estimates and must be confirmed against the live billing
account before relying on them.

## Architecture issues

### Carried forward from Phase 2 (unchanged — not "fixed" in Infra, §68)

1. Core `RunRepository.save` lacks expected-version support.
2. No cross-port Unit of Work for atomic run/event/telemetry transitions.
3. Permissions persisted as JSONB pending query needs.
4. Core event contract has no `command_id`.
5. Vendored Core dependency is temporary until tagged releases exist.

### Newly surfaced in Phase 3

6. **Runtime host ownership is undecided.** The reference host imports
   `@aion/core`/`@aion/data`, which the dependency rules forbid *infra* code from
   doing. It is scoped as an isolated verification **fixture** (not
   Terraform-managed platform code), but its production home — aion-core, or a
   new `aion-runtime` repo — is an open decision. **Recommendation: an ADR in
   aion-docs before Phase 4 wires a real product runtime.**
7. **DB privilege bootstrapping on managed Postgres.** `grants.sql`'s
   database/schema-level `GRANT`s require the migrator to own the DB/schema; the
   substantive per-table least-privilege holds regardless, but the ownership
   assumption should be made explicit in provisioning. **Recommendation: document
   as an operational precondition (done in database.md); revisit if a provider
   changes ownership defaults.**
8. **DB TLS is `require`, not `verify-ca`.** Acceptable over a private VPC path;
   pinning the server CA is a low-effort hardening. **Recommendation: upgrade
   when convenient.**
9. **Vendored `@aion/data` pinned to `main`.** No tagged release exists yet
   (mirrors issue 5). **Recommendation: pin to a tag once aion-data cuts one.**

## Exit criteria (§66–67)

| Criterion | Status |
|---|---|
| Declarative infrastructure | ✅ Terraform, validated |
| Staging + production boundaries | ✅ separate projects/state/secrets/DB |
| Managed Postgres | ✅ Cloud SQL 16 |
| Least-privilege DB roles | ✅ enforced + live-proven |
| Managed secrets | ✅ Secret Manager, no repo secrets |
| Minimum runtime hosting | ✅ Cloud Run + reference host |
| Controlled migrations | ✅ job, aion-data runner, fail-closed |
| CI/CD | ✅ validate + deploy |
| Production human gate | ✅ GitHub Environment approval |
| Health + logging | ✅ probes + structured JSON |
| Backups + restore plan | ✅ configured + test-ready procedure |
| Smoke-tested staging | ✅ locally; live pending creds |

None of the §67 "must NOT be complete if" conditions hold: no committed secrets,
runtime uses the app role (never superuser), migrations are automated, production
has a human gate, backups are configured, infra is recreatable from source,
staging and production have separate databases, Postgres is not publicly exposed,
health/readiness exist, and the release SHA is identifiable.

## Recommendation

**READY WITH CONDITIONS.** The infrastructure is complete, coherent, and proven
by static validation plus a full local acceptance run (including the DB-failure
and migration-failure scenarios). The conditions are operational, not design:
provision the two GCP projects and run one live staging deploy + backup restore
with real credentials, and resolve the runtime-host-ownership ADR (issue 6)
before Phase 4 attaches a product runtime.
