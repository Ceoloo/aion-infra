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

## The production authorization path (verified WITHOUT submitting a production decision)
Production runs `AION_AUTH_MODE=required` with two configured principals. The decision route requires: an authenticated principal with role `approve`; `decidedBy` equal to that principal's `actorId`;
and that actor to exist in `actors` as a **human** (or be supplied in the request *and* the principal hold `register`).

| Principal (no tokens shown) | kind | `actorId` | roles | actor registered in `actors`? |
|---|---|---|---|---|
| `principal_ops_console` | operator | `act_human_ops_1` | invoke, approve | **no** |
| `principal_revenue_copilot` | service | `act_service_revenue_copilot` | invoke | no (not an approver) |
Registered human actors: `operator-console` and four proof approvers from 2026-09-08 (`act_a051…`, `act_8787…`, `act_a9bf…`, `act_e4d1…`). The Console's approval button sends `decidedBy=operator-console` (`VITE_AION_OPERATOR_ID` overrides).

**Method:** the runtime (PR #46 build; the fix is aion-runtime PR #48) was run on a **scratch restore of production** (isolated container, `staging`, no CRM credentials) with the production principal configuration and real tokens (never printed).
Every request below was made against that copy; production received none.

| # | Request | Result |
|---|---|---|
| A1 | no credentials | 401 `auth_required` |
| A2 | service principal | 403 `approve_forbidden` |
| A3 | ops principal, `decidedBy=operator-console` (the Console default) | 403 `approver_mismatch` |
| A4 | ops principal, `decidedBy=act_human_ops_1`, no actor object | 403 `actor_not_registered` |
| A5 | same + a human actor object | 403 `register_forbidden` (principal lacks `register`) |
| B | after inserting `act_human_ops_1` as a human actor **on the copy only**: ops principal, `decidedBy=act_human_ops_1`, `approve=false` | recorded: approval `rejected` (`decided_by=act_human_ops_1`), execution `denied`; the other two approvals still pending |
Copy state after A1–A5: unchanged. **Production after the whole exercise: still 3 `pending`, 0 decided.**

**Finding:** with today's production configuration **no approval decision can be recorded** — neither through the route with the ops token nor via the Console's default approver id. The
authenticated approver identity that exists is `principal_ops_console` → `act_human_ops_1`; that identity is simply not registered as a human actor. (Four earlier grants by `operator-console` exist from 2026-09-07/08; I did not determine when required-mode auth began, so I do not know how those were authorized.)
I did not invent an actor id; the two existing identities are `act_human_ops_1` (authenticated, unregistered) and `operator-console` (registered, no principal maps to it).

### Options to make the path work (each needs your approval; none applied)
1. **Register the existing identity** — one `INSERT INTO actors` row for `act_human_ops_1` as `human` (production DB write, reversible with one DELETE; no restart). Tested on the copy (row B). The Console still sends `operator-console` until its `VITE_AION_OPERATOR_ID` is set to `act_human_ops_1` and rebuilt — a separate follow-up.
2. **Point the principal at the registered actor** — change `principal_ops_console.actorId` to `operator-console` in `AION_GATEWAY_API_KEYS` (edits a secret; needs a runtime recreate). Aligns the Console with no Console change.
3. Give the ops principal `register` — **not recommended** (broadens authority).
I recommend (1) for closing these approvals (smallest, no restart), and (2) later for the Console.
Whoever decides, note that `act_human_ops_1` is a shared operator identity: put the deciding person's name in the note, since the audit shows the actor, not the human.

## Decisions needed
1. Which of the three to reject: §1, §2, and/or §3 (each on its own evidence above).
2. Approval to make the decision path work (option 1 or 2), and to run the decisions in production one at a time.
3. Whether `act_human_ops_1` is acceptable as the approver of record.

## Timeout / escalation (not built; needs a policy decision)
Nothing ages out an unanswered approval, which is how these sat 8–12 days with no alert. `scripts/report-stale-approvals.sh` reports them read-only (it no longer suggests raw SQL); a timer that notifies via
ntfy past N hours is cheap and safe (no contract change) but is a host change needing approval; a runtime-level `expired` state is a contract change.
