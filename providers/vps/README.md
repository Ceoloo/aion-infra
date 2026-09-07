# VPS deployment profile

**A minimal, low-cost deployment of AION on a generic Ubuntu/Linux VPS**
(Hostinger, DigitalOcean, Hetzner, an EC2 VM, or any Ubuntu server). It uses no
Hostinger-specific APIs. It satisfies the same
[deployment contract](../../contracts/deployment-contract.md) as AWS and GCP,
running the **same runtime image** and the **same aion-data migrations**.

## OPS-001 topology (canonical)

```
DNS ──▶ runtime.<domain>          e.g. runtime.aionsystems.ai
          │
          ▼
       Traefik :443               (host edge — already on this VPS)
          │
          ▼
    aion-runtime :8080            (Docker; NOT published on the host)
          │
          ▼
       PostgreSQL                 (Mode A local or Mode B managed — never public)
```

Prefer a **stable, provider-independent hostname** (`runtime.aionsystems.ai`) over
a Hostinger machine FQDN so the Operator Console keeps one logical endpoint if
the Runtime later moves.

**Do not run Caddy next to Traefik.** One edge layer only. Legacy Caddy remains
available as compose profile `caddy` for greenfield hosts without Traefik.

### Two host-Traefik topologies

| Host Traefik runs… | `AION_TRAEFIK_NETWORK_EXTERNAL` | `AION_TRAEFIK_NETWORK` | Who owns the network |
|---|---|---|---|
| on its own Docker network (DO/Hetzner-style) | `true` | that existing network's name | the host Traefik; deploy only attaches, and fails if absent |
| `network_mode: host` (the Hostinger box) | `false` | `aion_edge` (any name) | **AION** — `scripts/deploy.sh` creates the bridge if missing; a host-network Traefik still routes to the container's IP on it |

The Runtime never publishes `:8080`. Traefik reaches it over this network by the
`traefik.docker.network` label; nothing else on the host can.

Then:

```
Vercel Operator Console
  └─ VITE_AION_RUNTIME_URL=https://runtime.aionsystems.ai
```

`VITE_AION_TENANT_ID` / `VITE_AION_OPERATOR_ID` are **frontend hints only**.
Tenant isolation and actor authorization are enforced by the Execution Gateway
(`x-aion-tenant-id` + Core policy) — never by Vite env vars.

## Layout

```
providers/vps/
├── README.md
├── docker-compose.yml     aion-runtime (+ Traefik labels) + optional postgres
├── .env.example           secrets contract (copy to root-owned 0600 /opt/aion/.env)
├── traefik/
│   └── aion-runtime.yml.example   optional file-provider snippet
├── legacy/
│   └── Caddyfile          only with AION_EDGE=caddy (no Traefik on host)
├── system/
│   └── init-roles.sh
└── scripts/
    ├── bootstrap-server.sh
    ├── deploy.sh            pull → migrate → roll → readiness → smoke
    ├── backup.sh
    └── restore.sh
```

## Database modes (same application, config-only difference)

**Mode A — local PostgreSQL** (cheapest, simplest):

```bash
AION_LOCAL_DB=1 ./scripts/deploy.sh
```

**Mode B — managed PostgreSQL** (lower operational risk):

```bash
./scripts/deploy.sh
```

## Secrets

- root-owned, `0600` `/opt/aion/.env` (from `.env.example`, never committed);
- separate `DATABASE_URL` (app) vs `MIGRATION_DATABASE_URL` (migrate one-shot only);
- immutable, **digest-pinned** `AION_IMAGE=ghcr.io/ceoloo/aion-runtime@sha256:<digest>`
  (deploy-vps.yml resolves the release tag to a digest and writes it);
- `AION_CORS_ORIGINS` = approved Vercel Console origins (comma-separated).

## Deploy (OPS-001 checklist)

1. Provision `/opt/aion/.env` with production values (`AION_ENVIRONMENT=production`,
   DB URLs, `AION_IMAGE=ghcr.io/ceoloo/aion-runtime@sha256:<digest>` — a
   digest-pinned, boot-certified release image, never a tag, `:latest`, or
   `main`; `deploy-vps.yml` fills this in. `AION_DOMAIN=runtime.aionsystems.ai`,
   Traefik entrypoint / cert resolver matching the host).
2. Set the Traefik network vars for your topology (see the table above):
   `AION_TRAEFIK_NETWORK_EXTERNAL` + `AION_TRAEFIK_NETWORK`. For a
   `network_mode: host` Traefik, `deploy.sh` creates the bridge — no manual
   `docker network create` needed.
3. Runtime stays on the internal + edge networks — **do not** publish `:8080`.
4. Point DNS `A`/`AAAA` for `runtime.aionsystems.ai` at the VPS.
5. `cd /opt/aion && ./scripts/deploy.sh` (or GitHub `deploy-vps.yml`).
6. Verify:
   - `https://runtime…/health/live`
   - `https://runtime…/health/ready`
   - `https://runtime…/` (release metadata)
   - one tenant-scoped `/v1/...` path (expects `x-aion-tenant-id`)
7. Configure GitHub Environment secrets: `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`.
8. **Only then** create the Vercel `aion-operator-console` project with
   `VITE_AION_RUNTIME_URL=https://runtime.aionsystems.ai` and set
   `AION_CORS_ORIGINS` on Runtime to that Vercel origin.

CI drives deploys over SSH — see
[`.github/workflows/deploy-vps.yml`](../../.github/workflows/deploy-vps.yml).

## Backups (Mode A)

`scripts/backup.sh` / `scripts/restore.sh` — encrypted off-host dump; restore
into an isolated target. Mode B uses the managed provider's PITR.

## Hardening

`scripts/bootstrap-server.sh` — Docker, ufw 22/80/443, `/opt/aion`, deploy user.
It does **not** install Traefik; on Hostinger the edge is already present.
Wire the Runtime to it via `AION_TRAEFIK_NETWORK` / `AION_TRAEFIK_NETWORK_EXTERNAL`
(see the topology table above).

## Deploy safety

- **Digest-pinned identity (no verify→deploy TOCTOU):** `deploy-vps.yml` (blank
  `runtime_image`) resolves the newest `execution-platform-vX.Y.Z` tag,
  dereferences the annotated Git tag to its commit SHA, `GET`s the GHCR manifest,
  captures the authoritative `Docker-Content-Digest`, and deploys
  `ghcr.io/ceoloo/aion-runtime@sha256:<digest>` — the verified artifact *is* the
  pull reference. `runtime_image` pins are canonicalised the same way (any tag →
  its digest); a non-`execution-platform-vX.Y.Z` pin also needs the `git_sha`
  input. It never deploys a mutable tag, `:latest`, or `aion-runtime`'s `main`.
- **Fail-closed migrations:** a failed migration aborts before the runtime is
  rolled; the previous container keeps serving.
- **Automatic rollback:** if the new container fails readiness or the smoke
  test, `deploy.sh` restores the previously-serving image (and rewrites
  `.env`), then exits non-zero.
- **Keep the previous image:** any `docker image prune -a` / `--filter until=…`
  job on the host must exclude `ghcr.io/ceoloo/aion-runtime`, or a rollback has
  nothing to roll back to.

## Status

**ACTIVE / LOW-COST DEPLOYMENT PROFILE — Traefik edge (OPS-001).** Runtime image,
migrations, health endpoints, and config surface are identical to AWS/GCP.
Live VPS activation is the OPS-001 operational milestone (see aion-docs
`roadmap/ops-001-live-runtime.md`).
