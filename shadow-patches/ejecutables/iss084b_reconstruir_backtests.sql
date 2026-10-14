-- iss084b — POBLADO DE LOS BACKTESTS. Correr DESPUÉS de iss084.
-- Cada bloque tarda ~50s. Correr sueltos si hay statement_timeout corto.
--
-- Sin este archivo, zonas_confiables no se puede regenerar de cero y la
-- calibración no sería reproducible. Es la pieza que faltaba.

-- ===========================================================================
-- A) MLB — TOTALES. 7,323 juegos con marcador; 6,022 usables (>=20 juegos
--    previos por equipo en esa condicion y >=100 de liga en 30 dias).
-- ===========================================================================
truncate public.backtest_mlb_totales;
with lf as (
  select i, sum(case when i=0 then 0 else ln(i::double precision) end)
             over (order by i rows between unbounded preceding and current row) lnfact
  from generate_series(0,30) i
),
mlb as (
  select espn_event_id, fecha, home_espn_id, away_espn_id, home_score, away_score,
         (home_score + away_score)::int total
  from public.historico_partidos_espn
  where espn_endpoint ilike '%baseball%'
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
perf_l as (select espn_event_id, avg(home_score) over w gf_l, avg(away_score) over w gc_l, count(*) over w pj_l
  from mlb window w as (partition by home_espn_id order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)),
perf_v as (select espn_event_id, avg(away_score) over w gf_v, avg(home_score) over w gc_v, count(*) over w pj_v
  from mlb window w as (partition by away_espn_id order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)),
base as (select espn_event_id, avg(home_score) over w base_l, avg(away_score) over w base_v, count(*) over w pj_liga
  from mlb window w as (order by fecha
               range between interval '30 days' preceding and interval '1 day' preceding)),
lam as (
  select m.espn_event_id, m.fecha, m.total, least(l.pj_l, v.pj_v)::int muestra,
    (least(greatest(b.base_l * (1 + (l.pj_l/(l.pj_l+20.0))*((l.gf_l/b.base_l)-1))
                           * (1 + (v.pj_v/(v.pj_v+20.0))*((v.gc_v/b.base_l)-1)), 1.5), 9.0)
   + least(greatest(b.base_v * (1 + (v.pj_v/(v.pj_v+20.0))*((v.gf_v/b.base_v)-1))
                           * (1 + (l.pj_l/(l.pj_l+20.0))*((l.gc_l/b.base_v)-1)), 1.5), 9.0))::double precision lam
  from mlb m join perf_l l using (espn_event_id) join perf_v v using (espn_event_id) join base b using (espn_event_id)
  where l.pj_l >= 20 and v.pj_v >= 20 and b.pj_liga >= 100
)
insert into public.backtest_mlb_totales (espn_event_id, fecha, total, lam, muestra, linea, lado, prob, acerto)
select x.espn_event_id, x.fecha, x.total, x.lam, x.muestra, q.linea, q.lado, q.prob,
       case when q.lado='Under' then x.total < q.linea else x.total > q.linea end
from lam x
cross join lateral (
  select ln.linea, lado.lado,
    case when lado.lado='Under'
         then 1 - public.prob_total_sobre(x.lam::numeric, ln.linea, 'baseball')
         else     public.prob_total_sobre(x.lam::numeric, ln.linea, 'baseball') end prob
  from (values (7.5::numeric),(8.5),(9.5),(10.5)) ln(linea)
  cross join (values ('Under'),('Over')) lado(lado)
) q;

-- ===========================================================================
-- B) NFL — TOTALES. 1,986 juegos con marcador; 1,443 usables.
-- ===========================================================================
truncate public.backtest_nfl_totales;
with nfl as (
  select espn_event_id, fecha, home_espn_id, away_espn_id, home_score, away_score,
         (home_score + away_score)::int total
  from public.historico_partidos_espn
  where espn_endpoint ilike '%football%'
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
perf_l as (select espn_event_id, avg(home_score) over w gf_l, avg(away_score) over w gc_l, count(*) over w pj_l
  from nfl window w as (partition by home_espn_id order by fecha
               range between interval '36 months' preceding and interval '1 day' preceding)),
perf_v as (select espn_event_id, avg(away_score) over w gf_v, avg(home_score) over w gc_v, count(*) over w pj_v
  from nfl window w as (partition by away_espn_id order by fecha
               range between interval '36 months' preceding and interval '1 day' preceding)),
base as (select espn_event_id, avg(home_score) over w base_l, avg(away_score) over w base_v, count(*) over w pj_liga
  from nfl window w as (order by fecha
               range between interval '120 days' preceding and interval '1 day' preceding)),
lam as (
  select m.espn_event_id, m.fecha, m.total, least(l.pj_l, v.pj_v)::int muestra,
    (least(greatest(b.base_l * (1 + (l.pj_l/(l.pj_l+8.0))*((l.gf_l/b.base_l)-1))
                           * (1 + (v.pj_v/(v.pj_v+8.0))*((v.gc_v/b.base_l)-1)), 8.0), 40.0)
   + least(greatest(b.base_v * (1 + (v.pj_v/(v.pj_v+8.0))*((v.gf_v/b.base_v)-1))
                           * (1 + (l.pj_l/(l.pj_l+8.0))*((l.gc_l/b.base_v)-1)), 8.0), 40.0))::double precision lam
  from nfl m join perf_l l using (espn_event_id) join perf_v v using (espn_event_id) join base b using (espn_event_id)
  where l.pj_l >= 8 and v.pj_v >= 8 and b.pj_liga >= 40
)
insert into public.backtest_nfl_totales (espn_event_id, fecha, total, lam, muestra, linea, lado, prob, acerto)
select x.espn_event_id, x.fecha, x.total, x.lam, x.muestra, q.linea, q.lado, q.prob,
       case when q.lado='Under' then x.total < q.linea else x.total > q.linea end
from lam x
cross join lateral (
  select ln.linea, lado.lado,
    case when lado.lado='Under'
         then 1 - public.prob_total_sobre(x.lam::numeric, ln.linea, 'football')
         else     public.prob_total_sobre(x.lam::numeric, ln.linea, 'football') end prob
  from (values (37.5::numeric),(40.5),(43.5),(46.5),(49.5)) ln(linea)
  cross join (values ('Under'),('Over')) lado(lado)
) q;

-- ===========================================================================
-- C) LÍNEA DE GANADOR — MLB y NFL.
--    RESULTADO (el dato que importa):
--      MLB  6,022 juegos: Brier modelo 0.25056 / volado 0.25000 / tasa base 0.24952
--      NFL  1,443 juegos: Brier modelo 0.25514 / volado 0.25000 / tasa base 0.24800
--    Los dos son PEORES que un volado y peores que la tasa base. El motor
--    Poisson generico NO sirve para la linea de ganador en ninguno de los dos.
--    (Esto NO es el modelo dedicado nfl-2026.09.2, que es otra cosa.)
-- ===========================================================================
truncate public.backtest_ml;
-- MLB
with lf as (
  select i, sum(case when i=0 then 0 else ln(i::double precision) end)
             over (order by i rows between unbounded preceding and current row) lnfact
  from generate_series(0,30) i
),
mlb as (
  select espn_event_id, fecha, home_espn_id, away_espn_id, home_score, away_score,
         (home_score > away_score) gano_local
  from public.historico_partidos_espn
  where espn_endpoint ilike '%baseball%'
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
perf_l as (select espn_event_id, avg(home_score) over w gf_l, avg(away_score) over w gc_l, count(*) over w pj_l
  from mlb window w as (partition by home_espn_id order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)),
perf_v as (select espn_event_id, avg(away_score) over w gf_v, avg(home_score) over w gc_v, count(*) over w pj_v
  from mlb window w as (partition by away_espn_id order by fecha
               range between interval '24 months' preceding and interval '1 day' preceding)),
base as (select espn_event_id, avg(home_score) over w base_l, avg(away_score) over w base_v, count(*) over w pj_liga
  from mlb window w as (order by fecha
               range between interval '30 days' preceding and interval '1 day' preceding)),
lam as (
  select m.espn_event_id, m.fecha, m.gano_local, least(l.pj_l, v.pj_v)::int muestra,
    least(greatest(b.base_l * (1 + (l.pj_l/(l.pj_l+20.0))*((l.gf_l/b.base_l)-1))
                          * (1 + (v.pj_v/(v.pj_v+20.0))*((v.gc_v/b.base_l)-1)), 1.5), 9.0)::double precision lam_l,
    least(greatest(b.base_v * (1 + (v.pj_v/(v.pj_v+20.0))*((v.gf_v/b.base_v)-1))
                          * (1 + (l.pj_l/(l.pj_l+20.0))*((l.gc_l/b.base_v)-1)), 1.5), 9.0)::double precision lam_v
  from mlb m join perf_l l using (espn_event_id) join perf_v v using (espn_event_id) join base b using (espn_event_id)
  where l.pj_l >= 20 and v.pj_v >= 20 and b.pj_liga >= 100
),
grid as (
  select x.espn_event_id, x.fecha, x.gano_local, x.muestra, x.lam_l, x.lam_v, lf.i k,
    exp(-x.lam_l + lf.i*ln(x.lam_l) - lf.lnfact) ph,
    exp(-x.lam_v + lf.i*ln(x.lam_v) - lf.lnfact) pa
  from lam x cross join lf
),
cum as (
  select g.*, sum(ph) over (partition by espn_event_id order by k rows between unbounded preceding and current row) cdf_h
  from grid g
)
insert into public.backtest_ml (deporte, espn_event_id, fecha, lam_l, lam_v, muestra, prob_local, gano_local)
select 'baseball', espn_event_id, fecha, max(lam_l), max(lam_v), max(muestra),
       sum(pa * (1 - cdf_h)) + 0.5 * sum(ph * pa), bool_or(gano_local)
from cum group by espn_event_id, fecha;

-- NFL (misma mecánica, ventanas de NFL, lf hasta 70 por el rango de puntos)
with lf as (
  select i, sum(case when i=0 then 0 else ln(i::double precision) end)
             over (order by i rows between unbounded preceding and current row) lnfact
  from generate_series(0,70) i
),
nfl as (
  select espn_event_id, fecha, home_espn_id, away_espn_id, home_score, away_score,
         (home_score > away_score) gano_local
  from public.historico_partidos_espn
  where espn_endpoint ilike '%football%'
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
perf_l as (select espn_event_id, avg(home_score) over w gf_l, avg(away_score) over w gc_l, count(*) over w pj_l
  from nfl window w as (partition by home_espn_id order by fecha
               range between interval '36 months' preceding and interval '1 day' preceding)),
perf_v as (select espn_event_id, avg(away_score) over w gf_v, avg(home_score) over w gc_v, count(*) over w pj_v
  from nfl window w as (partition by away_espn_id order by fecha
               range between interval '36 months' preceding and interval '1 day' preceding)),
base as (select espn_event_id, avg(home_score) over w base_l, avg(away_score) over w base_v, count(*) over w pj_liga
  from nfl window w as (order by fecha
               range between interval '120 days' preceding and interval '1 day' preceding)),
lam as (
  select m.espn_event_id, m.fecha, m.gano_local, least(l.pj_l, v.pj_v)::int muestra,
    least(greatest(b.base_l * (1 + (l.pj_l/(l.pj_l+8.0))*((l.gf_l/b.base_l)-1))
                          * (1 + (v.pj_v/(v.pj_v+8.0))*((v.gc_v/b.base_l)-1)), 8.0), 40.0)::double precision lam_l,
    least(greatest(b.base_v * (1 + (v.pj_v/(v.pj_v+8.0))*((v.gf_v/b.base_v)-1))
                          * (1 + (l.pj_l/(l.pj_l+8.0))*((l.gc_l/b.base_v)-1)), 8.0), 40.0)::double precision lam_v
  from nfl m join perf_l l using (espn_event_id) join perf_v v using (espn_event_id) join base b using (espn_event_id)
  where l.pj_l >= 8 and v.pj_v >= 8 and b.pj_liga >= 40
),
grid as (
  select x.espn_event_id, x.fecha, x.gano_local, x.muestra, x.lam_l, x.lam_v, lf.i k,
    exp(-x.lam_l + lf.i*ln(x.lam_l) - lf.lnfact) ph,
    exp(-x.lam_v + lf.i*ln(x.lam_v) - lf.lnfact) pa
  from lam x cross join lf
),
cum as (
  select g.*, sum(ph) over (partition by espn_event_id order by k rows between unbounded preceding and current row) cdf_h
  from grid g
)
insert into public.backtest_ml (deporte, espn_event_id, fecha, lam_l, lam_v, muestra, prob_local, gano_local)
select 'football', espn_event_id, fecha, max(lam_l), max(lam_v), max(muestra),
       sum(pa * (1 - cdf_h)) + 0.5 * sum(ph * pa), bool_or(gano_local)
from cum group by espn_event_id, fecha;

-- ===========================================================================
-- D) Volcado a modelo_backtest y recálculo de zonas
-- ===========================================================================
delete from public.modelo_backtest where deporte in ('baseball','football');

insert into public.modelo_backtest (fixture_id, fecha, liga_id, mercado, pick, prob_modelo, acerto, muestra_min, deporte)
select espn_event_id::bigint, fecha, null::int, 'Over/Under', lado||' '||linea::text, prob::numeric, acerto, muestra, 'baseball'
from public.backtest_mlb_totales
union all
select espn_event_id::bigint, fecha, null::int, 'Over/Under', lado||' '||linea::text, prob::numeric, acerto, muestra, 'football'
from public.backtest_nfl_totales
union all
select espn_event_id::bigint, fecha, null::int, 'Moneyline', 'Gana local', prob_local::numeric, gano_local, muestra, deporte
from public.backtest_ml
union all
select espn_event_id::bigint, fecha, null::int, 'Moneyline', 'Gana visitante', (1-prob_local)::numeric, not gano_local, muestra, deporte
from public.backtest_ml;

select * from public.recalcular_zonas_confiables();

-- FIN iss084b.
