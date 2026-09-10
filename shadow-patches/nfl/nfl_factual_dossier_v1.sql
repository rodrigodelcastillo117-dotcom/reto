-- NFL FACTUAL DOSSIER V1 — SHADOW / NO DEPLOY
-- Canonical contract keyed by exact espn_event_id. Market context is never P_RETO.

CREATE OR REPLACE VIEW public.nfl_factual_dossier_v1
WITH (security_invoker = true)
AS
SELECT
  p.espn_event_id AS canonical_event_id,
  'NFL'::text AS sport,
  p.fecha AS kickoff,
  p.temporada,
  p.semana,
  p.home_team,
  p.away_team,
  p.home_id,
  p.away_id,
  p.home_abrev,
  p.away_abrev,
  p.home_record,
  p.away_record,
  p.estado,
  'NO_OWN_MODEL'::text AS model_status,
  NULL::numeric AS p_reto_home,
  NULL::numeric AS p_reto_away,
  NULL::numeric AS projected_points_home,
  NULL::numeric AS projected_points_away,
  NULL::jsonb AS score_distribution,
  p.estadio,
  p.techado,
  p.temperatura,
  p.viento_rafaga,
  p.precipitacion,
  p.clima_cond,
  p.actualizado AS game_data_as_of,
  fh.fpi AS context_fpi_home,
  fa.fpi AS context_fpi_away,
  fh.epa_ofensiva AS context_epa_off_home,
  fh.epa_defensiva AS context_epa_def_home,
  fa.epa_ofensiva AS context_epa_off_away,
  fa.epa_defensiva AS context_epa_def_away,
  fh.actualizado AS context_fpi_home_as_of,
  fa.actualizado AS context_fpi_away_as_of,
  'CONTEXT_ONLY_CURRENT_SNAPSHOT'::text AS fpi_role,
  p.lesionados_home,
  p.lesionados_away,
  p.out_home,
  p.out_away,
  p.qb_comprometido_home,
  p.qb_comprometido_away,
  inj_home.items AS injuries_home,
  inj_away.items AS injuries_away,
  inj_home.as_of AS injuries_home_as_of,
  inj_away.as_of AS injuries_away_as_of,
  h2h.partidos AS h2h_games,
  h2h.ultimos_5 AS h2h_last5,
  h2h.actualizado AS h2h_as_of,
  'CONTEXT_ONLY'::text AS h2h_role,
  jsonb_build_object(
    'source','SPORTSBOOK_CONTEXT',
    'opening', CASE WHEN op.snapshot_at IS NULL THEN NULL ELSE jsonb_build_object('at',op.snapshot_at,'book',op.casa,'ml_home',op.ml_home,'ml_away',op.ml_away,'spread',op.spread,'total',op.total_linea) END,
    'current', CASE WHEN cur.snapshot_at IS NULL THEN NULL ELSE jsonb_build_object('at',cur.snapshot_at,'book',cur.casa,'ml_home',cur.ml_home,'ml_away',cur.ml_away,'spread',cur.spread,'total',cur.total_linea) END,
    'closing', CASE WHEN p.fecha > now() OR cls.snapshot_at IS NULL THEN NULL ELSE jsonb_build_object('at',cls.snapshot_at,'book',cls.casa,'ml_home',cls.ml_home,'ml_away',cls.ml_away,'spread',cls.spread,'total',cls.total_linea) END
  ) AS market_line_history,
  jsonb_build_object(
    'identity', true,
    'market_current', cur.snapshot_at IS NOT NULL,
    'market_opening', op.snapshot_at IS NOT NULL,
    'market_closing', p.fecha <= now() AND cls.snapshot_at IS NOT NULL,
    'injuries_home', inj_home.items IS NOT NULL,
    'injuries_away', inj_away.items IS NOT NULL,
    'h2h', h2h.partidos IS NOT NULL,
    'team_strength_context', fh.fpi IS NOT NULL AND fa.fpi IS NOT NULL,
    'own_model', false
  ) AS coverage
FROM public.nfl_partidos p
LEFT JOIN public.nfl_fpi fh ON fh.espn_team_id=p.home_id AND fh.temporada=p.temporada
LEFT JOIN public.nfl_fpi fa ON fa.espn_team_id=p.away_id AND fa.temporada=p.temporada
LEFT JOIN public.nfl_h2h h2h ON (lower(h2h.team_a)=lower(p.home_team) AND lower(h2h.team_b)=lower(p.away_team)) OR (lower(h2h.team_a)=lower(p.away_team) AND lower(h2h.team_b)=lower(p.home_team))
LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object('player_id',i.espn_player_id,'player',i.jugador,'status',i.estado,'injury',i.lesion,'note',i.nota,'source',i.fuente,'verified',i.verificado,'as_of',i.cargado_at) ORDER BY i.jugador) AS items, max(i.cargado_at) AS as_of
  FROM public.nfl_lesiones_semana i
  WHERE i.temporada=p.temporada AND i.semana=p.semana AND lower(i.equipo) IN (lower(p.home_team),lower(coalesce(p.home_abrev,'')))
) inj_home ON true
LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object('player_id',i.espn_player_id,'player',i.jugador,'status',i.estado,'injury',i.lesion,'note',i.nota,'source',i.fuente,'verified',i.verificado,'as_of',i.cargado_at) ORDER BY i.jugador) AS items, max(i.cargado_at) AS as_of
  FROM public.nfl_lesiones_semana i
  WHERE i.temporada=p.temporada AND i.semana=p.semana AND lower(i.equipo) IN (lower(p.away_team),lower(coalesce(p.away_abrev,'')))
) inj_away ON true
LEFT JOIN LATERAL (SELECT s.* FROM public.nfl_odds_snapshots s WHERE s.espn_event_id=p.espn_event_id AND s.snapshot_at<=p.fecha ORDER BY s.snapshot_at ASC LIMIT 1) op ON true
LEFT JOIN LATERAL (SELECT s.* FROM public.nfl_odds_snapshots s WHERE s.espn_event_id=p.espn_event_id AND s.snapshot_at<=least(now(),p.fecha) ORDER BY s.snapshot_at DESC LIMIT 1) cur ON true
LEFT JOIN LATERAL (SELECT s.* FROM public.nfl_odds_snapshots s WHERE s.espn_event_id=p.espn_event_id AND s.snapshot_at<=p.fecha ORDER BY s.snapshot_at DESC LIMIT 1) cls ON true;
