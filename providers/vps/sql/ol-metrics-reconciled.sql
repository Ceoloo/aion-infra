-- RECONCILED KPI / PROVENANCE CHANGE — PROPOSED, NOT APPLIED to production (needs owner approval).
-- Purpose: business-value reporting counts a record ONLY if it belongs to a mission that a person explicitly classified
-- 'production'. Everything else — validation runs, uncertain early missions (left unclassified), synthetic proofs, any future record — is
-- excluded BY DEFAULT, independent of naming, tenant id, metadata flags, or whether a mission row exists.
-- Nothing is deleted or altered in executions/approvals/outcomes/missions; history is preserved. The two existing views
-- keep their column lists (CREATE OR REPLACE). Rollback: ol-metrics-reconciled-rollback.sql (keeps the classification
-- table as evidence). Run as a superuser or aion_migrator via: psql -v ON_ERROR_STOP=1 -f <this file>  — safe to re-apply (IF NOT EXISTS / OR REPLACE / ON CONFLICT DO NOTHING)  (the file has its own BEGIN/COMMIT)
BEGIN;
SET LOCAL ROLE aion_migrator;   -- objects stay owned by the schema owner, like every existing ol_metrics object

-- 1. Explicit, auditable classification. Default for any mission NOT listed here = excluded AND listed in unclassified_missions.
--    Missions whose nature is uncertain are deliberately NOT seeded: they stay unclassified (excluded, visible) until a person decides.
CREATE TABLE IF NOT EXISTS ol_metrics.mission_classification (
  mission_id    text PRIMARY KEY REFERENCES public.missions(mission_id),
  data_class    text NOT NULL CHECK (data_class IN ('production','validation','synthetic')),
  reason        text NOT NULL CHECK (length(reason) > 0),
  classified_by text NOT NULL,
  classified_at timestamptz NOT NULL DEFAULT now()
);
-- ol_metrics has DEFAULT PRIVILEGES that auto-grant aion_app arw on new objects; classification is an owner decision,
-- so strip that and leave the runtime role read-only.
REVOKE ALL ON ol_metrics.mission_classification FROM aion_app;
GRANT SELECT ON ol_metrics.mission_classification TO aion_app;

-- 1b. Append-only audit of every classification change (insert/update/delete), written by a trigger so no writer can skip it.
--     Records the DATABASE role that connected (session_user — cannot be spoofed by the row), the role in force, the claimed
--     human (row.classified_by — asserted, not authenticated: everyone uses a shared DB login today), before/after values.
CREATE TABLE IF NOT EXISTS ol_metrics.mission_classification_audit (
  audit_id     bigserial PRIMARY KEY,
  changed_at   timestamptz NOT NULL DEFAULT clock_timestamp(),
  operation    text NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
  mission_id   text NOT NULL,
  old_class    text, new_class text,
  old_reason   text, new_reason text,
  claimed_by   text,
  session_role text NOT NULL DEFAULT session_user,
  effective_role text NOT NULL DEFAULT current_user,
  txid         bigint NOT NULL DEFAULT txid_current()
);
REVOKE ALL ON ol_metrics.mission_classification_audit FROM aion_app;
GRANT SELECT ON ol_metrics.mission_classification_audit TO aion_app;
CREATE OR REPLACE FUNCTION ol_metrics.audit_mission_classification() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN
  IF TG_OP = 'INSERT' THEN
    INSERT INTO ol_metrics.mission_classification_audit(operation, mission_id, new_class, new_reason, claimed_by)
      VALUES ('INSERT', NEW.mission_id, NEW.data_class, NEW.reason, NEW.classified_by);
  ELSIF TG_OP = 'UPDATE' THEN
    INSERT INTO ol_metrics.mission_classification_audit(operation, mission_id, old_class, new_class, old_reason, new_reason, claimed_by)
      VALUES ('UPDATE', NEW.mission_id, OLD.data_class, NEW.data_class, OLD.reason, NEW.reason, NEW.classified_by);
  ELSE
    INSERT INTO ol_metrics.mission_classification_audit(operation, mission_id, old_class, old_reason, claimed_by)
      VALUES ('DELETE', OLD.mission_id, OLD.data_class, OLD.reason, OLD.classified_by);
  END IF;
  RETURN NULL;
