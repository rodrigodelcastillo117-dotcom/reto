-- iss094 — SEASON_TYPE EXACTO DE MLB  [EJECUTABLE]
--
-- RECAPTURA: la versión anterior de este archivo era SÓLO PROSA, 0 líneas de
-- SQL. El dueño lo detectó y tenía razón: reabría el gate de reproducibilidad
-- que habíamos cerrado en iss082-084. Esta versión SÍ se ejecuta, es idempotente
-- y termina con assertions que fallan si el resultado no cuadra.
--
-- QUÉ ARREGLA
-- `tipo_temporada` sólo tenía dos valores de texto ('pretemporada' /
-- 'regular_o_playoffs'), así que era imposible separar regular de postseason. Y
-- el `cosechar` anterior DESCARTABA los season_type=1, de modo que una fila mal
-- etiquetada como regular nunca podía detectarse: no había con qué
-- contradecirla. Ese era el bug de diseño.
--
-- Contaminación medida, bidireccional:
--   53 partidos etiquetados regular_o_playoffs que ESPN dice son type 1
--      (2023-03-26..29 y 2024-03-26..27) -> estaban DENTRO de los backtests.
--    2 partidos etiquetados pretemporada que son type 2 (Serie de Seúl,
--      2024-03-20/21) -> estaban FUERA.
--   La Serie de Tokio 2025 (2025-03-18/19) no existía en la base.
--
-- ORDEN DE EJECUCIÓN: iss088 -> iss089 -> iss090 -> iss091 -> iss094 -> iss095 -> iss096
-- NO ejecutar iss087 después de iss089: reintroduce el bug de ventanas.

-- EJECUCION: correr el archivo COMPLETO en una sola transaccion. Las
-- assertions del final abortan todo si el resultado no cuadra.

-- ===========================================================================
-- 1) ESQUEMA: el season_type real de ESPN, persistido
-- ===========================================================================
alter table public.historico_partidos_espn add column if not exists season_type int;
alter table public.historico_partidos_espn add column if not exists season_year int;
comment on column public.historico_partidos_espn.season_type is
  'season.type de ESPN tal cual: 1 pretemporada, 2 temporada regular, 3 postseason, 4 allstar. tipo_temporada se DERIVA de aqui; NUNCA se infiere por fecha.';

alter table public.mlb_backfill_staging add column if not exists descartado_motivo text;

create table if not exists public.mlb_season_type_conflictos (
  id bigserial primary key,
  espn_event_id text not null,
  fecha date,
  tipo_en_db text,
  season_type_espn int,
  tipo_derivado text,
  detectado_at timestamptz not null default now()
);
comment on table public.mlb_season_type_conflictos is
  'Filas donde la etiqueta vieja de la base contradice el season.type real de ESPN. Se corrigen, pero queda registro de cada correccion.';

