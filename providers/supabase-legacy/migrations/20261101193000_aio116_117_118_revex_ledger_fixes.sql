-- AIO-116 / AIO-117 / AIO-118 — revex ledger integrity hotfixes
-- Target: live Supabase project qbahthzqvxytfgobgtxa (AION EMPIRE SYSTEM)
-- Also applied by providers/supabase-legacy/test/run-ledger-fix-tests.sh
--
-- Before live apply: dump pg_get_functiondef for revex_log_outreach,
-- revex_mark_collected, and the view revex_ceo_waiting_on_human
-- (see scripts/capture-live-revex-defs.sh).

begin;

-- ---------------------------------------------------------------------------
-- Schema columns used by attested send + draft resolution (AIO-116 / AIO-118)
-- ---------------------------------------------------------------------------
alter table public.revex_outreach
  add column if not exists evidence_ref text,
  add column if not exists attested_by text,
  add column if not exists recorded_by text,
  add column if not exists superseded_by uuid,
  add column if not exists resolved_at timestamptz;

alter table public.revenue_events
  add column if not exists amount numeric not null default 0,
  add column if not exists mrr_impact numeric not null default 0,
  add column if not exists evidence_type text,
  add column if not exists evidence_ref text,
  add column if not exists collected_at timestamptz;

create unique index if not exists revex_outreach_evidence_ref_uidx
  on public.revex_outreach (evidence_ref)
  where evidence_ref is not null;

