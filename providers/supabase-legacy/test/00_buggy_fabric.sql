-- Minimal live-shaped revex fabric that reproduces AIO-116/117/118.
-- Not a full dump — only the tables/functions the hotfix touches.

create extension if not exists pgcrypto;

create table public.events (
  id uuid primary key default gen_random_uuid(),
  correlation_id text not null,
  event_type text not null,
  department text not null default 'Revenue',
  agent_name text,
  workflow_name text default 'revex_30d',
  severity text not null default 'info',
  status text not null default 'open',
  trigger_source text default 'revex',
  environment text not null default 'production',
  title text not null,
  description text,
  recommended_action text,
  owner text default 'CEO Office',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.revenue_leads (
  id uuid primary key default gen_random_uuid(),
  lead_id text not null unique,
  company text,
  status text not null default 'New',
  pipeline_stage text not null default 'READY_FOR_OUTREACH',
  updated_at timestamptz not null default now()
);

create table public.revenue_events (
  id uuid primary key default gen_random_uuid(),
  revenue_event_id text not null unique,
  lead_id text,
  amount numeric not null default 0,
  mrr_impact numeric not null default 0,
  revenue_status text not null default 'pending',
  evidence_type text,
  evidence_ref text,
  verified_by text,
  collected_at timestamptz
);

create table public.revex_daily_metrics (
  day date primary key,
  touches numeric not null default 0,
  revenue_collected numeric not null default 0,
  mrr_collected numeric not null default 0
);

create table public.revex_actor_tools (
  actor_id text not null,
  tool text not null,
  prohibited boolean not null default false,
  primary key (actor_id, tool)
);

create table public.revex_outreach (
  id uuid primary key default gen_random_uuid(),
  lead_id text not null references public.revenue_leads (lead_id),
  channel text not null,
  direction text not null default 'outbound',
  outcome text not null default 'drafted',
  subject text,
  actor_id text,
  source text,
  evidence_ref text,
  attested_by text,
  recorded_by text,
  superseded_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

create or replace function public.revex_emit_event(
  p_event_type text,
  p_title text,
  p_description text default null,
  p_agent_name text default null,
  p_lead_id text default null,
  p_severity text default 'info',
  p_recommended_action text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.events (
    correlation_id, event_type, department, agent_name, workflow_name,
    severity, status, trigger_source, environment, title, description,
    recommended_action, owner, metadata
  ) values (
    coalesce(p_lead_id, gen_random_uuid()::text), p_event_type, 'Revenue',
    p_agent_name, 'revex_30d', p_severity, 'open', 'revex', 'production',
    p_title, p_description, p_recommended_action, 'CEO Office',
    jsonb_build_object('lead_id', p_lead_id, 'fabric', 'revex')
  ) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.revex_actor_has_prohibition(p_actor_id text, p_tool text)
returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
    select 1 from public.revex_actor_tools t
     where t.actor_id = p_actor_id
       and t.tool = p_tool
       and t.prohibited
  );
$$;

create or replace function public.revex_bump_daily(p_metric text, p_amount numeric default 1)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.revex_daily_metrics as m (day, touches, revenue_collected, mrr_collected)
  values (
    current_date,
    case when p_metric = 'touches' then p_amount else 0 end,
    case when p_metric = 'revenue_collected' then p_amount else 0 end,
    case when p_metric = 'mrr_collected' then p_amount else 0 end
  )
  on conflict (day) do update set
    touches = m.touches + excluded.touches,
    revenue_collected = m.revenue_collected + excluded.revenue_collected,
    mrr_collected = m.mrr_collected + excluded.mrr_collected;
end;
$$;

-- BUG AIO-116: agents cannot log CEO-attested email sends.
create or replace function public.revex_log_outreach(
  p_lead_id text,
  p_channel text,
  p_direction text default 'outbound',
  p_outcome text default 'drafted',
  p_subject text default null,
  p_actor_id text default 'followup_worker_01',
  p_source text default 'revex_outreach',
  p_evidence_ref text default null
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not exists (select 1 from public.revenue_leads where lead_id = p_lead_id) then
    raise exception 'unknown lead_id %', p_lead_id;
  end if;

  if p_channel = 'email' and p_outcome = 'sent'
     and public.revex_actor_has_prohibition(p_actor_id, 'gmail.send') then
    raise exception 'gmail.send is prohibited for %; log drafted and escalate', p_actor_id;
  end if;

  -- BUG AIO-118: insert-only; never resolves prior drafted rows.
  insert into public.revex_outreach (
    lead_id, channel, direction, outcome, subject, actor_id, source, evidence_ref
  ) values (
    p_lead_id, p_channel, p_direction, p_outcome, p_subject, p_actor_id, p_source, p_evidence_ref
  ) returning id into v_id;

  if p_outcome = 'sent' then
    perform public.revex_bump_daily('touches', 1);
  end if;

  return v_id;
end;
$$;

-- BUG AIO-117: unknown id still emits revenue.collected; re-collect double-counts.
create or replace function public.revex_mark_collected(
  p_revenue_event_id text,
  p_evidence_type text,
  p_evidence_ref text,
  p_verified_by text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric;
  v_mrr numeric;
  v_lead text;
begin
  update public.revenue_events
     set revenue_status = 'collected',
         evidence_type = p_evidence_type,
         evidence_ref = p_evidence_ref,
         verified_by = p_verified_by,
         collected_at = now()
   where revenue_event_id = p_revenue_event_id
  returning amount, mrr_impact, lead_id into v_amount, v_mrr, v_lead;

  -- no IF NOT FOUND
  perform public.revex_bump_daily('revenue_collected', coalesce(v_amount, 0));
  perform public.revex_bump_daily('mrr_collected', coalesce(v_mrr, 0));
  perform public.revex_emit_event(
    'revenue.collected',
    'Payment verified',
    p_revenue_event_id,
    p_verified_by,
    v_lead,
    'info',
    null
  );
end;
$$;

create or replace view public.revex_ceo_waiting_on_human as
  select 'draft_to_send'::text as wait_type,
         o.id::text as wait_id,
         o.lead_id,
         l.company,
         o.subject,
         o.created_at
    from public.revex_outreach o
    join public.revenue_leads l on l.lead_id = o.lead_id
   where o.outcome = 'drafted';

-- Seed: agent prohibited from gmail.send; one lead; one draft; one pending revenue event.
insert into public.revex_actor_tools (actor_id, tool, prohibited)
values ('followup_worker_01', 'gmail.send', true);

insert into public.revenue_leads (lead_id, company, pipeline_stage)
values ('LEAD-1', 'Acme HVAC', 'READY_FOR_OUTREACH');

insert into public.revex_outreach (lead_id, channel, direction, outcome, subject, actor_id, source, created_at)
values (
  'LEAD-1', 'email', 'outbound', 'drafted', 'Intro for Acme',
  'followup_worker_01', 'revex_outreach', timestamptz '2026-09-21 12:00:00+00'
);

insert into public.revenue_events (revenue_event_id, lead_id, amount, mrr_impact, revenue_status)
values ('REV-1', 'LEAD-1', 1500, 500, 'pending');