END $f$;
DROP TRIGGER IF EXISTS mission_classification_audit_trg ON ol_metrics.mission_classification;
CREATE TRIGGER mission_classification_audit_trg AFTER INSERT OR UPDATE OR DELETE ON ol_metrics.mission_classification
  FOR EACH ROW EXECUTE FUNCTION ol_metrics.audit_mission_classification();
CREATE OR REPLACE FUNCTION ol_metrics.audit_is_append_only() RETURNS trigger LANGUAGE plpgsql AS $f$
BEGIN RAISE EXCEPTION 'mission_classification_audit is append-only'; END $f$;
DROP TRIGGER IF EXISTS mission_classification_audit_ro ON ol_metrics.mission_classification_audit;
CREATE TRIGGER mission_classification_audit_ro BEFORE UPDATE OR DELETE ON ol_metrics.mission_classification_audit
  FOR EACH ROW EXECUTE FUNCTION ol_metrics.audit_is_append_only();
DROP TRIGGER IF EXISTS mission_classification_audit_ro_trunc ON ol_metrics.mission_classification_audit;
CREATE TRIGGER mission_classification_audit_ro_trunc BEFORE TRUNCATE ON ol_metrics.mission_classification_audit
  FOR EACH STATEMENT EXECUTE FUNCTION ol_metrics.audit_is_append_only();

-- 1c. The one supported way to classify: requires a non-empty reason and the name of the deciding person.
CREATE OR REPLACE FUNCTION ol_metrics.classify_mission(p_mission_id text, p_class text, p_reason text, p_decided_by text) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF coalesce(length(btrim(p_reason)),0) < 10 THEN RAISE EXCEPTION 'reason must be at least 10 characters'; END IF;
  IF coalesce(length(btrim(p_decided_by)),0) < 2 THEN RAISE EXCEPTION 'decided_by (the person) is required'; END IF;
  INSERT INTO ol_metrics.mission_classification(mission_id, data_class, reason, classified_by, classified_at)
    VALUES (p_mission_id, p_class, p_reason, p_decided_by, now())
  ON CONFLICT (mission_id) DO UPDATE SET data_class = EXCLUDED.data_class, reason = EXCLUDED.reason,
    classified_by = EXCLUDED.classified_by, classified_at = EXCLUDED.classified_at;
END $f$;
REVOKE ALL ON FUNCTION ol_metrics.classify_mission(text,text,text,text) FROM PUBLIC;   -- owner/superuser only; aion_app cannot execute it

INSERT INTO ol_metrics.mission_classification (mission_id, data_class, reason, classified_by) SELECT v.mission_id, v.data_class, v.reason, 'PROPOSED by audit 2026-09-20 from Console flags (asserted, not an authenticated person)'
FROM (VALUES
  ('msn_648d3df8-43f7-422f-b457-4f0bb63291f3','production','Console-launched OL-001 mission flagged productionEconomic=true, synthetic=false (2026-09-11). 13 executions, several failed. Owner to confirm it is a real lead attempt.'),
  ('msn_0e3c5c21-6bd4-4858-9232-032a399932d9','production','Console-launched OL-001 mission, launchMode=ol001_production, missionOrdinal 1, productionEconomic=true, synthetic=false (2026-09-12). One R2 approval still pending.'),
  ('msn_9eedcb95-45f5-457a-9680-9b14da913716','validation','pre_ol_validation cohort; Console flags productionEconomic=false (2026-09-08 pre-launch validation run).'),
  ('msn_db405716-0b9d-4823-8dc3-565c8e4689dd','validation','pre_ol_validation cohort; Console flags productionEconomic=false (2026-09-08 pre-launch validation run).'),
  ('msn_30fd4f95-6e33-4a6f-aab4-6524cdbf44ad','validation','pre_ol_validation cohort; Console flags productionEconomic=false (2026-09-08); one execution still awaiting approval.'),
  ('msn_eeb22b82-79cc-4f76-89f2-f430798b6a3c','validation','pre_ol_validation cohort; Console flags productionEconomic=false (2026-09-08 pre-launch validation run).'),
  ('msn_59c5efb6-d9eb-47ab-a70d-15607728f002','validation','pre_ol_validation cohort; Console flags productionEconomic=false (2026-09-08); one execution still awaiting approval.')
) AS v(mission_id, data_class, reason)
ON CONFLICT (mission_id) DO NOTHING;   -- re-apply after a rollback keeps any decision already recorded

