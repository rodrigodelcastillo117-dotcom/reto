-- iss087 — FUERA LA PRETEMPORADA + FOLDS Y BOOTSTRAP REPRODUCIBLES
-- Responde al AUDIT_NO_PASS, comentario 5641203225.
--
-- BLOCKER 1 (el grave): los backtests mezclaban Spring Training con temporada
-- regular. historico_partidos_espn TIENE la columna tipo_temporada y yo nunca
-- la filtre. Medido:
--     MLB  6,470 regular_o_playoffs  vs   853 pretemporada
--     NFL  1,693 regular_o_playoffs  vs   293 pretemporada
--   Por año en MLB la contaminacion no es uniforme:
--     2023: 2,511 reg /  15 pre     2024: 1,796 reg / 296 pre
--     2025:   119 reg /  94 pre     2026: 2,044 reg / 448 pre
--   El Brier 0.238846 y su IC95 NO son el numero limpio de MLB regular.
--
-- BLOCKER 2: los folds y el bootstrap vivian en comandos manuales. Aqui quedan
-- como SQL ejecutable.
--
-- BLOCKER 3: la tabla viva `calibradores` conservaba los numeros contaminados
-- de V1 con elegido=true. Se invalidan explicitamente.
--
-- PENDIENTE QUE NO SE RESUELVE AQUI: MLB 2025 tiene 119 juegos regulares de
-- ~2,430. Recuperarla exige una corrida de ingesta contra ESPN; no hay funcion
-- de backfill historico en la base y no se disparan edge functions a ciegas.

-- ===========================================================================
-- 1) calib_lambda RECONSTRUIDA: solo regular_o_playoffs, en TODO -- tanto en el
--    partido evaluado como en la historia que alimenta sus ventanas.
-- ===========================================================================
alter table public.calib_lambda add column if not exists tipo_temporada text;
truncate public.calib_lambda;

insert into public.calib_lambda (deporte, espn_event_id, fecha, total, lam, muestra, tipo_temporada)
with j as (
  select case when espn_endpoint ilike '%baseball%' then 'baseball' else 'football' end dep,
         espn_event_id, fecha, home_espn_id, away_espn_id, home_score, away_score,
         (home_score+away_score)::int total
  from public.historico_partidos_espn
  where (espn_endpoint ilike '%baseball%' or espn_endpoint ilike '%football%')
    and tipo_temporada = 'regular_o_playoffs'          -- <<< EL FILTRO QUE FALTABA
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
par as (select dep,
  case dep when 'baseball' then interval '24 months' else interval '36 months' end vent,
  case dep when 'baseball' then interval '30 days'   else interval '120 days'  end vliga,
  case dep when 'baseball' then 20.0 else 8.0 end peso,
  case dep when 'baseball' then 20   else 8   end minpj,
  case dep when 'baseball' then 100  else 40  end minliga,
  case dep when 'baseball' then 1.5  else 8.0 end lmin,
  case dep when 'baseball' then 9.0  else 40.0 end lmax
  from (select distinct dep from j) d),
pl as (select j.dep, j.espn_event_id,
    avg(j.home_score) over w gf, avg(j.away_score) over w gc, count(*) over w pj
  from j join par p on p.dep=j.dep
  window w as (partition by j.dep, j.home_espn_id order by j.fecha
       range between interval '36 months' preceding and interval '1 day' preceding)),
pv as (select j.dep, j.espn_event_id,
    avg(j.away_score) over w gf, avg(j.home_score) over w gc, count(*) over w pj
  from j join par p on p.dep=j.dep
  window w as (partition by j.dep, j.away_espn_id order by j.fecha
       range between interval '36 months' preceding and interval '1 day' preceding)),
bs as (select j.dep, j.espn_event_id,
    avg(j.home_score) over w bl, avg(j.away_score) over w bv, count(*) over w pj
  from j join par p on p.dep=j.dep
  window w as (partition by j.dep order by j.fecha
       range between interval '120 days' preceding and interval '1 day' preceding))
select j.dep, j.espn_event_id, j.fecha, j.total,
  (least(greatest(bs.bl*(1+(pl.pj/(pl.pj+p.peso))*((pl.gf/bs.bl)-1))
                      *(1+(pv.pj/(pv.pj+p.peso))*((pv.gc/bs.bl)-1)), p.lmin), p.lmax)
 + least(greatest(bs.bv*(1+(pv.pj/(pv.pj+p.peso))*((pv.gf/bs.bv)-1))
                      *(1+(pl.pj/(pl.pj+p.peso))*((pl.gc/bs.bv)-1)), p.lmin), p.lmax))::double precision,
  least(pl.pj, pv.pj)::int, 'regular_o_playoffs'
from j
join par p on p.dep=j.dep
join pl on pl.dep=j.dep and pl.espn_event_id=j.espn_event_id
join pv on pv.dep=j.dep and pv.espn_event_id=j.espn_event_id
join bs on bs.dep=j.dep and bs.espn_event_id=j.espn_event_id
where pl.pj >= p.minpj and pv.pj >= p.minpj and bs.pj >= p.minliga;

-- sigma RODANTE y causal, tambien solo con regular
update public.calib_lambda c set sd_rodante = r.sd, n_resid = r.n, data_asof_real = r.asof
from (
  select deporte, espn_event_id,
         stddev_pop(total - lam) over w sd, count(*) over w n,
         max(fecha) over (partition by deporte order by fecha
                          range between unbounded preceding and interval '1 day' preceding) asof
  from public.calib_lambda
  window w as (partition by deporte order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)
) r
where r.deporte=c.deporte and r.espn_event_id=c.espn_event_id;

-- ===========================================================================
-- 2) EVENTOS regenerados sobre la base limpia
-- ===========================================================================
delete from public.calib_eventos where model_version in ('mlb_totales_normal_v1','nfl_totales_normal_v1');
insert into public.calib_eventos
  (model_version, deporte, mercado, espn_event_id, fecha_partido, feature_cutoff,
   linea, p_raw, p_win_uncond, p_push, p_loss_uncond, resultado, n_muestra_modelo, data_asof_real)
