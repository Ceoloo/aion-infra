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
  `deploy-gcp.yml` (auto staging; human-gated production).
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

## Portability amendment (provider neutrality)

After the initial GCP-targeted Phase 3, a **portability-hardening pass** ensured
GCP is a *deployment profile*, not part of the AION runtime contract. AION can
now move between a generic VPS, AWS, or GCP without changing aion-core,
aion-data, or product code — see [portability.md](portability.md) and
[`contracts/deployment-contract.md`](../contracts/deployment-contract.md).

**What changed:**

- **Provider boundary.** The GCP Terraform + gcloud scripts moved intact to
  `providers/gcp/`; nothing was rewritten. GCP-specific names (Cloud Run, Cloud
  SQL, Secret Manager, WIF) now appear only inside `providers/gcp/` and its docs.
- **Deployment contract.** `contracts/deployment-contract.md` defines the stable,
  provider-neutral workload contract (runtime, database, config surface, secret
  injection, deployment sequence, recovery).
- **VPS profile (ACTIVE / low-cost).** `providers/vps/` — Docker Compose + Caddy
  (auto-TLS) + the same runtime image + optional local Postgres (Mode A) or
  managed DB (Mode B, config-only); env-file secrets; encrypted off-host
  backup + isolated-restore scripts; minimal server hardening; SSH deploy CI.
- **AWS profile (SUPPORTED architecture).** `providers/aws/` — full AION→AWS
  mapping + minimal, `validate`-passing Terraform (ECS Fargate, RDS 16, Secrets
  Manager, ECR, CloudWatch, ALB, GitHub OIDC) with the same runtime/migration
  separation. Not provisioned.
- **Same artifact / same migrations.** One `runtime/Dockerfile`; every profile
  consumes an image variable and runs the same aion-data migrate entrypoint.
  The runtime imports no cloud SDK; provider comments were removed from the app.
- **Portability tests.** `scripts/portability-check.sh` — **12/12 pass** (no
  cloud SDK in runtime/core/data, neutral secret injection/logging/health, one
  Dockerfile, same migrations, no hardcoded DB host, provider tech confined to
  `providers/`).

**Amendment exit checks (§37):** `PROVIDER_NEUTRAL_RUNTIME_CONTRACT`,
`SAME_RUNTIME_ARTIFACT`, `SAME_AION_DATA_MIGRATIONS`,
`GENERIC_POSTGRES_COMPATIBILITY`, `VPS_DEPLOYMENT_PROFILE`,
`AWS_DEPLOYMENT_MAPPING`, `GCP_PROFILE_ISOLATED`, `PROVIDER_NEUTRAL_LOGGING`,
`PROVIDER_NEUTRAL_HEALTH`, `PROVIDER_NEUTRAL_SECRET_INJECTION`,
`PORTABILITY_TESTS_PASS` — **all pass** (`scripts/portability-check.sh`). The
amendment does not require all three providers to be live.

**Gate closure — deploy sequence + backup/restore, run for real (Docker-free).**
Two committed, re-runnable harnesses execute the actual logic against a real
PostgreSQL 16 with the real built artifact (no Docker daemon / no VPS / no object
storage in this environment, so the container, SSH, and remote-S3 wrappers are
the only unexecuted legs):

- `scripts/local-acceptance.sh` — the full **migrate → deploy → readiness →
  smoke** sequence (contract §5). Observed: migrations applied by the migrator
  identity + grants; runtime booted as the **app** role (migration URL removed
  from its env); `/health/ready` 200; committed `scripts/smoke-test.sh` PASS with
  the deployed `GIT_SHA` matched; boot lifecycle self-check completed. This is
  the same sequence `providers/vps/scripts/deploy.sh` performs via Compose.
- `scripts/backup-restore-selftest.sh` — the **encrypt → off-host → decrypt →
  isolated-restore → validate** cycle (§32, §65) the VPS `backup.sh`/`restore.sh`
  perform. Observed: `pg_dump | gzip | openssl aes-256-cbc` produced a genuine
  ciphertext (`Salted__` header; plaintext-marker check passed) written to an
  off-host directory; decrypt + restore into a **separate isolated database**
  yielded **7/7 canonical tables** and the `schema_migrations` row; the isolated
  target was torn down. It never touched the source DB.

