# Twenty CRM overlay (CRM-001)

Self-hosted [Twenty](https://github.com/twentyhq/twenty) as AION’s **primary CRM
system-of-engagement** (ADR-019). Profile-gated — **off by default**.

## Non-negotiable ops rules

1. **Production GHL stays as-is** until Twenty workflow, tenant isolation,
   governance (Runtime `crm.*`), and rollback proofs pass. Do **not** set
   `CRM_PROVIDER=twenty` on production Runtime until that gate is green.
2. **No new microservice** — this overlay only adds compose services under
   `providers/vps/twenty/`.
3. **Separate database** — `twenty_pgdata` must never be the `aion_data` volume.
4. **Runtime-mediated access** — agents/products never get Twenty DB URLs or API
   keys. Only `aion-runtime` may call Twenty on `aion_internal`
   (`http://twenty-server:3000`).
5. **Secrets** — `TWENTY_*` live in root-owned `0600` `/opt/aion/.env` only.

## Staging host prerequisite (Gate A)

Gate A must run on an **isolated non-production host**, not the production
Docker daemon that already serves live Runtime / PostgreSQL / Traefik.

1. Provision a separate staging VPS (or equivalent) with its own Docker daemon.
2. Use a staging-only `/opt/aion/.env` (mode `0600`) — never copy production
   secret values. Required Twenty names: `TWENTY_PG_PASSWORD`,
   `TWENTY_APP_SECRET` (plus staging Runtime `TWENTY_API_*` /
   `CRM_PROVIDER` / staging DB URL when you enable the adapter).
3. Prefer GitHub Environment `staging` for CI-injected names once that
   Environment has secrets; leave production Environment untouched.
4. Confirm `twenty_pgdata` is not shared with production `aion_data`.

Do **not** paste secret values into chat, tickets, or PRs. Do **not** set
`CRM_PROVIDER=twenty` on production until Gate D.

## Enable (dev / staging)

From `providers/vps/` **on the staging host**:

```bash
# 1. Add TWENTY_* placeholders from ../.env.example into staging /opt/aion/.env
# 2. Bring up Twenty without touching the production Runtime CRM path:
docker compose \
  -f docker-compose.yml \
  -f twenty/docker-compose.twenty.yml \
  --profile twenty \
  up -d

docker compose -f docker-compose.yml -f twenty/docker-compose.twenty.yml \
  --profile twenty ps
```

Runtime continues using **GHL** until you deliberately set (on a non-prod
Runtime first):

```bash
CRM_PROVIDER=twenty
TWENTY_BACKEND=fake          # proofs / local
# later, after live adapter lands:
# TWENTY_BACKEND=live
# TWENTY_API_BASE_URL=http://twenty-server:3000
# TWENTY_API_KEY=...
```

## Services

| Service | Network | Role |
|---|---|---|
| `twenty-db` | `aion_internal` (+ `127.0.0.1:5433`) | Postgres for Twenty only |
| `twenty-redis` | `aion_internal` | Queue / cache |
| `twenty-server` | `aion_internal` (+ optional Traefik) | API + UI |
| `twenty-worker` | `aion_internal` | Background jobs |

## Optional public UI

Default: `TWENTY_TRAEFIK_ENABLE=false` — UI not exposed. For a controlled UI
route, set `TWENTY_TRAEFIK_ENABLE=true` and `TWENTY_DOMAIN=…`, then prefer IP
allowlist / VPN at the edge. Runtime→CRM traffic must stay on Docker DNS, not
the public hostname.

## Rollback

```bash
# Stop Twenty overlay only — Runtime + GHL unchanged:
docker compose -f docker-compose.yml -f twenty/docker-compose.twenty.yml \
  --profile twenty stop

# Ensure Runtime still on GHL:
# CRM_PROVIDER unset or CRM_PROVIDER=ghl
# GHL_BACKEND=live
docker compose up -d --no-deps aion-runtime
```

## Related

- aion-docs ADR-019, CRM-001 mission, reuse audit
- Runtime `CRM_PROVIDER` / `CrmBackend` (aion-runtime)
- EspoCRM benchmark is a separate ephemeral harness (not this overlay)
