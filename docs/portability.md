# Portability

**AION is cloud-portable, not cloud-abstracted.**

We do **not** build a fake universal cloud API. We preserve a portable *workload*
and let each provider use its native infrastructure correctly. Portability lives
at one boundary — the [deployment contract](../contracts/deployment-contract.md) —
not inside the application.

```
        AION Core  +  AION Data  +  AION Runtime artifact
                          │
                          │  one contract · one image · one set of migrations
                          ▼
             ┌────────────────────────────────┐
             │   Provider-neutral deployment   │
             │            contract             │
             └────────────────────────────────┘
              │              │               │
              ▼              ▼               ▼
         VPS profile    AWS profile     GCP profile
        (Compose+Caddy) (ECS/RDS/…)    (Cloud Run/SQL)
```

## What is portable (never changes between providers)

- **`aion-core`** — imports no provider package.
- **`aion-data`** — imports no provider package; owns the schema and the
  migration runner used everywhere.
- **The runtime image** — one image built by [aion-runtime](https://github.com/Ceoloo/aion-runtime) (ADR-002); env-var config; stdout JSON
  logs; `/health/live` + `/health/ready`; graceful shutdown; no cloud SDK.
- **The database contract** — PostgreSQL 16, reached by URL, two roles, same
  aion-data migrations.
- **The configuration surface** — `DATABASE_URL`, `AION_ENVIRONMENT`,
  `LOG_LEVEL`, `SERVICE_VERSION`, `GIT_SHA` (+ `MIGRATION_DATABASE_URL` for
  migrations).
- **The deployment sequence** — build → migrate (fail-closed) → deploy →
  readiness → smoke, with a production human gate.

## What is provider-specific (allowed to differ)

Infrastructure provisioning, networking, secret storage, runtime hosting,
logging *destination*, database provisioning, and CI/CD mechanics — all confined
to [`providers/`](../providers/).

## Provider capability matrix

| Capability | VPS | AWS | GCP |
|---|---|---|---|
| Runtime hosting | Docker Compose (Node container) | ECS Fargate (or App Runner) | Cloud Run |
| Container image | aion-runtime image (GHCR) | same image (ECR mirror optional) | same image (AR mirror optional) |
| PostgreSQL 16 | local container **or** managed URL | RDS | Cloud SQL |
| Secrets | root-owned `0600` env file | Secrets Manager | Secret Manager |
| Secret → app | env injection | env injection | env injection |
| Logs | stdout → Docker/journald/collector | stdout → CloudWatch | stdout → Cloud Logging |
| TLS / ingress | Caddy (auto certs) | ALB / App Runner | Cloud Run (managed) |
| Backups | off-host `pg_dump` (encrypted) | RDS automated + PITR | Cloud SQL + PITR |
| CI auth | SSH deploy key (GH Env) | GitHub OIDC → IAM role | Workload Identity Federation |
| Human prod gate | GitHub Environment | GitHub Environment | GitHub Environment |

The **health endpoints, log format, config vars, image, and migrations columns
are identical across all three** — that is the portability guarantee. Only the
infrastructure rows differ.

## Deployment maturity (honest status)

| Profile | Status |
|---|---|
| **Generic VPS** (Hostinger/DO/Hetzner/EC2/Ubuntu) | **ACTIVE / LOW-COST DEPLOYMENT PROFILE** — working reference: Compose + Caddy + runtime + optional local Postgres; deploy/backup/restore scripts; runtime + migrations proven locally. Live SSH-deploy to a real VPS is untested here. |
| **AWS** | **SUPPORTED ARCHITECTURE / SCALE-UP TARGET** — full provider mapping + minimal, `validate`-passing Terraform skeleton (ECS Fargate, RDS, Secrets Manager, ECR, CloudWatch, OIDC). Not provisioned; full productionization is a provider-activation mission. |
| **GCP** | **SUPPORTED MANAGED DEPLOYMENT PROFILE** — complete declarative Terraform, statically validated; the original Phase 3 implementation, now behind the provider boundary. Not live (needs GCP credentials). |

Parity is claimed only where it exists: the **workload** is at parity across all
three (same image, migrations, contract); the **infrastructure profiles** are at
different maturities as above.

## Recommended operating path

```
Early production:  Generic VPS (Hostinger-compatible)   ← cheapest, simplest
        │
        ▼  growth / operational demand
Scale-up:          AWS managed (ECS Fargate + RDS)
        │
        ▼  (alternative managed target, available now)
                   GCP (Cloud Run + Cloud SQL)
```

The point is not a migration date. The point is that moving is a **deployment
change** — a new provider profile consuming the same image, contract, and
migrations — **not an application rewrite**.

## Why not a provider-abstraction framework

We deliberately do **not** introduce application interfaces like
`CloudProvider.createDatabase()/deployContainer()`. Terraform and the provider
profiles already represent infrastructure differences; adding a runtime
abstraction would couple the application to an invented API and defeat the goal.
Portability belongs at the contract boundary, nowhere else (deployment-contract
§7; architecture-debt item 10).

## Limitations

- VPS local Postgres carries higher operational risk than managed Postgres
  (single host, self-managed backups) — see debt item 11; Mode B (managed URL)
  mitigates it with only a config change.
- VPS env-file secrets are weaker than a managed secret store — treat the host
  accordingly (debt item 12; `providers/vps/README.md` → Hardening).
- AWS and GCP profiles are not live-provisioned in this build.
