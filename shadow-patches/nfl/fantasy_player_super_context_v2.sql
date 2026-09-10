-- FANTASY PLAYER SUPER CONTEXT V2 — SHADOW / NO DEPLOY
-- Exact identity: ESPN player id + next season/week. No projections are invented.
-- Current-week facts are separated from prior-season baseline. A prior-season
-- metric is NEVER relabelled as current-season usage.

CREATE OR REPLACE VIEW public.fantasy_player_super_context_v2
WITH (security_invoker = true)
AS
SELECT
  j.espn_player_id,
  j.nombre AS player_name,
  j.posicion AS position,
  j.equipo AS team,
  j.activo AS player_master_active_flag,
  j.actualizado_at AS player_master_as_of,

  nxt.espn_event_id AS canonical_event_id,
  nxt.temporada AS season,
  nxt.semana AS week,
  nxt.fecha AS kickoff,
  nxt.rival AS opponent,
  nxt.es_local AS is_home,
  nxt.estado AS game_status,

  -- Current week availability.
  inj.estado AS injury_status,
  inj.lesion AS injury,
  inj.nota AS injury_note,
  inj.fuente AS injury_source,
  inj.verificado AS injury_verified,
  inj.cargado_at AS injury_as_of,
  depth.orden AS depth_order,
  depth.cargado_at AS depth_as_of,

  -- Current-season usage ONLY when truly loaded for that season.
  uc.juegos AS current_usage_games,
  uc.targets AS current_targets,
  uc.recepciones AS current_receptions,
  uc.acarreos AS current_carries,
  uc.target_share AS current_target_share,
  uc.rz5_share AS current_goal_line_share,
  uc.rz10_share AS current_rz10_share,
  uc.hvt AS current_high_value_touches,
  uc.hvt_pg AS current_high_value_touches_pg,
  uc.ppr_pg AS current_observed_ppr_pg,
  uc.ppr_sd AS current_observed_ppr_sd,
  uc.ppr_p25 AS current_observed_p25,
  uc.ppr_p50 AS current_observed_p50,
  uc.ppr_p75 AS current_observed_p75,
  uc.ppr_max AS current_observed_max,
  uc.cargado_at AS current_usage_as_of,

  adv.snap_pct AS current_snap_pct,
  adv.target_share_pct AS current_advanced_target_share_pct,
  adv.rz_targets_20 AS current_rz_targets_20,
  adv.rz_targets_10 AS current_rz_targets_10,
  adv.rz_acarreos_20 AS current_rz_carries_20,
  adv.rz_acarreos_5 AS current_goal_line_carries_5,
  adv.separacion_yardas AS current_separation_yards,
  adv.cargado_at AS current_advanced_usage_as_of,

  sr.snap_pct AS current_recent_snap_pct,
  sr.snap_pct_ult3 AS current_recent_snap_pct_last3,
  sr.snap_tendencia AS current_recent_snap_trend,

  -- Prior-season baseline: useful context before week 1, never current truth.
  up.temporada AS baseline_season,
  up.juegos AS baseline_games,
  up.targets AS baseline_targets,
  up.recepciones AS baseline_receptions,
  up.acarreos AS baseline_carries,
  up.target_share AS baseline_target_share,
  up.rz5_share AS baseline_goal_line_share,
  up.rz10_share AS baseline_rz10_share,
  up.hvt_pg AS baseline_high_value_touches_pg,
  up.ppr_pg AS baseline_ppr_pg,
  up.ppr_sd AS baseline_ppr_sd,
  up.ppr_p25 AS baseline_p25,
  up.ppr_p50 AS baseline_p50,
  up.ppr_p75 AS baseline_p75,
  up.ppr_max AS baseline_max,
  up.cargado_at AS baseline_as_of,
  CASE WHEN up.temporada IS NULL THEN NULL ELSE 'PRIOR_SEASON_CONTEXT_ONLY' END AS baseline_role,

  -- Opponent vs position. Current season if available; otherwise prior-season
  -- context is selected separately and labelled.
  dvpc.temporada AS defense_vs_pos_current_season,
  dvpc.partidos AS defense_vs_pos_current_games,
  dvpc.ppr_permitidos_pg AS defense_vs_pos_current_ppr_allowed_pg,
  dvpc.targets_pg AS defense_vs_pos_current_targets_pg,
  dvpc.yardas_recibidas_pg AS defense_vs_pos_current_rec_yards_pg,
  dvpc.yardas_terrestres_pg AS defense_vs_pos_current_rush_yards_pg,
  dvpc.tds_pg AS defense_vs_pos_current_tds_pg,
  dvpp.temporada AS defense_vs_pos_baseline_season,
  dvpp.partidos AS defense_vs_pos_baseline_games,
  dvpp.ppr_permitidos_pg AS defense_vs_pos_baseline_ppr_allowed_pg,
  dvpp.targets_pg AS defense_vs_pos_baseline_targets_pg,
  dvpp.yardas_recibidas_pg AS defense_vs_pos_baseline_rec_yards_pg,
  dvpp.yardas_terrestres_pg AS defense_vs_pos_baseline_rush_yards_pg,
  dvpp.tds_pg AS defense_vs_pos_baseline_tds_pg,
  CASE WHEN dvpp.temporada IS NULL THEN NULL ELSE 'PRIOR_SEASON_CONTEXT_ONLY' END AS defense_vs_pos_baseline_role,

  -- Game environment, context only.
  g.spread AS sportsbook_spread_context,
  g.total_linea AS sportsbook_total_context,
  g.ml_home AS sportsbook_ml_home_context,
  g.ml_away AS sportsbook_ml_away_context,
  g.casa AS sportsbook_source,
  g.actualizado AS sportsbook_as_of,
  g.techado,
  g.temperatura,
  g.viento_rafaga,
  g.precipitacion,
  vh.estadio AS venue,
  vh.altitud_ft AS venue_altitude_ft,
  vh.techo AS venue_roof,

  -- Projection authority stays NULL until canonical projection brain exists.
  'NO_CANONICAL_PROJECTION'::text AS projection_status,
  NULL::numeric AS projected_floor,
  NULL::numeric AS projected_median,
  NULL::numeric AS projected_ceiling,
  NULL::numeric AS projection_uncertainty,
  NULL::numeric AS projection_data_quality,
  NULL::text AS projection_model_version,
  NULL::timestamptz AS projection_snapshot_at,
  NULL::numeric AS start_probability,
  NULL::text AS recommended_slot,

  jsonb_build_object(
    'identity', j.espn_player_id IS NOT NULL,
    'next_event', nxt.espn_event_id IS NOT NULL,
    'injury_current_week', inj.cargado_at IS NOT NULL,
    'depth_current', depth.cargado_at IS NOT NULL,
    'current_season_usage', uc.espn_player_id IS NOT NULL,
    'current_advanced_usage', adv.espn_player_id IS NOT NULL,
    'current_recent_snaps', sr.espn_player_id IS NOT NULL,
    'prior_season_baseline', up.espn_player_id IS NOT NULL,
    'defense_vs_pos_current', dvpc.equipo_defensa IS NOT NULL,
    'defense_vs_pos_baseline', dvpp.equipo_defensa IS NOT NULL,
    'game_environment', g.espn_event_id IS NOT NULL,
    'canonical_projection', false
  ) AS coverage,

  jsonb_strip_nulls(jsonb_build_object(
    'canonical_projection','Canonical weekly fantasy projection brain not yet validated',
    'next_event', CASE WHEN nxt.espn_event_id IS NULL THEN 'No upcoming NFL event mapped for player team' END,
    'injury_current_week', CASE WHEN inj.cargado_at IS NULL THEN 'No exact player injury row for next season/week' END,
    'depth_current', CASE WHEN depth.cargado_at IS NULL THEN 'No verified current depth-chart row for player' END,
    'current_season_usage', CASE WHEN uc.espn_player_id IS NULL THEN 'Current-season usage not loaded yet; prior season is shown only as baseline' END,
    'current_advanced_usage', CASE WHEN adv.espn_player_id IS NULL THEN 'Current-season advanced usage not loaded yet' END,
    'current_recent_snaps', CASE WHEN sr.espn_player_id IS NULL THEN 'Current-season snap summary not loaded yet' END,
    'prior_season_baseline', CASE WHEN up.espn_player_id IS NULL THEN 'No prior-season usage baseline available' END,
    'defense_vs_pos_current', CASE WHEN dvpc.equipo_defensa IS NULL THEN 'Current-season defense-vs-position sample unavailable or too early' END,
    'defense_vs_pos_baseline', CASE WHEN dvpp.equipo_defensa IS NULL THEN 'No prior-season defense-vs-position baseline available' END,
    'air_yards','No temporal player air-yards source available yet',
    'adot','No temporal aDOT source available yet',
    'yprr','No licensed/verified YPRR source available yet',
    'xfp','No validated expected-fantasy-points model available yet',
    'route_participation','No verified route participation source available yet',
    'ol_dl','No dedicated OL/DL matchup source available yet',
    'coverage_matchup','No licensed man/zone/shadow-coverage feed available yet'
  )) AS missing_reason