-- 2. mission_record: cohort comes from the mission's own metadata, no silent default to 'OL-001'.
CREATE OR REPLACE VIEW ol_metrics.mission_record AS
 WITH ex AS (
         SELECT executions.mission_id,
            executions.tenant_id,
            count(*) AS agent_executions,
            min(executions.started_at) AS started_at,
            max(executions.completed_at) AS completed_at,
            count(*) FILTER (WHERE (executions.approval_id IS NOT NULL)) AS approvals_required,
            COALESCE(sum(((executions.cost ->> 'model'::text))::numeric), (0)::numeric) AS model_cost,
            COALESCE(sum(((executions.cost ->> 'tool'::text))::numeric), (0)::numeric) AS tool_cost,
            COALESCE(sum(((executions.cost ->> 'total'::text))::numeric), sum((COALESCE(((executions.cost ->> 'model'::text))::numeric, (0)::numeric) + COALESCE(((executions.cost ->> 'tool'::text))::numeric, (0)::numeric))), (0)::numeric) AS total_execution_cost,
            COALESCE(sum(executions.revenue_attributed), (0)::numeric) AS revenue_attributed
           FROM public.executions
          GROUP BY executions.mission_id, executions.tenant_id
        ), tc AS (
         SELECT telemetry_records.mission_id,
            count(*) AS tool_calls,
            COALESCE(sum(telemetry_records.cost), (0)::numeric) AS telemetry_cost
           FROM public.telemetry_records
          WHERE ((telemetry_records.tool_id IS NOT NULL) OR (telemetry_records.tool_used IS NOT NULL))
          GROUP BY telemetry_records.mission_id
        ), ev AS (
         SELECT evaluation_results.mission_id,
            avg(evaluation_results.quality_score) AS evaluation_score,
            bool_and(evaluation_results.success) AS all_execs_success,
            COALESCE(sum(evaluation_results.economic_value), (0)::double precision) AS economic_value_evald
           FROM public.evaluation_results
          GROUP BY evaluation_results.mission_id
        ), oc AS (
         SELECT outcomes.mission_id,
            sum(outcomes.value) FILTER (WHERE (outcomes.outcome_type = 'realized_revenue'::text)) AS realized_revenue_oc,
            max(outcomes.status) AS outcome_status,
            string_agg(DISTINCT outcomes.outcome_type, ','::text) AS outcome_types
           FROM public.outcomes
          GROUP BY outcomes.mission_id
        ), ap AS (
         SELECT approvals.mission_id,
            count(*) AS approvals_seen,
            count(*) FILTER (WHERE (approvals.status = 'granted'::text)) AS approvals_granted
           FROM public.approvals
          GROUP BY approvals.mission_id
        ), se AS (
         SELECT external_side_effects.execution_id,
            count(*) AS n
           FROM public.external_side_effects
          GROUP BY external_side_effects.execution_id
        ), sef AS (
         SELECT e.mission_id,
            count(*) AS artifacts_created,
            count(*) FILTER (WHERE (ese.status <> 'succeeded'::text)) AS side_effect_failures,
            string_agg(DISTINCT ese.error_code, ','::text) FILTER (WHERE (ese.error_code IS NOT NULL)) AS failure_reasons
           FROM (public.external_side_effects ese
             JOIN public.executions e USING (execution_id))
          GROUP BY e.mission_id
        ), iv AS (
         SELECT mission_interventions.mission_id,
            count(*) AS human_interventions,
            COALESCE(sum(mission_interventions.human_minutes), (0)::numeric) AS human_minutes,
            mode() WITHIN GROUP (ORDER BY mission_interventions.category) AS top_intervention_category,
            string_agg(DISTINCT mission_interventions.category, ','::text) AS intervention_categories
           FROM ol_metrics.mission_interventions
          GROUP BY mission_interventions.mission_id
        )
 SELECT m.mission_id,
    ex.tenant_id,
    COALESCE(mc.workflow, (m.metadata ->> 'workflow'::text)) AS workflow,
    COALESCE(mc.lead_source, (m.metadata ->> 'lead_source'::text)) AS lead_source,
    COALESCE(mc.cohort, (m.metadata ->> 'cohort'::text), 'UNASSIGNED'::text) AS cohort,
    ex.started_at,
    ex.completed_at,
    m.status,
    COALESCE(oc.outcome_status, m.status) AS outcome,
    sef.failure_reasons AS failure_reason,
    COALESCE(iv.human_interventions, (0)::bigint) AS human_interventions,
    COALESCE(iv.human_minutes, (0)::numeric) AS human_minutes,
    COALESCE(iv.top_intervention_category, 'NONE'::text) AS top_intervention_category,
    COALESCE(ex.agent_executions, (0)::bigint) AS agent_executions,
    COALESCE(tc.tool_calls, (0)::bigint) AS tool_calls,
    ex.model_cost,
    ex.tool_cost,
    ex.total_execution_cost,
    mc.opportunity_value,
    COALESCE(mc.realized_revenue, oc.realized_revenue_oc, (0)::numeric) AS realized_revenue,
    (COALESCE(mc.realized_revenue, oc.realized_revenue_oc, ex.revenue_attributed, (0)::numeric) - ex.total_execution_cost) AS economic_value,
    EXTRACT(epoch FROM (ex.completed_at - ex.started_at)) AS execution_duration_s,
    ((m.status = 'completed'::text) AND COALESCE(ev.all_execs_success, true) AND (COALESCE(sef.side_effect_failures, (0)::bigint) = 0)) AS success,
    COALESCE(sef.artifacts_created, (0)::bigint) AS artifacts_created,
    COALESCE(ap.approvals_seen, ex.approvals_required, (0)::bigint) AS approvals_required,
    COALESCE(ap.approvals_granted, (0)::bigint) AS approvals_granted,
    ev.evaluation_score,
    mc.lessons
   FROM ((((((((public.missions m
     LEFT JOIN ex ON ((ex.mission_id = m.mission_id)))
     LEFT JOIN tc ON ((tc.mission_id = m.mission_id)))
     LEFT JOIN ev ON ((ev.mission_id = m.mission_id)))
     LEFT JOIN oc ON ((oc.mission_id = m.mission_id)))
     LEFT JOIN ap ON ((ap.mission_id = m.mission_id)))
     LEFT JOIN sef ON ((sef.mission_id = m.mission_id)))
     LEFT JOIN iv ON ((iv.mission_id = m.mission_id)))
     LEFT JOIN ol_metrics.mission_context mc ON ((mc.mission_id = m.mission_id)));

