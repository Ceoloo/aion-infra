# AWS profile — architecture & activation notes

This is the reference AWS design for AION. It exists to prove architectural
compatibility and define the migration path, not to be a complete production
platform yet (aion-infra amendment §16–18).

## Topology

```
                       ┌─────────────── VPC (10.20.0.0/16) ───────────────┐
   Internet ─▶ ALB ────┤ public subnets (2 AZ)                            │
   (ACM 443)   │        │   └─ Fargate tasks (aion-runtime) ── egress ─▶ IGW
               │        │        │ 8080 (from ALB SG only)                │
               │        │        ▼ 5432 (task SG only)                    │
               │        │ private subnets (2 AZ)                          │
               │        │   └─ RDS PostgreSQL 16 (not public)             │
               └────────┴──────────────────────────────────────────────-─┘
   Secrets Manager ─▶ task env    CloudWatch ◀─ stdout    ECR ◀─ image
```

Tasks run in public subnets with `assign_public_ip = true` for egress (ECR,
Secrets Manager) with **no NAT gateway**, to keep the reference cheap. RDS is
private and reachable only from the task security group.

## Same-artifact / same-migrations proof

- The ECS task definition runs `var.image` — the **same** aion-runtime image
  (`ghcr.io/ceoloo/aion-runtime`) that VPS and GCP deploy. No AWS-specific image;
  aion-infra builds none (ADR-002).
- The **migrate** task overrides the command to `node dist/migrate.js`, which
  runs **aion-data's** migration runner + the aion-runtime image's `grants.sql` — the same
  migrations as every provider.
- The runtime reads `DATABASE_URL` from Secrets Manager as an env value; it
  imports no AWS SDK. Portability is preserved at the contract boundary.

## Activation checklist (provider-activation mission)

The minimal Terraform here is `validate`-clean. To go live:

1. **Remote state** — create an S3 state bucket (+ native lockfile/DynamoDB),
   one prefix per environment; supply via `-backend-config`.
2. **TLS** — request an ACM certificate for the domain and pass
   `certificate_arn`; the HTTPS listener activates (the HTTP:80 listener is a
   `validate`/dev placeholder). Add a Route 53 (or external DNS) record to the
   ALB.
3. **Environments** — apply twice with distinct `name_prefix`/`environment`
   (`aion-staging`, `aion-prod`); set `multi_az = true`,
   `deletion_protection = true`, longer `backup_retention_days` for production.
4. **CI** — grant the `ci_deploy` role the deploy permissions (ECR push, ECS
   update-service, ecs run-task, iam:PassRole for the task/execution roles) and
   wire a `deploy-aws.yml` mirroring `deploy-gcp.yml`/`deploy-vps.yml`, with the
   production GitHub Environment human gate.
5. **DB roles** — RDS master is `aion_migrator` (the DDL role); the migrate
   step creates/【grants】 the least-privileged `aion_app` role via
   the aion-runtime image's `grants.sql` (extend it to `CREATE ROLE aion_app` on first run,
   as the VPS `init-roles.sh` does, or run a one-time bootstrap SQL).
6. **Backups/restore** — RDS automated backups + PITR are enabled by
   `backup_retention_days`; document a snapshot-restore-into-isolated-instance
   drill mirroring the GCP `backup-verify.sh` and VPS `restore.sh`.

## Deliberately excluded (§18)

EKS, MSK/Kafka, ElastiCache/Redis, OpenSearch, multi-region, App Mesh, and
autoscaling beyond ECS managed defaults. Add any of these only under a mission
that justifies it.

## Cost drivers (rough, needs live confirmation)

ALB (~$16/mo baseline) + Fargate task(s) (~$10–30/mo for small) + RDS
(db.t4g.micro ~$15/mo; Multi-AZ ~2×) + Secrets Manager (~$0.40/secret) +
CloudWatch + data transfer. A minimal staging footprint is on the order of
~$45–70/mo; production with Multi-AZ RDS is higher. Confirm against live
pricing before relying on these.
