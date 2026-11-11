-- orden/50_bootstrap.sql — BOOTSTRAP DE DATOS, SIN ASSERTIONS
--
-- SEPARADO a proposito. El dueno señalo que iss094 mezclaba definicion del
-- bootstrap con assertions finales, y que en una base virgen las assertions de
-- season_type pueden correr ANTES de que termine la descarga, porque pg_cron es
-- asincrono. Tenia razon: eso hacia que las assertions "pasaran" sin probar nada.
--
-- Ahora el orden es explicito:
--   50_bootstrap.sql        define y ARRANCA la descarga
--   60_espera_bootstrap.sql BLOQUEA hasta que termine de verdad
--   70_universo.sql         construye el universo del backtest
--   80_assertions.sql       recien entonces comprueba
--
-- Este archivo NO comprueba nada de los datos: solo deja el mecanismo listo.

-- ===========================================================================
-- 4) BOOTSTRAP AUTO-CONDUCIDO
--
--    ANTES aqui habia comandos COMENTADOS. El dueno lo detecto: sobre una base
--    limpia el archivo por si solo NO reconstruia el estado de datos, y las
--    assertions pasaban solo porque produccion ya estaba corregida. Tenia razon.
--
--    El problema real: pg_net es ASINCRONO. La respuesta HTTP no aterriza hasta
--    que la transaccion cierra, asi que ninguna funcion puede terminar el
--    trabajo en un solo llamado. pg_cron lo resuelve de verdad: un paso por
--    minuto, y el job SE DESPROGRAMA SOLO al terminar.
-- ===========================================================================
create table if not exists public.mlb_bootstrap_log (
  id bigserial primary key, paso jsonb not null, at timestamptz not null default now());
comment on table public.mlb_bootstrap_log is
  'Bitacora del bootstrap auto-conducido. Permite auditar la corrida sin depender de la memoria de nadie.';

create table if not exists public.mlb_bootstrap_estado (
  id int primary key default 1 check (id = 1),
  desde date not null, hasta date not null,
  arrancado_at timestamptz not null default now());
comment on table public.mlb_bootstrap_estado is
  'Rango activo del bootstrap. Existe porque arrancar() reiniciaba TODA la tabla de control sin importar el rango pedido: bug encontrado por mi propia prueba.';

-- BUG RAIZ CORREGIDO: mlb_backfill_encolar (iss088) insertaba el rango pedido
-- pero luego SELECCIONABA cualquier fecha pendiente de TODA la tabla. Por eso
-- arrancar('2025-06-15','2025-06-20') acabo encolando 1,306 fechas.
create or replace function public.mlb_backfill_encolar(p_desde date, p_hasta date, p_max int default 40)
returns int language plpgsql security definer set search_path to 'public' as $function$
declare v_f date; v_rid bigint; v_n int := 0;
begin
  insert into mlb_backfill_control (fecha)
  select d::date from generate_series(p_desde, p_hasta, interval '1 day') d
  on conflict (fecha) do nothing;

  for v_f in
    select fecha from mlb_backfill_control
     where estado in ('pendiente','error') and intentos < 3
       and fecha between p_desde and p_hasta      -- <<< EL FILTRO QUE FALTABA
     order by fecha limit p_max
  loop
    select net.http_get(
      url := 'https://site.web.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?dates='
             || to_char(v_f,'YYYYMMDD'),
      headers := jsonb_build_object(
        'User-Agent','Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Accept','application/json, text/plain, */*',
        'Referer','https://www.espn.com/','Origin','https://www.espn.com'),
      timeout_milliseconds := 25000) into v_rid;
    update mlb_backfill_control
       set request_id=v_rid, estado='solicitado', intentos=intentos+1, actualizado_at=now()
     where fecha=v_f;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