-- 3. cohort_kpis (business-value KPIs): only explicitly production-classified missions.
CREATE OR REPLACE VIEW ol_metrics.cohort_kpis AS
 SELECT cohort,
    count(*) AS missions_completed,
    count(*) FILTER (WHERE success) AS successful_missions,
    round(((100.0 * (count(*) FILTER (WHERE success))::numeric) / (NULLIF(count(*), 0))::numeric), 1) AS mission_success_rate_pct,
    round(((100.0 * (count(*) FILTER (WHERE (human_interventions > 0)))::numeric) / (NULLIF(count(*), 0))::numeric), 1) AS human_intervention_rate_pct,
    round(avg(human_minutes), 1) AS human_minutes_per_mission,
    round(((100.0 * (count(*) FILTER (WHERE (NOT success)))::numeric) / (NULLIF(count(*), 0))::numeric), 1) AS failure_rate_pct,
    round(avg(total_execution_cost), 4) AS avg_cost_per_mission,
    round(avg(economic_value), 2) AS avg_economic_value_per_execution,
    round((sum(economic_value) / NULLIF(sum(total_execution_cost), (0)::numeric)), 2) AS ev_per_execution_cost,
    round((sum(human_minutes) / NULLIF((sum(economic_value) / 1000.0), (0)::numeric)), 2) AS human_minutes_per_1k_ev
   FROM ol_metrics.mission_record
  WHERE mission_id IN ( SELECT mission_id FROM ol_metrics.mission_classification WHERE data_class = 'production')
  GROUP BY cohort;

