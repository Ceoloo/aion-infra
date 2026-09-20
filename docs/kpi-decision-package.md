# KPI reporting — decision package (2026-09-20)

**The SQL is NOT applied.** `providers/vps/sql/ol-metrics-reconciled.sql` (+ `-rollback.sql`) was extended this pass and tested on a scratch restore of production
(a copy: production data and ACLs, isolated container; production untouched). Approving it has one operational consequence — read §5 first.

## 1. Classification evidence for the three unflagged missions
Ten missions exist. Seven carry Console flags (`productionEconomic` true/false, `synthetic`) and were classified from them. Three carry **no flags at all**;
the data cannot settle what they are, and one fact matters:

| Mission | Created (UTC) | Evidence (sanitized) | What it does *not* show |
|---|---|---|---|
| `msn_c5409a36…` | 2026-09-07 06:13 | tag `OL-001` only; keys `cohort, autonomy, budgetUnits, workflowVersion, workflowTemplateId`; 3 executions, all `succeeded`, R1, **no approval, no outcome, no revenue**; **one real CRM write** (`crm.contact.update@1`, succeeded) on a contact that no Console mission or approval refers to | no customer name/lead/opportunity fields on the mission |
| `msn_d9aa3dac…` | 2026-09-07 17:23 | identical pattern: 3 succeeded R1 executions, no approval/outcome/revenue, **one real CRM contact update** on a different contact, also unlinked to any Console mission | same |
| `OL-001-M001` | 2026-09-07 06:22 | hand-seeded: a `mission_context` row (workflow `QUALIFY→INTERACT→FOLLOW_UP→OPPORTUNITY`, `lead_source` self-labelled `REAL_LEAD`, **no opportunity value, no realized revenue**); 1 succeeded R1 execution; **no CRM side effect recorded**; ordinal predates the Console's `missionOrdinal` | no approval, no outcome |

Read-together: all three predate the Console flags (first flagged mission is 2026-09-08 05:22), none produced revenue or outcomes, none needed approval. Two of them touched real CRM
contact records during bring-up, which is why "probably test" cannot be asserted from the database. I did not read those two contacts in the CRM (that was not part of the authorization); doing so
read-only (tags/date-added only, no names in any document) would likely settle it — say so if you want it.
**What the classification changes:** because none carries revenue, classifying them `production` would only add 3 zero-revenue missions to the OL-001 mission count and success-rate
denominators; `validation` leaves the KPIs at the 2 flagged production missions. The SQL ships them as `unverified` (excluded, listed) until you decide.

## 2. Unclassified-count indicator
- **View:** `ol_metrics.classification_health` (one row): `unclassified_count`, `oldest_unclassified_created_at`, `unverified_count`, `last_classification_change_at`.
  `ol_metrics.unclassified_missions` is the list (with the Console's flags shown as hints).
- **Script:** `providers/vps/scripts/report-unclassified-missions.sh` (read-only; `MAX_AGE_HOURS`, default 24): prints the counts and list; exit 1 if any mission has waited longer than the threshold,
  2 if it cannot query. Before the SQL is applied it reports "not installed" and exits 0 (run against production today to confirm). Tested on the scratch copy: 0 → 0/exit 0; a 30 h-old new mission →
  listed, exit 1 at 24 h, exit 0 at 48 h.
- **Not wired to a timer or ntfy** (a timer is a host change needing approval). Suggested: run it from the existing `aion-monitor` cadence or daily, and page on exit 1.

## 3. Classification procedure
1. Detect: `report-unclassified-missions.sh` (or `SELECT * FROM ol_metrics.unclassified_missions`).
2. Review the evidence (read-only): the mission's metadata flags, its executions, outcomes, and `external_side_effects` (as in §1).
3. Decide (the owner) one of `production` (real customer/revenue work), `validation` (pre-launch/bring-up with real tooling), `synthetic` (proof/fixture), `unverified` (undecided; excluded).
4. Record it — the single supported path, run on the host (owner/operator):
   ```
   docker exec aion-postgres-1 psql -U postgres -d aion_data -c \
     "SELECT ol_metrics.classify_mission('<mission_id>','production|validation|synthetic|unverified','<reason, ≥10 chars>','<the deciding person>')"
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
the *claimed* decider (the `classified_by` argument), the **database login** (`session_user`, not spoofable via the row) and the role in force, transaction id. The table is append-only —
UPDATE/DELETE raise even for the owner role, and TRUNCATE raises for the superuser (tested). The initial seeding of 10 rows is itself audited.
**Limits, honestly:** (a) everyone reaches the DB through shared logins, so the *human* identity is asserted by the operator, not authenticated; (b) the owner or a superuser can still
`ALTER TABLE … DISABLE TRIGGER`, drop the trigger, or set `session_replication_role=replica` (superuser) — that leaves no audit row of its own. Mitigation available today: the audit rows are in the hourly encrypted DB backups, so tampering shows as a
non-append-only diff between backups. A stronger design (per-person DB roles, or classification only through an authenticated runtime endpoint) is not built.

## 5. What approving the SQL changes (the consequence to accept)
- KPIs (`cohort_kpis`) drop from `OL-001: 10 missions` to **2** (the two Console-flagged production missions). Nothing is deleted; executions, approvals, outcomes and missions are untouched.
- A **new** production mission does **not** count in KPIs until someone classifies it (fail-closed by design). `unclassified_missions`/`classification_health` is the to-do list.
- `mission_record` no longer defaults every mission to cohort `OL-001` (5 show `pre_ol_validation`).
- Not idempotent (apply once); rollback restores the exact previous view definitions (md5-verified) and keeps the classification + audit tables as evidence. After a rollback, a re-apply requires dropping the kept tables and
  two audit functions first (commented in the rollback file).
- Test summary (scratch restore): apply OK; `cohort_kpis` 10→2; 10 audit INSERT rows written; permissions/audit/append-only checks as above; new mission listed and excluded; rollback → view definitions identical to baseline, 10 classification + 10 audit rows kept.

**Decision needed:** approve applying the SQL (yes/no), and per the three missions: production / validation / leave `unverified`.
