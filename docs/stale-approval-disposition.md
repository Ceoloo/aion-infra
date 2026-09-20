# Stale approvals — per-approval review and authorization-path check (2026-09-20, second pass)

**Nothing was approved, rejected, cancelled or replayed in production.** Three R2 approvals have been `pending` (their runs/executions `awaiting_approval`) for 8–12 days.
Each is assessed on **its own** evidence below; no approval's disposition is inferred from another's. Record ids and CRM names are omitted (this repo is public; ids are in
`approvals.command_snapshot`). Approvals ages as of 2026-09-20 ~14:40 UTC.

## What "cancel" means here
The runtime has no `cancelled` approval state (schema: `pending|granted|rejected`). Closing a stale gate = a **rejection with a "superseded" note** through the runtime's decision route.
Verified on fixtures earlier: approval `pending→rejected` (with `decided_by`, note), execution/run `awaiting_approval→denied`, one extra audit event, **0 external side effects**; a second decision → HTTP 409.
Note the route answers a *rejection* with **HTTP 403 body `status: denied`** — that is the normal success response for `approve:false`, not an authorization failure (seen again in §3-B).

## 1. `apr_c7e02e9f…` — validation opportunity create (12.4 days)
| | |
|---|---|
| **Action (sanitized)** | R2 `crm.opportunity.create`; payload has only a generic name of the form "L2A opportunity <timestamp>" and a provider field — **no contact, pipeline, stage or value** |
| **Context** | mission `msn_30fd4f95…`, cohort `pre_ol_validation`, `productionEconomic=false`, mission classified `validation`; created 2026-09-08 05:23 |
| **Current state** | approval `pending`, run and execution `awaiting_approval`; the mission's two other executions `succeeded`; `expires_at`/`consumed_at` empty; **0** recorded external side effects for the approval, **0** opportunity creations for the mission |
| **Cancellation rationale** | A pre-launch validation step for a mission that is flagged non-production; the create it gates never happened and carries no customer data; 12 days on, nothing depends on it, and leaving it pending keeps an execution stuck and hides real pending gates. Rejecting cannot cause a CRM change. |
| **Not established** | whether anyone still wants the validation opportunity created (a business preference, not a data fact). |

## 2. `apr_46feebb7…` — validation opportunity create (12.3 days)
Same review, separately verified: R2 `crm.opportunity.create`, generic timestamped name only; mission `msn_59c5efb6…`, cohort `pre_ol_validation`, `productionEconomic=false`, classified `validation`; created 2026-09-08 06:37;
approval/run/execution `awaiting_approval`, sibling executions `succeeded`, 0 side effects, 0 opportunity creations. Rationale as §1. (Two records with the same shape were reviewed twice, not once-and-copied.)

## 3. `apr_63a095b9…` — production opportunity update (8.6 days)
| | |
|---|---|
| **Action (sanitized)** | R2 `crm.opportunity.update` on the Console-launched OL-001 mission's linked opportunity: stage → *Negotiation*, status → *open*, value → *500* |
| **Context** | mission `msn_0e3c5c21…` (`launchMode=ol001_production`, `missionOrdinal` 1, `productionEconomic=true`, classified `production`); requested 2026-09-12 01:12 |
| **Current state** | approval `pending`, run/execution `awaiting_approval`; the mission's two other executions `succeeded`; 0 side effects recorded for this approval. **CRM (read-only check, 2026-09-20 earlier this session):** the record is already stage *Negotiation*, status *open*, value *500* — reached 2026-09-08 04:51 UTC through the earlier approved acceptance update, last changed 2026-09-12 00:00, i.e. **before** this approval was requested |
| **Cancellation rationale** | Approving would at best re-apply identical values; the requested end-state already holds. |
| **Why it is a different decision** | This is the mission KPIs count as ordinal 1. Rejecting records a *denied* execution on a production mission — it is a business call, unlike §1–2. Alternatives: leave it pending (keeps the gate visible, keeps an execution stuck), or approve (no functional change, records an approved+executed write on a real record). **Re-run the read-only CRM check immediately before deciding**; the CRM record can drift. |

## Recommendation (each item is separate)
- §1 and §2: reject as superseded (validation steps, no effect).
- §3: **your call** — I lean to reject-as-superseded after re-checking the CRM state, but I am not treating the evidence for §3 as covering §1–2, or the reverse.
- All: one at a time, re-verifying state after each, with notes such as *"SUPERSEDED (audit 2026-09-20): <specific reason>; closed by owner decision; no CRM action taken"*.