-- 4. Record-level ledger so value rows are judged on provenance, not on whether a mission was created.
--    Sum business value ONLY over: SELECT ... FROM ol_metrics.business_value_ledger WHERE counts_as_business_value.
--    (revenue_attributed rows are attribution, not realized revenue; filter status/outcome_type as needed.)
CREATE OR REPLACE VIEW ol_metrics.business_value_ledger AS
SELECT u.source, u.record_id, u.run_id, u.mission_id, u.tenant_id, u.status, u.outcome_type, u.amount, u.currency,
       COALESCE(c.data_class, 'unclassified') AS data_class,
       COALESCE(c.data_class = 'production', false) AS counts_as_business_value
FROM (
  SELECT 'outcome'::text AS source, o.outcome_id AS record_id, o.run_id,
         COALESCE(o.mission_id, (SELECT x.mission_id FROM public.executions x WHERE x.run_id = o.run_id AND x.mission_id IS NOT NULL LIMIT 1)) AS mission_id,
         (SELECT x.tenant_id FROM public.executions x WHERE x.run_id = o.run_id ORDER BY x.created_at LIMIT 1) AS tenant_id,
         o.status, o.outcome_type, o.value AS amount, o.currency
    FROM public.outcomes o WHERE o.value IS NOT NULL
  UNION ALL
  SELECT 'execution', e.execution_id, e.run_id, e.mission_id, e.tenant_id, e.status, 'revenue_attributed', e.revenue_attributed, NULL::text
    FROM public.executions e WHERE e.revenue_attributed IS NOT NULL
) u LEFT JOIN ol_metrics.mission_classification c ON c.mission_id = u.mission_id;
REVOKE ALL ON ol_metrics.business_value_ledger FROM aion_app;
GRANT SELECT ON ol_metrics.business_value_ledger TO aion_app;

-- 5. Visibility: nothing silently drops out of reporting — unclassified missions are listed for an owner to classify.
CREATE OR REPLACE VIEW ol_metrics.unclassified_missions AS
SELECT m.mission_id, m.created_at, m.status, m.metadata ->> 'cohort' AS cohort_hint,
       m.metadata ->> 'productionEconomic' AS console_production_flag, m.metadata ->> 'synthetic' AS console_synthetic_flag
FROM public.missions m LEFT JOIN ol_metrics.mission_classification c USING (mission_id) WHERE c.mission_id IS NULL;
REVOKE ALL ON ol_metrics.unclassified_missions FROM aion_app;
GRANT SELECT ON ol_metrics.unclassified_missions TO aion_app;

-- 6. One-row health indicator for monitoring/dashboards: how many missions await classification, how old, when last changed.
CREATE OR REPLACE VIEW ol_metrics.classification_health AS
SELECT (SELECT count(*) FROM ol_metrics.unclassified_missions)                    AS unclassified_count,
       (SELECT min(created_at) FROM ol_metrics.unclassified_missions)             AS oldest_unclassified_created_at,
       (SELECT max(changed_at) FROM ol_metrics.mission_classification_audit)      AS last_classification_change_at;
REVOKE ALL ON ol_metrics.classification_health FROM aion_app;
GRANT SELECT ON ol_metrics.classification_health TO aion_app;
COMMIT;
