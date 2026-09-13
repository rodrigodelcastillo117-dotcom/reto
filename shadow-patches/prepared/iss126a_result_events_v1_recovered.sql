-- ISS126a — RECOVERED EXECUTED BASE: iss083_append_only_result_events_v1_retry
-- Source: exact SQL recovered from supabase_migrations.schema_migrations on disposable.
-- Staged in Git so ISS126 V2 is reproducible. No production mutation.

create or replace function public.result_event_current_apodo()
returns text language sql stable security definer set search_path=public as $$
  select u.apodo from public.usuarios u where u.user_id=auth.uid() limit 1
$$;

create table if not exists public.result_events (
  event_id uuid primary key default gen_random_uuid(),
  dedupe_key text not null unique,
  apodo text not null,
  entity_kind text not null,
  entity_id text not null,
  event_kind text not null,
  from_status text,
  to_status text not null,
  outcome text,
  amount numeric,
  stake numeric,
  odds numeric,
  occurred_at timestamptz not null,
  graded_at timestamptz,
  source text not null,
  source_version text not null,
  payload jsonb not null default '{}'::jsonb,
  provenance jsonb not null default '{}'::jsonb,
  reverses_event_id uuid references public.result_events(event_id),
  created_at timestamptz not null default now(),
  constraint result_events_entity_kind_ck check (entity_kind in ('parlay')),
  constraint result_events_event_kind_ck check (event_kind in ('terminal_result','result_reversal','result_correction'))
);
create index if not exists result_events_apodo_created_idx on public.result_events(apodo,created_at desc,event_id desc);
create index if not exists result_events_entity_idx on public.result_events(entity_kind,entity_id,occurred_at desc,event_id desc);

create table if not exists public.result_event_acks (
  event_id uuid not null references public.result_events(event_id) on delete restrict,
  apodo text not null,
  acked_at timestamptz not null default now(),
  ack_source text not null default 'app',
  primary key(event_id,apodo)
);

create table if not exists public.result_event_delivery (
  event_id uuid primary key references public.result_events(event_id) on delete restrict,
  push_status text not null default 'pending',
  attempts integer not null default 0,
  last_attempt_at timestamptz,
  provider_message_id text,
  last_error text,
  updated_at timestamptz not null default now(),
  constraint result_event_delivery_status_ck check (push_status in ('pending','skipped','sent','failed'))
);

alter table public.result_events enable row level security;
alter table public.result_event_acks enable row level security;
alter table public.result_event_delivery enable row level security;

do $$ begin
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='result_events' and policyname='Auth own result events') then
    create policy "Auth own result events" on public.result_events
      for select to authenticated
      using (lower(trim(apodo))=lower(trim(public.result_event_current_apodo())));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='result_events' and policyname='Service result events') then
    create policy "Service result events" on public.result_events
      for all to service_role using (true) with check (true);
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='result_event_acks' and policyname='Auth own result event acks') then
    create policy "Auth own result event acks" on public.result_event_acks
      for all to authenticated
      using (lower(trim(apodo))=lower(trim(public.result_event_current_apodo()))
        and exists(select 1 from public.result_events e where e.event_id=result_event_acks.event_id
          and lower(trim(e.apodo))=lower(trim(public.result_event_current_apodo()))))
      with check (lower(trim(apodo))=lower(trim(public.result_event_current_apodo()))
        and exists(select 1 from public.result_events e where e.event_id=result_event_acks.event_id
          and lower(trim(e.apodo))=lower(trim(public.result_event_current_apodo()))));
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='result_event_acks' and policyname='Service result event acks') then
    create policy "Service result event acks" on public.result_event_acks for all to service_role using(true) with check(true);
  end if;
  if not exists(select 1 from pg_policies where schemaname='public' and tablename='result_event_delivery' and policyname='Service result event delivery') then
    create policy "Service result event delivery" on public.result_event_delivery for all to service_role using(true) with check(true);
  end if;
end $$;

create or replace function public.fn_result_events_immutable()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  raise exception 'result_events is append-only; append a reversal/correction event instead';
end $$;
drop trigger if exists zzz_result_events_immutable on public.result_events;
create trigger zzz_result_events_immutable before update or delete on public.result_events
for each row execute function public.fn_result_events_immutable();

create or replace function public.fn_record_parlay_result_event(
  p_parlay_id uuid,p_apodo text,p_old_result text,p_new_result text,
  p_apuesta numeric,p_ganancia_neta numeric,p_momio_total numeric,p_picks_data jsonb,
  p_graded_at timestamptz,p_source text default 'parlays.resultado'
) returns uuid
language plpgsql security definer set search_path=public,extensions as $$
declare
  v_event_kind text; v_dedupe_key text; v_event_id uuid; v_reverses uuid;
  v_ts timestamptz := coalesce(p_graded_at,now());
  v_old_terminal boolean := coalesce(p_old_result,'pendiente') in ('ganado','perdido','nulo');
  v_new_terminal boolean := coalesce(p_new_result,'pendiente') in ('ganado','perdido','nulo');