FROM public.nfl_jugadores j
LEFT JOIN LATERAL (
  SELECT c.* FROM public.nfl_calendario_equipo c
  WHERE lower(c.equipo)=lower(j.equipo)
    AND c.fecha>=now()
    AND lower(coalesce(c.estado,'')) NOT IN ('final','post','ft','cancelled','canceled')
  ORDER BY c.fecha ASC LIMIT 1
) nxt ON true
LEFT JOIN public.nfl_partidos g ON g.espn_event_id=nxt.espn_event_id
LEFT JOIN public.nfl_estadios vh ON vh.team_espn_id=g.home_id
LEFT JOIN LATERAL (
  SELECT i.* FROM public.nfl_lesiones_semana i
  WHERE i.espn_player_id=j.espn_player_id
    AND i.temporada=nxt.temporada AND i.semana=nxt.semana
    AND i.cargado_at<=nxt.fecha
  ORDER BY i.cargado_at DESC LIMIT 1
) inj ON true
LEFT JOIN LATERAL (
  SELECT d.* FROM public.nfl_depth_chart d
  WHERE d.espn_player_id=j.espn_player_id
    AND d.temporada=nxt.temporada AND d.cargado_at<=nxt.fecha
  ORDER BY d.cargado_at DESC LIMIT 1
) depth ON true
LEFT JOIN public.nfl_uso_jugador uc
  ON uc.espn_player_id=j.espn_player_id AND uc.temporada=nxt.temporada
