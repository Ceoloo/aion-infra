# GHL AIO-17 acceptance — smallest run (Contact → Opportunity → Note/Task)

Scope is AIO-17 only. **Conversation and Appointment stay deferred:** `conversation.read/send` and
`appointment.create` must keep returning `CAPABILITY_DISABLED` in every stage below.

## Stage 0 — fixtures (DONE 2026-09-20, no external calls)
`npm run proof:aio17-ghl-lead-workflow` on aion-runtime `6eb2b79`, run with `GHL_API_KEY`/`GHL_LOCATION_ID`/
`AION_GHL_API_KEY` unset: **14/14 tests pass** — payload validation, disabled-capability fixtures, and the in-process
contact → opportunity → stage → note → task workflow with durability proofs against `FakeGhlBackend`. No database
needed. `npm run proof:revenue-workflow` (fixture backend, isolated DB) also passes A–J, including the restart-resume
and the three R2 approval gates. **Evidence type: fixture only — no live GHL integration evidence exists for AIO-17.**

## Stage 1 — live run: BLOCKED on an authorized test tenant
No designated test tenant exists. The only location on record (the production location, id in `/opt/aion/.env`) holds
real client records, so it is **not** a sandbox. Needed from you:
- a dedicated GHL **sub-account/location for testing** and a PIT scoped to that location only, **or** explicit written
  authorization to write tagged test records into the existing location; and
- your call on cleanup: **the live backend implements no delete** (no DELETE call in `live-ghl-backend.ts`), so live
  test records stay in GHL until removed by hand. Use one obviously synthetic contact (`[AION-TEST]` name,
  `@example.invalid` email), record every created id, and delete them in GHL afterwards.

Proposed minimal run once authorized (a small new script would be written and validated in that same step — it is
deliberately not written blind now, because it would perform live writes):
1. Disposable local Postgres + local Runtime (`AION_ENVIRONMENT=local`, never the production Runtime), live backend
   selected by the test-location `GHL_*` env only.
2. One synthetic lead: `contact` create/update → `opportunity` create → `note` create → `task` create, each through the
   Execution Gateway with R2 approvals granted by a human actor.
3. Assert: each step's `external_side_effects` row + audit entry; replay with the same idempotency key does not
   duplicate; a foreign tenant is denied; `conversation.*`/`appointment.create` still `CAPABILITY_DISABLED`.
4. Report as **live-integration evidence against the test tenant**, list created ids for manual cleanup.

## Hazards found in existing scripts — and their fix (aion-runtime PR #46, draft, CI green)
Before: `proof:ghl-live-capability` defaulted `AION_RUNTIME_URL` to the production Runtime, the production tenant and real
client record ids, and wrote live (a note, an R2 stage update); any proof run on a host with the deployment `.env`
loaded selected the **live** backend just because credentials existed; 13 proof scripts inherited that.
After PR #46 (not yet merged): every proof defaults to an explicit **fake** backend and *refuses* if GHL credentials are
present; the live proofs have no production defaults. A live run needs **all** of: `AION_PROOF_LIVE=1`,
`GHL_BACKEND=live`, `GHL_LOCATION_ID` in `AION_PROOF_GHL_TEST_LOCATIONS`, `AION_PROOF_CREDENTIAL_SCOPE=test-location`,
explicit `GHL_ACCEPTANCE_TENANT` (not a production tenant) / `_CONTACT_ID` / `_OPPORTUNITY_ID` / `_PRIOR_STAGE` /
`_TARGET_STAGE` (none a known production id — those are held only as SHA-256), and for `live-capability` an explicit
loopback or allowlisted `AION_RUNTIME_URL`. `live-aio17` is refused unconditionally: **live AIO-17 execution stays
blocked** until you authorize a test tenant. Prohibited configurations are proven to fail before any network request
(72 tests, capture server sees 0 requests). See `docs/synthetic-data-controls.md`.

## Read-only GHL check of the stale-approval opportunity (DONE 2026-09-20; two GET calls, zero writes)
Opportunity `rGbI…` (id, client and lead names redacted — this repo is public): status `open`, value `500`, pipeline
"AION Pipeline", stage **Negotiation**, created 2026-09-06, last stage change 2026-09-08 04:51 UTC (the approved
acceptance-gate update), last updated 2026-09-12 00:00 UTC.
Stale approval `apr_63a095b9…` (requested 2026-09-12 01:12) would set stage Negotiation, status open, value 500 — the
**current state already equals the requested state**, so it is redundant. It was not approved, rejected or replayed;
the mission owner should close it as superseded. Worth noting: the OL-001 "production" mission ordinal 1 targets the
same opportunity used in the 2026-09-08 acceptance test, i.e. the test record doubles as production mission #1.
(Cloudflare in front of the GHL API rejects the default `Python-urllib` User-Agent with error 1010; the check sent a
descriptive UA.)
