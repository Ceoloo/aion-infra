# AWS deployment profile

**The AION → AWS mapping, as a minimal reference profile.** It proves the AION
workload runs on AWS with **no application changes** — the same runtime image,
the same aion-data migrations, the same [deployment
contract](../../contracts/deployment-contract.md) — and defines the migration
path. It is intentionally **not** a full productionized platform (aion-infra
amendment §18); full activation is a provider-activation mission.

```
Internet → ALB (HTTPS/ACM) → ECS Fargate (aion-runtime, SAME image)
                                    │  private SG
                                    ▼
                             RDS PostgreSQL 16 (not public)
Secrets → Secrets Manager → task env     Logs → CloudWatch
CI → GitHub OIDC → IAM role              Backups → RDS automated + PITR
```

## Mapping (contract capability → AWS service)

| Contract capability | AWS implementation |
|---|---|
| Runtime hosting | **ECS Fargate** (immutable-container match; App Runner is an alternative) |
| Container image | **ECR** (immutable tags, scan on push) |
| PostgreSQL 16 | **RDS for PostgreSQL** (private, encrypted, Multi-AZ for prod) |
| Secret injection | **Secrets Manager** → task `secrets` env |
| Structured logs | stdout → **CloudWatch Logs** (awslogs driver) |
| Health/readiness | ALB target-group health check → `/health/ready` |
| Backups / PITR | RDS automated backups + point-in-time recovery |
| CI identity | GitHub Actions → **OIDC** → IAM deploy role (keyless) |
| Human prod gate | GitHub Environment required reviewers |

No EKS, MSK, ElastiCache, OpenSearch, multi-region, or extra autoscaling (§18).

## What is implemented vs documented

- **Implemented** (`terraform/`, `validate`-passing): VPC + subnets + SGs, RDS
  PostgreSQL 16 (private, encrypted, backups/PITR, deletion protection,
  Multi-AZ toggles), ECR, Secrets Manager (app + migration secrets with
  least-privilege read roles), CloudWatch log group, ECS cluster + **two** task
  definitions (runtime, migrate), ALB + target group + listeners, ECS service,
  GitHub OIDC provider + CI deploy role.
- **Documented, not built**: remote-state backend wiring, ACM certificate for
  443 (an HTTP:80 listener stands in for `validate`), a full deploy workflow,
  and live provisioning. See [architecture.md](architecture.md).

## Least privilege & separation (same guarantees as GCP)

- The **runtime** task gets a `DATABASE_URL` secret and an execution role that
  can read **only** that secret. It never receives `MIGRATION_DATABASE_URL`.
- The **migrate** task (run one-off via `aws ecs run-task`, command overridden
  to `node dist/migrate.js`) gets a separate execution role that can read
  **only** the migration secret.
- RDS is **not publicly accessible**; only the task security group can reach
  5432; only the ALB can reach the task on 8080.

## Deploy path (migration-before-deploy)

```
build image → push to ECR
  → aws ecs run-task <name>-migrate --wait   (fail-closed; halts on error)
  → aws ecs update-service --force-new-deployment   (rolls runtime)
  → ALB marks targets healthy via /health/ready
  → smoke test (scripts/smoke-test.sh against the ALB DNS/domain)
```

Production preserves the human gate via a GitHub Environment (same as VPS/GCP).

## Usage (when activated)

```bash
cd providers/aws/terraform
terraform init -backend-config=backend.hcl        # S3 state, per-env
TF_VAR_app_password=… TF_VAR_migrator_password=… \
  terraform apply -var name_prefix=aion-staging -var environment=staging
```

## Status

**SUPPORTED ARCHITECTURE / SCALE-UP TARGET.** Minimal Terraform validates; the
workload is at parity (same image, migrations, contract). Not provisioned — no
AWS credentials in this build.
