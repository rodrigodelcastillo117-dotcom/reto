-- iss068 · La pestaña de fútbol estaba vacía por DOS bugs, no por falta de datos.
--
-- CÓMO SE ENCONTRÓ
-- Perseguía la causa del fallo diario de RONGOL (job 182). Medí los 14 pasos del
-- ciclo uno por uno: los 13 "normales" suman 7.6 segundos. El paso caro resultó ser
-- el INSERT final de bitácora, y dentro de él un `select count(*) from picks_premium`.
-- picks_premium es una VISTA: contarla materializa todo. Se murió a los 25s dentro
-- de norm_equipo_txt.
--
-- BUG 1 — v_analisis_fut_completo: producto cartesiano de 83.5 millones de pares.
-- El emparejamiento partido <-> snapshot de momios era un LEFT JOIN LATERAL que por
-- CADA fila de `enriquecido` (2,622 = 102 partidos × sus mercados) recorría los
-- 31,841 snapshots de los últimos 3 días calculando 4 norm_equipo_txt (cadena de
-- regexp) + 2 similarity por par. Medido: 2,622 × 31,841 = 83.5 millones.
--   - v_analisis_fut_completo: TIMEOUT (>60s)
--   - picks_premium:           TIMEOUT (>25s, no se podía ni contar)
--   - v_picks_futbol_calc:     TIMEOUT (>20s)  <-- ésta la lee la app
-- El emparejamiento depende SOLO de los nombres de equipo, no del mercado, así que
-- se repetía ~26 veces por partido de gratis.
-- ARREGLO: se calcula 1 vez por partido en mv_fut_precio_snapshot (materialized
-- view, refrescada por cron cada 30 min), con índice GIN trigram para podar.
-- Equivalencia verificada sobre el conjunto COMPLETO: 104/104 partidos devuelven el
-- mismo snapshot.id que el método viejo. 0 diferencias.
--   Resultado como anon: 0.095s para las tres vistas juntas (antes: timeout).
--
-- BUG 2 — v_picks_futbol_calc: el LEFT JOIN se volvía INNER JOIN silencioso.
--   LEFT JOIN LATERAL (... predicciones_modelo ...) pm ON true
--   WHERE ... AND NOT (pm.lambda_local = 1.35 AND pm.lambda_visita = 1.35)
-- Si el LATERAL no empareja, pm.lambda_local es NULL. NULL = 1.35 es NULL;
-- NULL AND NULL es NULL; NOT NULL es NULL; la fila se DESCARTA.
-- Y el LATERAL unía por igualdad EXACTA de nombres contra predicciones_modelo.
-- Medido el 2026-09-11: de 103 filas de picks_premium, UNA sola emparejaba. De los
-- 29 picks que pasaban todos los demás filtros, CERO. Normalizando con
-- norm_equipo_txt: también cero. predicciones_modelo simplemente no cubre estos
-- partidos (incluso tiene filas de MLB: "Chicago Cubs vs Pittsburgh Pirates").
-- Resultado: la vista devolvía 0 filas SIEMPRE. La pestaña de fútbol vacía.
-- ARREGLO: el respaldo se deriva de la muestra del propio pick
-- (muestra_modelo = least(pj_local, pj_visita), lo que devuelve lambdas_partido),
-- con los MISMOS umbrales que ya usa construir_dossier_partido:
-- >=12 alta, >=6 media, resto baja. No inventé umbrales nuevos.
-- La exclusión del fallback 1.35/1.35 ya la hace v_analisis_fut_completo en su CTE
-- base sobre las lambdas reales, así que aquí sólo se deja NULL-safe con COALESCE.
--   Resultado como anon: 29 picks, 5 apostables, 6 ligas (Liga MX, MLS, Serie A,
--   Jupiler Pro League, Liga 1...), mezcla real de Over 2.5 / Under 2.5 / Over 3.5 /
--   Under 3.5 — no "todos menos de 3.5". Momios reales de DraftKings.
--
-- ORDEN DE APLICACIÓN: 1) columnas generadas  2) índices GIN (cada uno solo)
-- 3) matview  4) función de refresco  5) GRANT (solo, nunca con un test)
-- 6) las tres vistas en orden  7) cron.
-- Las tres vistas completas se aplicaron con `create or replace view` preservando
-- el orden de columnas y apendizando las nuevas al final, que es lo único que
-- Postgres permite sin dropear dependientes.

-- 1) Dejar de recalcular la normalización 83 millones de veces.
alter table public.radar_odds_snapshots
  add column if not exists norm_home_txt text generated always as (public.norm_equipo_txt(home_team)) stored,
  add column if not exists norm_away_txt text generated always as (public.norm_equipo_txt(away_team)) stored;

