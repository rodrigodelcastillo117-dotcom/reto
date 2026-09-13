-- ISS129c — NFL PUBLIC SURFACE FAIL-CLOSE · STAGED / NO PROD MUTATION
-- Depends on ISS129 + ISS129b.
-- Prevents NULL probabilities from falling through CASE/ELSE into fabricated picks.

create or replace view public.nfl_reto_modelo as
select distinct on (s.espn_event_id)
  s.espn_event_id,
  s.home_team,
  s.away_team,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_home_ml end as p_home_ml,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_away_ml end as p_away_ml,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_tie_regulation end as p_tie_regulation,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_home_cover end as p_home_cover,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_away_cover end as p_away_cover,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_spread_push end as p_spread_push,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_over end as p_over,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_under end as p_under,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_total_push end as p_total_push,
  s.dk_spread_home,
  s.dk_total,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.exp_home end as exp_home,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.exp_away end as exp_away,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.exp_total end as exp_total,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.exp_margin end as exp_margin,
  s.uncertainty,
  s.coverage,
  s.model_version,
  case when v2.fn_nfl_release_allowed(s.model_version)
       then s.model_status else 'VALIDATION_BLOCKED' end as model_status,
  coalesce(g.validation_status,'FAIL_CLOSED_OOS_NOT_PROVEN') as calibration_status,
  case when v2.fn_nfl_release_allowed(s.model_version)
       then s.quality_status else 'SUPPRESSED' end as quality_status,
  case when v2.fn_nfl_release_allowed(s.model_version)
       then s.suppression_reason
       else 'P_RETO bloqueado: validacion OOS independiente no demostrada' end as suppression_reason,
  s.prob_source,
  s.decision_time,
  s.kickoff
from v2.nfl_decision_snapshot s
left join v2.nfl_model_validation_gate g on g.model_version=s.model_version
order by s.espn_event_id, s.decision_time desc, s.built_at desc;

create or replace view public.nfl_tablero as
select
  p.espn_event_id,
  p.fecha,
  to_char(p.fecha at time zone 'America/Mexico_City','DD/MM hh12:mi AM') as hora_cdmx,
  p.away_team || ' @ ' || p.home_team as partido,
  p.semana,
  case p.tipo_temporada when 1 then 'pretemporada' when 2 then 'regular' when 3 then 'postemporada' end as temporada,
  p.spread_detalle as linea,
  p.total_linea as total,
  p.ml_home,
  p.ml_away,
  round(100::numeric*p.p_home,1) as prob_local,
  round(100::numeric*p.p_away,1) as prob_visitante,
  p.estadio,
  p.techado,
  p.temperatura,
  p.viento_rafaga,
  p.precipitacion,
  p.out_home || '/' || p.lesionados_home as bajas_local,
  p.out_away || '/' || p.lesionados_away as bajas_visitante,
  p.qb_comprometido_home or p.qb_comprometido_away as alerta_qb,
  pr.mejor_pick,
  pr.mejor_prob,
  pr.alertas,
  p.estado,
  case when p.estado='final' then p.pts_away || '-' || p.pts_home end as marcador,
  round(s.p_home_ml,1) as p_reto_local,
  round(s.p_away_ml,1) as p_reto_visitante,
  round(s.p_tie_regulation,2) as p_reto_empate_regular,
  case
    when s.model_status<>'READY' or s.p_home_ml is null or s.p_away_ml is null then null
    when s.p_home_ml>=s.p_away_ml then 'Gana '||s.home_team
    else 'Gana '||s.away_team
  end as reto_pick,
  case when s.model_status='READY' then round(greatest(s.p_home_ml,s.p_away_ml),1) end as reto_pick_prob,
  case
    when s.model_status<>'READY' or s.dk_spread_home is null or s.p_home_cover is null or s.p_away_cover is null then null
    when s.p_home_cover>=s.p_away_cover then s.home_team||' '||v2.fn_fmt_spread(s.dk_spread_home)
    else s.away_team||' '||v2.fn_fmt_spread(-s.dk_spread_home)
  end as reto_spread_pick,
  case when s.model_status='READY' then round(greatest(s.p_home_cover,s.p_away_cover),1) end as reto_spread_prob,
  case
    when s.model_status<>'READY' or s.dk_total is null or s.p_over is null or s.p_under is null then null
    when s.p_over>=s.p_under then 'Over '||trim(trailing '.' from to_char(s.dk_total,'FM9990.99'))
    else 'Under '||trim(trailing '.' from to_char(s.dk_total,'FM9990.99'))
  end as reto_total_pick,
  case when s.model_status='READY' then round(greatest(s.p_over,s.p_under),1) end as reto_total_prob,
  case when s.model_status='READY' then round(s.exp_home,1) end as reto_pts_local,
  case when s.model_status='READY' then round(s.exp_away,1) end as reto_pts_visitante,
  case when s.model_status='READY' then round(s.exp_total,1) end as reto_total_esperado,
  case when s.model_status='READY' then round(s.exp_margin,1) end as reto_margen_esperado,
  s.uncertainty as reto_incertidumbre,
  s.model_version as reto_modelo,
  s.model_status as reto_model_status,
  s.calibration_status as reto_calibracion,
  s.decision_time as reto_decision_time,
  case when s.model_status='READY' then 'MODELO_RETO' else 'MERCADO_NO_VIG' end as prob_fuente,
  case when s.model_status='READY' then round(s.p_spread_push,1) end as reto_spread_push,
  case when s.model_status='READY' then round(s.p_total_push,1) end as reto_total_push
from public.nfl_partidos p
left join public.nfl_predicciones pr on pr.espn_event_id=p.espn_event_id
left join public.nfl_reto_modelo s on s.espn_event_id=p.espn_event_id
order by p.fecha;

create or replace function public.modelo_version_activa(p_deporte text)
returns text language sql stable as $function$
  select case
    when p_deporte ~* '(soccer|futbol|fútbol)' then public.get_active_crossleague_model_version()
    when p_deporte ~* '(football|nfl|americano)' then
      (select m.model_version from public.nfl_reto_modelo m
       where m.model_status='READY' and m.model_version is not null
       order by m.model_version desc limit 1)
    else null
  end;
$function$;