Also fixed a build-breaker introduced by the amendment: a `*/` inside a
`runtime/src/migrate.ts` doc comment had terminated the block early (the runtime
now typechecks and builds clean; `local-acceptance.sh` builds it as step 0).

Still requiring real infrastructure (unchanged in nature, narrowed in scope):
Docker-Compose-on-a-real-VPS, live SSH deploy, and upload to a remote
S3-compatible endpoint — none available here. The logic each wraps is proven
above.

## Architecture issues

### Carried forward from Phase 2 (unchanged — not "fixed" in Infra, §68)

1. Core `RunRepository.save` lacks expected-version support.
2. No cross-port Unit of Work for atomic run/event/telemetry transitions.
3. Permissions persisted as JSONB pending query needs.
4. Core event contract has no `command_id`.
5. Vendored Core dependency is temporary until tagged releases exist.

### Newly surfaced in Phase 3

6. **Runtime host ownership — RESOLVED** by
   [ADR-0001](adr/ADR-0001-runtime-host-ownership.md): the host's canonical home
   is a **dedicated `aion-runtime` package/repo** that depends on `@aion/core` +
   `@aion/data` downward (allowed) and is consumed by `aion-infra` only as an
   image. `aion-core/runtime` was rejected (core must stay database-agnostic) and
   `aion-products` was rejected (the platform runtime is not a product). Until
   `aion-runtime` is created, `aion-infra/runtime/` remains the interim fixture,
   kept minimal and provider-neutral. The ADR should be ratified into aion-docs
   (ready-to-copy body in the ADR file); aion-infra does not modify aion-docs.
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

### Added by the portability amendment

10. **Provider portability must stay workload-level, not a cloud-API
    abstraction.** The invariant is preserved at the deployment-contract boundary
    only; there is deliberately no `CloudProvider` framework in the application
    (deployment-contract §7; docs/portability.md). **Recommendation: keep it that
    way — reject any PR that adds a runtime cloud-abstraction layer.**
11. **VPS local Postgres has higher operational risk than managed PostgreSQL**
    (single host, self-managed backups/patching). **Recommendation: use Mode B
    (managed DB URL) as soon as budget allows — it is a config-only change.**
12. **VPS env-file secrets are weaker than a managed secret store.** Root-owned
    `0600` is pragmatic but not a vault. **Recommendation: treat the host as
    sensitive (hardening), and prefer a managed secret source as AION grows.**

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

**READY WITH CONDITIONS.** The infrastructure is complete and coherent, now
**provider-portable** (VPS active reference, AWS supported mapping, GCP managed
profile — one workload, one image, one set of migrations), and proven by static
validation (15/15 Phase 3 + 12/12 portability), a full local acceptance run
(DB-failure and migration-failure scenarios), and a VPS-style acceptance run.

The runtime-host-ownership ADR is now **resolved**
([ADR-0001](adr/ADR-0001-runtime-host-ownership.md): a dedicated `aion-runtime`
package). The deploy sequence and backup/restore are proven for real against a
live PostgreSQL via the two committed harnesses. The remaining conditions are
purely infrastructure-availability, not design:

- stand up one real target (a VPS with Docker + SSH, plus an S3-compatible
  bucket) and run `providers/vps/scripts/deploy.sh` + `backup.sh`/`restore.sh`
  there — the only unexecuted legs are the container/SSH/remote-S3 wrappers;
- keep portability at the contract boundary — no cloud-abstraction framework
  (debt item 10);
- ratify ADR-0001 into aion-docs and, when convenient, extract `aion-runtime`.

Provider maturities are reported honestly and not claimed at parity beyond the
workload: **VPS ACTIVE**, **AWS SUPPORTED ARCHITECTURE**, **GCP SUPPORTED MANAGED
PROFILE** — none live-provisioned in this build.
