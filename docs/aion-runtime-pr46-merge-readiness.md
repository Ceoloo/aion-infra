# aion-runtime PR #46 — merge/deploy readiness (2026-09-20)

**Not merged, not deployed. Live AIO-17 stays blocked.** PR #46 is a draft at `9d6ee2a`; CI green (typecheck · build · portability · acceptance ·
mission proofs · proof-safety tests). It changes two things that must be kept apart:

| | Applies to | Effect |
|---|---|---|
| **A. Proof-script restrictions** | `npm run proof:*`, acceptance, certification scripts (they source `scripts/lib/proof-env.sh`) | refuse to run against production, against live GHL, or without an explicit backend |
| **B. Normal production execution** | the deployed runtime (`node dist/index.js`) | CRM backend chosen by an explicit policy; **production can no longer fall back to fake** |

Proofs set `AION_PROOF=1`; the deployed runtime never does. A only fires when that flag is present, so it cannot change how production runs.

## 1. Ordinary runtime behaviour with today's production environment
Production today: `AION_ENVIRONMENT`, `GHL_API_KEY`, `GHL_LOCATION_ID` set; **`GHL_BACKEND` and `AION_ACK_FAKE_CRM` unset** (names checked, values never read out).
Real process (`node dist/index.js`) against a disposable Postgres, production-shaped env with dummy credentials, GHL base URL pointed at a capture server
(`aion-runtime/scripts/demo-crm-backend-behavior.mjs`):

