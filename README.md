# aion-infra

**The minimum secure, reproducible, recoverable — and provider-portable —
production home for AION.**

AION Infra is **Phase 3** of the AION architecture
([aion-docs/roadmap/build-order.md](https://github.com/Ceoloo/aion-docs/blob/main/roadmap/build-order.md)).
Phases 1–2 produced a control-plane kernel ([AION Core](https://github.com/Ceoloo/aion-core))
and a durable data layer ([AION Data](https://github.com/Ceoloo/aion-data)).
Phase 3 moves that workload from *production-quality code + local database* to a
*secure, reproducible, recoverable production environment* — **and keeps it
portable across a generic VPS, AWS, or GCP** (portability amendment), without
rewriting Core, Data, or product code.

> **AION is cloud-portable, not cloud-abstracted.** There is one AION workload;
> cloud providers are deployment environments. We do not build a universal cloud
> API — portability lives at one boundary, the
> [deployment contract](contracts/deployment-contract.md). See
> [docs/portability.md](docs/portability.md).

```
   AION Core + AION Data + AION Runtime artifact
                     │  one contract · one image · one set of migrations
                     ▼
        Provider-neutral deployment contract
          │                │              │
     VPS profile      AWS profile     GCP profile
   Compose + Caddy   ECS/RDS/…       Cloud Run/SQL
   (ACTIVE, cheap)   (SUPPORTED)     (SUPPORTED managed)
```

## The workload contract (stable, provider-neutral)

Every target runs the **same** container image, configured **only** by
environment variables, against a **PostgreSQL 16-compatible** database reached by
URL:

```
DATABASE_URL · AION_ENVIRONMENT · LOG_LEVEL · SERVICE_VERSION · GIT_SHA   → runtime
MIGRATION_DATABASE_URL                                                     → migrations only
GET /health/live · GET /health/ready · structured stdout logs · SIGTERM shutdown
```

Full contract: [contracts/deployment-contract.md](contracts/deployment-contract.md).

## Deployment profiles

| Profile | Runtime | Database | Status |
|---|---|---|---|
| **[VPS](providers/vps/README.md)** | Docker Compose + Caddy (auto-TLS) | local Postgres (Mode A) **or** managed URL (Mode B) | **ACTIVE / low-cost** |
| **[AWS](providers/aws/README.md)** | ECS Fargate | RDS PostgreSQL 16 | **SUPPORTED architecture** (minimal TF, not provisioned) |
| **[GCP](providers/gcp/README.md)** | Cloud Run | Cloud SQL PostgreSQL 16 | **SUPPORTED managed** (full TF, not provisioned) |

The **workload** is at parity on all three (same image, migrations, health,
config). Only the infrastructure differs — see the
[capability matrix](docs/portability.md#provider-capability-matrix).

## What Phase 3 owns

- **Declarative infrastructure** for each profile (Terraform for AWS/GCP;
  Compose + scripts for VPS), reproducible from source, with separated state.
- **PostgreSQL 16-compatible database**: encrypted, backups, PITR (managed) or
  scheduled off-host encrypted dumps (VPS); never publicly exposed.
- **The Phase 2 two-role model** enforced everywhere: `aion_app` (DML only,
  append-only logs, no DDL) and `aion_migrator` (DDL, migrations only).
- **Secret injection** per profile (env file / Secrets Manager / Secret Manager),
  never committed; the runtime never holds the migration credential.
- **Least-privilege identities**; keyless CI where the provider supports it.
- **Minimum runtime hosting** via a thin, provider-neutral reference host.
- **Controlled migrations** through AION Data's own runner (never a second
  system), migration-before-deploy and fail-closed.
- **CI/CD** with a **human-gated** production release on every profile.
- **Health + logging**, **basic alerts**, and **backup + restore** procedures.

## What Phase 3 does NOT own (non-goals)

No Kubernetes, service mesh, brokers, Redis, vector/warehouse stores,
multi-region active-active, agent-runtime fleets, product/CRM schema, or a
cloud-abstraction framework. Business logic stays in Core; canonical data stays
in Data (aion-docs/repositories/dependency-rules.md). Full list + rationale:
[docs/phase-3.md](docs/phase-3.md).

## Repository layout

```
aion-infra/
├── README.md · .gitignore · .env.example
├── contracts/
│   └── deployment-contract.md      the provider-neutral workload contract
├── providers/
│   ├── vps/     compose · Caddyfile · scripts (deploy/backup/restore/bootstrap) · system
│   ├── aws/     README · architecture.md · terraform (minimal, validates)
│   └── gcp/     README · terraform (modules + environments) · scripts (gcloud)
├── scripts/     verify · portability-check · health-check · smoke-test · backup-restore-selftest
├── docs/        architecture · environments · security · networking · database ·
│                deployment · observability · backup-recovery · runbook ·
│                portability · phase-3 · adr/
└── .github/     workflows (validate · deploy-gcp · deploy-vps) + gcp-deploy action
```

> The **runtime host** (the composition root that boots Core+Data and builds the
> one image) lives in the sibling repo **[aion-runtime](https://github.com/Ceoloo/aion-runtime)**
> ([ADR-002](https://github.com/Ceoloo/aion-docs/blob/main/adr/ADR-002-runtime-host-ownership.md)).
> aion-infra **consumes** its image (`ghcr.io/ceoloo/aion-runtime`) — it builds none.

## Workflows

- **Runtime image**: built + published by [aion-runtime](https://github.com/Ceoloo/aion-runtime)'s CI; every profile below deploys that image.
- **VPS**: `providers/vps/scripts/deploy.sh` (pull → migrate fail-closed → roll →
  readiness → smoke); CI over SSH via [deploy-vps.yml](.github/workflows/deploy-vps.yml).
- **GCP**: merge to `main` → [deploy-gcp.yml](.github/workflows/deploy-gcp.yml)
  (auto staging; human-gated production).
- **AWS**: mapping + minimal Terraform; activation is a provider-activation
  mission ([providers/aws/architecture.md](providers/aws/architecture.md)).

## Verification

- **Infra Phase 3 checks:** `scripts/verify.sh` → **14/14 pass** (IaC across all
  profiles, DB provisioning + roles, migration/health path, backups, human gate,
  image consumption, no committed secrets).
- **Infra portability checks:** `scripts/portability-check.sh` → **10/10 pass**
  (fixture removed, infra builds no image, all profiles consume the aion-runtime
  image + same migrate entrypoint, provider tech confined).
- **Runtime host:** the runtime-source + acceptance checks run in
  [aion-runtime](https://github.com/Ceoloo/aion-runtime)'s CI (portability 9/9;
  migrate → deploy → readiness → smoke against an ephemeral Postgres).

## Status

Phase 3 + 3.5 are structurally complete: the runtime host is extracted to
[aion-runtime](https://github.com/Ceoloo/aion-runtime) and every profile consumes
its image. Phase 3 infrastructure is **defined declaratively for three profiles
and verified by static validation + acceptance runs**. GCP is fully specified;
VPS is a working low-cost reference; AWS is a validated minimal mapping. **Live
cloud provisioning of any profile requires that provider's credentials and is a
remaining operational step** — see [docs/phase-3.md](docs/phase-3.md).
