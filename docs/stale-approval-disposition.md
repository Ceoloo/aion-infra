# Stale approvals — evidence and proposed audited disposition (2026-09-20)

**Nothing was approved, rejected, cancelled or replayed.** Three R2 approvals have been `pending` (their executions
`awaiting_approval`) since 2026-09-08 / 2026-09-12. This records the evidence and a proposal for you to authorize.

| Approval | Requested | Capability | Cohort | Assessment |
|---|---|---|---|---|
| `apr_c7e02e9f…` | 2026-09-08 05:23 | `crm.opportunity.create` | `pre_ol_validation`, `productionEconomic=false` | pre-launch validation step; superseded by later real missions |
| `apr_46feebb7…` | 2026-09-08 06:37 | `crm.opportunity.create` | `pre_ol_validation`, `productionEconomic=false` | same |
| `apr_63a095b9…` | 2026-09-12 01:12 | `crm.opportunity.update` | `OL-001`, `productionEconomic=true` (ordinal 1) | **intended effect already satisfied** (below) |

## Read-only evidence for `apr_63a095b9…` (2026-09-20; two GET calls, zero writes)
The approval would set the linked CRM opportunity to: stage *Negotiation*, status *open*, value *500*. A read-only lookup
of that opportunity (and its pipeline's stage names) shows it is **already** stage *Negotiation*, status *open*, value
*500* — it reached that state on 2026-09-08 04:51 UTC via the approved acceptance-gate update, and was last updated
2026-09-12 00:00 UTC, *before* this approval was requested. Approving would at best re-apply identical values. (Record
ids and names are deliberately omitted — this repo is public; the ids are in `approvals.command_snapshot`.)
The other two would create generically named validation opportunities; no reason to create them now.

## Proposed disposition: **reject, with a "superseded" note** (audited), not delete, not force-status
- The runtime's schema allows only `pending | granted | rejected` for approvals (and `cancelled` only on runs/executions
  via other paths), so there is **no `superseded` state**; the honest, auditable encoding is `rejected` with the reason in
  `note`. (A first-class `superseded`/`expired` state is a contract change — see "Timeout/escalation" below.)
- Use the runtime's decision route, **not** raw SQL: it enforces a verified human approver, writes `decided_by`/`decided_at`
  (a DB check requires both), appends an audit event, and refuses a second decision.

Exact request (operator principal from `AION_GATEWAY_API_KEYS`; secrets not shown), per approval, after you confirm:
```http
POST /v1/approvals/<approvalId>/decision
Authorization: Bearer <operator token>
x-aion-tenant-id: aion-systems
Content-Type: application/json

{"approve": false,
 "decidedBy": "<the human operator's actor id>",
 "actor": <that human's Core Actor object, required if the principal does not resolve it>,
 "note": "SUPERSEDED (audit 2026-09-20): the target CRM record already holds the requested state per a read-only check; closed by owner decision; no CRM action taken."}
```
For the two validation approvals use a note such as *"SUPERSEDED: pre-launch validation step; closed by owner decision"*.

## What a rejection does — verified on a disposable runtime (fixtures, not production)
A fixture R2 approval was parked exactly like these, then rejected with the request above:
| | before | after |
|---|---|---|
| approval | `pending` | `rejected`, `decided_by` set, note stored |
| execution | `awaiting_approval` | `denied` |
| run | `awaiting_approval` | `denied` |
| audit events for the run | 2 | 3 |
| external side effects | 0 | **0** (no CRM call) |
A second decision (attempted re-grant) returned **HTTP 409** and the approval stayed `rejected`.
**Not verified:** the production auth path (operator principal + durable human-approver grant) — the test ran with auth
`open`; confirm with a dry run on a disposable runtime using `AION_AUTH_MODE=required` before touching production.

## Decisions for you
1. Authorize rejecting all three as superseded (I would execute one at a time and re-verify state after each), or name
   which to keep open. Rejecting `apr_63a095b9…` is a business call about mission ordinal 1 — you may prefer to close
   it as the mission's own record instead.
2. Which human actor id is the approver of record.

## Timeout / escalation (not built; needs a policy decision)
Nothing ages out an unanswered approval today, which is how these sat for 8–12 days with no alert. Options: a
`report-stale-approvals.sh` run on a timer that notifies via ntfy past N hours (no contract change, cheap), and/or a
runtime-level `expired` state with an SLA per risk level (contract change). The first is safe to add now.