create or replace function public.mlb_bootstrap_paso(p_lote int default 140)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_pend int; v_vuelo int; v_enc int := 0; v_cos jsonb; v_d date; v_h date;
begin
  select desde, hasta into v_d, v_h from mlb_bootstrap_estado where id = 1;
  if v_d is null then
    return jsonb_build_object('error','no hay rango activo: llamar mlb_bootstrap_arrancar primero');
  end if;

  v_cos := public.mlb_backfill_cosechar();

  select count(*) filter (where estado='pendiente'),
         count(*) filter (where estado='solicitado')
    into v_pend, v_vuelo
  from mlb_backfill_control where intentos < 3 and fecha between v_d and v_h;

  if v_pend > 0 then
    select public.mlb_backfill_encolar(v_d, v_h, p_lote) into v_enc;
  end if;

  select count(*) filter (where estado='pendiente'),
         count(*) filter (where estado='solicitado')
    into v_pend, v_vuelo
  from mlb_backfill_control where intentos < 3 and fecha between v_d and v_h;

  return jsonb_build_object('rango', v_d::text||'..'||v_h::text,
    'pendientes', v_pend, 'en_vuelo', v_vuelo, 'encolados_ahora', v_enc,
    'con_error', v_cos->'con_error',
    'terminado', (v_pend = 0 and v_vuelo = 0));
end $function$;

create or replace function public.mlb_bootstrap_tick()
returns void language plpgsql security definer set search_path to 'public' as $function$
declare r jsonb; v_apl jsonb;
begin
  r := public.mlb_bootstrap_paso(140);
  insert into mlb_bootstrap_log (paso) values (r);

  if (r->>'terminado')::boolean then
    v_apl := public.mlb_season_type_aplicar();
    insert into mlb_bootstrap_log (paso) values (jsonb_build_object('fase','aplicar','resultado',v_apl));
    perform cron.unschedule('mlb_bootstrap');
    insert into mlb_bootstrap_log (paso) values (jsonb_build_object('fase','fin','cron','desprogramado'));
  end if;
end $function$;

create or replace function public.mlb_bootstrap_arrancar(p_desde date, p_hasta date)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_n int;
begin
  insert into mlb_bootstrap_estado (id, desde, hasta, arrancado_at)
  values (1, p_desde, p_hasta, now())
  on conflict (id) do update set desde=excluded.desde, hasta=excluded.hasta, arrancado_at=now();

  -- SOLO el rango pedido. Antes esto reiniciaba la tabla completa.
  update mlb_backfill_control set estado='pendiente', intentos=0, ultimo_error=null
   where fecha between p_desde and p_hasta;
  insert into mlb_backfill_control (fecha)
  select d::date from generate_series(p_desde, p_hasta, interval '1 day') d
  on conflict (fecha) do nothing;
  select count(*) into v_n from mlb_backfill_control where fecha between p_desde and p_hasta;

  delete from mlb_bootstrap_log;
  perform cron.unschedule('mlb_bootstrap') where exists (select 1 from cron.job where jobname='mlb_bootstrap');
  perform cron.schedule('mlb_bootstrap', '* * * * *', 'select public.mlb_bootstrap_tick()');

  return jsonb_build_object('rango', p_desde::text||'..'||p_hasta::text,
    'fechas_en_rango', v_n,
    'cron','mlb_bootstrap cada minuto; se desprograma solo al terminar');
end $function$;

grant execute on function public.mlb_bootstrap_paso(int) to service_role;
grant execute on function public.mlb_bootstrap_tick() to service_role;
grant execute on function public.mlb_bootstrap_arrancar(date,date) to service_role;

-- UN SOLO COMANDO reconstruye el histórico completo, sin repeticiones manuales:
--   select public.mlb_bootstrap_arrancar('2023-02-15','2026-09-12');
-- y despues, para auditar la corrida:
--   select * from public.mlb_bootstrap_log order by id;
--
-- PROBADO DE VERDAD sobre 2025-06-15..2025-06-20: paso 1 encolo 6 y quedaron 6
-- en vuelo; paso 2 reporto terminado=true; corrio mlb_season_type_aplicar; y el
-- job se desprogramo solo (cron_activo = 0). La prueba tambien encontro los dos
-- bugs de arriba, que ya estan corregidos.


-- ARRANQUE. Un solo comando; el job se desprograma solo al terminar.
select public.mlb_bootstrap_arrancar('2023-02-15','2026-09-12');