| Scenario | New code (PR #46) | `main` today |
|---|---|---|
| **production as it is today** (creds set, `GHL_BACKEND` unset) | starts, **live**, `warn crm_backend_inferred`; 1 request reached the CRM stand-in | live (silent) |
| production, `GHL_BACKEND` **unset**, creds **missing** | **refuses to start** (`config_invalid`, exit 1) | **starts on the FAKE backend silently** |
| production, `GHL_BACKEND=live`, creds set | live, `info crm_backend` | live |
| production, `GHL_BACKEND=live`, creds missing | refuses to start | starts on **fake** silently |
| production, `GHL_BACKEND=fake`, creds set | refuses to start | goes **live** (value ignored) |
| production, `GHL_BACKEND=fake` + `AION_ACK_FAKE_CRM=1` | starts, `error crm_backend_fake_in_production`, `/health/ready` reports `crm_backend=fake`, 0 CRM requests | fake, silent |
| production, `GHL_BACKEND=sandbox` (invalid) | refuses to start | ignored → live/fake by creds |
| production, `GHL_BACKEND=` (blank line) | treated as unset → refuses without creds | same as unset |
| staging / local | unchanged (creds → live, none → fake) | unchanged |

**Unset / fake / live / invalid — summary:** unset+creds = live with a warning (today's behaviour preserved); unset+no creds = refuse; `fake` = refuse unless acknowledged
(then loud, visible in logs and `/health/ready`); `live` = needs creds; anything else = refuse. Evidence: `demo-crm-behavior.txt` / `demo-crm-behavior-main.txt`
(the `main` run shows the hazard the PR closes). Unit coverage: `src/adapters/ghl/backend-selection.test.ts` (18 cases).

**Production cannot silently execute against a fake backend:** the only path to `fake` in production is `GHL_BACKEND=fake` **and** `AION_ACK_FAKE_CRM=1`
(used only by `scripts/image-boot-check.sh` for image certification); it logs at error level at every start and is reported by the readiness endpoint. Boot-certification
of the real image with those flags was run and passes.

## 2. Test-credential attestation is not isolation
`AION_PROOF_CREDENTIAL_SCOPE=test-location` is only an acknowledgement and is **not** trusted. Before any live proof, `proof-credential-scope.mjs` checks the
credential behaviourally with read-only calls: the designated location answers 200; a random location, agency-level search and **every known production location**
must answer 401/403 (GHL answers a foreign location with 403 "The token does not have access to this location"); anything else (200 where denial is required, 404,
5xx, network error) refuses. It also refuses if it has no production location to test against, and the GHL base URL cannot be overridden.
- **Requirement for a live proof:** a token *actually scoped* to a designated test location (a sub-account/test location created for this; no such location or token exists today).
  The production token on this host is scoped to the production location — calibrated read-only: own location 200, foreign 403 — so it is correctly refused.
- The check itself was tested against a mock GHL (13 tests) and calibrated against the real API's answers; it has **not** yet run against a real test location, because none exists.
- Live AIO-17 (`live-aio17`) is refused unconditionally by the guard.

## 3. Required environment changes — explicit backend selection prepared and VERIFIED on the proposed image
Nothing is required for production to keep working. Prepared (tracked in aion-infra PR #13, **not on the host**): compose passes `GHL_BACKEND: ${GHL_BACKEND:-}` to the runtime; `.env.example` documents `GHL_BACKEND=live`. Applying it = add `GHL_BACKEND=live` to `/opt/aion/.env` (secret file — back up first) + install that compose + `docker compose up -d --no-deps aion-runtime` (recreate, ~10 s). Safe with the *current* image (ignored). No credential is changed and no proof script is enabled.

**Startup verified with the proposed image** — a local build of `origin/main` + PR #46 + PR #48 (`aion-runtime:candidate-20260920`, digest `sha256:d3d64bc836…`), the *proposed* compose rendered with the real `/opt/aion/.env`, database = a scratch restore of production, CRM base URL = a local capture server (nothing could reach GHL):
| Configuration | Result |
|---|---|
| **A. proposed** (`GHL_BACKEND=live` added) | starts; `/health/ready` `crm_backend=live`; log `info crm_backend` (no warning) |
| **B. today's `.env` unchanged / rollback state** (unset) | starts; `crm_backend=live`; `warn crm_backend_inferred` |
| C. `GHL_BACKEND=live`, `GHL_API_KEY` blanked | **refuses** (`config_invalid`, exit 1) |
| D. `GHL_BACKEND=fake` in production, no acknowledgement | **refuses** |
| E. `GHL_BACKEND=Live` (case typo) | accepted as `live` |
Requests that reached the CRM stand-in during all five boots: **0**. (Boot alone makes no CRM calls.)

**AWS / GCP profiles — deployed or used by CI? No evidence of either.** `deploy-gcp.yml` is *dormant by design*: its jobs run only if `GCP_WORKLOAD_IDENTITY_PROVIDER` and the CI service-account variables exist; `gh variable list` and `gh secret list` on this repo returned nothing, so no plan or apply could have run here (CI's `terraform plan (staging)` shows *skipped*; its "successful" deploy-gcp runs only executed the image-resolve step). No workflow applies the AWS profile. Whether someone created an environment by hand from these modules cannot be known from the repo. Both profiles pass only `AION_ENVIRONMENT`, DB URLs and release metadata — **no `GHL_*`, no `AION_AUTH_MODE`/`AION_GATEWAY_API_KEYS`** — so a current image (auth is required off-local) would not start in either without more wiring. Action taken: both READMEs now carry a **NOT SUPPORTED until wired** banner listing what must be added (`GHL_BACKEND=live`, secret-backed `GHL_API_KEY`/`GHL_LOCATION_ID`, `AION_GATEWAY_API_KEYS`, `AION_AUTH_MODE=required`) and the boot-check to run. I did not change Terraform.

## 4. Rollback
- **Env change:** delete the `GHL_BACKEND` line (and restore the compose backup) → recreate the runtime. Behaviour returns to inferred-live (config B above was booted and verified).
- **Image:** `deploy.sh` rolls back automatically to the previous digest if readiness fails; manually: `DEPLOY_IMAGE=<previous digest> scripts/deploy.sh`.
  The previous digest is printed by `deploy.sh` ("previous runtime: …") and visible with `docker inspect` before the roll. Setting `GHL_BACKEND=live` on the *old* image is harmless (ignored).
- No DB or data rollback is involved.

## 5. Not done / limits
- Guard sees the caller's environment and DB; a *remote* runtime's own credentials can't be inspected — hence the behavioural scope check plus loopback/allow-listed URLs.
- Other repositories' proof scripts are not covered.
- After merge nothing runs differently in production until item 2 is deployed.
