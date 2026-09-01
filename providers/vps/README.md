# VPS deployment profile

**A minimal, low-cost deployment of AION on a generic Ubuntu/Linux VPS**
(Hostinger, DigitalOcean, Hetzner, an EC2 VM, or any Ubuntu server). It uses no
Hostinger-specific APIs. It satisfies the same
[deployment contract](../../contracts/deployment-contract.md) as AWS and GCP,
running the **same runtime image** and the **same aion-data migrations**.

```
Internet ──▶ Caddy (HTTPS, auto-certs) ──▶ aion-runtime ──▶ PostgreSQL
             only 80/443 exposed          (same image)      (never public)
```

One server is enough — no Kubernetes, Swarm, Consul, Nomad, RabbitMQ, or Redis.

## Layout

```
providers/vps/
├── README.md
├── docker-compose.yml     caddy + aion-runtime + optional postgres (profile local-db)
├── Caddyfile              HTTPS reverse proxy (automatic certificates)
├── .env.example           the VPS secrets contract (copy to a root-owned 0600 .env)
├── system/
│   └── init-roles.sh      first-boot creation of aion_app + aion_migrator (Mode A)
└── scripts/
    ├── bootstrap-server.sh  minimal server hardening (Docker, firewall, deploy user)
    ├── deploy.sh            pull → migrate (fail-closed) → roll → readiness → smoke
    ├── backup.sh            encrypted, off-host pg_dump to S3-compatible storage
    └── restore.sh           restore into an ISOLATED target + validate schema
```

## Database modes (same application, config-only difference)

**Mode A — local PostgreSQL** (cheapest, simplest): enable the `local-db`
profile; Postgres runs in a container on a persistent volume, bound to
`127.0.0.1` only. `init-roles.sh` creates the two roles at first boot; the deploy
step applies migrations + `grants.sql`.

```bash
AION_LOCAL_DB=1 ./scripts/deploy.sh     # brings up postgres, migrates, deploys
```

**Mode B — managed PostgreSQL** (lower operational risk): omit the `local-db`
profile; point `DATABASE_URL`/`MIGRATION_DATABASE_URL` at a managed PostgreSQL
(any provider) with `DATABASE_SSL=true`. **No application change** — only `.env`
differs.

```bash
./scripts/deploy.sh                      # runtime only; DB is remote
```

## Secrets (the VPS implementation of the secrets contract)

There is no managed secret store on a bare VPS, and we don't pretend otherwise
(§12). The pragmatic secure model:

- a **root-owned, `0600`** env file at `/opt/aion/.env` (copied from
  `.env.example`, never committed);
- injected into the containers by Compose;
- **separate application and migration credentials** — and the long-running
  runtime is given an explicit env allowlist that **excludes**
  `MIGRATION_DATABASE_URL`, so it never holds the DDL credential.

This is weaker than a managed secret store (architecture-debt item 12); treat the
host accordingly (see Hardening) and prefer Mode B + a managed secret source as
you grow.

## Deploy

On the server (`/opt/aion`), with a `0600` `.env` in place:

```bash
./scripts/deploy.sh          # or AION_LOCAL_DB=1 ./scripts/deploy.sh for Mode A
```

The sequence is the contract sequence: **pull immutable image → apply migrations
(fail-closed) → roll runtime → readiness → smoke**. A failed migration aborts
before the runtime is rolled; the previous container keeps serving. CI drives
this over SSH — see [`.github/workflows/deploy-vps.yml`](../../.github/workflows/deploy-vps.yml).

## Backups (Mode A)

`scripts/backup.sh` takes an encrypted `pg_dump` and uploads it **off the VPS**
to a configurable S3-compatible endpoint (AWS S3, Backblaze B2, MinIO, …) — no
object-storage vendor is hardwired. Schedule it via cron or a systemd timer.
`scripts/restore.sh` proves recoverability by restoring into an **isolated**
target and validating the canonical schema — it never touches the live DB.
Mode B relies on the managed provider's backups/PITR instead.

## Hardening (minimal, pragmatic — §15)

`scripts/bootstrap-server.sh` automates the safe parts:

- non-root deploy user; Docker from the official apt repo (no `curl | sh`);
- `ufw` firewall exposing **only** 22/80/443 — the database port is never opened;
- unattended security updates enabled;
- app dir `/opt/aion` owned by the deploy user; `.env` `0600`.

It **recommends** (not auto-applies) SSH key-only auth and disabling root login —
review before changing SSH. Note: Docker group membership ≈ root, so only the
deploy user is added. This is deliberately not a full enterprise hardening suite.

## Status

**ACTIVE / LOW-COST DEPLOYMENT PROFILE.** The runtime image, migrations, health
endpoints, and config surface are identical to AWS/GCP. The runtime + migration
+ readiness + smoke flow is proven locally (see [`docs/phase-3.md`](../../docs/phase-3.md));
the Docker-Compose-on-a-real-VPS step is documented but not executed in this
build (no Docker daemon / no VPS available here).
