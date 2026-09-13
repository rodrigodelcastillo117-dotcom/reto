-- ISS127 — WASTED PUSH SINGLE AUTHORITY · STAGED CUTOVER ONLY
-- Do not apply to production before WASTED AUDIT_PASS / release authorization.
-- Requires ISS126.
--
-- Existing production had two parlay-result notification paths:
--   notify_parlay_graded -> notificaciones (in-app current state)
--   alertar_calificados -> enviar_alerta (push)
-- ISS127 preserves the first strictly as CURRENT-STATE in-app projection and turns
-- alertar_calificados into the result_event_delivery outbox consumer. Result history
-- remains immutable; the notification row may be replaced because it is a projection.

create or replace function public.alertar_calificados()
returns integer language plpgsql security definer set search_path=public,pg_temp as $$
declare r record; n int:=0; ok boolean;
begin
  for r in
    select d.event_id
    from public.result_event_delivery d
    join public.result_events e using(event_id)
    where d.push_status in ('pending','failed')
      and d.attempts < 5
      and (d.next_attempt_at is null or d.next_attempt_at<=now())
    order by e.occurred_at,e.created_at,e.event_id
    limit 100
    for update of d skip locked
  loop
    ok:=public.fn_dispatch_result_event_push(r.event_id);
    if ok then n:=n+1; end if;
  end loop;
  return n;
end $$;

-- In-app projection: exactly one current parlay-result card, never a historical ledger.
create or replace function public.notify_parlay_graded()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_titulo text;v_mensaje text;v_tipo text;v_legs int;
begin
  if old.resultado is not distinct from new.resultado then return new; end if;
  if not (coalesce(old.resultado,'pendiente') in ('ganado','perdido','nulo')
          or coalesce(new.resultado,'pendiente') in ('ganado','perdido','nulo')) then
    return new;
  end if;

  -- Remove previous projection for this parlay. Historical truth lives in result_events.
  delete from public.notificaciones
  where tipo in ('parlay_ganado','parlay_perdido','parlay_nulo')
    and data->>'parlay_id'=new.id::text;

  -- Reversal to pending intentionally leaves no terminal current-state card.
  if new.resultado not in ('ganado','perdido','nulo') then return new; end if;

  v_legs:=case when jsonb_typeof(coalesce(new.picks_data,'[]'::jsonb))='array'
               then jsonb_array_length(coalesce(new.picks_data,'[]'::jsonb)) else 0 end;
  if new.resultado='ganado' then
    v_tipo:='parlay_ganado';
    v_titulo:='Parlay x'||v_legs||' Ganado +$'||round(coalesce(new.ganancia_neta,0)::numeric,2);
    v_mensaje:='Momio total @'||coalesce(new.momio_total,0)||' — Resultado confirmado';
  elsif new.resultado='perdido' then
    v_tipo:='parlay_perdido';
    v_titulo:='Parlay x'||v_legs||' Perdido -$'||round(abs(coalesce(new.ganancia_neta,0))::numeric,2);
    v_mensaje:='Momio total @'||coalesce(new.momio_total,0);
  else
    v_tipo:='parlay_nulo';
    v_titulo:='Parlay x'||v_legs||' Nulo';
    v_mensaje:='Resultado anulado / push. No cuenta como etiqueta de aprendizaje.';
  end if;

  insert into public.notificaciones(apodo,tipo,titulo,mensaje,data)
  values(new.apodo,v_tipo,v_titulo,v_mensaje,
    jsonb_build_object('parlay_id',new.id,'legs',v_legs,'monto',new.ganancia_neta,
                       'authority','result_events_current_projection'));
  return new;
end $$;

-- Keep generic push trigger behavior, but parlay current-state cards no longer claim
-- that they fired a push. Their push truth is result_event_delivery.
create or replace function public.trigger_enviar_push_notificacion()
returns trigger language plpgsql security definer set search_path=public,extensions as $$
declare v_has_active_sub boolean;v_title text;v_body text;v_url text;v_tag text;
begin
  if new.push_disparada is true then return new; end if;

  if new.tipo in ('parlay_ganado','parlay_perdido','parlay_nulo') then
    return new;
  end if;

  if new.tipo='marcador' and new.data->>'origen'='score_notifications' then
    update public.notificaciones set push_disparada=true where id=new.id;
    return new;
  end if;

  select exists(select 1 from public.push_subscriptions where apodo=new.apodo and active=true)
    into v_has_active_sub;
  if not v_has_active_sub then return new; end if;

  v_title:=coalesce(new.titulo,'Reto 13M');
  v_body:=coalesce(new.mensaje,'');
  v_url:=coalesce(new.url,'/');
  v_tag:=coalesce(new.tipo,'reto13m');

  perform net.http_post(
    url:='https://wpiztubmmmzclhlprgpd.supabase.co/functions/v1/enviar-notificacion-push',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||public.sk()),
    body:=jsonb_build_object('apodo',new.apodo,'title',v_title,'body',v_body,'url',v_url,'tag',v_tag),
    timeout_milliseconds:=30000);

  update public.notificaciones set push_disparada=true where id=new.id;
  return new;
exception when others then
  raise warning 'Trigger push falló para notificación %: %',new.id,sqlerrm;
  return new;
end $$;

-- Legacy parlays.push_notified may remain for wire compatibility but is no longer
-- delivery authority after this cutover.
do $$ begin
  if exists(select 1 from information_schema.columns
            where table_schema='public' and table_name='parlays' and column_name='push_notified') then
    execute 'comment on column public.parlays.push_notified is ''DEPRECATED: not delivery truth. Canonical parlay result delivery lives in result_event_delivery.''';
  end if;
end $$;