-- ===========================================================================
-- 2) COSECHAR: guarda TODOS los season_type
--    Guardar el type 1 es lo que permite DETECTAR etiquetas malas. Descartarlo
--    era el bug. El filtro de universo se aplica al construir el backtest, no
--    al guardar el dato crudo.
-- ===========================================================================
create or replace function public.mlb_backfill_cosechar()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_filas int := 0;
begin
  with r as (
    select c.fecha, c.request_id, h.status_code, h.content
    from mlb_backfill_control c
    join net._http_response h on h.id = c.request_id
    where c.estado = 'solicitado'
  ),
  ok as (select * from r where status_code = 200 and content is not null),
  ev as (select ok.fecha, ok.request_id, e
         from ok, lateral jsonb_array_elements((ok.content::jsonb)->'events') e),
  filas as (
    select ev.fecha, ev.request_id,
           e->>'id' espn_event_id,
           (e->>'date')::timestamptz kickoff,
           (e->'season'->>'type')::int season_type,
           (e->'season'->>'year')::int season_year,
           e->'competitions'->0->'status'->'type'->>'name' status_name,
           (select c2->'team'->>'id' from jsonb_array_elements(e->'competitions'->0->'competitors') c2 where c2->>'homeAway'='home' limit 1) home_espn_id,
           (select c2->'team'->>'id' from jsonb_array_elements(e->'competitions'->0->'competitors') c2 where c2->>'homeAway'='away' limit 1) away_espn_id,
           (select c2->'team'->>'displayName' from jsonb_array_elements(e->'competitions'->0->'competitors') c2 where c2->>'homeAway'='home' limit 1) home_nombre,
           (select c2->'team'->>'displayName' from jsonb_array_elements(e->'competitions'->0->'competitors') c2 where c2->>'homeAway'='away' limit 1) away_nombre,
           (select nullif(c2->>'score','')::int from jsonb_array_elements(e->'competitions'->0->'competitors') c2 where c2->>'homeAway'='home' limit 1) home_score,
           (select nullif(c2->>'score','')::int from jsonb_array_elements(e->'competitions'->0->'competitors') c2 where c2->>'homeAway'='away' limit 1) away_score
    from ev
  )
  insert into mlb_backfill_staging
    (fecha_consulta, request_id, espn_event_id, kickoff, home_espn_id, away_espn_id,
     home_nombre, away_nombre, home_score, away_score, season_type, season_year,
     status_name, descartado_motivo)
  select fecha, request_id, espn_event_id, kickoff, home_espn_id, away_espn_id,
         home_nombre, away_nombre, home_score, away_score, season_type, season_year,
         status_name,
         case when season_type = 1 then 'pretemporada: no entra al backtest, se guarda para poder CORREGIR etiquetas'
              when season_type not in (1,2,3) then 'season_type '||season_type||': fuera de universo'
              when status_name <> 'STATUS_FINAL' then 'no finalizado'
              when home_score is null or away_score is null then 'sin marcador'
         end
  from filas
  where espn_event_id is not null
    and home_espn_id is not null and away_espn_id is not null
  on conflict (fecha_consulta, espn_event_id) do update
    set season_type = excluded.season_type,
        season_year = excluded.season_year,
        status_name = excluded.status_name,
        descartado_motivo = excluded.descartado_motivo,
        home_score = excluded.home_score,
        away_score = excluded.away_score;
  get diagnostics v_filas = row_count;

  update mlb_backfill_control c set estado='cargado',
    eventos=(select count(*) from mlb_backfill_staging s where s.fecha_consulta=c.fecha),
    actualizado_at=now()
  from net._http_response h
  where h.id=c.request_id and c.estado='solicitado' and h.status_code=200;

  update mlb_backfill_control c set estado='error',
    ultimo_error='HTTP '||h.status_code, actualizado_at=now()
  from net._http_response h
  where h.id=c.request_id and c.estado='solicitado' and h.status_code <> 200;

  return jsonb_build_object(
    'cargadas', (select count(*) from mlb_backfill_control where estado='cargado'),
    'con_error', (select count(*) from mlb_backfill_control where estado='error'),
    'pendientes', (select count(*) from mlb_backfill_control where estado in ('pendiente','solicitado')),
    'filas_staging_tocadas', v_filas);
end $function$;

-- ===========================================================================
-- 3) APLICAR: dedup EXPLÍCITO, conflictos registrados, etiqueta DERIVADA
--    "0 duplicados" se reporta en dos cifras separadas, como pidió el dueño:
--    duplicados_colapsados_antes_de_aplicar y duplicados_aplicados.
-- ===========================================================================
create or replace function public.mlb_season_type_aplicar()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_conf int := 0; v_upd int := 0; v_ins int := 0; v_dup_aplicados int := 0;
begin
  create temporary table if not exists _st (
    espn_event_id text primary key, kickoff timestamptz,
    home_espn_id text, away_espn_id text, home_nombre text, away_nombre text,
    home_score int, away_score int, season_type int, season_year int, status_name text
  ) on commit drop;
  delete from _st;

  insert into _st
  select distinct on (espn_event_id) espn_event_id, kickoff,
         home_espn_id, away_espn_id, home_nombre, away_nombre,
         home_score, away_score, season_type, season_year, status_name
  from mlb_backfill_staging
  order by espn_event_id, source_asof desc;

  insert into mlb_season_type_conflictos
    (espn_event_id, fecha, tipo_en_db, season_type_espn, tipo_derivado)
  select h.espn_event_id, h.fecha::date, h.tipo_temporada, s.season_type,
         case s.season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end
  from historico_partidos_espn h
  join _st s on s.espn_event_id = h.espn_event_id
  where h.tipo_temporada is distinct from
        (case s.season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end)
    and not exists (select 1 from mlb_season_type_conflictos c
                     where c.espn_event_id = h.espn_event_id);
  get diagnostics v_conf = row_count;

  update historico_partidos_espn h
     set season_type = s.season_type,
         season_year = s.season_year,
         tipo_temporada = case s.season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end
  from _st s
  where s.espn_event_id = h.espn_event_id
    and (h.season_type is distinct from s.season_type
      or h.tipo_temporada is distinct from (case s.season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end));
  get diagnostics v_upd = row_count;

  insert into historico_partidos_espn
    (espn_event_id, espn_endpoint, fecha, home_espn_id, away_espn_id,
     home_nombre, away_nombre, home_score, away_score, tipo_temporada,
     season_type, season_year, cargado_at)
  select s.espn_event_id, 'baseball/mlb', s.kickoff, s.home_espn_id, s.away_espn_id,
         s.home_nombre, s.away_nombre, s.home_score, s.away_score,
         case s.season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end,
         s.season_type, s.season_year, now()
  from _st s
  where s.status_name = 'STATUS_FINAL'
    and s.home_score is not null and s.away_score is not null
    and not exists (select 1 from historico_partidos_espn h where h.espn_event_id = s.espn_event_id);
  get diagnostics v_ins = row_count;

  select count(*) into v_dup_aplicados from (
    select espn_event_id from historico_partidos_espn
     where espn_endpoint='baseball/mlb' group by 1 having count(*) > 1) d;

  return jsonb_build_object(
    'staging_filas_crudas', (select count(*) from mlb_backfill_staging),
    'staging_eventos_tras_dedup', (select count(*) from _st),
    'duplicados_colapsados_antes_de_aplicar',
      (select count(*) from mlb_backfill_staging) - (select count(*) from _st),
    'etiquetas_corregidas', v_upd,
    'conflictos_registrados', v_conf,
    'insertados_nuevos', v_ins,
    'duplicados_aplicados', v_dup_aplicados);
