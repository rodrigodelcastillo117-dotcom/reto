-- ISS126 WASTED / RESULT_EVENT BACKEND GATE — DISPOSABLE ONLY
-- Covers: real parlay trigger, stable retry idempotence, correction/reversal,
-- out-of-order fail-close, current-learning label, VOID exclusion, immutable history,
-- app recovery ack, push request dedupe and no-subscription skip.

begin;

-- 1) Real trigger path + chain semantics.
insert into public.parlays(id,apodo,fecha,picks_data,apuesta,momio_total,resultado,ganancia_neta,updated_at)
values('88888888-8888-4888-8888-888888888888','audit_chain',current_date,'[]'::jsonb,
       100,2.5,'pendiente',0,'2026-09-12 13:00:00+00');
update public.parlays set resultado='perdido',ganancia_neta=-100,updated_at='2026-09-12 13:05:00+00'
where id='88888888-8888-4888-8888-888888888888';
update public.parlays set resultado='pendiente',ganancia_neta=0,updated_at='2026-09-12 13:06:00+00'
where id='88888888-8888-4888-8888-888888888888';
update public.parlays set resultado='ganado',ganancia_neta=150,updated_at='2026-09-12 13:07:00+00'
where id='88888888-8888-4888-8888-888888888888';
update public.parlays set resultado='perdido',ganancia_neta=-100,updated_at='2026-09-12 13:08:00+00'
where id='88888888-8888-4888-8888-888888888888';

DO $$
DECLARE n int;r record;
BEGIN
  select count(*) into n from public.result_events
  where entity_id='88888888-8888-4888-8888-888888888888';
  if n<>4 then raise exception 'TRIGGER_CHAIN_COUNT=% expected=4',n; end if;

  select * into r from public.v_result_event_current
  where entity_id='88888888-8888-4888-8888-888888888888';
  if r.to_status<>'perdido' or r.outcome<>'lost' or r.event_kind<>'result_correction' then
    raise exception 'CURRENT_RESULT_BAD %/%/%',r.to_status,r.outcome,r.event_kind;
  end if;
  select count(*) into n from public.v_result_events_learning_current
  where entity_id='88888888-8888-4888-8888-888888888888';
  if n<>1 then raise exception 'LEARNING_CURRENT_COUNT=% expected=1',n; end if;
END $$;

-- 2) Stable retry and stale/out-of-order rejection.
DO $$
DECLARE pid uuid:='33333333-3333-4333-8333-333333333333';e1 uuid;e2 uuid;n int;
BEGIN
  e1:=public.fn_record_parlay_result_event(pid,'audit_retry','pendiente','perdido',100,-100,2.5,'[]',
       '2026-09-12 10:00:00+00','audit');
  e2:=public.fn_record_parlay_result_event(pid,'audit_retry','pendiente','perdido',100,-100,2.5,'[]',
       '2026-09-12 10:00:00+00','retry_different_source');
  if e1 is distinct from e2 then raise exception 'IDEMPOTENT_RETRY_FAIL'; end if;
  select count(*) into n from public.result_events where entity_id=pid::text;
  if n<>1 then raise exception 'IDEMPOTENT_RETRY_COUNT=%',n; end if;

  perform public.fn_record_parlay_result_event(pid,'audit_retry','perdido','ganado',100,150,2.5,'[]',
       '2026-09-12 10:10:00+00','correction');

  begin
    perform public.fn_record_parlay_result_event(pid,'audit_retry','ganado','perdido',100,-100,2.5,'[]',
      '2026-09-12 10:05:00+00','stale_time');
    raise exception 'OUT_OF_ORDER_NOT_BLOCKED';
  exception when others then
    if sqlerrm='OUT_OF_ORDER_NOT_BLOCKED' then raise; end if;
    if position('RESULT_EVENT_OUT_OF_ORDER' in sqlerrm)=0 then
      raise exception 'WRONG_OUT_OF_ORDER_ERROR=%',sqlerrm;
    end if;
  end;

  begin
    perform public.fn_record_parlay_result_event(pid,'audit_retry','perdido','ganado',100,150,2.5,'[]',
      '2026-09-12 10:15:00+00','stale_state');
    raise exception 'STATE_MISMATCH_NOT_BLOCKED';
  exception when others then
    if sqlerrm='STATE_MISMATCH_NOT_BLOCKED' then raise; end if;
    if position('RESULT_EVENT_STATE_MISMATCH' in sqlerrm)=0 then
      raise exception 'WRONG_STATE_ERROR=%',sqlerrm;
    end if;
  end;
END $$;

