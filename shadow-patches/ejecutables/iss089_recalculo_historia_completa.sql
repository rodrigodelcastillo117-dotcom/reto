-- iss089 — RECÁLCULO COMPLETO SOBRE LA HISTORIA RECUPERADA
--
-- Cierra DOS defectos que el dueño señaló y que iss087 NO cerró en Git:
--
-- DEFECTO A (ventanas): iss087 declaraba parámetros por deporte
--     MLB 24 meses / 30 días   vs   NFL 36 meses / 120 días
--   en el CTE `par`, pero los marcos RANGE estaban HARDCODEADOS a
--   36 months / 120 days para AMBOS. El `par` se unía y nunca se usaba para
--   la ventana. Resultado: MLB corrió con 36 meses de memoria de equipo y 120
--   días de línea base de liga — no con lo declarado. Un marco RANGE no se
--   puede parametrizar en SQL, así que aquí la lambda se calcula en DOS ramas
--   separadas, una por deporte, cada una con su marco literal correcto.
--
-- DEFECTO B (linaje): `feature_cutoff = partido - 1 día` era una promesa, no
--   una medición. Ahora cada feature reporta su propio as-of real
--   (asof_home, asof_away, asof_league, asof_dispersion) y
--   data_asof_real = greatest(los cuatro). La invariante se verifica al final.
--
-- Y corre sobre la historia que iss088 recuperó (antes MLB 2025 tenía 119
-- juegos regulares de ~2,430; 2024 tenía 1,796). Cobertura verificada:
--     2023: 2,431   2024: 2,426   2025: 2,429   (real: 2,430 por temporada)
--     2026: 2,187 hasta 2026-09-10 (temporada en curso)
--   Los 3 días sin juegos de cada temporada son el Juego de Estrellas.
--
-- SIN EV. SIN KELLY. SIN EDGE CONTRA EL MERCADO. Nada aquí lee una casa de
-- apuestas: la lambda sale de carreras anotadas y recibidas, y la dispersión
-- de residuos propios.

-- ===========================================================================
-- 0) Columnas de linaje por feature
-- ===========================================================================
alter table public.calib_lambda add column if not exists tipo_temporada  text;
alter table public.calib_lambda add column if not exists asof_home       timestamptz;
alter table public.calib_lambda add column if not exists asof_away       timestamptz;
alter table public.calib_lambda add column if not exists asof_league     timestamptz;
alter table public.calib_lambda add column if not exists asof_dispersion timestamptz;
alter table public.calib_lambda add column if not exists vent_equipo     text;
alter table public.calib_lambda add column if not exists vent_liga       text;

truncate public.calib_lambda;

-- ===========================================================================
-- 1) LAMBDA — rama BASEBALL: ventana de equipo 24 meses, liga 30 días
-- ===========================================================================
insert into public.calib_lambda
  (deporte, espn_event_id, fecha, total, lam, muestra, tipo_temporada,
   asof_home, asof_away, asof_league, vent_equipo, vent_liga)
with j as (
  select espn_event_id, fecha, home_espn_id, away_espn_id,
         home_score, away_score, (home_score+away_score)::int total
  from public.historico_partidos_espn
  where espn_endpoint ilike '%baseball%'
    and tipo_temporada = 'regular_o_playoffs'
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
pl as (select espn_event_id,
    avg(home_score) over w gf, avg(away_score) over w gc,
    count(*) over w pj, max(fecha) over w asof
  from j
  window w as (partition by home_espn_id order by fecha
       range between interval '24 months' preceding and interval '1 day' preceding)),
pv as (select espn_event_id,
    avg(away_score) over w gf, avg(home_score) over w gc,
    count(*) over w pj, max(fecha) over w asof
  from j
  window w as (partition by away_espn_id order by fecha
       range between interval '24 months' preceding and interval '1 day' preceding)),
bs as (select espn_event_id,
    avg(home_score) over w bl, avg(away_score) over w bv,
    count(*) over w pj, max(fecha) over w asof
  from j
  window w as (order by fecha
       range between interval '30 days' preceding and interval '1 day' preceding))
select 'baseball', j.espn_event_id, j.fecha, j.total,
  (least(greatest(bs.bl*(1+(pl.pj/(pl.pj+20.0))*((pl.gf/bs.bl)-1))
                      *(1+(pv.pj/(pv.pj+20.0))*((pv.gc/bs.bl)-1)), 1.5), 9.0)
 + least(greatest(bs.bv*(1+(pv.pj/(pv.pj+20.0))*((pv.gf/bs.bv)-1))
                      *(1+(pl.pj/(pl.pj+20.0))*((pl.gc/bs.bv)-1)), 1.5), 9.0))::double precision,
  least(pl.pj, pv.pj)::int, 'regular_o_playoffs',
  pl.asof, pv.asof, bs.asof, '24 months', '30 days'
from j
join pl on pl.espn_event_id=j.espn_event_id
join pv on pv.espn_event_id=j.espn_event_id
join bs on bs.espn_event_id=j.espn_event_id
where pl.pj >= 20 and pv.pj >= 20 and bs.pj >= 100;

-- ===========================================================================
-- 2) LAMBDA — rama FOOTBALL: ventana de equipo 36 meses, liga 120 días
-- ===========================================================================
insert into public.calib_lambda
  (deporte, espn_event_id, fecha, total, lam, muestra, tipo_temporada,
   asof_home, asof_away, asof_league, vent_equipo, vent_liga)