begin
  if p_parlay_id is null or nullif(trim(p_apodo),'') is null then raise exception 'parlay_id/apodo required'; end if;
  if p_old_result is not distinct from p_new_result then return null; end if;
  if not (v_old_terminal or v_new_terminal) then return null; end if;
  if not v_old_terminal and v_new_terminal then v_event_kind:='terminal_result';
  elsif v_old_terminal and not v_new_terminal then v_event_kind:='result_reversal';
  else v_event_kind:='result_correction'; end if;
  if v_old_terminal then
    select e.event_id into v_reverses from public.result_events e
    where e.entity_kind='parlay' and e.entity_id=p_parlay_id::text and e.to_status=p_old_result
      and e.event_kind in ('terminal_result','result_correction')
    order by e.occurred_at desc,e.created_at desc,e.event_id desc limit 1;
  end if;
  v_dedupe_key:=encode(digest(concat_ws('|','result_event_v1','parlay',p_parlay_id::text,
    coalesce(p_old_result,'NULL'),coalesce(p_new_result,'NULL'),
    to_char(v_ts at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US'),
    coalesce(p_ganancia_neta::text,'NULL'),coalesce(p_apuesta::text,'NULL')),'sha256'),'hex');
  insert into public.result_events(dedupe_key,apodo,entity_kind,entity_id,event_kind,from_status,to_status,outcome,
    amount,stake,odds,occurred_at,graded_at,source,source_version,payload,provenance,reverses_event_id)
  values(v_dedupe_key,p_apodo,'parlay',p_parlay_id::text,v_event_kind,p_old_result,p_new_result,
    case p_new_result when 'ganado' then 'won' when 'perdido' then 'lost' when 'nulo' then 'void' else null end,
    p_ganancia_neta,p_apuesta,p_momio_total,v_ts,v_ts,p_source,'result_event_v1',
    jsonb_build_object('parlay_id',p_parlay_id,'picks_data',coalesce(p_picks_data,'[]'::jsonb),
      'legs',case when jsonb_typeof(coalesce(p_picks_data,'[]'::jsonb))='array' then jsonb_array_length(coalesce(p_picks_data,'[]'::jsonb)) else null end),
    jsonb_build_object('transition',concat_ws('->',coalesce(p_old_result,'NULL'),coalesce(p_new_result,'NULL')),'captured_at',now()),v_reverses)
  on conflict(dedupe_key) do nothing returning event_id into v_event_id;
  if v_event_id is null then select event_id into v_event_id from public.result_events where dedupe_key=v_dedupe_key;
  else insert into public.result_event_delivery(event_id,push_status) values(v_event_id,'pending') on conflict(event_id) do nothing; end if;
  return v_event_id;
end $$;

create or replace function public.tg_emit_parlay_result_event()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.fn_record_parlay_result_event(new.id,new.apodo,old.resultado,new.resultado,
    new.apuesta,new.ganancia_neta,new.momio_total,new.picks_data,coalesce(new.updated_at,now()),'parlays.resultado_trigger');
  return new;
end $$;
drop trigger if exists on_parlay_result_event on public.parlays;
create trigger on_parlay_result_event after update of resultado on public.parlays
for each row when (old.resultado is distinct from new.resultado and
  (old.resultado in ('ganado','perdido','nulo') or new.resultado in ('ganado','perdido','nulo')))
execute function public.tg_emit_parlay_result_event();

create or replace function public.ack_result_event(p_event_id uuid,p_ack_source text default 'app')
returns boolean language plpgsql security definer set search_path=public as $$
declare v_apodo text;
begin
  v_apodo:=public.result_event_current_apodo();
  if v_apodo is null then raise exception 'authenticated user has no apodo'; end if;
  if not exists(select 1 from public.result_events e where e.event_id=p_event_id and lower(trim(e.apodo))=lower(trim(v_apodo))) then raise exception 'result event not found for current user'; end if;
  insert into public.result_event_acks(event_id,apodo,acked_at,ack_source)
  values(p_event_id,v_apodo,now(),coalesce(nullif(trim(p_ack_source),''),'app'))
  on conflict(event_id,apodo) do update set acked_at=excluded.acked_at,ack_source=excluded.ack_source;
  return true;
end $$;

create or replace view public.v_result_events_unacked with (security_invoker=true) as
select e.* from public.result_events e
left join public.result_event_acks a on a.event_id=e.event_id and lower(trim(a.apodo))=lower(trim(e.apodo))
where a.event_id is null;

grant select on public.result_events to authenticated;
grant select on public.v_result_events_unacked to authenticated;
grant select,insert,update on public.result_event_acks to authenticated;
grant execute on function public.ack_result_event(uuid,text) to authenticated;
revoke insert,update,delete on public.result_events from authenticated;
revoke all on public.result_event_delivery from authenticated;
revoke execute on function public.fn_record_parlay_result_event(uuid,text,text,text,numeric,numeric,numeric,jsonb,timestamptz,text) from public,authenticated;
revoke execute on function public.tg_emit_parlay_result_event() from public,authenticated;
revoke execute on function public.fn_result_events_immutable() from public,authenticated;
