-- FANTASY EQUIPO PLAYER CONTEXT V1 — SHADOW / NO DEPLOY
-- One factual player context row keyed by ESPN player id.
-- No START/SIT, floor/median/ceiling, win probability or fantasy projection is fabricated here.
-- Those fields remain NULL until a canonical projection brain exists and is validated.

CREATE OR REPLACE VIEW public.fantasy_equipo_player_context_v1
WITH (security_invoker = true)
AS
SELECT
  j.espn_player_id,
  j.nombre AS player_name,
  j.posicion AS position,
  j.equipo AS team,
  j.activo AS player_active_flag,
  j.actualizado_at AS player_master_as_of,

  -- Current aggregate context from the player master. Context only, not a projection.
  j.partidos AS games_history,
  j.ppr_promedio AS historical_ppr_avg,
  j.ppr_ultimos_5 AS historical_ppr_last5,
  j.targets_promedio AS historical_targets_avg,

  -- Next exact scheduled event from the team calendar.
  nxt.espn_event_id AS next_event_id,
  nxt.temporada AS season,
  nxt.semana AS week,
  nxt.fecha AS kickoff,
  nxt.rival AS opponent,
  nxt.es_local AS is_home,

  -- Injury / availability for that exact season+week when available.
  inj.estado AS injury_status,
  inj.lesion AS injury,
  inj.nota AS injury_note,
  inj.fuente AS injury_source,
  inj.verificado AS injury_verified,
  inj.cargado_at AS injury_as_of,

  -- Current-season usage. If 2026 data is not loaded yet these stay NULL; no fallback is relabeled as current.
  u.juegos AS usage_games,
  u.targets,
  u.recepciones,
  u.acarreos,
  u.target_share,
  u.rz5_share,
  u.rz10_share,
  u.hvt,
  u.hvt_pg,
  u.ppr_pg AS observed_ppr_pg,
  u.ppr_sd AS observed_ppr_sd,
  u.ppr_p25 AS observed_ppr_p25,
  u.ppr_p50 AS observed_ppr_p50,
  u.ppr_p75 AS observed_ppr_p75,
  u.ppr_max AS observed_ppr_max,
  u.cargado_at AS usage_as_of,

  adv.snap_pct,
  adv.target_share_pct,
  adv.rz_targets_20,
  adv.rz_targets_10,
  adv.rz_acarreos_20,
  adv.rz_acarreos_5,
  adv.separacion_yardas,
  adv.cargado_at AS advanced_usage_as_of,

  snap.snap_pct AS recent_snap_pct,
  snap.snap_pct_ult3 AS recent_snap_pct_last3,
  snap.snap_tendencia AS recent_snap_trend,

  -- Opponent-vs-position context. This is matchup context only, never a direct projection.
  dvp.partidos AS defense_vs_pos_games,
  dvp.ppr_permitidos_pg AS defense_vs_pos_ppr_allowed_pg,
  dvp.recepciones_pg AS defense_vs_pos_receptions_pg,
  dvp.targets_pg AS defense_vs_pos_targets_pg,
  dvp.yardas_recibidas_pg AS defense_vs_pos_rec_yards_pg,
  dvp.yardas_terrestres_pg AS defense_vs_pos_rush_yards_pg,
  dvp.tds_pg AS defense_vs_pos_tds_pg,

  -- Game environment is contextual only.
  game.total_linea AS sportsbook_total_context,
  game.spread AS sportsbook_spread_context,
  game.techado,
  game.temperatura,
  game.viento_rafaga,
  game.precipitacion,
  game.casa AS sportsbook_source,
  game.actualizado AS game_context_as_of,

  -- Projection authority intentionally absent until model exists.
  'NO_CANONICAL_PROJECTION'::text AS projection_status,
  NULL::numeric AS projected_floor,
  NULL::numeric AS projected_median,
  NULL::numeric AS projected_ceiling,
  NULL::numeric AS start_probability,
  NULL::text AS recommended_slot,

  jsonb_build_object(
    'identity', j.espn_player_id IS NOT NULL,
    'next_event', nxt.espn_event_id IS NOT NULL,
    'injury', inj.cargado_at IS NOT NULL,
    'current_season_usage', u.espn_player_id IS NOT NULL,
    'advanced_usage', adv.espn_player_id IS NOT NULL,
    'recent_snaps', snap.espn_player_id IS NOT NULL,
    'defense_vs_position', dvp.equipo_defensa IS NOT NULL,
    'game_environment', game.espn_event_id IS NOT NULL,
    'canonical_projection', false
  ) AS coverage,

  jsonb_build_object(
    'canonical_projection','Projection brain not yet validated',
    'current_season_usage',CASE WHEN u.espn_player_id IS NULL THEN 'Current-season usage not loaded for this player yet' ELSE NULL END,
    'advanced_usage',CASE WHEN adv.espn_player_id IS NULL THEN 'Current-season advanced usage not loaded for this player yet' ELSE NULL END,
    'defense_vs_position',CASE WHEN dvp.equipo_defensa IS NULL THEN 'Current-season opponent-vs-position data unavailable' ELSE NULL END
  ) AS missing_reason

FROM public.nfl_jugadores j
LEFT JOIN LATERAL (
  SELECT c.*
  FROM public.nfl_calendario_equipo c
  WHERE lower(c.equipo)=lower(j.equipo)
    AND c.fecha>=now()
    AND lower(coalesce(c.estado,'')) NOT IN ('final','post','ft','cancelled','canceled')
  ORDER BY c.fecha ASC
  LIMIT 1
) nxt ON true
LEFT JOIN public.nfl_partidos game
  ON game.espn_event_id=nxt.espn_event_id
LEFT JOIN LATERAL (
  SELECT i.*
  FROM public.nfl_lesiones_semana i
  WHERE i.espn_player_id=j.espn_player_id
    AND i.temporada=nxt.temporada
    AND i.semana=nxt.semana
  ORDER BY i.cargado_at DESC
  LIMIT 1
) inj ON true
LEFT JOIN public.nfl_uso_jugador u
  ON u.espn_player_id=j.espn_player_id AND u.temporada=nxt.temporada
LEFT JOIN public.nfl_uso_avanzado adv
  ON adv.espn_player_id=j.espn_player_id AND adv.temporada=nxt.temporada
LEFT JOIN public.nfl_snaps_resumen snap
  ON snap.espn_player_id=j.espn_player_id AND snap.temporada=nxt.temporada
LEFT JOIN public.nfl_defensa_vs_posicion_ppr dvp
  ON lower(dvp.equipo_defensa)=lower(nxt.rival)
 AND dvp.temporada=nxt.temporada
 AND upper(dvp.posicion)=upper(j.posicion);