-- ---------------------------------------------------------------------------
-- Shared helper: resolve open drafts for a lead+channel (AIO-118)
-- ---------------------------------------------------------------------------
create or replace function public.revex_resolve_open_drafts(
  p_lead_id text,
  p_channel text,
  p_successor_id uuid
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_n int;
begin
  update public.revex_outreach o
     set superseded_by = p_successor_id,
         resolved_at = coalesce(o.resolved_at, now())
   where o.lead_id = p_lead_id
     and o.channel = p_channel
     and o.outcome = 'drafted'
     and o.resolved_at is null
     and o.id is distinct from p_successor_id;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

revoke all on function public.revex_resolve_open_drafts(text, text, uuid) from public, anon;
grant execute on function public.revex_resolve_open_drafts(text, text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- AIO-116: attested send path (human sent; agent records with evidence)
-- ---------------------------------------------------------------------------
create or replace function public.revex_log_attested_send(
  p_lead_id text,
  p_channel text,
  p_occurred_at timestamptz,
  p_evidence_ref text,
  p_attested_by text default 'human_operator',
  p_recorded_by text default 'followup_worker_01',
  p_subject text default null,
  p_source text default 'revex_attested_send'
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing uuid;
  v_id uuid;
  v_resolved int;
begin
  if p_lead_id is null or btrim(p_lead_id) = '' then
    raise exception 'lead_id required';
  end if;
  if p_channel is null or btrim(p_channel) = '' then
    raise exception 'channel required';
  end if;
  if p_evidence_ref is null or btrim(p_evidence_ref) = '' then
    raise exception 'evidence_ref required for attested send';
  end if;
  if p_attested_by is null or btrim(p_attested_by) = '' then
    raise exception 'attested_by required';
  end if;
  if not exists (select 1 from public.revenue_leads where lead_id = p_lead_id) then
    raise exception 'unknown lead_id %', p_lead_id;
  end if;

  -- Idempotent on evidence_ref (e.g. Gmail message id).
  select id into v_existing
    from public.revex_outreach
   where evidence_ref = p_evidence_ref
   limit 1;
  if found then
    return jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'id', v_existing,
      'lead_id', p_lead_id,
      'outcome', 'sent',
      'evidence_ref', p_evidence_ref
    );
  end if;

  insert into public.revex_outreach (
    lead_id, channel, direction, outcome, subject,
    actor_id, source, evidence_ref, attested_by, recorded_by, created_at
  ) values (
    p_lead_id,
    p_channel,
    'outbound',
    'sent',
    p_subject,
    p_attested_by,          -- actor = human who sent
    p_source,
    p_evidence_ref,
    p_attested_by,
    p_recorded_by,          -- recorder = agent that logged it
    coalesce(p_occurred_at, now())
  ) returning id into v_id;

  v_resolved := public.revex_resolve_open_drafts(p_lead_id, p_channel, v_id);
  perform public.revex_bump_daily('touches', 1);
  perform public.revex_emit_event(
    'outreach.attested_sent',
    format('Attested %s send', p_channel),
    p_evidence_ref,
    p_recorded_by,
    p_lead_id,
    'info',
    null
  );

  return jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'id', v_id,
    'lead_id', p_lead_id,
    'outcome', 'sent',
    'evidence_ref', p_evidence_ref,
    'attested_by', p_attested_by,
    'recorded_by', p_recorded_by,
    'drafts_resolved', v_resolved
  );
end;
$$;

revoke all on function public.revex_log_attested_send(text, text, timestamptz, text, text, text, text, text)
  from public, anon;
grant execute on function public.revex_log_attested_send(text, text, timestamptz, text, text, text, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- AIO-118 (+ partial AIO-116): replace revex_log_outreach
-- Signature matches the live call shape documented in AIO-116. Agent email+sent
-- prohibition is preserved; non-draft outcomes resolve open drafts.
--
-- DROP first so a divergent live arity cannot leave the buggy overload callable.
-- If capture-live-revex-defs.sh shows a different argument list, stop and reconcile
-- before re-applying.
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'revex_log_outreach'
  loop
    execute format('drop function if exists %s', r.sig);
  end loop;
end;
$$;

create function public.revex_log_outreach(
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
  if p_lead_id is null or btrim(p_lead_id) = '' then
    raise exception 'lead_id required';
  end if;
  if not exists (select 1 from public.revenue_leads where lead_id = p_lead_id) then
    raise exception 'unknown lead_id %', p_lead_id;
  end if;

  -- Agents still cannot claim they sent email themselves.
  if p_channel = 'email' and p_outcome = 'sent'
     and public.revex_actor_has_prohibition(p_actor_id, 'gmail.send') then
    raise exception 'gmail.send is prohibited for %; use revex_log_attested_send for CEO/human sends', p_actor_id;
  end if;

  insert into public.revex_outreach (
    lead_id, channel, direction, outcome, subject, actor_id, source, evidence_ref
  ) values (
    p_lead_id, p_channel, coalesce(p_direction, 'outbound'), coalesce(p_outcome, 'drafted'),
    p_subject, p_actor_id, p_source, p_evidence_ref
  ) returning id into v_id;

  if coalesce(p_outcome, 'drafted') is distinct from 'drafted' then
    perform public.revex_resolve_open_drafts(p_lead_id, p_channel, v_id);
  end if;

  if p_outcome = 'sent' then
    perform public.revex_bump_daily('touches', 1);
  end if;

  return v_id;
end;
$$;

revoke all on function public.revex_log_outreach(text, text, text, text, text, text, text, text)
  from public, anon;
grant execute on function public.revex_log_outreach(text, text, text, text, text, text, text, text)
  to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- AIO-118: harden CEO waits view + backfill historical drafts
-- ---------------------------------------------------------------------------
create or replace view public.revex_ceo_waiting_on_human as
  select 'draft_to_send'::text as wait_type,
         o.id::text as wait_id,
         o.lead_id,
         l.company,
         o.subject,
         o.created_at
    from public.revex_outreach o
    join public.revenue_leads l on l.lead_id = o.lead_id
   where o.outcome = 'drafted'
     and o.resolved_at is null
     and not exists (
       select 1
         from public.revex_outreach later
        where later.lead_id = o.lead_id
          and later.channel = o.channel
          and later.outcome is distinct from 'drafted'
          and later.created_at >= o.created_at
          and later.id is distinct from o.id
     );

-- One-time backfill: drafts that already have a later non-draft on same lead+channel.
update public.revex_outreach o
   set resolved_at = coalesce(o.resolved_at, now()),
       superseded_by = coalesce(
         o.superseded_by,
         (
           select later.id
             from public.revex_outreach later
            where later.lead_id = o.lead_id
              and later.channel = o.channel
              and later.outcome is distinct from 'drafted'
              and later.created_at >= o.created_at
              and later.id is distinct from o.id
            order by later.created_at asc
            limit 1
         )
       )
 where o.outcome = 'drafted'
   and o.resolved_at is null
   and exists (
     select 1
       from public.revex_outreach later
      where later.lead_id = o.lead_id
        and later.channel = o.channel
        and later.outcome is distinct from 'drafted'
        and later.created_at >= o.created_at
        and later.id is distinct from o.id
   );

-- ---------------------------------------------------------------------------
-- AIO-117: mark_collected — fail closed, idempotent, return jsonb
-- Return type change requires drop (Postgres cannot OR REPLACE void → jsonb).
-- ---------------------------------------------------------------------------
drop function if exists public.revex_mark_collected(text, text, text, text);

create function public.revex_mark_collected(
  p_revenue_event_id text,
  p_evidence_type text,
  p_evidence_ref text,
  p_verified_by text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_amount numeric;
  v_mrr numeric;
  v_lead text;
  v_status text;
  v_id text;
begin
  if p_revenue_event_id is null or btrim(p_revenue_event_id) = '' then
    raise exception 'revenue_event_id required';
  end if;

  select revenue_event_id, amount, mrr_impact, lead_id, revenue_status
    into v_id, v_amount, v_mrr, v_lead, v_status
    from public.revenue_events
   where revenue_event_id = p_revenue_event_id
   for update;

  if not found then
    raise exception 'unknown revenue_event_id %', p_revenue_event_id;
  end if;

  -- Idempotent: already collected → no metrics bump, no second event.
  if v_status = 'collected' then
    return jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'revenue_event_id', v_id,
      'lead_id', v_lead,
      'amount', v_amount,
      'mrr_impact', v_mrr,
      'revenue_status', v_status
    );
  end if;

  update public.revenue_events
     set revenue_status = 'collected',
         evidence_type = p_evidence_type,
         evidence_ref = p_evidence_ref,
         verified_by = p_verified_by,
         collected_at = now()
   where revenue_event_id = p_revenue_event_id
  returning amount, mrr_impact, lead_id, revenue_status
    into v_amount, v_mrr, v_lead, v_status;

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

  return jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'revenue_event_id', p_revenue_event_id,
    'lead_id', v_lead,
    'amount', v_amount,
    'mrr_impact', v_mrr,
    'revenue_status', v_status,
    'verified_by', p_verified_by,
    'evidence_type', p_evidence_type,
    'evidence_ref', p_evidence_ref
  );
end;
$$;

revoke all on function public.revex_mark_collected(text, text, text, text)
  from public, anon, authenticated;
grant execute on function public.revex_mark_collected(text, text, text, text)
  to service_role;

commit;
