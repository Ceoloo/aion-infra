# Can synthetic revenue-proof records enter production business-value reporting? (2026-09-20)

**Answer: not guaranteed today.** Production is currently clean — `outcomes` has 0 rows and `executions.revenue_attributed`
is NULL everywhere — but that is because the proof has never been run against it, not because anything would stop it.
Findings below are empirical (isolated database, plus a read-only copy of production), not inferred.

## What the proof writes
Run against a fresh disposable DB (`npm run proof:revenue-workflow`, aion-runtime `6eb2b79`):
0 `missions`, 7 `executions` (all `mission_id` NULL), one `outcomes` row `realized / revenue_qualified / 1500 USD`,
two executions with `revenue_attributed = 1500`, three R2 approvals — all under tenant **`aion-systems`, the
production tenant id**.

## Gaps
1. **Unmarked value rows.** The outcome row has a `proof` key in `metadata`; the two executions carrying
   `revenue_attributed` have **no marker at all**. No column anywhere is named like synthetic/test/sandbox.
   Nothing in the runtime source reads `synthetic` or `productionEconomic` — those are opaque client metadata.
2. **No guard on the proof.** It accepts any `DATABASE_URL`, and the GHL adapter selects the **live** backend
   whenever `GHL_API_KEY` + `GHL_LOCATION_ID` are in the environment — on a host with the deployment `.env` loaded
   the proof would write real CRM records.
3. **Reporting views ignore flags.** `ol_metrics.mission_record` defaults any mission lacking a `mission_context` row
   to cohort `'OL-001'` and ignores `missions.metadata.cohort`. **Live effect today:** `cohort_kpis` reports
   `OL-001: 10 missions`, including the five `pre_ol_validation` missions. `economic_value` also falls back to
   `executions.revenue_attributed` — exactly the unmarked column the proof fills.
4. **Why the KPI views are safe *today* is accidental:** they are driven `FROM missions`, and the proof creates no
   missions, so its rows never join in. Tenant-scoped API reads (`GET /v1/outcomes`, `/v1/revenue-sessions`) have no
   synthetic filter and would show proof rows.
5. `ol_metrics` is defined in no repo searched (ad-hoc SQL dumped at `/opt/aion/ol-metrics.schema.sql`); it has no
   owner or review path.
6. Side observation: `approvals.tenant_id` and `approvals.execution_id` are NULL on **all 16** production
   approvals; only `run_id` links them to executions.

## Controls prepared
| Control | Where | State |
|---|---|---|
| Proof safety guard: refuses if live GHL creds set, `AION_ENVIRONMENT=production`, or DB holds non-proof data; synthetic tenants `aion-proof-synthetic`/`aion-proof-foreign`; `AION_PROOF_DB_DISPOSABLE=1` opt-out for CI | **aion-runtime PR #46 (draft)** | Tested locally against a real copy of production (refused: 92 exec/16 approvals/10 missions), fresh DB and re-run (allowed), full proof PASS. **CI path unverified locally** — the PR's CI run is the check |
| Fail-closed view fix: `cohort_kpis` counts only missions with `metadata.productionEconomic='true'`, not `synthetic='true'`, no `proof` tag; cohorts read from each mission's own metadata | `providers/vps/sql/ol-metrics-production-economic.sql` (+ `-rollback.sql`) | Tested on a **copy** of production: `cohort_kpis` 10 → 2 missions; `mission_record` shows 5 `OL-001` + 5 `pre_ol_validation`; `synthetic=true` or a `proof` tag each drop a mission out; rollback output byte-identical to baseline. **NOT applied to production** — a DDL change on the canonical DB needs your approval |

Effect of the view fix on today's data: only the two `productionEconomic=true` missions count. The three older
`OL-001`-tagged missions (`msn_c5409a36…`, `OL-001-M001`, `msn_d9aa3dac…`) carry no flags and are excluded — that is
the fail-closed choice; if any are genuinely production, flag them.

## Not solved (needs a decision)
A durable fix is a first-class `synthetic`/`environment` marker on `executions`/`outcomes` set by the runtime
(an aion-data migration + contract change), so exclusion does not depend on client-supplied metadata. Other proof
scripts (mission001–009, ghl-phase-ab, live-acceptance) share the exposure and are untouched.