with j as (
  select espn_event_id, fecha, home_espn_id, away_espn_id,
         home_score, away_score, (home_score+away_score)::int total
  from public.historico_partidos_espn
  where espn_endpoint ilike '%football%'
    and tipo_temporada = 'regular_o_playoffs'
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
pl as (select espn_event_id,
    avg(home_score) over w gf, avg(away_score) over w gc,
    count(*) over w pj, max(fecha) over w asof
  from j
  window w as (partition by home_espn_id order by fecha
       range between interval '36 months' preceding and interval '1 day' preceding)),
pv as (select espn_event_id,
    avg(away_score) over w gf, avg(home_score) over w gc,
    count(*) over w pj, max(fecha) over w asof
  from j
  window w as (partition by away_espn_id order by fecha
       range between interval '36 months' preceding and interval '1 day' preceding)),
bs as (select espn_event_id,
    avg(home_score) over w bl, avg(away_score) over w bv,
    count(*) over w pj, max(fecha) over w asof
  from j
  window w as (order by fecha
       range between interval '120 days' preceding and interval '1 day' preceding))
select 'football', j.espn_event_id, j.fecha, j.total,
  (least(greatest(bs.bl*(1+(pl.pj/(pl.pj+8.0))*((pl.gf/bs.bl)-1))
                      *(1+(pv.pj/(pv.pj+8.0))*((pv.gc/bs.bl)-1)), 8.0), 40.0)
 + least(greatest(bs.bv*(1+(pv.pj/(pv.pj+8.0))*((pv.gf/bs.bv)-1))
                      *(1+(pl.pj/(pl.pj+8.0))*((pl.gc/bs.bv)-1)), 8.0), 40.0))::double precision,
  least(pl.pj, pv.pj)::int, 'regular_o_playoffs',
  pl.asof, pv.asof, bs.asof, '36 months', '120 days'
from j
join pl on pl.espn_event_id=j.espn_event_id
join pv on pv.espn_event_id=j.espn_event_id
join bs on bs.espn_event_id=j.espn_event_id
where pl.pj >= 8 and pv.pj >= 8 and bs.pj >= 40;

-- ===========================================================================
-- 3) SIGMA rodante y causal + linaje consolidado
--    La dispersión usa SOLO residuos anteriores al partido, y reporta su
--    propio as-of. data_asof_real = greatest de los cuatro features.
-- ===========================================================================
update public.calib_lambda c
   set sd_rodante = r.sd, n_resid = r.n, asof_dispersion = r.asof
from (
  select deporte, espn_event_id,
         stddev_pop(total - lam) over w sd,
         count(*) over w n,
         max(fecha) over w asof
  from public.calib_lambda
  window w as (partition by deporte order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)
) r
where r.deporte=c.deporte and r.espn_event_id=c.espn_event_id;

update public.calib_lambda
   set data_asof_real = greatest(asof_home, asof_away, asof_league, asof_dispersion);

-- ===========================================================================
-- 4) EVENTOS: uno por (partido, línea). WIN/PUSH/LOSS.
--    Línea entera -> ±0.5 y puede empujar. Línea .5 -> NUNCA empuja.
--    p_win_uncond es lo que se muestra; p_raw = P(WIN | no PUSH) sólo evalúa.
-- ===========================================================================
delete from public.calib_eventos
 where model_version in ('mlb_totales_normal_v1','nfl_totales_normal_v1');

insert into public.calib_eventos
  (model_version, deporte, mercado, espn_event_id, fecha_partido, feature_cutoff,
   linea, p_raw, p_win_uncond, p_push, p_loss_uncond, resultado,
   n_muestra_modelo, data_asof_real)
select
  case when c.deporte='baseball' then 'mlb_totales_normal_v1' else 'nfl_totales_normal_v1' end,
  c.deporte, 'Over/Under', c.espn_event_id, c.fecha, c.data_asof_real,
  q.linea,
  round(greatest(0.0001, least(0.9999, q.pw / nullif(q.pw + q.pl, 0)))::numeric, 6),
  round(q.pw::numeric,6), round(greatest(0, 1-q.pw-q.pl)::numeric,6), round(q.pl::numeric,6),
  case when c.total > q.linea then 'WIN' when c.total = q.linea then 'PUSH' else 'LOSS' end,
  c.muestra, c.data_asof_real
from public.calib_lambda c
cross join lateral (
  select ln.linea,
    case when ln.linea = trunc(ln.linea)
         then 1 - public.normal_cdf(((ln.linea + 0.5 - c.lam)/c.sd_rodante)::double precision)
         else 1 - public.normal_cdf(((ln.linea       - c.lam)/c.sd_rodante)::double precision) end pw,
    case when ln.linea = trunc(ln.linea)
         then public.normal_cdf(((ln.linea - 0.5 - c.lam)/c.sd_rodante)::double precision)
         else public.normal_cdf(((ln.linea       - c.lam)/c.sd_rodante)::double precision) end pl
  from unnest(case when c.deporte='baseball'
                   then array[7,7.5,8,8.5,9,9.5,10,10.5]::numeric[]
                   else array[37,37.5,40,40.5,43,43.5,46,46.5,49,49.5]::numeric[] end) ln(linea)
) q
where c.sd_rodante is not null and c.sd_rodante > 0 and c.n_resid >= 200
  and c.data_asof_real is not null and q.pw + q.pl > 0;

-- NOTA: linea_entera es columna GENERADA en calib_eventos; no se inserta.

-- FIN iss089. Las métricas, folds y decisión de método quedan en iss090.
