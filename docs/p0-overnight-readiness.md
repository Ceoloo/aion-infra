# P0 overnight readiness (OPS-001 revenue path)

Non-destructive checklist for the production **revenue path** visibility:
Traefik → `aion-runtime:8080` → Postgres, with the Operator Console on Vercel
(`VITE_AION_RUNTIME_URL`) and an optional Revenue Copilot compose profile.

**This document does not authorize deploys.** Production rolls require human
reviewers. **Do not AI-auto-deploy production.**

## Quick verify (read-only)

```bash
# From aion-infra checkout (or any host with curl):
URL=https://runtime.aionsystems.ai \
  CHECK_SERVICES=1 \
  CORS_ORIGIN=https://aion-operator-console.vercel.app \
  scripts/verify-p0-runtime-readiness.sh

# Optional Copilot + host env presence (values never printed):
URL=https://runtime.aionsystems.ai \
  COPILOT_URL=https://copilot.aionsystems.ai \
  ENV_FILE=/opt/aion/.env \
  STRICT_ENV=1 \
  scripts/verify-p0-runtime-readiness.sh
```

The script:

1. `GET /health/live` and `GET /health/ready` (must be `200`)
2. `GET /` release JSON (`git_sha` / `service_version`)
3. Optionally `GET /v1/services` (JSON or auth challenge — proves the route)
4. Optionally CORS preflight for the Console origin
5. Documents required env **names** and can check **presence only** from
   `ENV_FILE` / process env — **never prints secret values**
6. Exits non-zero on probe failure (or missing keys when `STRICT_ENV=1`)

Related scripts: `scripts/health-check.sh` (live+ready only),
`scripts/smoke-test.sh` (post-deploy SHA check). Prefer
`verify-p0-runtime-readiness.sh` for overnight / P0 visibility.

## CORS origin checklist (Console + Copilot ↔ Runtime)

| Client | Public URL / origin | Runtime / edge setting |
|---|---|---|
| Operator Console (Vercel) | `https://<console>.vercel.app` (and custom domain if any) | Exact origin(s) in `AION_CORS_ORIGINS` |
| Revenue Copilot (browser, if any) | Copilot HTTPS origin | Add that origin to the same allowlist if the browser calls Runtime directly |
| Console build env | `VITE_AION_RUNTIME_URL=https://runtime…` | Must match the Traefik host (`AION_DOMAIN`) |

Rules:

- Origins are **exact** (scheme + host + port). No wildcards in the Traefik
  `accessControlAllowOriginList`.
- Empty `AION_CORS_ORIGINS` ⇒ **no** CORS headers ⇒ browser Console calls fail.
- After changing `AION_CORS_ORIGINS`, recreate the Runtime container so Traefik
  reloads the `aion-cors` middleware labels.
- Preflight proof:

```bash
curl -i -X OPTIONS "https://runtime…/v1/services" \
  -H "Origin: https://aion-operator-console.vercel.app" \
  -H "Access-Control-Request-Method: GET"
# Expect Allow-Origin echoing the Origin (and typically 204/200).
```

`VITE_AION_TENANT_ID` / `VITE_AION_OPERATOR_ID` are **hints only**. Authority is
enforced by the Execution Gateway (`x-aion-tenant-id` + Core policy).

## Secrets boundary (browser never gets provider keys)

| Secret / credential | Where it lives | Who receives it | Never |
|---|---|---|---|
| `DATABASE_URL` (`aion_app`) | `/opt/aion/.env` (0600) / Secret Manager | **Runtime** only | Browser, Copilot (unless a future ADR), git |
| `MIGRATION_DATABASE_URL` (`aion_migrator`) | same store | **Migrate one-shot only** | Long-running Runtime, browser, Vercel |
| `GHL_API_KEY` (+ location/version config) | same store | **Runtime** (CRM adapter / gateway) | Browser `VITE_*`, Revenue Copilot (writes blocked until gateway; keys stay off Copilot) |
| `OPENROUTER_API_KEY` (+ model config) | same store | **Revenue Copilot** profile only | Runtime allowlist, browser, git |
| `VITE_AION_RUNTIME_URL` | Vercel project env | Browser bundle (public) | Must not embed any `*_API_KEY` or DB URL |

Split allowlist is intentional least privilege (see
[design/external-credentials.md](design/external-credentials.md) and
`providers/vps/docker-compose.yml`):

- OpenRouter → Copilot
- GHL → Runtime
- Migrator URL → migrate job, never the long-running Runtime

## Migrate-before-roll (fail-closed)

Every production target follows the same sequence
([deployment-contract.md](../contracts/deployment-contract.md) §5):

```
resolve immutable image
  → apply aion-data migrations (migrator role; FAIL-CLOSED)
  → roll Runtime
  → /health/ready
  → smoke / P0 readiness
```

A failed migration **stops** the deploy; the previous Runtime keeps serving.
Do not roll a new image before migrations succeed.

## Do not AI-auto-deploy production

- Production deploys require **human reviewers** (GitHub Environment required
  reviewers on `production`, plus main-only ref). See [deployment.md](deployment.md).
- Cloud / overnight agents may **verify readiness**, update docs/scripts, and
  open PRs — they must **not** trigger `deploy-vps.yml` / `deploy-gcp.yml`
  production, SSH-roll production, or `terraform apply` production.
- Staging may follow existing CI policy; production remains deliberate.

## Compose profile: `revenue-copilot`

Enable only when an image and keys are ready:

```bash
# /opt/aion/.env: COPILOT_IMAGE, OPENROUTER_API_KEY, AION_RUNTIME_URL, …
cd /opt/aion
docker compose --profile revenue-copilot up -d
```

Copilot must point `AION_RUNTIME_URL` at the durable Runtime FQDN used for
`/v1/commands`. Prefer the stable hostname (`runtime.aionsystems.ai`) once DNS
resolves; until then the live Hostinger FQDN is acceptable.

## Operator checklist (no deploy)

- [ ] `URL=… scripts/verify-p0-runtime-readiness.sh` → PASS
- [ ] Console `VITE_AION_RUNTIME_URL` matches Runtime host
- [ ] `AION_CORS_ORIGINS` includes Console origin; preflight OK
- [ ] GHL keys present on **Runtime** host env (not in Vercel)
- [ ] OpenRouter key present only if Copilot profile is enabled (not on Runtime)
- [ ] `DATABASE_URL` is `aion_app`; migrator URL absent from Runtime container env
- [ ] No production workflow dispatched by an automated agent