LEFT JOIN public.nfl_uso_avanzado adv
  ON adv.espn_player_id=j.espn_player_id AND adv.temporada=nxt.temporada
LEFT JOIN public.nfl_snaps_resumen sr
  ON sr.espn_player_id=j.espn_player_id AND sr.temporada=nxt.temporada
LEFT JOIN LATERAL (
  SELECT u.* FROM public.nfl_uso_jugador u
  WHERE u.espn_player_id=j.espn_player_id AND u.temporada<nxt.temporada
  ORDER BY u.temporada DESC LIMIT 1
) up ON true
LEFT JOIN public.nfl_defensa_vs_posicion_ppr dvpc
  ON lower(dvpc.equipo_defensa)=lower(nxt.rival)
 AND dvpc.temporada=nxt.temporada
 AND upper(dvpc.posicion)=upper(j.posicion)
LEFT JOIN LATERAL (
  SELECT d.* FROM public.nfl_defensa_vs_posicion_ppr d
  WHERE lower(d.equipo_defensa)=lower(nxt.rival)
    AND d.temporada<nxt.temporada
    AND upper(d.posicion)=upper(j.posicion)
  ORDER BY d.temporada DESC LIMIT 1
) dvpp ON true;

COMMENT ON VIEW public.fantasy_player_super_context_v2 IS
'Fantasy factual context keyed by ESPN player id and next event. Current-season facts and prior-season baselines are explicitly separated. Projection fields remain NULL until a canonical validated projection brain exists.';