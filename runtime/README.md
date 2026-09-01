# AION reference runtime host

> **A thin deployability fixture — not a product, and not the canonical home of
> the AION runtime.** It exists so Phase 3 can prove the infrastructure actually
> runs the real Phase 1/2 workload (aion-infra §6). It does no product work.

AION Core is a library/kernel and AION Data is a persistence package; neither is
a long-running service on its own. To prove the infrastructure is *deployable*,
Phase 3 needs a minimal host that boots the real stack and exposes health. This
is that host — the smallest thing that:

1. validates its configuration and **fails fast** if it is missing/malformed;
2. initializes **AION Core** over **AION Data**'s durable Postgres adapters;
3. connects to PostgreSQL as the **least-privileged `aion_app` role**;
4. exposes **liveness** (`/health/live`) and **readiness** (`/health/ready`,
   which checks DB connectivity);
5. emits **structured JSON logs** carrying release metadata;
6. optionally runs **one controlled, non-destructive Core lifecycle** as a boot
   self-check (`RUN_SMOKE_ON_BOOT=true`);
7. **shuts down gracefully** on `SIGTERM`.

It imports `@aion/core` and `@aion/data` exactly as any consumer would, and
never forks their contracts (they are vendored at pinned commits, mirroring
`aion-data/scripts/setup-core.mjs`).

## Boundary note (important)

The AION dependency rules say `aion-infra` does not depend on `aion-core` /
`aion-data` **in code**. This reference host does import them — so it is
deliberately scoped as a **verification fixture**, isolated in `runtime/` with
its own `package.json`, and is **not** part of the Terraform-managed platform.
Its production home is now **decided** by
[`docs/adr/ADR-0001-runtime-host-ownership.md`](../docs/adr/ADR-0001-runtime-host-ownership.md):
a dedicated **`aion-runtime`** package/repo (depends on `@aion/core` +
`@aion/data` downward; consumed by aion-infra only as an image). Until that
package is created, this directory is the **interim fixture / seed** for it —
kept minimal and provider-neutral. Phase 3 establishes the secure place to run
and records where the runtime code will live (aion-infra §54).

## The deployment interface (contract)

Any image the Phase 3 pipeline deploys as "the AION runtime" MUST honor this
contract; the fixture is one conforming implementation.

| Aspect | Contract |
|---|---|
| Port | Listens on `$PORT` (default `8080`), HTTP. |
| Liveness | `GET /health/live` → `200` while the process is healthy; no dependency work. |
| Readiness | `GET /health/ready` → `200` only when it can serve (DB reachable); `503` otherwise. |
| Release info | `GET /` → JSON `{ git_sha, service_version, build_time, environment }`. |
| Config | Read from env only: `DATABASE_URL` (required), `AION_ENVIRONMENT`, `PORT`, `LOG_LEVEL`, `DATABASE_SSL`, release vars. Fail fast if required config is missing. |
| Credentials | Uses the **app** role only. Must never receive `MIGRATION_DATABASE_URL`. |
| Logs | Structured JSON to stdout/stderr, one object per line, no secrets. |
| Signals | Drains and exits `0` on `SIGTERM`. |
| Migrations | NOT run by the long-running host. The image also provides `node dist/migrate.js` for the migration **job** (uses `MIGRATION_DATABASE_URL`). |

## Environment variables

| Var | Required | Default | Meaning |
|---|---|---|---|
| `DATABASE_URL` | ✅ (runtime) | — | App-role connection string (from Secret Manager). |
| `MIGRATION_DATABASE_URL` | ✅ (migrate job) | — | Migrator-role connection string. Runtime must NOT have it. |
| `AION_ENVIRONMENT` | | `local` | `local` \| `staging` \| `production`. |
| `PORT` | | `8080` | HTTP port. |
| `LOG_LEVEL` | | `info` | `debug` \| `info` \| `warn` \| `error`. |
| `DATABASE_SSL` | | `true` off-local | Require TLS to the DB. |
| `RUN_SMOKE_ON_BOOT` | | `false` | Run the Core lifecycle self-check at startup. |
| `SERVICE_VERSION`, `GIT_SHA`, `BUILD_TIME` | | `unknown` | Release metadata (surfaced via `/health` + logs). |

## Build & run

```bash
npm run setup:deps   # vendor + build pinned @aion/core and @aion/data
npm install
npm run build
# migrate job entrypoint (migrator credential):
MIGRATION_DATABASE_URL=... node dist/migrate.js
# long-running host (app credential):
DATABASE_URL=... AION_ENVIRONMENT=staging node dist/index.js
```

Container: `docker build -t aion-runtime:<sha> .` (multi-stage, non-root, no dev
deps, no secrets baked in). The same image runs both the service and the
migration job (the job overrides the command).
