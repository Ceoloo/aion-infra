# AION Deployment Contract

**The stable, provider-neutral contract between the AION workload and the
infrastructure that runs it.** Any environment that satisfies this contract can
run AION — a generic Linux VPS, AWS, GCP, or another compatible target — without
changing `aion-core`, `aion-data`, the runtime image, or product code.

> **Critical invariant (portability)**
>
> The same AION runtime artifact must be deployable to a generic Linux VPS or a
> managed cloud environment **without changing AION Core, AION Data, or
> product-domain code.** Provider-specific changes are limited to: infrastructure
> provisioning, networking, secret injection, runtime hosting, logging
> destinations, database provisioning, and CI/CD deployment mechanics.

This document is authoritative for aion-infra. Provider profiles under
[`providers/`](../providers/) are *implementations* of it; they may differ only
in the infrastructure column, never in the workload behavior column.

AION is **cloud-portable, not cloud-abstracted** — see
[`docs/portability.md`](../docs/portability.md). There is no universal cloud API;
there is one portable workload and several native infrastructures.

---

## 1. Runtime

| Requirement | Contract |
|---|---|
| Execution | A Linux-compatible Node.js process, shipped as one immutable OCI container image (`runtime/Dockerfile`). |
| Configuration | **Environment variables only.** No provider SDK, no config baked into the image. |
| Ingress | HTTPS — terminated by the platform (managed) or a reverse proxy (VPS). The app serves plain HTTP on `$PORT`. |
| Liveness | `GET /health/live` → `200` while the process is healthy; performs no dependency work. |
| Readiness | `GET /health/ready` → `200` only when it can serve (database reachable); `503` otherwise. |
| Release identity | `GET /` returns `{ git_sha, service_version, build_time, environment }`. |
| Logs | Structured JSON, one object per line, to **stdout/stderr**. No provider logging SDK. |
| Shutdown | Drains and exits `0` on `SIGTERM`. |

The runtime **must not** import a cloud SDK (GCP/AWS/Hostinger) to perform its
ordinary function. Verified by `scripts/portability-check.sh`.

## 2. Database

| Requirement | Contract |
|---|---|
| Engine | **PostgreSQL 16-compatible.** No provider-specific SQL, extensions, or APIs. |
| Location | Anywhere reachable via a URL — local on a VPS, or managed (Cloud SQL / RDS / other). The app must not assume host, socket, or vendor. |
| Persistence | Durable storage that survives restarts. |
| TLS | Required when connected remotely (`sslmode=require` or stronger). |
| Roles | Two separated roles: an **application** role (DML; no DDL; append-only `events`/`telemetry_records`) and a **migration** role (DDL). |
| Migrations | Applied by **aion-data's own migration runner**, the same files on every provider. Provider infra provisions the database; it never forks the schema. |
| Backup / restore | Every production target provides scheduled backups, an off-host copy, and a documented, test-ready restore. |

## 3. Configuration surface (environment variables)

The **runtime** receives:

| Var | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | ✅ | Application-role PostgreSQL URL. |
| `AION_ENVIRONMENT` | ✅ | `local` \| `staging` \| `production`. |
| `LOG_LEVEL` | | `debug` \| `info` \| `warn` \| `error`. |
| `SERVICE_VERSION` | | Release version string. |
| `GIT_SHA` | | Running commit. |
| `PORT` | | HTTP port (default 8080). |
| `DATABASE_SSL` | | Require TLS to the DB (default true off-local). |

The **migration execution** additionally receives:

| Var | Required | Meaning |
|---|---|---|
| `MIGRATION_DATABASE_URL` | ✅ | Migration-role PostgreSQL URL. **Never given to the long-running runtime.** |

No other configuration is required to run. Secrets are always injected as
environment values and never committed to source (`.env.example` placeholders
only); how they are stored is provider-specific (§Secrets below).

## 4. Secrets

Secret **values reach the workload through the environment**. Each provider
translates its native secret mechanism into env injection:

| Provider | Mechanism |
|---|---|
| VPS | root-owned `0600` env file, injected by Docker Compose / systemd |
| AWS | Secrets Manager → task/service env |
| GCP | Secret Manager → Cloud Run env |

The application never fetches secrets from a cloud SDK (unless a future ADR
justifies it). Runtime gets only `DATABASE_URL` (+ non-secret config); migration
gets `MIGRATION_DATABASE_URL`.

## 5. Deployment sequence (every target)

```
build immutable artifact (image tagged by git SHA)
   → apply aion-data migrations (migration role; FAIL-CLOSED — stop on error)
   → deploy runtime (new image)
   → readiness check (/health/ready)
   → smoke test (reachable, healthy, correct release SHA)
```

Production deployment on every target preserves a **human gate** (GitHub
Environment required reviewers, or equivalent). A failed migration halts the
deploy before the runtime is updated; the previous version keeps serving.

## 6. Recovery (every production target)

Each production target documents:

- **runtime rollback** — redeploy a previous immutable image (no DB change);
- **database backup** — scheduled, off-host, encrypted;
- **database restore** — into an isolated target first, validated, then cut over;
- **secret rotation** — replace the secret value + roll the runtime.

Because aion-data migrations are forward-only, the default recovery posture is
*restore previous runtime + forward-fix schema*, not database rollback.

## 7. What is explicitly NOT in the contract

- No cloud provider name, SDK, or API.
- No provider-specific health, logging, or secret semantics in application code.
- No universal "CloudProvider" abstraction layer (that would be the wrong kind of
  portability — see [`docs/portability.md`](../docs/portability.md)).

Conformance is checked by `scripts/portability-check.sh` and the per-profile
READMEs under [`providers/`](../providers/).
