-- ROLLBACK of ol-metrics-reconciled.sql: restores the exact pre-change view definitions (captured 2026-09-20 from
-- /opt/aion/ol-metrics.schema.sql) and drops only the two views this change added. The classification TABLE is
-- deliberately KEPT as evidence of what was decided (nothing references it after rollback). To remove it too, run
-- the commented DROP by hand.
BEGIN;
SET LOCAL ROLE aion_migrator;
DROP VIEW IF EXISTS ol_metrics.classification_health;
DROP VIEW IF EXISTS ol_metrics.unclassified_missions;
DROP FUNCTION IF EXISTS ol_metrics.classify_mission(text,text,text,text);
DROP VIEW IF EXISTS ol_metrics.business_value_ledger;
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
    COALESCE(mc.cohort, 'OL-001'::text) AS cohort,
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
  GROUP BY cohort;
-- The audit table + triggers are kept too (evidence; the audit table is append-only). To remove everything by hand:
-- DROP TABLE ol_metrics.mission_classification_audit; DROP TABLE ol_metrics.mission_classification;
-- DROP FUNCTION ol_metrics.audit_mission_classification(); DROP FUNCTION ol_metrics.audit_is_append_only();
-- (old line) DROP TABLE ol_metrics.mission_classification;   -- only if you also want the classification evidence gone
COMMIT;
