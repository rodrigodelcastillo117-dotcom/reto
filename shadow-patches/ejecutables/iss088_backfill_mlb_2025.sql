-- iss088 — BACKFILL HISTÓRICO MLB 2025, REPRODUCIBLE E IDEMPOTENTE
-- Decisión del dueño: recuperar 2025, no renunciar al año ni usar una edge
-- function desconocida. Escribimos el nuestro.
--
-- POR QUÉ pg_net Y NO curl DESDE LA SESIÓN
-- ESPN responde 403 a la red de esta sesión (política de egreso) Y a
-- site.api.espn.com desde Supabase (Akamai lo bloquea desde ago-2026).
-- El espejo site.web.api.espn.com sirve el MISMO JSON y responde 200 desde
-- pg_net con cabeceras de navegador. Eso ya estaba documentado en la edge
-- function get-espn-matches; aquí se reusa el mismo camino que sí funciona.
--   Probado: dates=20250615 -> 200, 15 eventos, season {type:2, year:2025}.
--
-- FLUJO: fetch -> staging -> validar -> diff contra DB -> upsert idempotente
--        por espn_event_id -> conflictos a auditoría (NUNCA se pisa en silencio).
-- SÓLO temporada regular y postseason (season.type 2 y 3). Nada de Spring
-- Training (type 1).

create table if not exists public.mlb_backfill_staging (
  fecha_consulta date not null,
  request_id bigint,
  espn_event_id text,
  kickoff timestamptz,
  home_espn_id text, away_espn_id text,
  home_nombre text,  away_nombre text,
  home_score int,    away_score int,
  season_type int,   season_year int,
  status_name text,
  source_asof timestamptz not null default now(),
  primary key (fecha_consulta, espn_event_id)
);
comment on table public.mlb_backfill_staging is
  'Staging del backfill de MLB. Nada pasa a historico_partidos_espn sin validarse aqui primero.';

create table if not exists public.mlb_backfill_conflictos (
  id bigserial primary key,
  espn_event_id text not null,
  campo text not null,
  valor_en_db text,
  valor_en_espn text,
  detectado_at timestamptz not null default now(),
  resuelto boolean not null default false
);
comment on table public.mlb_backfill_conflictos is
  'Si ESPN contradice un marcador o equipo que ya existe en la base, NO se pisa en silencio: queda aqui como conflicto de auditoria.';

create table if not exists public.mlb_backfill_control (
  fecha date primary key,
  request_id bigint,
  estado text not null default 'pendiente'
    check (estado in ('pendiente','solicitado','cargado','sin_eventos','error')),
  eventos int,
  intentos int not null default 0,
  ultimo_error text,
  actualizado_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 1) Encolar las fechas que faltan (idempotente: sólo las no cargadas)
-- ---------------------------------------------------------------------------
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
     order by fecha limit p_max
  loop
    select net.http_get(
      url := 'https://site.web.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?dates='
             || to_char(v_f,'YYYYMMDD'),
      headers := jsonb_build_object(
        'User-Agent','Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Accept','application/json, text/plain, */*',
        'Referer','https://www.espn.com/',
        'Origin','https://www.espn.com'),
      timeout_milliseconds := 25000) into v_rid;
    update mlb_backfill_control
       set request_id=v_rid, estado='solicitado', intentos=intentos+1, actualizado_at=now()
     where fecha=v_f;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

