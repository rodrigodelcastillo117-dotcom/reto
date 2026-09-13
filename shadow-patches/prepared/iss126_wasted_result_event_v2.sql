-- ISS126 — RESULT_EVENT / WASTED V2 HARDENING · STAGED ONLY
-- No production mutation. Apply after recovered iss083_append_only_result_events_v1_retry.
--
-- Invariants:
--  * immutable append-only result history
--  * stable retry identity; no now()-based result version
--  * chronological + state-chain fail-close
--  * correction/reversal appends; never rewrites history
--  * one current label for learning; VOID/PENDING never become Brier/log-loss labels
--  * push delivery is a separate outbox. `queued` means the existing atomic
--    alert ledger accepted/has the request; it does NOT claim device delivery.

alter table public.result_event_delivery drop constraint if exists result_event_delivery_status_ck;
alter table public.result_event_delivery add constraint result_event_delivery_status_ck
  check (push_status in ('pending','dispatching','queued','skipped','failed','sent'));
alter table public.result_event_delivery add column if not exists next_attempt_at timestamptz;
alter table public.result_event_delivery add column if not exists dispatch_key text;
create unique index if not exists result_event_delivery_dispatch_key_uq
  on public.result_event_delivery(dispatch_key) where dispatch_key is not null;
update public.result_event_delivery
set dispatch_key='result_event:'||event_id::text
where dispatch_key is null;

create or replace function public.fn_record_parlay_result_event(
  p_parlay_id uuid,p_apodo text,p_old_result text,p_new_result text,
  p_apuesta numeric,p_ganancia_neta numeric,p_momio_total numeric,p_picks_data jsonb,
  p_graded_at timestamptz,p_source text default 'parlays.resultado'
) returns uuid
language plpgsql security definer set search_path=public,extensions as $$
declare
  v_event_kind text; v_dedupe_key text; v_event_id uuid; v_reverses uuid;
  v_ts timestamptz := p_graded_at;
  v_old text := coalesce(p_old_result,'pendiente');
  v_new text := coalesce(p_new_result,'pendiente');
  v_old_terminal boolean; v_new_terminal boolean; v_latest record;