select
  case when c.deporte='baseball' then 'mlb_totales_normal_v1' else 'nfl_totales_normal_v1' end,
  c.deporte, 'Over/Under', c.espn_event_id, c.fecha, c.data_asof_real, q.linea,
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

-- ===========================================================================
-- 3) BOOTSTRAP REPRODUCIBLE (antes vivia en comandos manuales). Cluster = PARTIDO.
-- ===========================================================================
create or replace function public.bootstrap_mejora_por_partido(
  p_model text, p_params jsonb, p_desde timestamptz, p_hasta timestamptz, p_reps int default 1000)
returns jsonb language sql stable set search_path to 'public' as $function$
with por_partido as (
  select espn_event_id,
         avg(power(p_raw::double precision - (resultado='WIN')::int, 2))
       - avg(power(greatest(1e-6, least(1-1e-6,
             1.0/(1.0+exp(-((p_params->>'a')::double precision
                          + (p_params->>'b')::double precision * ln(p_raw/(1-p_raw))::double precision)))))
             - (resultado='WIN')::int, 2)) as mejora
  from calib_eventos
  where model_version=p_model and fecha_partido >= p_desde and fecha_partido < p_hasta
    and resultado in ('WIN','LOSS') and p_raw is not null
  group by 1
),
idx as (select row_number() over (order by espn_event_id) i, mejora from por_partido),
n as (select count(*)::int c from idx),
draws as (select b.b, 1 + floor(random()*(select c from n))::int i
          from generate_series(1,p_reps) b(b), generate_series(1,(select c from n)) g(g)),
boot as (select d.b, avg(x.mejora) prom from draws d join idx x on x.i=d.i group by d.b)
select jsonb_build_object(
  'n_partidos', (select c from n),
  'mejora_media_brier', round(avg(prom)::numeric,6),
  'ic95_inf', round(percentile_cont(0.025) within group (order by prom)::numeric,6),
  'ic95_sup', round(percentile_cont(0.975) within group (order by prom)::numeric,6),
  'pct_remuestreos_a_favor', round((100.0*count(*) filter (where prom>0)/count(*))::numeric,1),
  'significativa', (percentile_cont(0.025) within group (order by prom)) > 0,
  'reps', p_reps)
from boot;
$function$;
grant execute on function public.bootstrap_mejora_por_partido(text,jsonb,timestamptz,timestamptz,int)
  to anon, authenticated, service_role;

-- ===========================================================================
-- 4) FOLDS POR TEMPORADA (reproducibles). El metodo se elige AQUI.
-- ===========================================================================
truncate public.calib_fits;
insert into public.calib_fits values
 ('mlb_s2023','mlb_totales_normal_v1',1,'2024-01-01','2024-01-01','2025-01-01',
   public.fit_platt('mlb_totales_normal_v1','2000-01-01'::timestamptz,'2024-01-01'::timestamptz)),
 ('nfl_s2022','nfl_totales_normal_v1',1,'2023-07-01','2023-07-01','2024-07-01',
   public.fit_platt('nfl_totales_normal_v1','2000-01-01'::timestamptz,'2023-07-01'::timestamptz)),
 ('nfl_s2023','nfl_totales_normal_v1',2,'2024-07-01','2024-07-01','2025-07-01',
   public.fit_platt('nfl_totales_normal_v1','2000-01-01'::timestamptz,'2024-07-01'::timestamptz)),
 ('mlb_final','mlb_totales_normal_v1',99,'2025-01-01','2026-01-01','2027-01-01',
   public.fit_platt('mlb_totales_normal_v1','2000-01-01'::timestamptz,'2025-01-01'::timestamptz));

-- ===========================================================================
-- 5) INVALIDAR los calibradores contaminados que seguian vivos con elegido=true
-- ===========================================================================
alter table public.calibradores add column if not exists invalidado boolean not null default false;
alter table public.calibradores add column if not exists motivo_invalidacion text;
update public.calibradores
set elegido = false, invalidado = true,
    motivo_invalidacion = 'INVALIDADO 11-sep-2026 (AUDIT_NO_PASS 5641203225). Ajustado sobre un universo que mezclaba pretemporada con temporada regular, y con las probabilidades de linea .5 infladas. Sustituido por cal_v2_limpio.'
where calibration_version in ('cal_v1_2026_09_11','cal_v2_simulacion');

-- FIN iss087. Numeros en shadow-patches/REPORTE_CALIBRACION_V2_LIMPIO.md
