-- Card parcial honesta para partidos de futbol CONTEXT_ONLY (copas con equipos de
-- division inferior sin fuerza de liga medida). Vista nueva, no toca nada existente.
-- Ver FUTBOL_CONTEXT_ONLY_V1.md.
create or replace view public.v_reto_soccer_contexto_v1 as
select 'futbol'::text as deporte, a.liga_nombre, a.espn_event_id, a.kickoff,
  a.home_team, a.away_team, 'CONTEXTO_SIN_PROB'::text as estado,
  a.home_current_n, a.home_current_w, a.home_current_d, a.home_current_l,
  a.home_current_ppg, a.home_current_gf_pg, a.home_current_ga_pg,
  a.away_current_n, a.away_current_w, a.away_current_d, a.away_current_l,
  a.away_current_ppg, a.away_current_gf_pg, a.away_current_ga_pg,
  a.home_last5_w, a.home_last5_d, a.home_last5_l, a.home_last5_ppg,
  a.away_last5_w, a.away_last5_d, a.away_last5_l, a.away_last5_ppg,
  a.h2h_n, a.h2h_recent, a.home_form_summary, a.away_form_summary, a.analysis_summary,
  coalesce(a.guard_reason,'No se publica probabilidad: una de las dos divisiones no tiene fuerza de liga medida (equipo de categoria inferior). Se muestra el contexto, no un pronostico.') as motivo_sin_prob,
  a.context_data_asof, a.model_version
from public.v_futpro_analysis_v4 a
where a.analysis_status = 'CONTEXT_ONLY' and a.canonical_pick_prob is null and a.kickoff > now()
  and not exists (select 1 from public.tarjeta_soccer_cache t where t.espn_event_id = a.espn_event_id)
order by a.kickoff;
grant select on public.v_reto_soccer_contexto_v1 to anon, authenticated;
