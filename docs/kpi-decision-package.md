# KPI reporting — decision package (2026-09-20)

**The SQL is NOT applied.** `providers/vps/sql/ol-metrics-reconciled.sql` (+ `-rollback.sql`) was extended this pass and tested on a scratch restore of production
(a copy: production data and ACLs, isolated container; production untouched). Approving it has one operational consequence — read §5 first.

## 1. Classification evidence for the three unflagged missions
> **Correction to my earlier draft:** it said two of these missions made "one real CRM contact update". That was wrong. The side-effect rows carry `backend = ghl-fake` (47-character
> generated ids, `ghl_` prefix). The first `ghl-live` effect anywhere is 2026-09-08 01:10 — after both missions. **No real CRM record was touched by any of the three**, so there are no CRM contacts to read;
> the requested read-only contact check was attempted on the recorded ids and the CRM rejected them as invalid (HTTP 400), consistent with generated ids. (The read used the production token, GET only, and printed nothing about any record.)

Ten missions exist; seven carry Console flags and are proposed from them (5 `validation`, 2 `production`). Three carry no flags and are **left unclassified** — the data cannot say whether they were tests, and
neither a CRM write nor the absence of revenue would settle that. What the records do show:

| Mission | Created (UTC) | Declared intent (from the record) | Execution history | Not established |
|---|---|---|---|---|
| `msn_c5409a36…` | 2026-09-07 06:13 | name "OL-001 · Revenue Production v1 · <timestamp>", template `revenue-production-v1`, cohort `OL-001`, objective "Generate qualified business-funding opportunities", no `launchedFrom`, no success criteria | 3 executions, all `succeeded`, R1, no approval, no outcome, no revenue; one `crm.contact.update` on the **fake backend** (a generated id) | whether this was meant as a production run that simply had no live CRM wired yet, or a bring-up trial |
| `msn_d9aa3dac…` | 2026-09-07 17:23 | identical template/naming (a second run 11 h later) | same pattern; one `crm.contact.update` on the **fake backend** | same |
| `OL-001-M001` | 2026-09-07 06:22 | hand-seeded row: "Mission 001 · lead research (supervised)"; objective "Turn one real lead into a qualified opportunity…"; description "for a real AION Systems opportunity"; `lead_source` self-labelled `REAL_LEAD`; success criteria `{qualified, opportunity_created}` | 1 succeeded R1 execution; no approval, no outcome, no revenue, **no CRM side effect at all** | its declared intent is a real lead; nothing shows what, if anything, happened to it |

