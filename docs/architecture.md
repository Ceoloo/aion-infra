# Architecture

AION Infra is the ground the AION platform runs on. It supports the existing
Core + Data workload; it does not decide what that workload does
(aion-docs/repositories/aion-infra.md).

## The deployed spine

```
GitHub (source of truth)
   │  PR validation · human-gated release
   ▼
CI/CD (GitHub Actions + Workload Identity Federation, keyless)
   │  build immutable image (tagged by SHA) → migrate job → roll service
   ▼
AION RUNTIME (Cloud Run service)      ── reference host: boots Core over Data
   │  least-privileged app role · TLS · Direct VPC egress
   ▼
AION DATA (durable adapters)          ── @aion/data implements Core's ports
   │
   ▼
MANAGED POSTGRES (Cloud SQL 16)       ── private IP · encrypted · backups · PITR

supporting planes:
  Secret Manager   — DATABASE_URL / MIGRATION_DATABASE_URL, least-privilege access
  Cloud Logging    — structured JSON app logs + infra logs, bounded retention
  Cloud Monitoring — basic alerts (runtime down, DB down, backup failed)
  GCS              — Terraform remote state, separated per environment
```

## Component map (Terraform modules)

| Module | Provisions | Key guarantees |
|---|---|---|
| `networking` | VPC, subnet, Private Services Access, deny-all ingress | DB never on the public internet; runtime→DB over a private path |
| `database` | Cloud SQL 16 instance, app DB, `aion_app`/`aion_migrator` roles | private IP, encrypted, backups+PITR, deletion protection, two-role model |
| `secrets` | Secret Manager secrets + IAM | runtime reads only `DATABASE_URL`; migrator reads only `MIGRATION_DATABASE_URL`; no plaintext outputs |
| `runtime` | Cloud Run service + migration job + Artifact Registry | least-privileged SAs, secret env, health probes, release metadata, immutable images |
| `observability` | log retention + alert policies + channel | provider-native, minimal, bounded retention |

Environments (`bootstrap`, `staging`, `production`) compose these modules with
per-environment values and **separate remote state**.

## How the workload maps on

AION Core is a kernel and AION Data a persistence package — neither is a
long-running service. The **reference runtime host** (`runtime/`) is the thin
process that makes them deployable: it builds a real `Orchestrator` (Core) wired
to `createDataLayer` (Data) over Cloud SQL, exactly as aion-data's own
integration harness does. The infrastructure's job is to run *that* safely:

- inject the app-role `DATABASE_URL` from Secret Manager;
- reach the private database over Direct VPC egress with TLS;
- expose `/health/ready` (fails when the DB is unreachable) so traffic is
  withheld until the workload can serve;
- surface the running commit via `/health` and structured logs.

Migrations are applied by a **separate** Cloud Run job using the migrator
identity and AION Data's own runner — the runtime never carries DDL rights.

## Boundaries honored

- **Infra supports, does not dictate** (aion-docs/repositories/aion-infra.md):
  no business logic or orchestration decisions live here.
- **Canonical data stays in aion-data**: this repo forks no schema; the DB
  module provisions the instance and roles, and AION Data's migrations remain
  authoritative for shape.
- **The reference host is a fixture, not owned platform code** — see
  [runtime/README.md](../runtime/README.md) and the boundary note in
  [phase-3.md](phase-3.md).

## Environment boundaries

Staging and production are **separate GCP projects** with separate networks,
databases, secrets, identities, and Terraform state. No lower environment can
reach a higher one's data or secrets (aion-docs/architecture/environments.md).
Promotion to production is a governed, human-gated pipeline step, not a copy.
