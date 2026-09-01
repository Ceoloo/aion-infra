# Security

AION Infra implements AION's posture of **least privilege everywhere** and
**no ambient authority** (aion-docs/architecture/security-model.md). Every
identity gets only what a specific unit of work requires; every secret lives in
a managed store; no secret is ever committed.

## Identities (least privilege, separated)

| Identity | Who/what | May | May NOT |
|---|---|---|---|
| **Runtime SA** (`aion-<env>-runtime`) | the Cloud Run service | write logs/metrics; read its `DATABASE_URL` secret; connect as `aion_app` | run migrations, read the migrator secret, touch other cloud resources |
| **Migration SA** (`aion-<env>-migrator`) | the migration job | write logs; read `MIGRATION_DATABASE_URL`; connect as `aion_migrator` | serve traffic; long-running compute |
| **CI/deploy SA** (`aion-ci-<env>`) | GitHub Actions via OIDC | apply Terraform, push images, roll the service, execute the migrate job | be a permanent key; assume the *other* environment (staging vs prod separated) |
| **Human admin** | operators | break-glass DB access, approvals | routine production DB login (see §"Human DB access") |

No shared "god" credential. The runtime never has infra-admin rights, migration
credentials, or arbitrary cloud control (aion-infra §16, §49).

## Database roles (the Phase 2 two-role model)

Provisioned by the `database` module; privileges shaped by
`grants.sql` (shipped in the [aion-runtime](https://github.com/Ceoloo/aion-runtime) image):

| Role | Privilege | Used via |
|---|---|---|
| `aion_app` | `SELECT/INSERT/UPDATE` on canonical tables; **no DDL**; **no UPDATE/DELETE** on `events`/`telemetry_records` (append-only) | `DATABASE_URL` (runtime) |
| `aion_migrator` | DDL (create/alter), owns schema, migration ledger | `MIGRATION_DATABASE_URL` (migrate job only) |

The runtime never connects as owner/superuser (aion-infra §12). Append-only
enforcement at the grant level complements aion-data's application-level
append-only adapters. This separation is verified — see
[phase-3.md](phase-3.md) → "Verification".

## Secrets

- **Managed store**: Google Secret Manager, one set per environment
  (`aion-<env>-database-url`, `aion-<env>-migration-database-url`).
- **No secrets in Git**: `.env`/`*.tfvars`/`backend.hcl` are git-ignored; only
  `*.example` placeholders are committed. `gitleaks` runs in CI (§NO_PUBLIC_SECRET).
- **No secrets in Terraform state output**: secret values are `sensitive`
  variables and are never `output` (aion-infra §14). Passwords enter via
  `TF_VAR_*` from CI secret material.
- **Runtime receives only what it needs**: the runtime SA can read only its
  `DATABASE_URL`; the migrator SA only `MIGRATION_DATABASE_URL` (secrets module
  IAM bindings).

### Rotation (aion-infra §15)

Deliberate rotation without rebuilding the platform:

1. Generate a new password; set `TF_VAR_app_password` (or migrator).
2. `terraform apply` — updates the Cloud SQL user password and writes a **new
   Secret Manager version** of the connection string.
3. Roll the service (redeploy) so it picks up `version = latest`.
4. The migrator credential rotates the same way, independently.

Automatic scheduled rotation is not required in Phase 3; the architecture
supports deliberate rotation, which is what the current operating model needs.

## Production secrets in CI (§50)

GitHub Actions authenticate to GCP via **Workload Identity Federation** —
short-lived OIDC tokens, **no stored cloud keys**. The OIDC provider is bound to
this repository, and the production CI identity is bound to `main` only
(bootstrap module). Database passwords are the only static secrets, stored as
GitHub Environment secrets and injected as `TF_VAR_*`; the rationale (Cloud SQL
password auth) is documented here rather than hidden.

## Network & TLS

- Database on **private IP only**; no public exposure (aion-infra §13).
- External runtime endpoint is HTTPS with Google-managed TLS (§36).
- DB connections require TLS (`ssl_mode = ENCRYPTED_ONLY`; runtime uses
  `sslmode=require`). See [networking.md](networking.md).

## Human access to the database (§38)

Production DB access is exceptional. Normal operation never requires logging into
production Postgres. When investigation demands it:

- use an authenticated admin identity (no shared credential);
- prefer read-only;
- use Cloud SQL IAM / short-lived access where possible; actions are logged.

See [runbook.md](runbook.md) → "Human database access (break-glass)".

## Access control matrix (§37)

| Action | Who |
|---|---|
| Plan infrastructure | any contributor (PR); CI on staging |
| Apply staging | CI (staging SA) after merge |
| Apply production | CI (production SA) **after human approval** |
| Read production secrets | production runtime/migration SAs (scoped); admins break-glass |
| Run migrations | migration job (migrator identity) |
| Access database | app role (runtime); migrator (migrations); admin (break-glass) |
| Restore backup | admin, into an **isolated** target (never over prod) |
| Deploy runtime | CI, human-gated for production |
