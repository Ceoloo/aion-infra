# aion-infra

**The minimum secure, reproducible, recoverable production home for AION.**

AION Infra is **Phase 3** of the AION architecture
([aion-docs/roadmap/build-order.md](https://github.com/Ceoloo/aion-docs/blob/main/roadmap/build-order.md)).
Phases 1–2 produced a control-plane kernel ([AION Core](https://github.com/Ceoloo/aion-core))
and a durable data layer ([AION Data](https://github.com/Ceoloo/aion-data)) that
already survive a process restart against a local Postgres. Phase 3 moves that
workload from *production-quality code + local database* to a *secure,
reproducible, recoverable production environment* — and **no more** (aion-infra
is justified by the workload that exists now, never by imagined scale;
aion-docs/engineering/principles.md #1).

```
        INTERNET
           │  managed HTTPS/TLS
           ▼
   AION RUNTIME SERVICE  (Cloud Run — Core + Data client)
           │  private VPC path, app role, TLS
           ▼
   MANAGED POSTGRES  (Cloud SQL for PostgreSQL 16)

   supporting: Secret Manager · Cloud Logging/Monitoring · automated
   backups + PITR · migration job · CI/CD with a production human gate
```

## What Phase 3 owns

- **Declarative infrastructure** (Terraform) for **staging** and **production**,
  reproducible from source, with separated remote state.
- **Managed PostgreSQL 16** (Cloud SQL): private IP, encrypted, automated
  backups + point-in-time recovery, production deletion protection.
- **The Phase 2 two-role model** enforced: `aion_app` (DML only, no DDL,
  append-only logs) and `aion_migrator` (DDL, migrations only).
- **Managed secrets** (Secret Manager): per-environment, least-privilege access;
  no secret in Git or Terraform state output.
- **Least-privilege identities**: separate runtime, migration, CI/deploy, and
  human-admin identities; keyless GitHub→GCP via Workload Identity Federation.
- **Minimum runtime hosting** (Cloud Run): a thin reference host that boots the
  real Core+Data workload, exposes health/readiness, logs structured JSON, and
  identifies its release SHA.
- **Controlled migrations** through AION Data's own runner (never a second
  migration system), run migration-before-deploy and fail-closed.
- **CI/CD**: PR validation + plan; automatic staging deploy; **human-gated**
  production release.
- **Health + logging**, **basic alerts**, and a **backup + restore** procedure.

## What Phase 3 does NOT own (deliberate non-goals)

No Kubernetes, service mesh, brokers (Kafka/RabbitMQ), Redis, vector/warehouse
stores, multi-region active-active, agent-runtime fleets, or any product/CRM
schema. Business logic and orchestration decisions stay in Core; canonical data
stays in Data (aion-docs/repositories/dependency-rules.md). See
[docs/phase-3.md](docs/phase-3.md) for the full "not built" list and why.

## Topology & environments

| | Local | Staging | Production |
|---|---|---|---|
| Owner | developer | platform | platform |
| Database | docker-compose Postgres (in aion-data) | Cloud SQL, zonal | Cloud SQL, **regional/HA** |
| Deletion protection | — | off (rebuildable) | **on** |
| Secrets | `.env` placeholders | Secret Manager (staging) | Secret Manager (production) |
| Deploy | manual | **automatic** after merge to `main` | **human-gated** release |

Full detail: [docs/environments.md](docs/environments.md),
[docs/architecture.md](docs/architecture.md).

## Provider / IaC

**Google Cloud** (Cloud Run + Cloud SQL + Secret Manager + Cloud
Logging/Monitoring + GCS remote state + Workload Identity Federation), chosen for
minimum operational complexity for a single Node.js service + Postgres —
serverless containers, no VM to patch, no Kubernetes. This is a new durable
architectural decision recorded as a draft ADR (see
[docs/phase-3.md](docs/phase-3.md) → "Provider decision"). Tooling is
**Terraform**; the capability requirements — not vendor loyalty — drive it, and
the design stays deliberately small.

## Repository layout

```
aion-infra/
├── README.md · .gitignore · .env.example
├── docs/            architecture, environments, security, networking, database,
│                    deployment, observability, backup-recovery, runbook, phase-3
├── terraform/
│   ├── modules/     networking · database · secrets · runtime · observability
│   └── environments/ bootstrap · staging · production   (separated remote state)
├── runtime/         reference runtime host (deployability fixture; see its README)
│   └── sql/grants.sql   canonical least-privilege grants (shipped in the image)
├── scripts/         migrate · health-check · backup-verify · smoke-test
├── policies/        CI guardrails + accepted limitations
└── .github/         workflows (validate · deploy) + deploy-env composite action
```

## Workflows

- **Local**: run the reference runtime against the aion-data compose Postgres —
  see [runtime/README.md](runtime/README.md).
- **Staging**: merge to `main` → CI builds an immutable image → runs the
  migration job → rolls the service → smoke-tests. [docs/deployment.md](docs/deployment.md).
- **Production**: manual dispatch → **required-reviewer approval** (the human
  gate) → same steps with production identity, from `main` only.

## Security, backups, status

- Security controls: [docs/security.md](docs/security.md),
  [docs/networking.md](docs/networking.md).
- Backups & recovery: [docs/backup-recovery.md](docs/backup-recovery.md).
- Operational procedures: [docs/runbook.md](docs/runbook.md).
- **Phase 3 scope, what was and was not built, limitations, costs, exit
  criteria, and the Phase 4 recommendation:** [docs/phase-3.md](docs/phase-3.md).

> **Status:** Phase 3 infrastructure is **defined declaratively and verified by
> static validation + a full local acceptance run** (migrations, app-role
> connect, health, smoke, DB-failure readiness, migration-failure fail-closed,
> role separation). **Live cloud provisioning of staging/production requires GCP
> credentials and is a remaining operational step** — see
> [docs/phase-3.md](docs/phase-3.md).