end $function$;

grant execute on function public.mlb_backfill_cosechar() to service_role;
grant execute on function public.mlb_season_type_aplicar() to service_role;

-- ===========================================================================
-- 4) CÓMO SE CORRIÓ LA RE-BAJADA (reproducible: es un bucle idempotente)
--    Se reinicia el control porque las fechas ya cargadas se bajaron con el
--    filtro viejo que tiraba los type 1, y por eso no sirven para corregir.
-- ===========================================================================
-- update public.mlb_backfill_control set estado='pendiente', intentos=0, ultimo_error=null;
-- insert into public.mlb_backfill_control (fecha)
-- select d::date from generate_series('2023-02-15'::date,'2023-11-10'::date, interval '1 day') d
-- union all select d::date from generate_series('2024-02-15'::date,'2024-11-10'::date, interval '1 day') d
-- union all select d::date from generate_series('2025-02-15'::date,'2025-11-10'::date, interval '1 day') d
-- union all select d::date from generate_series('2026-02-15'::date,'2026-09-12'::date, interval '1 day') d
-- on conflict (fecha) do nothing;
-- -- repetir hasta pendientes = 0 (pg_net es asincrono: cosechar NO devuelve
-- -- nada si se llama inmediatamente despues de encolar):
-- --   select public.mlb_backfill_encolar('2023-02-15','2026-09-12', 140);
-- --   select public.mlb_backfill_cosechar();
-- select public.mlb_season_type_aplicar();
--   Corrida real: 1,306 fechas, 0 errores HTTP, 10,512 etiquetas escritas,
--   55 conflictos registrados, 932 filas nuevas, 14 duplicados colapsados,
--   0 duplicados aplicados.

-- ===========================================================================
-- 5) ASSERTIONS: si esto no pasa, el patch NO quedó aplicado
-- ===========================================================================
do $$
declare v_n int; v_reg int;
begin
  -- 5a) la etiqueta se DERIVA del entero, sin excepciones
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type is not null
     and tipo_temporada is distinct from
         (case season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end);
  if v_n > 0 then raise exception 'ETIQUETA NO DERIVADA: % filas', v_n; end if;

  -- 5b) ninguna fila de MLB sin season_type
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type is null;
  if v_n > 0 then raise exception 'SIN SEASON_TYPE: % filas de MLB', v_n; end if;

  -- 5c) la temporada regular tiene que cuadrar con las ~2,430 reales
  for v_reg in select season_year from public.historico_partidos_espn
                where espn_endpoint='baseball/mlb' and season_type=2
                  and season_year between 2023 and 2025 group by 1
  loop
    select count(*) into v_n from public.historico_partidos_espn
     where espn_endpoint='baseball/mlb' and season_type=2 and season_year=v_reg;
    if v_n not between 2400 and 2440 then
      raise exception 'TEMPORADA REGULAR % fuera de rango: % partidos (esperado ~2,430)', v_reg, v_n;
    end if;
  end loop;

  -- 5d) regular y postseason NO se mezclan
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type=3 and season_year between 2023 and 2025;
  if v_n < 100 then raise exception 'POSTSEASON NO SEPARADA: solo % partidos type 3', v_n; end if;

  -- 5e) los conflictos quedaron registrados, no corregidos en silencio
  select count(*) into v_n from public.mlb_season_type_conflictos;
  if v_n = 0 then raise exception 'SIN REGISTRO DE CONFLICTOS: se corrigio en silencio'; end if;

  -- 5f) 0 duplicados APLICADOS en el destino
  select count(*) into v_n from (
    select espn_event_id from public.historico_partidos_espn
     where espn_endpoint='baseball/mlb' group by 1 having count(*)>1) d;
  if v_n > 0 then raise exception 'DUPLICADOS APLICADOS: %', v_n; end if;

  raise notice 'iss094 OK: season_type exacto, regular y postseason separadas, 0 duplicados aplicados';
end $$;

-- FIN iss094. El universo del backtest lo reconstruye iss094b.
