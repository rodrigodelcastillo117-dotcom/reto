-- Vista VIVA del tablero de validación (la lee la página /validacion y el email).
-- Devuelve 1 fila, 1 columna `data` (jsonb) con todo el tablero calculado en el momento.
-- Solo lectura. DINERO OFF. Fuente: v_reto_pick_grade_v1 (picks ya con resultado).
create or replace view v_reto_tablero_validacion_v1 as
with g as (
  select deporte, prob_pct, acierto, kickoff, lower(coalesce(mercado,'(nulo)')) as mkt
  from v_reto_pick_grade_v1 where acierto is not null
),
por as (
  select jsonb_agg(jsonb_build_object(
    'd',deporte,'n',n,'hit',hit,'dice',dice,'brier',brier,'n_alta',n_alta,'hit_alta',hit_alta
  ) order by n desc) j
  from (
    select deporte, count(*) n,
      round(avg(acierto::numeric)*100,1) hit,
      round(avg(prob_pct),1) dice,
      round(avg((prob_pct/100.0-acierto)^2)::numeric,4) brier,
      count(*) filter (where prob_pct>=70) n_alta,
      round(avg(acierto::numeric) filter (where prob_pct>=70)*100,1) hit_alta
    from g group by deporte
  ) s
),
buck as (
  select jsonb_agg(jsonb_build_object('b',bucket,'n',n,'dice',dice,'real',rl) order by ord) j
  from (
    select case when prob_pct<55 then '50-55' when prob_pct<60 then '55-60'
                when prob_pct<65 then '60-65' when prob_pct<70 then '65-70'
                when prob_pct<80 then '70-80' else '80+' end bucket,
           min(case when prob_pct<55 then 1 when prob_pct<60 then 2 when prob_pct<65 then 3
                    when prob_pct<70 then 4 when prob_pct<80 then 5 else 6 end) ord,
           count(*) n, round(avg(prob_pct),1) dice, round(avg(acierto::numeric)*100,1) rl
    from g group by 1
  ) b
),
wk as (
  select jsonb_agg(jsonb_build_object('w',to_char(wk,'DD Mon'),'n',n,'hit',hit) order by wk) j
  from ( select date_trunc('week',kickoff) wk, count(*) n, round(avg(acierto::numeric)*100,1) hit from g group by 1 ) w
),
merc as (  -- récord por tipo de mercado (btts / ml / ganador / totales…)
  select jsonb_agg(jsonb_build_object('m',mkt,'n',n,'dice',dice,'real',rl,'sesgo',sesgo) order by n desc) j
  from (
    select mkt, count(*) n, round(avg(prob_pct),1) dice, round(avg(acierto::numeric)*100,1) rl,
           round(avg(prob_pct)-avg(acierto::numeric)*100,1) sesgo
    from g group by 1 having count(*) >= 25
  ) m
),
tot as (
  select jsonb_build_object(
    'n', count(*), 'hit', round(avg(acierto::numeric)*100,1), 'dice', round(avg(prob_pct),1),
    'n_alta', count(*) filter (where prob_pct>=70),
    'hit_alta', round(avg(acierto::numeric) filter (where prob_pct>=70)*100,1),
    'desde', to_char(min(kickoff),'DD Mon'), 'hasta', to_char(max(kickoff),'DD Mon YYYY')
  ) j from g
),
forma as (  -- forma reciente: ¿vamos calientes o fríos?
  select jsonb_build_object(
    'd7',  (select jsonb_build_object('n',count(*),'hit',round(avg(acierto::numeric)*100,1)) from g where kickoff > now()-interval '7 days'),
    'd30', (select jsonb_build_object('n',count(*),'hit',round(avg(acierto::numeric)*100,1)) from g where kickoff > now()-interval '30 days')
  ) j
),
-- CLV (¿le ganamos al cierre?): proxy del lado favorito del mercado (entrada vs último snapshot).
-- Se enciende solo: 'recolectando' (<7 días), 'preliminar' (<14), 'listo' (>=14). DINERO OFF.
clv_ev as (
  select case when entry_home_pct >= entry_away_pct then mov_home_pp else mov_away_pp end as clv_fav_pp
  from v_reto_clv_multicasa_v1 where n_snaps >= 2 and entry_home_pct is not null
),
clv_dias as ( select count(distinct captured_at::date) d from reto_clv_snapshots_v1 ),
clv as (
  select jsonb_build_object(
    'eventos', (select count(*) from clv_ev),
    'dias_datos', (select d from clv_dias),
    'clv_pp', (select round(avg(clv_fav_pp)::numeric,2) from clv_ev),
    'estado', case when (select d from clv_dias) < 7 then 'recolectando'
                   when (select d from clv_dias) < 14 then 'preliminar' else 'listo' end
  ) j
)
select jsonb_build_object(
  'generado_at', now(),
  'totales', (select j from tot),
  'forma', (select j from forma),
  'por_deporte', (select j from por),
  'por_mercado', (select j from merc),
  'buckets', (select j from buck),
  'semanas', (select j from wk),
  'clv', (select j from clv)
) as data;

grant select on v_reto_tablero_validacion_v1 to anon, authenticated;
