-- ============================================================================
-- Capa CLV honesta v1 — Supabase prod wpiztubmmmzclhlprgpd — 2026-10-20
-- Reemplaza el veredicto basado en PROMEDIO (lo inflan outliers) por uno basado
-- en MEDIANA + % que gana al cierre. Añade veredicto a nivel sistema y una vista
-- que confronta accuracy-vs-mediana con CLV real. Fuente: oraculo_picks_tracking.
-- ============================================================================

-- 1) clv_dashboard honesto (mismas 6 columnas; veredicto por mediana+beat-rate)
create or replace view public.clv_dashboard as
with picks_clv as (
  select case when liga = any (array['MLB','NHL','NBA','NFL']) then liga else 'Soccer' end as deporte,
         mercado, clv_pct, resultado
  from oraculo_picks_tracking
  where odds_apertura is not null and clv_registrado_at is not null
), global as (
  select count(*) as picks_con_clv,
         round(avg(clv_pct),2) as clv_promedio,
         round((percentile_cont(0.5) within group (order by clv_pct))::numeric,2) as clv_mediana,
         round(avg(case when clv_pct>0 then 1.0 else 0.0 end)*100,1) as pct_beat_closing,
         round(stddev(clv_pct),2) as clv_stddev
  from picks_clv
), por_deporte as (
  select deporte, count(*) as picks,
         round(avg(clv_pct),2) as clv_avg,
         round((percentile_cont(0.5) within group (order by clv_pct))::numeric,2) as clv_median,
         round(avg(case when clv_pct>0 then 1.0 else 0.0 end)*100,1) as pct_beat,
         round(avg(case when resultado='ganado' then 1.0 else 0.0 end)*100,1) as win_pct,
         case
           when count(*) < 100 then 'MUESTRA INSUFICIENTE'
           when round(avg(case when clv_pct>0 then 1.0 else 0.0 end)*100,1) >= 53
                and (percentile_cont(0.5) within group (order by clv_pct)) > 0
             then 'EDGE PROBABLE — vigilar persistencia'
           when round(avg(case when clv_pct>0 then 1.0 else 0.0 end)*100,1) between 48 and 53
             then 'SIN EDGE — moneda contra el cierre'
           else 'EDGE NEGATIVO — el mercado gana'
         end as veredicto
  from picks_clv group by deporte
)
select g.picks_con_clv, g.clv_promedio, g.pct_beat_closing, g.clv_stddev,
  case
    when g.picks_con_clv < 100 then 'MUESTRA INSUFICIENTE — aún no se puede juzgar'
    when g.pct_beat_closing >= 53 and g.clv_mediana > 0 then 'EDGE PROBABLE — gana al cierre >53% y CLV mediano > 0'
    when g.pct_beat_closing between 48 and 53 then 'SIN EDGE CLARO — a nivel de moneda contra el cierre (CLV mediano '||g.clv_mediana||', gana al cierre '||g.pct_beat_closing||'%). El promedio '||g.clv_promedio||'% lo inflan outliers.'
    else 'EDGE NEGATIVO — el mercado le gana al sistema'
  end as interpretacion,
  (select json_agg(json_build_object(
      'deporte', d.deporte, 'picks', d.picks, 'clv_avg', d.clv_avg, 'clv_median', d.clv_median,
      'pct_beat', d.pct_beat, 'win_pct', d.win_pct, 'veredicto', d.veredicto)
      order by d.picks desc) from por_deporte d) as por_deporte
from global g;

-- 2) Veredicto CLV a nivel sistema (por deporte y deporte×mercado)
create or replace view public.v_reto_clv_veredicto_sistema_v1 as
with b as (
  select case when liga = any (array['MLB','NHL','NBA','NFL']) then liga else 'Soccer' end as deporte,
         coalesce(mercado,'(s/m)') as mercado, clv_pct
  from oraculo_picks_tracking
  where odds_apertura is not null and clv_registrado_at is not null
), agg as (
  select grouping(mercado) as es_total_mercado, deporte, mercado, count(*) n,
         round(avg(clv_pct),2) clv_mean,
         round((percentile_cont(0.5) within group (order by clv_pct))::numeric,2) clv_median,
         round(avg(case when clv_pct>0 then 1.0 else 0.0 end)*100,1) pct_beat_close,
         round(stddev(clv_pct),1) sd
  from b group by deporte, rollup(mercado)
)
select deporte,
  case when es_total_mercado=1 then '· TODOS' else mercado end as mercado,
  n, clv_mean, clv_median, pct_beat_close, sd, (clv_mean - clv_median) as sesgo_outliers,
  case
    when n < 100 then 'MUESTRA INSUFICIENTE'
    when pct_beat_close >= 53 and clv_median > 0 then 'EDGE PROBABLE'
    when pct_beat_close between 48 and 53 then 'SIN EDGE (moneda)'
    else 'EDGE NEGATIVO'
  end as veredicto
from agg order by deporte, es_total_mercado desc, n desc;

-- 3) Realidad: accuracy-vs-mediana confrontado con CLV real
create or replace view public.v_reto_realidad_vs_mercado_v1 as
with clv as (
  select case when liga = any (array['MLB','NHL','NBA','NFL']) then liga else 'Soccer' end as dep, clv_pct
  from oraculo_picks_tracking
  where odds_apertura is not null and clv_registrado_at is not null
), clv_agg as (
  select dep, count(*) n, round(avg(clv_pct),2) clv_mean,
         round((percentile_cont(0.5) within group (order by clv_pct))::numeric,2) clv_median,
         round(avg(case when clv_pct>0 then 1.0 else 0.0 end)*100,1) pct_beat_close
  from clv group by dep
), mapa as (
  select v.deporte, v.mercado, v.muestra_oos, v.accuracy_pct,
         case v.deporte when 'mlb' then 'MLB' when 'nba' then 'NBA' when 'nhl' then 'NHL'
           when 'nfl' then 'NFL' when 'soccer' then 'Soccer' else null end as dep_clv
  from reto_modelo_validacion_v1 v
)
select m.deporte, m.mercado, m.accuracy_pct as acierto_vs_mediana_pct, m.muestra_oos as muestra_modelo,
  c.n as picks_con_clv, c.clv_mean as clv_real_mean, c.clv_median as clv_real_median,
  c.pct_beat_close as gana_al_cierre_pct,
  case
    when c.n is null then 'SIN MEDICION CLV — acierto vs mediana no prueba edge de mercado'
    when c.pct_beat_close >= 53 and c.clv_median > 0 then 'CONSISTENTE — acierta y gana al cierre'
    when c.pct_beat_close between 48 and 53 then 'ENGAÑOSO — acierta a la mediana pero es moneda contra el cierre'
    else 'CONTRADICTORIO — acierta a la mediana pero el mercado le gana'
  end as diagnostico
from mapa m left join clv_agg c on c.dep = m.dep_clv
order by m.deporte, m.mercado;
