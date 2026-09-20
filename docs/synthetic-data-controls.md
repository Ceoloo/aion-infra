# Keeping synthetic proof records out of business-value reporting (2026-09-20, reconciled)

**Status:** proof-side controls are built and CI-green (aion-runtime PR #46, draft). The reporting-side SQL is
tested on a copy of production and **returned for approval — not applied**. A durable, write-time provenance fix is
designed but not built (needs an aion-data migration + runtime change).

## Immediate historical correction vs durable solution
| | Immediate correction (this SQL) | Durable solution (designed, not built) |
|---|---|---|
| What it does | Reporting counts a record only if its mission was **explicitly classified `production` by a person**; everything else is excluded by default | The runtime stamps every mission/execution/outcome with a `data_class` **at write time** |
| Source of truth | `ol_metrics.mission_classification` (auditable table, owner-written, app role read-only) | A column set from the *authenticated principal's registered environment* — never from client-supplied metadata |
| Default | Unclassified ⇒ excluded (and listed in `unclassified_missions`) | `unclassified` by DB default ⇒ excluded; only `production` counts |
| Depends on names / tenant ids / whether a mission exists? | **No** | **No** |
| Deletes anything? | **No** — executions, approvals, outcomes, missions untouched | No |
| Needs | approval to run one SQL file | aion-data migration, runtime change, image deploy, a tenant/environment registry (synthetic tenants registered as `synthetic`), and moving `ol_metrics` into a repo with an owner and tests |

## Empirical basis (isolated DB + a copy of production)
- The revenue proof writes one `realized`/1500 USD outcome and two `executions.revenue_attributed = 1500`, **0 missions**,
  under the production tenant id (old proof). Only the outcome row carried a marker (`metadata.proof`); the executions
  carried none. No schema column marks synthetic data.
- The old `cohort_kpis` was protected only by accident (views are driven `FROM missions`, the proof creates none).
  Tenant-scoped API reads have no synthetic filter.
- Live effect today: `cohort_kpis` reports `OL-001: 10 missions`, including 5 `pre_ol_validation` (view ignores
  `metadata.cohort`), because `mission_record` defaults every mission without a `mission_context` row to `'OL-001'`.

## The reconciled SQL — `providers/vps/sql/ol-metrics-reconciled.sql` (+ `-rollback.sql`)
1. `ol_metrics.mission_classification` table (`production|validation|synthetic|unverified`, reason, classified_by,
   classified_at) seeded with all 10 existing missions. `aion_app` gets **SELECT only** — the schema's default privileges
   auto-grant `arw`, so the SQL `REVOKE`s them (found by testing; without it the runtime role could rewrite classification).
2. `mission_record`: cohort from the mission's own `metadata.cohort`, no silent `'OL-001'` default. Columns unchanged.
3. `cohort_kpis`: only `production`-classified missions. Columns unchanged.
4. `business_value_ledger` (new view): every outcome value and every `revenue_attributed`, with `data_class` and
   `counts_as_business_value`; sum business value **only** over `WHERE counts_as_business_value`.
5. `unclassified_missions` (new view): nothing silently drops out — missions awaiting a decision are listed.

### The eight missions excluded from KPIs, with reasons
| Mission | Class | Reason (from the data) |
|---|---|---|
| `msn_c5409a36…` | unverified | Tagged cohort OL-001, no `productionEconomic`/`synthetic` flags; created 2026-09-07 06:13 during runtime bring-up, before the Console set flags |
| `OL-001-M001` | unverified | Hand-seeded OL-001 mission (`mission_context` row, `realized_revenue` NULL, 2026-09-07); no flags; ordinal predates the Console's `missionOrdinal` (whose #1 is `msn_0e3c5c21…`) — likely superseded |
| `msn_d9aa3dac…` | unverified | Tagged cohort OL-001, no flags; created 2026-09-07 17:23 during bring-up |
| `msn_9eedcb95…` | validation | `pre_ol_validation`; Console flags `productionEconomic=false` (2026-09-08) |
| `msn_db405716…` | validation | same |
| `msn_30fd4f95…` | validation | same; one execution still awaiting approval |
| `msn_eeb22b82…` | validation | same |
| `msn_59c5efb6…` | validation | same; one execution still awaiting approval |

**Included (2):** `msn_648d3df8…` (Console-launched OL-001, `productionEconomic=true`, 13 executions, several failed) and
`msn_0e3c5c21…` (`launchMode=ol001_production`, ordinal 1, one R2 approval pending). Both are included *because the
Console flagged them*, not because anyone verified them — owner to confirm. If any of the three `unverified` are real
leads, reclassify (`UPDATE ol_metrics.mission_classification …`, owner role).

### Test evidence (production copy with real ownership/ACLs; production untouched)
- After apply: `cohort_kpis` 10 → **2** missions; `mission_record` 5 `OL-001` + 5 `pre_ol_validation`; 8 classified
  rows listed above; `unclassified_missions` 0 rows; base-table content checksums unchanged (only the new table's rows
  and schema hash differ).
- `aion_app`: `permission denied` on UPDATE/INSERT of classification; can SELECT (10 rows).
- Ledger with injected test rows (rolled back): production-classified mission 250 + 500 counted; validation 999 + 900 and
  unverified 700 excluded (750 counted vs 2,599 excluded).
- A **new** mission whose metadata says `productionEconomic=true, synthetic=false` appears in `unclassified_missions` and
  **not** in the KPIs until classified.
- The real fake-backend proof's records (3 rows, 4,500 total) → `data_class=unclassified`, `counts=false` — and still
  `false` after rewriting them to the **production tenant id** (the legacy case), proving exclusion does not depend on
  tenant naming or on mission creation.
- Rollback: `pg_get_viewdef` md5 of both views **identical to the live baseline** (not merely the dump-derived one),
  outputs and pre-existing ACLs identical, the two added views dropped, classification table **kept as evidence**.
- Not idempotent by design (the table already exists on a second apply); apply once.

**Operational consequence to approve:** after apply, a *new* production mission does not count in KPIs until someone
classifies it. That is the fail-closed choice; `unclassified_missions` is the to-do list.

## Proof-side controls — aion-runtime PR #46 (draft, CI green)
Review of the first guard found it failed **open**: one flag re-enabled live GHL; the CI opt-out skipped all DB checks
(so it could aim a proof at production); 1 of ~16 scripts was guarded (13 start a runtime that inherits `GHL_*`);
`proof:ghl-live-capability` defaulted to the production runtime, tenant and real record ids; credentials still implied
live. Now:
- **Explicit backend selection.** `GHL_BACKEND=fake|live` in the runtime. Under `AION_PROOF=1` credentials never imply
  live, and live also needs `AION_PROOF_LIVE=1`. Unset outside a proof ⇒ legacy behaviour (deployed runtimes unchanged
  until their `.env` sets `GHL_BACKEND=live` — a follow-up to schedule with a deploy).
- **Every proof script** sources `proof-env.sh` first: guard, then explicit fake backend. `proof:ghl-live-capability`
  goes through the guard; both live proofs lost their production defaults.
- **Live mode** needs *all* of: `AION_PROOF_LIVE=1`, `GHL_BACKEND=live`, an allowlisted **test** location, a
  test-scope attestation, explicit non-production tenant / record ids / loopback-or-allowlisted runtime, and credentials
  differing from the host's production env file. Known production location/record ids are stored **only as SHA-256**.
  `live-aio17` is refused unconditionally — **live AIO-17 stays blocked**.
- **CI opt-out** is job-level, honored only when `GITHUB_ACTIONS=true`, skips only "DB already holds non-proof rows",
  and can never bypass production markers (`ol_metrics` schema, production-economic missions) or any GHL/production refusal.
- **Tests** (`npm run test:proof-safety`, also in CI): 72 tests — a capture server asserts **0 requests** on every
  refusal, a structural test fails if any proof script is unguarded, DB cases run against real Postgres. Mutation-checked:
  deliberately breaking 5 protections (opt-out outside CI, opt-out bypassing production markers, old override flag,
  a script losing its prelude, runtime inferring live) is caught each time. Guarded proofs still pass: AIO-17 14/14,
  revenue proof A–J, mission009 A–J; the PR's CI job passes.
- **Limits.** The guard sees the caller's environment and DB; a remote runtime's own credentials can't be inspected, so
  live-capability requires the operator's attestation plus a loopback/allowlisted URL. Other repos' proofs are untouched.