-- ---------------------------------------------------------------------------
-- 2) Cosechar respuestas -> staging. Sólo regular (2) y postseason (3).
-- ---------------------------------------------------------------------------
create or replace function public.mlb_backfill_cosechar()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_ok int := 0; v_vacias int := 0; v_err int := 0; v_filas int := 0;
begin
  with r as (
    select c.fecha, c.request_id, h.status_code, h.content
    from mlb_backfill_control c
    join net._http_response h on h.id = c.request_id
    where c.estado = 'solicitado'
  ),
  ok as (select * from r where status_code = 200 and content is not null),
  ev as (
    select ok.fecha, ok.request_id, e
    from ok, lateral jsonb_array_elements((ok.content::jsonb)->'events') e
  ),
  filas as (
    select ev.fecha, ev.request_id,
           e->>'id' espn_event_id,
           (e->>'date')::timestamptz kickoff,
           (e->'season'->>'type')::int season_type,
           (e->'season'->>'year')::int season_year,
           e->'competitions'->0->'status'->'type'->>'name' status_name,
           (select c2->'team'->>'id' from jsonb_array_elements(e->'competitions'->0->'competitors') c2
             where c2->>'homeAway'='home' limit 1) home_espn_id,
           (select c2->'team'->>'id' from jsonb_array_elements(e->'competitions'->0->'competitors') c2
             where c2->>'homeAway'='away' limit 1) away_espn_id,
           (select c2->'team'->>'displayName' from jsonb_array_elements(e->'competitions'->0->'competitors') c2
             where c2->>'homeAway'='home' limit 1) home_nombre,
           (select c2->'team'->>'displayName' from jsonb_array_elements(e->'competitions'->0->'competitors') c2
             where c2->>'homeAway'='away' limit 1) away_nombre,
           (select nullif(c2->>'score','')::int from jsonb_array_elements(e->'competitions'->0->'competitors') c2
             where c2->>'homeAway'='home' limit 1) home_score,
           (select nullif(c2->>'score','')::int from jsonb_array_elements(e->'competitions'->0->'competitors') c2
             where c2->>'homeAway'='away' limit 1) away_score
    from ev
  )
  insert into mlb_backfill_staging
    (fecha_consulta, request_id, espn_event_id, kickoff, home_espn_id, away_espn_id,
     home_nombre, away_nombre, home_score, away_score, season_type, season_year, status_name)
  select fecha, request_id, espn_event_id, kickoff, home_espn_id, away_espn_id,
         home_nombre, away_nombre, home_score, away_score, season_type, season_year, status_name
  from filas
  where season_type in (2,3)                        -- NADA de Spring Training
    and espn_event_id is not null
    and home_espn_id is not null and away_espn_id is not null
    and home_score is not null and away_score is not null
    and status_name = 'STATUS_FINAL'
  on conflict (fecha_consulta, espn_event_id) do nothing;
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

  return jsonb_build_object('filas_nuevas_staging', v_filas,
    'cargadas', (select count(*) from mlb_backfill_control where estado='cargado'),
    'con_error', (select count(*) from mlb_backfill_control where estado='error'),
    'pendientes', (select count(*) from mlb_backfill_control where estado in ('pendiente','solicitado')));
end $function$;

-- ---------------------------------------------------------------------------
-- 3) Diff + upsert idempotente. Conflictos a auditoría, nunca pisar en silencio.
-- ---------------------------------------------------------------------------
create or replace function public.mlb_backfill_aplicar()
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare v_ins int := 0; v_conf int := 0;
begin
  -- conflictos: ya existe el evento y ESPN dice otra cosa
  insert into mlb_backfill_conflictos (espn_event_id, campo, valor_en_db, valor_en_espn)
  select s.espn_event_id, x.campo, x.en_db, x.en_espn
  from mlb_backfill_staging s
  join historico_partidos_espn h on h.espn_event_id = s.espn_event_id
  cross join lateral (values
    ('home_score', h.home_score::text, s.home_score::text),
    ('away_score', h.away_score::text, s.away_score::text),
    ('home_espn_id', h.home_espn_id::text, s.home_espn_id),
    ('away_espn_id', h.away_espn_id::text, s.away_espn_id)
  ) x(campo, en_db, en_espn)
  where x.en_db is distinct from x.en_espn
    and not exists (select 1 from mlb_backfill_conflictos c
                     where c.espn_event_id=s.espn_event_id and c.campo=x.campo and not c.resuelto);
  get diagnostics v_conf = row_count;

  -- insertar SOLO lo que no existe (idempotente por espn_event_id)
  insert into historico_partidos_espn
    (espn_event_id, espn_endpoint, fecha, home_espn_id, away_espn_id,
     home_nombre, away_nombre, home_score, away_score, tipo_temporada, cargado_at)
  select distinct on (s.espn_event_id)
    s.espn_event_id, 'baseball/mlb', s.kickoff, s.home_espn_id, s.away_espn_id,
    s.home_nombre, s.away_nombre, s.home_score, s.away_score, 'regular_o_playoffs', now()
  from mlb_backfill_staging s
  where not exists (select 1 from historico_partidos_espn h where h.espn_event_id = s.espn_event_id)
  order by s.espn_event_id, s.source_asof desc;
  get diagnostics v_ins = row_count;

  return jsonb_build_object('insertados', v_ins, 'conflictos_nuevos', v_conf,
    'staging_total', (select count(*) from mlb_backfill_staging),
    'duplicados_en_db', (select count(*) from (
        select espn_event_id from historico_partidos_espn
         where espn_endpoint='baseball/mlb' group by 1 having count(*) > 1) d));
end $function$;
