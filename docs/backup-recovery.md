# Backup & Recovery

Production database backups are mandatory and, on their own, insufficient —
recoverability must be *demonstrated*, not assumed (aion-infra §31–34, §65).

## What is configured

| Control | Setting (production) |
|---|---|
| Automated daily backups | enabled, `03:00` UTC |
| Retained backups | 30 (staging: 7) |
| Point-in-time recovery | enabled; WAL retained 7 days |
| Backup encryption | Google-managed at rest |
| Deletion protection | instance-level, on (blocks API delete + `terraform destroy`) |

PITR lets recovery target any moment within the retention window, not just the
nightly snapshot.

## Recovery objectives (§33 — operational objectives, not SLAs)

Conservative targets for an early production system:

| Objective | Target | Basis |
|---|---|---|
| **RPO** (max data loss) | ≤ 5 minutes | PITR replays WAL to near the failure point |
| **RTO** (time to restore) | ≤ 1 hour | clone-restore of a small instance + redeploy runtime |

These are objectives to operate against and improve, not contractual guarantees.

## Restore verification (§32, §65)

**The critical question: can AION actually restore its durable state?**
`providers/gcp/scripts/backup-verify.sh` answers it without ever restoring over production:

- `MODE=check` (default): lists backups, asserts the latest is recent (< ~26h).
- `MODE=restore`: clones the latest backup into a **new, isolated** instance,
  asserts the 7 canonical tables are present, then tears the target down. It
  never touches the live instance.

> **Honesty note:** live restore verification requires GCP credentials + quota
> and has **not** been executed in this build. The procedure is exact and
> test-ready; running it against a real staging backup is a remaining
> operational verification (see [phase-3.md](phase-3.md)). We do **not** claim a
> restore succeeded that was not performed.

What *has* been verified locally: the canonical schema and the migration runner
apply cleanly to a fresh PostgreSQL 16 and the two-role model holds — so a
restored instance plus a runtime redeploy is a coherent recovery path.

## Disaster recovery (§34 — proportional)

No active-active multi-region. Initial DR is:

1. managed automated backups + PITR;
2. infrastructure recreatable from Terraform (declarative, reproducible);
3. this documented, test-ready restore procedure;
4. redeployable immutable runtime artifacts (any prior SHA);
5. secret recovery: Secret Manager holds versioned secrets; Terraform re-creates
   the secret containers and CI re-injects values on rebuild.

That is sufficient for this phase.

## Rollback philosophy (§47)

aion-data migrations are **forward-only** — do not pretend every schema change is
reversible. Prefer:

```
restore previous runtime image (instant)  +  forward-fix schema (new migration)
```

Restore the database only for genuine data loss or corruption, into an isolated
target first, validated, before any cutover. Never restore production over
itself blind.
