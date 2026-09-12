# Design Spec — External Credentials (OpenRouter, GoHighLevel)

- **Drives:** integrating an external model router (OpenRouter) and an external
  CRM (GoHighLevel) as governed AION execution environments
- **Priority:** per-mission (wire when a mission needs the model router or CRM)
- **Status:** Credential slots + Revenue Copilot HTTP consumer profile landed.
  Rotate keys into `/opt/aion/.env`; enable compose profile `revenue-copilot`
  when `COPILOT_IMAGE` is set. GHL writes still wait on Execution Gateway.

`aion-infra` owns **where secrets live and how they reach the workload**. This
spec defines the credential contract for two external services. It contains **no
secret values** — only the environment-variable names the workload reads.
Following the [security model](https://github.com/Ceoloo/aion-docs/blob/main/architecture/security-model.md):
**no secret is ever committed to any repository or document — ever.**

## The rule (restated because it is the whole point)

- Secrets live **only** in the aion-infra secret store (see
  [docs/security.md](../security.md)), injected as **environment variables** at
  runtime — exactly like `DATABASE_URL`
  ([deployment contract](../../contracts/deployment-contract.md) §Configuration:
  "Environment variables only. No provider SDK, no config baked into the image").
- Code reads `process.env.X`; code never contains the value.
- A leaked key is **rotated at the source**, not scrubbed from history. If a key
  is ever pasted into a chat, an issue, a log, or a commit, treat it as
  compromised and rotate it immediately.

## Credential contract

| Env var | Owner service | Purpose | Notes |
|---|---|---|---|
| `OPENROUTER_API_KEY` | OpenRouter | auth for the model-router provider | Bearer token (`sk-or-...`). Meters real credits — scope/limit it. |
| `OPENROUTER_MODEL` | OpenRouter | default model id (e.g. `anthropic/claude-3.5-sonnet`) | not a secret; config, may live in non-secret env. |
| `GHL_API_KEY` | GoHighLevel | auth for the CRM tool | Private Integration Token (`pit-...`). Bearer. |
| `GHL_LOCATION_ID` | GoHighLevel | which sub-account the tool acts on | not a secret; config. |
| `GHL_API_VERSION` | GoHighLevel | API version header (e.g. `2021-07-28`) | not a secret; config. |

Only `OPENROUTER_API_KEY` and `GHL_API_KEY` are **secrets** (secret store). The
rest are ordinary configuration and may be plain env in the profile.

## Injection per provider profile

Consistent with the existing provider-neutral posture — the secret **store**
differs by profile; the **env-var names the workload reads do not**:

| Profile | Secret store | Injection |
|---|---|---|
| **VPS** (active) | root-owned `0600` `/opt/aion/.env` on the host | Compose interpolation into the **consuming service's** explicit `environment:` allowlist |
| **GCP** | Secret Manager | Cloud Run secret-to-env mapping on the consuming service |
| **AWS** | Secrets Manager / SSM Parameter Store | ECS task-definition `secrets` → env |

The workload is identical across all three; switching profiles never changes how
code reads the credential (capability-over-vendor).

### VPS: which service gets the credential

On the VPS profile these secrets are declared in `providers/vps/.env.example`
(placeholders; the real values live only in the server's `/opt/aion/.env`).
Compose uses **per-service allowlists** (least privilege; Runtime still withholds
`MIGRATION_DATABASE_URL`):

| Credential | Injected into | Not injected into |
|---|---|---|
| `GHL_*` | `aion-runtime` (Phase A/B CRM via adapter + Execution Gateway) | Revenue Copilot (GHL writes blocked until gateway; keys stay off Copilot) |
| `OPENROUTER_*` | `revenue-copilot` profile only | `aion-runtime` |
| `DATABASE_URL` | `aion-runtime` | Copilot / browser |
| `MIGRATION_DATABASE_URL` | migrate one-shot only | long-running Runtime |

```yaml
# providers/vps/docker-compose.yml (authoritative wiring)
services:
  aion-runtime:
    environment:
      DATABASE_URL: ${DATABASE_URL:?set DATABASE_URL in .env}
      AION_CORS_ORIGINS: ${AION_CORS_ORIGINS:-}
      GHL_API_KEY: ${GHL_API_KEY:-}
      GHL_LOCATION_ID: ${GHL_LOCATION_ID:-}
      GHL_API_VERSION: ${GHL_API_VERSION:-2021-07-28}
      # OPENROUTER_* intentionally absent
  revenue-copilot:
    profiles: ["revenue-copilot"]
    environment:
      OPENROUTER_API_KEY: ${OPENROUTER_API_KEY:?set OPENROUTER_API_KEY in .env}
      OPENROUTER_MODEL: ${OPENROUTER_MODEL:-anthropic/claude-3.5-sonnet}
      AION_RUNTIME_URL: ${AION_RUNTIME_URL:-https://runtime…}
      # GHL_* reserved / commented — not injected today
```

Keys may sit in `/opt/aion/.env` unused until the consuming profile is enabled.
Rotation: edit `/opt/aion/.env`, then re-roll **only** the service that reads
that key (Runtime for GHL, Copilot for OpenRouter). Browser / Vercel `VITE_*`
must never receive provider keys — see
[p0-overnight-readiness.md](../p0-overnight-readiness.md).

## Least privilege

- **Scope each key to the minimum.** The OpenRouter key should carry a spend
  limit; the GHL token should be a Private Integration granted only the CRM
  scopes the tool actually uses (read/update contacts, etc.), never account-wide
  admin — the credential mirrors the tool's declared
  [permissions](https://github.com/Ceoloo/aion-docs/blob/main/governance/permissions.md).
- **One identity per external environment.** The OpenRouter provider and the GHL
  tool act under their own service identities
  ([security model](https://github.com/Ceoloo/aion-docs/blob/main/architecture/security-model.md):
  no ambient/shared "god" credential).
- **Never logged.** Structured logs carry references and non-secret reasons only
  ([observability](../observability.md)): a failed CRM call logs
  `ghl_auth_failed`, never the token or the connection detail.

## Rotation

- Rotation is a config change: replace the value in the secret store; the next
  deploy (or a secret-refresh) picks it up. No code change, no schema change.
- Because keys carry cost/authority (OpenRouter spend, GHL write access), a
  suspected exposure is rotated **before** anything else.

## What this spec deliberately does NOT do

- Does not store, embed, or reference any key value.
- Does not choose the model-router or CRM client library — that is the
  consuming repo's concern (see
  [aion-products OpenRouter provider](https://github.com/Ceoloo/aion-products/blob/main/docs/design/openrouter-provider.md)
  and
  [aion-core GHL tool](https://github.com/Ceoloo/aion-core/blob/main/docs/design/crm-tool-ghl.md)).
- Does not provision anything before a mission requires the integration.