begin
  if p_parlay_id is null or nullif(trim(p_apodo),'') is null then
    raise exception 'RESULT_EVENT_IDENTITY_REQUIRED';
  end if;
  -- A null timestamp cannot identify a stable provider/grading version. `now()` here
  -- would make a retry a different event, so fail closed instead.
  if v_ts is null then raise exception 'RESULT_EVENT_VERSION_TIME_REQUIRED'; end if;
  if v_old not in ('pendiente','ganado','perdido','nulo')
     or v_new not in ('pendiente','ganado','perdido','nulo') then
    raise exception 'RESULT_EVENT_STATUS_INVALID: % -> %',v_old,v_new;
  end if;
  if v_old=v_new then return null; end if;

  v_old_terminal := v_old in ('ganado','perdido','nulo');
  v_new_terminal := v_new in ('ganado','perdido','nulo');
  if not (v_old_terminal or v_new_terminal) then return null; end if;

  v_dedupe_key:=encode(digest(concat_ws('|','result_event_v2','parlay',p_parlay_id::text,
    v_old,v_new,to_char(v_ts at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US'),
    coalesce(p_ganancia_neta::text,'NULL'),coalesce(p_apuesta::text,'NULL')),'sha256'),'hex');

  -- Exact retry is resolved before chronology/state-chain checks.
  select e.event_id into v_event_id from public.result_events e where e.dedupe_key=v_dedupe_key;
  if v_event_id is not null then return v_event_id; end if;

  select e.event_id,e.to_status,e.occurred_at into v_latest
  from public.result_events e
  where e.entity_kind='parlay' and e.entity_id=p_parlay_id::text
  order by e.occurred_at desc,e.created_at desc,e.event_id desc limit 1;

  if v_latest.event_id is not null then
    if v_ts < v_latest.occurred_at then
      raise exception 'RESULT_EVENT_OUT_OF_ORDER: incoming % < latest %',v_ts,v_latest.occurred_at;
    end if;
    if v_latest.to_status is distinct from v_old then
      raise exception 'RESULT_EVENT_STATE_MISMATCH: latest to_status=% incoming from_status=%',
        v_latest.to_status,v_old;
    end if;
  end if;

  if not v_old_terminal and v_new_terminal then v_event_kind:='terminal_result';
  elsif v_old_terminal and not v_new_terminal then v_event_kind:='result_reversal';
  else v_event_kind:='result_correction'; end if;

  if v_old_terminal and v_latest.event_id is not null then v_reverses:=v_latest.event_id; end if;

  insert into public.result_events(
    dedupe_key,apodo,entity_kind,entity_id,event_kind,from_status,to_status,outcome,
    amount,stake,odds,occurred_at,graded_at,source,source_version,payload,provenance,reverses_event_id)
  values(v_dedupe_key,p_apodo,'parlay',p_parlay_id::text,v_event_kind,v_old,v_new,
    case v_new when 'ganado' then 'won' when 'perdido' then 'lost'
               when 'nulo' then 'void' else null end,
    p_ganancia_neta,p_apuesta,p_momio_total,v_ts,v_ts,p_source,'result_event_v2',
    jsonb_build_object('parlay_id',p_parlay_id,'picks_data',coalesce(p_picks_data,'[]'::jsonb),
      'legs',case when jsonb_typeof(coalesce(p_picks_data,'[]'::jsonb))='array'
                  then jsonb_array_length(coalesce(p_picks_data,'[]'::jsonb)) else null end),
    jsonb_build_object('transition',v_old||'->'||v_new,'captured_at',now(),
      'version_time',v_ts,'dedupe_contract','entity+transition+version_time+economics'),v_reverses)
  on conflict(dedupe_key) do nothing returning event_id into v_event_id;

  if v_event_id is null then
    select event_id into v_event_id from public.result_events where dedupe_key=v_dedupe_key;
  else
    insert into public.result_event_delivery(event_id,push_status,dispatch_key)
    values(v_event_id,'pending','result_event:'||v_event_id::text)
    on conflict(event_id) do nothing;
  end if;
  return v_event_id;
end $$;

create or replace function public.tg_emit_parlay_result_event()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.fn_record_parlay_result_event(
    new.id,new.apodo,old.resultado,new.resultado,new.apuesta,new.ganancia_neta,
    new.momio_total,new.picks_data,new.updated_at,'parlays.resultado_trigger');
  return new;
end $$;

create or replace view public.v_result_event_current with (security_invoker=true) as
select distinct on (e.entity_kind,e.entity_id) e.*
from public.result_events e
order by e.entity_kind,e.entity_id,e.occurred_at desc,e.created_at desc,e.event_id desc;

create or replace view public.v_result_events_learning_current with (security_invoker=true) as
select e.* from public.v_result_event_current e
where e.to_status in ('ganado','perdido') and e.outcome in ('won','lost');

grant select on public.v_result_event_current to authenticated;
grant select on public.v_result_events_learning_current to authenticated;

-- Dispatches one immutable result event via the existing alert ledger contract.
-- Production `enviar_alerta()` dedupes on (apodo,tipo,clave) and queues net.http_post
-- in the same DB transaction. clave = immutable result_event_id, so a correction gets
-- its own push while a retry cannot queue a second request for the same event.
create or replace function public.fn_dispatch_result_event_push(p_event_id uuid)
returns boolean
language plpgsql security definer set search_path=public,pg_temp as $$
declare
  e public.result_events%rowtype; d public.result_event_delivery%rowtype;
  v_title text; v_body text; v_url text := '/pit';
  v_ok boolean := false; v_ledger boolean := false; v_has_sub boolean := false;
begin
  select * into e from public.result_events where event_id=p_event_id;
  if e.event_id is null then raise exception 'RESULT_EVENT_NOT_FOUND'; end if;

  select * into d from public.result_event_delivery where event_id=p_event_id for update;
  if d.event_id is null then
    insert into public.result_event_delivery(event_id,push_status,dispatch_key)
    values(p_event_id,'pending','result_event:'||p_event_id::text) returning * into d;
  end if;
  if d.push_status in ('queued','sent','skipped') then return true; end if;

  update public.result_event_delivery
  set push_status='dispatching',attempts=attempts+1,last_attempt_at=now(),
      last_error=null,updated_at=now(),dispatch_key=coalesce(dispatch_key,'result_event:'||p_event_id::text)
  where event_id=p_event_id;

  if to_regprocedure('public.enviar_alerta(text,text,text,text,text,text)') is null
     or to_regclass('public.alertas_enviadas') is null
     or to_regclass('public.push_subscriptions') is null then
    update public.result_event_delivery
    set push_status='failed',last_error='PUSH_PROVIDER_UNAVAILABLE',
        next_attempt_at=now()+interval '5 minutes',updated_at=now()
    where event_id=p_event_id;
    return false;
  end if;

  execute 'select exists(select 1 from public.alertas_enviadas where apodo=$1 and tipo=''result_event'' and clave=$2)'
    into v_ledger using e.apodo,p_event_id::text;
  if v_ledger then
    update public.result_event_delivery set push_status='queued',last_error=null,next_attempt_at=null,updated_at=now()
    where event_id=p_event_id;
    return true;
  end if;

  execute 'select exists(select 1 from public.push_subscriptions where apodo=$1)'
    into v_has_sub using e.apodo;
  if not v_has_sub then
    update public.result_event_delivery
    set push_status='skipped',last_error='NO_PUSH_SUBSCRIPTION',next_attempt_at=null,updated_at=now()
    where event_id=p_event_id;
    return true;
  end if;

  if e.event_kind='result_reversal' then
    v_title:='↩️ Resultado revertido';
    v_body:='Tu parlay volvió a pendiente mientras se confirma el resultado.';
  elsif e.event_kind='result_correction' then
    v_title:=case e.outcome when 'won' then '🏆 Resultado corregido: GANADO'
                            when 'lost' then '💥 Resultado corregido: PERDIDO'
                            when 'void' then '↩️ Resultado corregido: NULO'
                            else 'Resultado corregido' end;
    v_body:='Se corrigió el resultado de tu parlay. Abre Reto 13M para ver el detalle.';
  else
    v_title:=case e.outcome when 'won' then '🏆 Parlay ganado'
                            when 'lost' then '💥 Parlay perdido'
                            when 'void' then '↩️ Parlay nulo'
                            else 'Resultado de parlay' end;
    v_body:=case e.outcome when 'won' then 'Tu parlay terminó ganado.'
                          when 'lost' then 'Tu parlay terminó perdido.'
                          when 'void' then 'Tu parlay fue declarado nulo.'
                          else 'Tu parlay cambió de estado.' end;
  end if;

  execute 'select public.enviar_alerta($1,$2,$3,$4,$5,$6)'
    into v_ok using e.apodo,'result_event',p_event_id::text,v_title,v_body,v_url;

  execute 'select exists(select 1 from public.alertas_enviadas where apodo=$1 and tipo=''result_event'' and clave=$2)'
    into v_ledger using e.apodo,p_event_id::text;
  if v_ok or v_ledger then
    update public.result_event_delivery
    set push_status='queued',last_error=null,next_attempt_at=null,updated_at=now()
    where event_id=p_event_id;
    return true;
  end if;

  update public.result_event_delivery
  set push_status='failed',last_error='PUSH_NOT_QUEUED',next_attempt_at=now()+interval '5 minutes',updated_at=now()
  where event_id=p_event_id;
  return false;
exception when others then
  update public.result_event_delivery
  set push_status='failed',last_error=sqlerrm,next_attempt_at=now()+interval '5 minutes',updated_at=now()
  where event_id=p_event_id;
  return false;
end $$;

revoke execute on function public.fn_dispatch_result_event_push(uuid) from public,authenticated;
grant execute on function public.fn_dispatch_result_event_push(uuid) to service_role;
