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

## 3. Required environment changes
None are required for PR #46 to keep production working (row 1 above). Recommended, in this order, each needing your go-ahead:
1. **Make the choice explicit** (removes the `crm_backend_inferred` warning and the reliance on inference):
   - `.env`: add `GHL_BACKEND=live`
   - `docker-compose.yml` runtime service `environment:` add `GHL_BACKEND: ${GHL_BACKEND:-}` (the variable is not passed through today; without this line `.env` has no effect)
   - `.env.example`: document `GHL_BACKEND=live` (values `live|fake`; `fake` additionally needs `AION_ACK_FAKE_CRM=1` and is for image certification only)
   - Applying needs `docker compose up -d --no-deps aion-runtime` (a runtime recreate, ~seconds; approval required).
2. **Deploy the new image** with `scripts/deploy.sh` (`DEPLOY_IMAGE=<digest>`): validate → migrate (this PR adds **no** migration) → roll → readiness → automatic rollback on failure.
   Check `/health/ready` for `crm_backend":"live"` afterwards.
3. **Other deployment profiles.** `providers/gcp` and `providers/aws` pass `AION_ENVIRONMENT=<staging|production>` but **no GHL_* variables at all**. With the new image a
   *production* deployment there refuses to start until it gets credentials (`GHL_API_KEY`/`GHL_LOCATION_ID`, via secret manager) or an explicit fake acknowledgement.
   That is the intended behaviour (those profiles currently run the fake backend silently in production), but it is a breaking change for them. I have no evidence any is deployed;
   check before promoting the image tag anywhere but the VPS.

## 4. Rollback
- **Env change (item 1):** delete the `GHL_BACKEND` line (and the compose passthrough) → recreate the runtime. Behaviour returns to inferred-live.
- **Image (item 2):** `deploy.sh` rolls back automatically to the previous digest if readiness fails; manually: `DEPLOY_IMAGE=<previous digest> scripts/deploy.sh`.
  The previous digest is printed by `deploy.sh` ("previous runtime: …") and visible with `docker inspect` before the roll. Setting `GHL_BACKEND=live` on the *old* image is harmless (ignored).
- No DB or data rollback is involved.

## 5. Not done / limits
- Guard sees the caller's environment and DB; a *remote* runtime's own credentials can't be inspected — hence the behavioural scope check plus loopback/allow-listed URLs.
- Other repositories' proof scripts are not covered.
- After merge nothing runs differently in production until item 2 is deployed.