-- 2) Índices trigram. CADA CREATE INDEX EN SU PROPIA LLAMADA.
create index if not exists idx_ros_trgm_home_txt
  on public.radar_odds_snapshots using gin (norm_home_txt public.gin_trgm_ops);
create index if not exists idx_ros_trgm_away_txt
  on public.radar_odds_snapshots using gin (norm_away_txt public.gin_trgm_ops);

-- 3) El emparejamiento, 1 vez por partido en lugar de 1 vez por mercado.
--    El operador % es SOLO un pre-filtro indexado; el filtro exacto sigue siendo
--    similarity() > 0.45. Con el umbral en 0.45 el conjunto de % es un
--    superconjunto de > 0.45, así que el resultado es idéntico.
drop materialized view if exists public.mv_fut_precio_snapshot;
create materialized view public.mv_fut_precio_snapshot as
select f.fixture_id,
       o.id, o.odds_event_id, o.home_team, o.away_team, o.sport_key,
       o.home_ml, o.away_ml, o.draw_ml, o.over_odds, o.under_odds, o.over_line,
       o.snapshot_at, o.espn_event_id, o.bookmaker, o.overround, o.confiable,
       now() as emparejado_at
from (select distinct fixture_id, home_nombre, away_nombre
      from public.fut_predicciones
      where fecha > now() - interval '3 hours') f
left join lateral (
  select r.id, r.odds_event_id, r.home_team, r.away_team, r.sport_key,
         r.home_ml, r.away_ml, r.draw_ml, r.over_odds, r.under_odds, r.over_line,
         r.snapshot_at, r.espn_event_id, r.bookmaker, r.overround, r.confiable
  from public.radar_odds_snapshots r
  where r.snapshot_at > (now() - '3 days'::interval)
    and r.norm_home_txt operator(public.%) public.norm_equipo_txt(f.home_nombre)
    and r.norm_away_txt operator(public.%) public.norm_equipo_txt(f.away_nombre)
    and similarity(public.norm_equipo_txt(r.home_team), public.norm_equipo_txt(f.home_nombre)) > 0.45::double precision
    and similarity(public.norm_equipo_txt(r.away_team), public.norm_equipo_txt(f.away_nombre)) > 0.45::double precision
  order by r.snapshot_at desc
  limit 1
) o on true
with no data;

-- 4) Refresco. El umbral de pg_trgm se fija AQUÍ para que no dependa de la sesión.
create or replace function public.refrescar_mv_fut_precio_snapshot()
returns text
language plpgsql
as $$
declare v_t0 timestamptz := clock_timestamp(); v_n int; v_con int;
begin
  perform set_config('pg_trgm.similarity_threshold', '0.45', true);
  perform set_config('statement_timeout', '300000', true);
  refresh materialized view public.mv_fut_precio_snapshot;
  select count(*), count(*) filter (where id is not null)
    into v_n, v_con from public.mv_fut_precio_snapshot;
  insert into public.rongol_paso_log (paso, fin, ok, segundos, detalle)
  values ('refrescar_mv_fut_precio_snapshot', now(), true,
          round(extract(epoch from (clock_timestamp()-v_t0))::numeric,2),
          format('partidos=%s con_precio=%s', v_n, v_con));
  return format('partidos=%s con_precio=%s', v_n, v_con);
exception when others then
  insert into public.rongol_paso_log (paso, fin, ok, segundos, detalle)
  values ('refrescar_mv_fut_precio_snapshot', now(), false,
          round(extract(epoch from (clock_timestamp()-v_t0))::numeric,2), left(sqlerrm,500));
  return 'ERROR: ' || sqlerrm;
end;
$$;

-- 5) GRANT SOLO. Un GRANT junto a un test que falla se va con el rollback.
grant select on public.mv_fut_precio_snapshot to anon, authenticated;

-- 6) Cron: refresco cada 30 min, en :05 y :35 (después de que corra el lote de futuros).
-- select cron.schedule('mv-fut-precio-refresh', '5,35 * * * *',
--   'select public.refrescar_mv_fut_precio_snapshot();');
-- jobid asignado: 460

-- PENDIENTE CONOCIDO, no resuelto aquí:
-- predicciones_modelo no cubre los partidos de picks_premium (1 de 103). La tabla
-- se alimenta de otra cadena (capturar_predicciones / motor_snapshot_capturar) y
-- mezcla deportes. No la toqué: el respaldo ahora sale del dato propio del pick,
-- que es más directo y no depende de emparejar nombres. Pero si alguien quiere que
-- predicciones_modelo sirva para fútbol, hay que arreglar su ingesta, no esta vista.
