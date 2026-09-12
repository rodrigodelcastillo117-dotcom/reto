with g as (
  select h.liga_id, h.fecha,
         case when h.home_score>h.away_score then 'H'
              when h.home_score=h.away_score then 'D' else 'A' end as y,
         f.home_gf,f.home_gc,f.away_gf,f.away_gc,f.sample_home,f.sample_away,
         lm.mh, lm.ma
  from public.historico_partidos_espn h
  cross join lateral v2.fn_soccer_features_asof(h.home_espn_id,h.away_espn_id,h.liga_id,h.fecha,540) f
  cross join lateral (
     select avg(x.home_score) mh, avg(x.away_score) ma
     from public.historico_partidos_espn x
     where x.liga_id=h.liga_id and x.home_score is not null
       and x.fecha < h.fecha and x.fecha >= h.fecha - interval '540 days'
  ) lm
  where h.liga_id in (144,103,197,119,179) and h.home_score is not null
    and f.sample_home>=8 and f.sample_away>=8 and lm.mh is not null and lm.ma is not null
),
p as (
  select g.*,
    (d->>'p_home')::numeric/100.0 ph,
    (d->>'p_draw')::numeric/100.0 pd,
    (d->>'p_away')::numeric/100.0 pa
  from g cross join lateral v2.fn_score_dist(g.home_gf,g.home_gc,g.away_gf,g.away_gc,g.mh,g.ma,null) d
),
scored as (
  select p.*,
    (ph-(case when y='H' then 1 else 0 end))^2
   +(pd-(case when y='D' then 1 else 0 end))^2
   +(pa-(case when y='A' then 1 else 0 end))^2 as brier_model,
    -ln(greatest(1e-6, case y when 'H' then ph when 'D' then pd else pa end)) as logloss_model,
    greatest(ph,pd,pa) as conf,
    case when ph>=pd and ph>=pa then 'H' when pd>=ph and pd>=pa then 'D' else 'A' end as yhat,
    width_bucket(greatest(ph,pd,pa),0,1,10) as bk
  from p
),
per_bin as (
  select liga_id, bk, count(*) nb, avg((yhat=y)::int) acc_b, avg(conf) conf_b
  from scored group by liga_id, bk
),
ntot as (select liga_id, count(*) n from scored group by liga_id),
ece as (
  select pb.liga_id, sum( (pb.nb::numeric/nt.n) * abs(pb.acc_b - pb.conf_b) ) as ece
  from per_bin pb join ntot nt on nt.liga_id=pb.liga_id group by pb.liga_id
)
select s.liga_id,
  count(*) n,
  round(avg((yhat=y)::int)::numeric,4) acc,
  round(avg(brier_model)::numeric,4) brier_model,
  round(avg(logloss_model)::numeric,4) logloss_model,
  round(e.ece::numeric,4) ece
from scored s join ece e on e.liga_id=s.liga_id
group by s.liga_id, e.ece
order by s.liga_id;

-- ============================================================================
-- (Arriba) ECE/calibración por liga. Abajo: ganancia de Brier vs Baseline A
-- (tasas base AS-OF) con IC95% analítico, y estabilidad por temporada.
-- Todas READ-ONLY contra v2.fn_score_dist (producción) + historico_partidos_espn.
-- Ejecutadas 2026-09-09; resultados en BLOQUE2b_domestic_walkforward_2026-09-09.md
-- ============================================================================