Read together: intent labels lean production (OL-001 cohort; "Revenue Production"; "real lead") but all three predate the Console flags (first flagged mission: 2026-09-08 05:22) and the live CRM (first live effect
2026-09-08 01:10), and none has any real-world effect on record. The two flagged production missions differ: named leads, live GHL opportunity, launched from the Console with `productionEconomic=true`.
**Neither the intent labels nor the absence of revenue proves test or production; only the owner can say.** They therefore stay **unclassified**: excluded from KPIs (same as today's proposed effect on them), listed in
`unclassified_missions`, and counted by the indicator. If classified `production` they would add three zero-revenue missions to the OL-001 mission count and success-rate denominators.

## 2. Unclassified-count indicator
- **View:** `ol_metrics.classification_health` (one row): `unclassified_count`, `oldest_unclassified_created_at`, `last_classification_change_at`.
  `ol_metrics.unclassified_missions` is the list (with the Console's flags shown as hints).
- **Script:** `providers/vps/scripts/report-unclassified-missions.sh` (read-only; `MAX_AGE_HOURS`, default 24): prints the counts and list; exit 1 if any mission has waited longer than the threshold,
  2 if it cannot query. Before the SQL is applied it reports "not installed" and exits 0 (run against production today to confirm). Tested on the scratch copy: 0 → 0/exit 0; a 30 h-old new mission →
  listed, exit 1 at 24 h, exit 0 at 48 h.
- **Not wired to a timer or ntfy** (a timer is a host change needing approval). Suggested: run it from the existing `aion-monitor` cadence or daily, and page on exit 1.

## 3. Classification procedure
1. Detect: `report-unclassified-missions.sh` (or `SELECT * FROM ol_metrics.unclassified_missions`).
2. Review the evidence (read-only): the mission's metadata flags, its executions, outcomes, and `external_side_effects` (as in §1).
3. Decide (the owner) one of `production` (real customer/revenue work), `validation` (pre-launch/bring-up), `synthetic` (proof/fixture). Undecided = **do nothing**: the mission stays unclassified (excluded, listed).
4. Record it — the single supported path, run on the host (owner/operator):
   ```
   docker exec aion-postgres-1 psql -U postgres -d aion_data -c \
     "SELECT ol_metrics.classify_mission('<mission_id>','production|validation|synthetic','<reason, ≥10 chars>','<the deciding person>')"
   ```
   It refuses a short reason or an empty person and rejects unknown classes. Reclassifying is the same call; the earlier decision stays in the audit table.
5. Verify: `SELECT * FROM ol_metrics.classification_health;` and the mission's rows in `ol_metrics.mission_classification_audit`. KPI views update immediately (they are views).

## 4. Who may classify, and how changes are audited
| Principal | Read | Classify | Evidence (scratch copy) |
|---|---|---|---|
| `aion_app` (the runtime, incl. Console via runtime) | yes | **no** — UPDATE/INSERT on the table and on the audit table, and `EXECUTE classify_mission`, are all `permission denied` | tested |
| `aion_migrator` (schema owner) | yes | yes | tested |
| `postgres` superuser (via `docker exec` on the host) | yes | yes | tested |
| Anyone else | — | no; and the runtime has **no API** that writes classification | |
So the practical set is: people with root on the VPS, or holding the migrator credential (`/opt/aion/.env`, root 0600). Recommended policy: the **owner decides**, one named operator executes.

**Audit trail** (`ol_metrics.mission_classification_audit`, written by a trigger so no writer can skip it): time, operation (INSERT/UPDATE/DELETE), mission, old/new class, old/new reason,
the *claimed* decider (the `classified_by` argument — **asserted by whoever runs the call, not authenticated**), the **database login** (`session_user`, not spoofable via the row) and the role in force, transaction id. The table is append-only —
UPDATE/DELETE raise even for the owner role, and TRUNCATE raises for the superuser (tested). The initial seeding of 7 rows is itself audited and labelled `PROPOSED by audit 2026-09-20 from Console flags (asserted, not an authenticated person)` — it becomes a decision only when you accept it.
**Limits, honestly:** (a) everyone reaches the DB through shared logins, so the *human* identity is asserted by the operator, not authenticated; (b) the owner or a superuser can still
`ALTER TABLE … DISABLE TRIGGER`, drop the trigger, or set `session_replication_role=replica` (superuser) — that leaves no audit row of its own. Mitigation available today: the audit rows are in the hourly encrypted DB backups, so tampering shows as a
non-append-only diff between backups. A stronger design (per-person DB roles, or classification only through an authenticated runtime endpoint) is not built.

## 5. What approving the SQL changes (the consequence to accept)
- KPIs (`cohort_kpis`) drop from `OL-001: 10 missions` to **2** (the two Console-flagged production missions). Nothing is deleted; executions, approvals, outcomes and missions are untouched.
- A **new** production mission does **not** count in KPIs until someone classifies it (fail-closed by design). `unclassified_missions`/`classification_health` is the to-do list (after apply it starts at 3).
- `mission_record` no longer defaults every mission to cohort `OL-001` (5 show `pre_ol_validation`).
- Re-applicable: the SQL uses IF NOT EXISTS / OR REPLACE / ON CONFLICT DO NOTHING, so apply → rollback → apply → apply → rollback → apply was run in sequence on a scratch copy (all OK; a decision recorded in between survives every step). Rollback restores the previous view definitions and keeps the classification + audit tables as evidence.
- Test summary (fresh scratch restore, re-run after the revision): apply OK; `cohort_kpis` 10→2; 7 audit INSERT rows; `classification_health.unclassified_count = 3`; the indicator lists the three and exits 1 (>24 h); permissions/audit/append-only checks as above; new mission listed and excluded; rollback → `cohort_kpis` back to 10 / view definitions restored, classification + audit rows kept. Note: the indicator will exit 1 immediately after apply (three missions older than 24 h) until you classify them — expected.

**Decisions needed:** (a) accept the 7 proposed classifications and the 10→2 KPI consequence; (b) for each of the three: production / validation / leave unclassified; (c) then approve applying the SQL. Until all three are accepted the SQL stays unapplied.
