-- ============================================================================
-- Gate de medibilidad + primer CLV real del sistema reto — wpiztubmmmzclhlprgpd
-- 2026-10-20. Ver ARQUITECTURA_Y_GATE_V1.md.
-- ============================================================================

-- (1) Mapa-gate: estado de CLV por mercado que la app publica.
create or replace view public.v_reto_mercado_gate_v1 as
with pub as (
  select s.deporte, s.mercado,
         count(*) picks, count(distinct s.espn_event_id) eventos,
         count(distinct s.espn_event_id) filter (where cl.espn_event_id is not null) eventos_con_cierre
  from public.reto_pick_snapshot_v1 s
  left join (select distinct espn_event_id from public.v_linea_de_cierre where sirve_para_clv) cl
    on cl.espn_event_id = s.espn_event_id
  group by s.deporte, s.mercado
), val as (
  select deporte, mercado, accuracy_pct, muestra_oos from public.reto_modelo_validacion_v1
)
select p.deporte, p.mercado, p.picks, p.eventos, p.eventos_con_cierre,
  v.accuracy_pct as acierto_vs_mediana_pct, v.muestra_oos as muestra_validacion,
  round(100.0*p.eventos_con_cierre/nullif(p.eventos,0),0) as pct_cobertura_cierre,
  case
    when p.eventos_con_cierre = 0 then 'SIN CUOTAS — CLV no medible (falta feed de cuotas para este deporte)'
    when p.mercado in ('OU','OU25') then 'LINEA NO COMPARABLE — el cierre usa otra linea; CLV directo no aplica'
    else 'CLV MEDIBLE — hay linea de cierre para enganchar'
  end as estado_clv,
  case when v.accuracy_pct is null then 'SIN VALIDACION OOS'
       else 'validado vs mediana ('||v.accuracy_pct||'% / n='||v.muestra_oos||')' end as estado_modelo
from pub p
left join val v on v.deporte = p.deporte and v.mercado = p.mercado
order by p.deporte, p.mercado;

-- (2) CLV real del sistema reto para soccer Moneyline (prob modelo vs prob de
-- cierre de-vigada de 3 patas, radar_odds_snapshots). NO es CLV realizado.
create or replace view public.v_reto_clv_soccer_ml_v1 as
with cl as (
  select espn_event_id,
         avg(1.0/home_ml_close) as ih, avg(1.0/away_ml_close) as ia,
         avg(1.0/nullif(draw_ml_close,0)) as idr
  from public.radar_odds_snapshots
  where home_ml_close > 1 and away_ml_close > 1
  group by espn_event_id
), devig as (
  select espn_event_id,
         ih/(ih+ia+coalesce(idr,0)) as p_home,
         ia/(ih+ia+coalesce(idr,0)) as p_away,
         case when idr is null then null else idr/(ih+ia+idr) end as p_draw
  from cl
), picks as (
  select s.espn_event_id, s.partido, s.pick_lado, s.prob_pct/100.0 as prob_modelo, g.acierto,
         case s.pick_lado when 'home' then d.p_home when 'away' then d.p_away
              when 'empate' then d.p_draw end as prob_cierre
  from public.reto_pick_snapshot_v1 s
  join devig d on d.espn_event_id = s.espn_event_id
  left join public.v_reto_pick_grade_v1 g
    on g.espn_event_id=s.espn_event_id and g.mercado=s.mercado and g.deporte=s.deporte
  where s.deporte='soccer' and s.mercado='ML'
)
select espn_event_id, partido, pick_lado,
       round((prob_modelo*100)::numeric,1) as prob_modelo_pct,
       round((prob_cierre*100)::numeric,1)  as prob_cierre_pct,
       round(((prob_modelo-prob_cierre)*100)::numeric,1) as ventaja_pp,
       acierto
from picks where prob_cierre is not null
order by ventaja_pp desc;