-- 3) VOID never contaminates learning; ack hides from unacked but preserves event.
DO $$
DECLARE pid uuid:='99999999-9999-4999-8999-999999999999';eid uuid;n int;
BEGIN
  eid:=public.fn_record_parlay_result_event(pid,'audit_ack','pendiente','nulo',50,0,2.0,'[]',
       '2026-09-12 14:00:00+00','audit');
  select count(*) into n from public.v_result_events_learning_current where entity_id=pid::text;
  if n<>0 then raise exception 'VOID_LEARNING_CONTAMINATION=%',n; end if;
  select count(*) into n from public.v_result_events_unacked where event_id=eid;
  if n<>1 then raise exception 'UNACKED_BEFORE=%',n; end if;
  insert into public.result_event_acks(event_id,apodo,ack_source)
  values(eid,'audit_ack','audit')
  on conflict(event_id,apodo) do update set acked_at=now(),ack_source='audit_retry';
  select count(*) into n from public.v_result_events_unacked where event_id=eid;
  if n<>0 then raise exception 'UNACKED_AFTER=%',n; end if;
  select count(*) into n from public.result_events where event_id=eid;
  if n<>1 then raise exception 'ACK_DELETED_HISTORY=%',n; end if;

  begin update public.result_events set outcome='won' where event_id=eid;
    raise exception 'IMMUTABLE_UPDATE_NOT_BLOCKED';
  exception when others then if sqlerrm='IMMUTABLE_UPDATE_NOT_BLOCKED' then raise; end if; end;
  begin delete from public.result_events where event_id=eid;
    raise exception 'IMMUTABLE_DELETE_NOT_BLOCKED';
  exception when others then if sqlerrm='IMMUTABLE_DELETE_NOT_BLOCKED' then raise; end if; end;
END $$;

-- 4) Push dedupe contract with a disposable stub of the existing production alert ledger.
-- These objects are rolled back; no real push is sent by this test.
create table public.alertas_enviadas(
  id uuid primary key default gen_random_uuid(),apodo text not null,tipo text not null,
  clave text not null,titulo text,cuerpo text,unique(apodo,tipo,clave));
create table public.push_subscriptions(
  id uuid primary key default gen_random_uuid(),apodo text not null,subscription jsonb,active boolean default true);
create or replace function public.enviar_alerta(
  p_apodo text,p_tipo text,p_clave text,p_titulo text,p_cuerpo text,p_url text default '/')
returns boolean language plpgsql as $$
begin
  if exists(select 1 from public.alertas_enviadas where apodo=p_apodo and tipo=p_tipo and clave=p_clave) then return false; end if;
  if not exists(select 1 from public.push_subscriptions where apodo=p_apodo) then return false; end if;
  insert into public.alertas_enviadas(apodo,tipo,clave,titulo,cuerpo)
  values(p_apodo,p_tipo,p_clave,p_titulo,p_cuerpo);
  return true;
end $$;
insert into public.push_subscriptions(apodo,subscription) values('audit_push','{}'::jsonb);

DO $$
DECLARE pid uuid:='66666666-6666-4666-8666-666666666666';eid uuid;ok1 boolean;ok2 boolean;n int;st text;at int;
BEGIN
  eid:=public.fn_record_parlay_result_event(pid,'audit_push','pendiente','perdido',100,-100,2.5,'[]',
       '2026-09-12 12:00:00+00','audit');
  ok1:=public.fn_dispatch_result_event_push(eid);
  ok2:=public.fn_dispatch_result_event_push(eid);
  if not ok1 or not ok2 then raise exception 'DISPATCH_RETURN_FAIL'; end if;
  select count(*) into n from public.alertas_enviadas
  where apodo='audit_push' and tipo='result_event' and clave=eid::text;
  if n<>1 then raise exception 'PUSH_LEDGER_DEDUPE_COUNT=%',n; end if;
  select push_status,attempts into st,at from public.result_event_delivery where event_id=eid;
  if st<>'queued' or at<>1 then raise exception 'DELIVERY_STATE status=% attempts=%',st,at; end if;
END $$;

DO $$
DECLARE pid uuid:='77777777-7777-4777-8777-777777777777';eid uuid;ok boolean;st text;er text;
BEGIN
  eid:=public.fn_record_parlay_result_event(pid,'audit_no_sub','pendiente','ganado',100,150,2.5,'[]',
       '2026-09-12 12:05:00+00','audit');
  ok:=public.fn_dispatch_result_event_push(eid);
  select push_status,last_error into st,er from public.result_event_delivery where event_id=eid;
  if not ok or st<>'skipped' or er<>'NO_PUSH_SUBSCRIPTION' then
    raise exception 'NO_SUB_SKIP_FAIL ok=% status=% error=%',ok,st,er;
  end if;
END $$;

rollback;
