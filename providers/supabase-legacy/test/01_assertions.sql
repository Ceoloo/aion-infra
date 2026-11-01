-- Assertions run after the hotfix migration. Fail via RAISE EXCEPTION.

do $$
declare
  v_err text;
  v_id uuid;
  v_json jsonb;
  v_waits int;
  v_touches numeric;
  v_collected numeric;
  v_events int;
begin
  -- AIO-116: agent still blocked from claiming email+sent via revex_log_outreach
  begin
    perform public.revex_log_outreach(
      'LEAD-1', 'email', 'outbound', 'sent', 'should fail',
      'followup_worker_01', 'revex_outreach', null
    );
    raise exception 'AIO-116 FAIL: agent email+sent should still raise';
  exception
    when raise_exception then
      get stacked diagnostics v_err = message_text;
      if v_err not like '%gmail.send is prohibited%' and v_err not like '%revex_log_attested_send%' then
        raise exception 'AIO-116 FAIL: unexpected error: %', v_err;
      end if;
  end;

  -- AIO-116: attested path logs send as human actor, bumps touches
  v_json := public.revex_log_attested_send(
    'LEAD-1',
    'email',
    timestamptz '2026-11-01 15:00:00+00',
    'gmail-msg-001',
    'human_operator',
    'followup_worker_01',
    'Intro for Acme',
    'revex_attested_send'
  );
  if coalesce((v_json->>'ok')::boolean, false) is not true then
    raise exception 'AIO-116 FAIL: attested send not ok: %', v_json;
  end if;
  if coalesce((v_json->>'idempotent')::boolean, true) is not false then
    raise exception 'AIO-116 FAIL: first attested send should not be idempotent';
  end if;

  -- Idempotent on evidence_ref
  v_json := public.revex_log_attested_send(
    'LEAD-1', 'email', now(), 'gmail-msg-001',
    'human_operator', 'followup_worker_01', 'Intro for Acme', 'revex_attested_send'
  );
  if coalesce((v_json->>'idempotent')::boolean, false) is not true then
    raise exception 'AIO-116 FAIL: second attested send should be idempotent';
  end if;

  select touches into v_touches from public.revex_daily_metrics where day = current_date;
  if coalesce(v_touches, 0) <> 1 then
    raise exception 'AIO-116 FAIL: expected 1 touch after attested send, got %', v_touches;
  end if;

  -- AIO-118: draft wait cleared
  select count(*) into v_waits from public.revex_ceo_waiting_on_human where lead_id = 'LEAD-1';
  if v_waits <> 0 then
    raise exception 'AIO-118 FAIL: CEO waits should be empty after attested send, got %', v_waits;
  end if;

  select count(*) into v_waits
    from public.revex_outreach
   where lead_id = 'LEAD-1' and outcome = 'drafted' and resolved_at is null;
  if v_waits <> 0 then
    raise exception 'AIO-118 FAIL: open drafts remain: %', v_waits;
  end if;

  -- AIO-117: unknown id fails closed (no event)
  begin
    perform public.revex_mark_collected('REV-DOES-NOT-EXIST', 'bank', 'ref-x', 'human_operator');
    raise exception 'AIO-117 FAIL: unknown id should raise';
  exception
    when raise_exception then
      get stacked diagnostics v_err = message_text;
      if v_err not like 'unknown revenue_event_id%' then
        raise exception 'AIO-117 FAIL: unexpected error: %', v_err;
      end if;
  end;

  select count(*) into v_events from public.events where event_type = 'revenue.collected';
  if v_events <> 0 then
    raise exception 'AIO-117 FAIL: false revenue.collected emitted for unknown id';
  end if;

  -- AIO-117: real collect works and returns jsonb
  v_json := public.revex_mark_collected('REV-1', 'bank', 'wire-1', 'human_operator');
  if coalesce((v_json->>'ok')::boolean, false) is not true
     or coalesce((v_json->>'idempotent')::boolean, true) is not false then
    raise exception 'AIO-117 FAIL: first collect bad payload: %', v_json;
  end if;

  select revenue_collected into v_collected from public.revex_daily_metrics where day = current_date;
  if coalesce(v_collected, 0) <> 1500 then
    raise exception 'AIO-117 FAIL: expected revenue_collected=1500, got %', v_collected;
  end if;

  select count(*) into v_events from public.events where event_type = 'revenue.collected';
  if v_events <> 1 then
    raise exception 'AIO-117 FAIL: expected 1 revenue.collected event, got %', v_events;
  end if;

  -- AIO-117: re-collect is idempotent (no double count / no second event)
  v_json := public.revex_mark_collected('REV-1', 'bank', 'wire-1', 'human_operator');
  if coalesce((v_json->>'idempotent')::boolean, false) is not true then
    raise exception 'AIO-117 FAIL: re-collect should be idempotent: %', v_json;
  end if;

  select revenue_collected into v_collected from public.revex_daily_metrics where day = current_date;
  if coalesce(v_collected, 0) <> 1500 then
    raise exception 'AIO-117 FAIL: double-counted revenue_collected=%', v_collected;
  end if;

  select count(*) into v_events from public.events where event_type = 'revenue.collected';
  if v_events <> 1 then
    raise exception 'AIO-117 FAIL: duplicate revenue.collected events: %', v_events;
  end if;

  raise notice 'AIO-116/117/118 ledger fix assertions PASS';
end;
$$;
