-- Vista VIVA del tablero de validación (la lee la página /validacion de la app).
-- Devuelve 1 fila, 1 columna `data` (jsonb) con todo el tablero calculado en el momento.
-- Solo lectura. DINERO OFF. Fuente: v_reto_pick_grade_v1 (picks ya con resultado).
create or replace view v_reto_tablero_validacion_v1 as
with g as (
  select deporte, prob_pct, acierto, kickoff
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
  from (
    select date_trunc('week',kickoff) wk, count(*) n, round(avg(acierto::numeric)*100,1) hit
    from g group by 1
  ) w
),
tot as (
  select jsonb_build_object(
    'n', count(*),
    'hit', round(avg(acierto::numeric)*100,1),
    'dice', round(avg(prob_pct),1),
    'n_alta', count(*) filter (where prob_pct>=70),
    'hit_alta', round(avg(acierto::numeric) filter (where prob_pct>=70)*100,1),
    'desde', to_char(min(kickoff),'DD Mon'),
    'hasta', to_char(max(kickoff),'DD Mon YYYY')
  ) j from g
)
select jsonb_build_object(
  'generado_at', now(),
  'totales', (select j from tot),
  'por_deporte', (select j from por),
  'buckets', (select j from buck),
  'semanas', (select j from wk)
) as data;

grant select on v_reto_tablero_validacion_v1 to anon, authenticated;