## The approval identity path, end to end (third pass — traced and fixed in aion-runtime PR #48)
**Chain as it exists:** bearer token → *principal* (`AION_GATEWAY_API_KEYS`) → the durable *human actor* it is bound to (`principal.actorId`) → `POST /v1/approvals/:id/decision` → `approvals.decided_by` (FK → `actors`) + audit event.
| Link | Finding |
|---|---|
| Console → runtime | The Console (a static Vercel SPA, `workforce-control`) sends **no bearer token at all** (its own source says browser bearer auth needs a BFF or session token that does not exist). In `required` mode every Console call is 401. It builds its own `actor` object with a self-declared permission list and sends `decidedBy=operator-console` (or `VITE_AION_OPERATOR_ID`). |
| Principal → actor | `principal_ops_console` (operator; roles invoke+approve; tenant aion-systems) → `actorId=act_human_ops_1`. **`act_human_ops_1` is not in `actors`.** The string is the placeholder shipped in `.env.example` (and in a unit-test fixture); nothing in the repo, database or logs shows it was chosen as a real operator identity, and no decision was ever made as it. The runtime does not log which principal made a request, so whether the ops token has ever been used cannot be established. |
| Authorization | `main` required `decidedBy` to equal the principal's actor **and** an actor row to exist (or be registered from the request body by a principal with `register`). |
| Tenant boundary | **Not enforced on decisions.** Reproduced on an isolated copy: an operator bound to tenant B rejected tenant A's approval and vice-versa; a request with no tenant header succeeded. |
| Persisted decision | `decided_by` = whatever the client claimed (validated only against the principal); audit event carried no principal. |

**Is `act_human_ops_1` the intended authorized operator? Not established.** It is the identity the ops token authenticates as, and it is a template value. I have **not** registered it. Registering it would make the token's holder — whoever that is — the approver of record for R2 gates.
**Owner confirmation needed:** (a) who holds `principal_ops_console`'s token; (b) whether that is one person or shared; (c) the actor id and display name to register (this doc assumes the existing `act_human_ops_1` only because the token already authenticates as it — you may prefer a different id, which means changing the principal's `actorId` in `.env` and recreating the runtime).

**The fix (aion-runtime PR #48, draft, separate from PR #46 and from the cleanup PRs):** in `required` mode `decided_by` is **derived from `principal.actorId`**; a body `decidedBy` may only restate it (`403 approver_mismatch` otherwise); a client `actor` object is never used to identify or register the approver; the approver must already be a registered human; the approval's tenant must be within the principal's tenants and equal the request's tenant header (undeterminable tenant → denied); the audit trace and log record `principalId`/`principalKind`. A principal identifies a **credential** — if the token is shared, `decided_by` names the operator *account*, not a uniquely authenticated person (documented in `docs/approval-identity.md`).
**Tests, real process + Postgres restored from production into an isolated container (no production request), fixture principals:** 15 scenarios, `main` vs PR — cross-tenant decisions succeed on `main` and are denied by the PR; impersonation (other registered human, forged id + actor object) denied on both; unauthenticated / service principal / unregistered approver denied; authorized reject and grant succeed, attributed to the authenticated actor with `principalId` in the audit; repeat decision and grant-after-reject → 409 with state unchanged; 10 unit tests, 5 mutations of the protections each caught. A final run with the **production principal shape** confirms: Console-style body → `approver_mismatch`; unregistered actor → `actor_not_registered`; after registering the actor *on the copy*, `{approve:false}` with no `decidedBy` → recorded, attributed to the principal's actor. The candidate image (main + #46 + #48) was also booted under the proposed configuration (see `aion-runtime-pr46-merge-readiness.md`).
A rejection is answered `403` with `status: denied` — that is success for `approve:false`.

**Smallest deployment + data change (both need authorization; neither applied):**
1. Merge aion-runtime #48 (and #46) → CI builds the image → `deploy.sh` with the digest (rollback: automatic on failed readiness, or the previous digest).
2. One INSERT: `sql/register-operator-actor.sql` (`-v actor_id=… -v display_name=…`), tested on a copy incl. refusals; rollback `register-operator-actor-rollback.sql` (refuses if the actor has decided anything). Order: 1 then 2 — or 2 first, harmless with the old image (a decision still needs `decidedBy` to equal the actor there).
3. The Console cannot decide in production until it authenticates (BFF/session) — a separate product change, **not** part of this fix. Until then decisions are made by an operator calling the route with the ops token.
The three existing approvals remain undecided.

### Note on my earlier test
The first-pass authorization check ran the runtime on a scratch copy of production with the **real** gateway tokens in that process's environment (localhost only, never printed). The later, fuller test suite used freshly generated fixture tokens. Recommendation stands from the review comment: prefer fixture principals; if you want, rotating the two gateway tokens is a cheap precaution (a `.env` edit + runtime recreate; **not** done and not required by any evidence of exposure).

## Decisions needed
1. Which of the three to reject: §1, §2, and/or §3 (each on its own evidence above).
2. The approver identity: who holds the ops token, and the actor id/display name to register.
3. Authorization to deploy the identity fix and register the actor; then to run the decisions in production one at a time.

## Timeout / escalation (not built; needs a policy decision)
Nothing ages out an unanswered approval, which is how these sat 8–12 days with no alert. `scripts/report-stale-approvals.sh` reports them read-only (it no longer suggests raw SQL); a timer that notifies via
ntfy past N hours is cheap and safe (no contract change) but is a host change needing approval; a runtime-level `expired` state is a contract change.
