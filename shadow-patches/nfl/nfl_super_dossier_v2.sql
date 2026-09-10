-- NFL SUPER DOSSIER V2 — SHADOW / NO DEPLOY
-- One canonical factual dossier per espn_event_id.
-- IMPORTANT: this view DOES NOT create P_RETO. Sportsbook/no-vig is context only.
-- Temporal rule: whenever a source has a capture timestamp, only rows captured
-- at/before kickoff are eligible for the dossier snapshot.

CREATE OR REPLACE VIEW public.nfl_super_dossier_v2
WITH (security_invoker = true)
AS
SELECT
  p.espn_event_id AS canonical_event_id,
  'NFL'::text AS sport,
  p.fecha AS kickoff,
  p.temporada,
  p.semana,
  p.tipo_temporada,
  p.estado,
  p.home_team,
  p.away_team,
  p.home_id,
  p.away_id,
  p.home_abrev,
  p.away_abrev,
  p.home_record,
  p.away_record,

  -- Model authority: intentionally absent until an own model is validated.
  'NO_OWN_MODEL'::text AS model_status,
  NULL::numeric AS p_reto_home,
  NULL::numeric AS p_reto_away,
  NULL::numeric AS projected_points_home,
  NULL::numeric AS projected_points_away,
  NULL::jsonb AS score_distribution,

  -- Temporal-safe strength context from the last historical FPI snapshot
  -- captured on/before kickoff. These fields are CONTEXT, never P_RETO.
  fph.fpi AS fpi_home_asof,
  fpa.fpi AS fpi_away_asof,
  fph.fpi_rank AS fpi_rank_home_asof,
  fpa.fpi_rank AS fpi_rank_away_asof,
  fph.epa_ofensiva AS fpi_epa_off_home_asof,
  fpa.epa_ofensiva AS fpi_epa_off_away_asof,
  fph.epa_defensiva AS fpi_epa_def_home_asof,
  fpa.epa_defensiva AS fpi_epa_def_away_asof,
  fph.epa_equipos_esp AS fpi_epa_st_home_asof,
  fpa.epa_equipos_esp AS fpi_epa_st_away_asof,
  fph.guardado_at AS fpi_home_snapshot_at,
  fpa.guardado_at AS fpi_away_snapshot_at,
  'CONTEXT_ONLY_TEMPORAL_SAFE'::text AS fpi_role,

  -- Recent form: exact previous completed games before this kickoff.
  form_h.games AS recent_home_games,
  form_h.wins AS recent_home_wins,
  form_h.losses AS recent_home_losses,
  form_h.ties AS recent_home_ties,
  form_h.pf_pg AS recent_home_pf_pg,
  form_h.pa_pg AS recent_home_pa_pg,
  form_h.last5 AS recent_home_last5,
  form_a.games AS recent_away_games,
  form_a.wins AS recent_away_wins,
  form_a.losses AS recent_away_losses,
  form_a.ties AS recent_away_ties,
  form_a.pf_pg AS recent_away_pf_pg,
  form_a.pa_pg AS recent_away_pa_pg,
  form_a.last5 AS recent_away_last5,

  -- Rest / schedule context, derivable without future leakage.
  prev_h.last_game_at AS home_previous_game_at,
  prev_a.last_game_at AS away_previous_game_at,
  CASE WHEN prev_h.last_game_at IS NULL THEN NULL
       ELSE floor(extract(epoch FROM (p.fecha-prev_h.last_game_at))/86400.0)::int END AS home_rest_days,
  CASE WHEN prev_a.last_game_at IS NULL THEN NULL
       ELSE floor(extract(epoch FROM (p.fecha-prev_a.last_game_at))/86400.0)::int END AS away_rest_days,
  CASE WHEN prev_h.last_game_at IS NULL THEN NULL
       ELSE floor(extract(epoch FROM (p.fecha-prev_h.last_game_at))/86400.0) < 7 END AS home_short_week,
  CASE WHEN prev_a.last_game_at IS NULL THEN NULL
       ELSE floor(extract(epoch FROM (p.fecha-prev_a.last_game_at))/86400.0) < 7 END AS away_short_week,

  -- QB/depth-chart factual context. Not a projection.
  qbh.qb1_name AS home_qb1,
  qbh.qb1_player_id AS home_qb1_player_id,
  qbh.qb2_name AS home_qb2,
  qbh.depth_as_of AS home_depth_as_of,
  qba.qb1_name AS away_qb1,
  qba.qb1_player_id AS away_qb1_player_id,
  qba.qb2_name AS away_qb2,
  qba.depth_as_of AS away_depth_as_of,

  -- Exact week injuries, filtered by capture <= kickoff when capture exists.
  ih.items AS injuries_home,
  ia.items AS injuries_away,
  ih.out_count AS injuries_home_out,
  ia.out_count AS injuries_away_out,
  ih.questionable_count AS injuries_home_questionable,
  ia.questionable_count AS injuries_away_questionable,
  ih.as_of AS injuries_home_as_of,
  ia.as_of AS injuries_away_as_of,
  p.qb_comprometido_home,
  p.qb_comprometido_away,

  -- H2H is historical context only.
  h2h.partidos AS h2h_games,
  h2h.gana_a AS h2h_team_a_wins,
  h2h.gana_b AS h2h_team_b_wins,
  h2h.empates AS h2h_ties,
  h2h.pts_a AS h2h_team_a_pf_pg,
  h2h.pts_b AS h2h_team_b_pf_pg,
  h2h.ultimos_5 AS h2h_last5,
  h2h.actualizado AS h2h_as_of,
  'CONTEXT_ONLY'::text AS h2h_role,

  -- Venue / travel proxy.
  vh.estadio AS venue,
  vh.techo AS venue_roof,
  vh.altitud_ft AS venue_altitude_ft,
  vh.lat AS venue_lat,
  vh.lon AS venue_lon,
  va.lat AS away_homebase_lat,
  va.lon AS away_homebase_lon,
  CASE
    WHEN vh.lat IS NULL OR vh.lon IS NULL OR va.lat IS NULL OR va.lon IS NULL THEN NULL
    ELSE round((3958.7613 * acos(least(1.0, greatest(-1.0,
      cos(radians(va.lat::double precision))*cos(radians(vh.lat::double precision))*
      cos(radians(vh.lon::double precision)-radians(va.lon::double precision)) +
      sin(radians(va.lat::double precision))*sin(radians(vh.lat::double precision))
    ))))::numeric,0)
  END AS away_travel_miles_proxy,
  'HOME_BASE_TO_VENUE_PROXY'::text AS travel_distance_role,

  -- Weather nearest to kickoff hour. nfl_clima_hora does not expose capture_at,
  -- so this is current factual forecast context and MUST NOT be used for
  -- historical replay/model training until provenance is added.
  wx.hora_utc AS weather_hour,
  wx.temp_f AS weather_temp_f,
  wx.viento_mph AS weather_wind_mph,
  wx.viento_dir AS weather_wind_dir,
  wx.humedad AS weather_humidity,
  wx.lluvia_mm AS weather_rain_mm,
  'CONTEXT_ONLY_NO_CAPTURE_ASOF'::text AS weather_role,

  -- Market history. Context only; never own probability.
  jsonb_build_object(
    'source','SPORTSBOOK_CONTEXT',
    'opening', CASE WHEN op.snapshot_at IS NULL THEN NULL ELSE jsonb_build_object(
      'at',op.snapshot_at,'book',op.casa,'ml_home',op.ml_home,'ml_away',op.ml_away,
      'spread',op.spread,'total',op.total_linea,'over_odds',op.over_odds,'under_odds',op.under_odds) END,
    'current', CASE WHEN cur.snapshot_at IS NULL THEN NULL ELSE jsonb_build_object(
      'at',cur.snapshot_at,'book',cur.casa,'ml_home',cur.ml_home,'ml_away',cur.ml_away,
      'spread',cur.spread,'total',cur.total_linea,'over_odds',cur.over_odds,'under_odds',cur.under_odds) END,
    'closing', CASE WHEN p.fecha > now() OR cls.snapshot_at IS NULL THEN NULL ELSE jsonb_build_object(
      'at',cls.snapshot_at,'book',cls.casa,'ml_home',cls.ml_home,'ml_away',cls.ml_away,
      'spread',cls.spread,'total',cls.total_linea,'over_odds',cls.over_odds,'under_odds',cls.under_odds) END
  ) AS market_line_history,
  CASE WHEN op.snapshot_at IS NULL OR cur.snapshot_at IS NULL THEN NULL
       ELSE cur.ml_home-op.ml_home END AS market_ml_home_move_american,
  CASE WHEN op.snapshot_at IS NULL OR cur.snapshot_at IS NULL THEN NULL
       ELSE cur.spread-op.spread END AS market_spread_move,
  CASE WHEN op.snapshot_at IS NULL OR cur.snapshot_at IS NULL THEN NULL
       ELSE cur.total_linea-op.total_linea END AS market_total_move,
  'CONTEXT_ONLY'::text AS market_role,

  -- Coverage contract: missing because unavailable is different from a technical bug.
  jsonb_build_object(
    'identity', p.espn_event_id IS NOT NULL,
    'fpi_temporal_home', fph.guardado_at IS NOT NULL,
    'fpi_temporal_away', fpa.guardado_at IS NOT NULL,
    'recent_form_home', coalesce(form_h.games,0) > 0,
    'recent_form_away', coalesce(form_a.games,0) > 0,
    'rest_home', prev_h.last_game_at IS NOT NULL,
    'rest_away', prev_a.last_game_at IS NOT NULL,
    'depth_qb_home', qbh.qb1_player_id IS NOT NULL,
    'depth_qb_away', qba.qb1_player_id IS NOT NULL,
    'injuries_home', ih.as_of IS NOT NULL,
    'injuries_away', ia.as_of IS NOT NULL,
    'h2h', h2h.partidos IS NOT NULL,
    'venue', vh.estadio IS NOT NULL,
    'weather', wx.hora_utc IS NOT NULL,
    'market_opening', op.snapshot_at IS NOT NULL,
    'market_current', cur.snapshot_at IS NOT NULL,
    'market_closing', p.fecha <= now() AND cls.snapshot_at IS NOT NULL,
    'own_model', false
  ) AS coverage,

  jsonb_strip_nulls(jsonb_build_object(
    'own_model','NFL own model not yet validated',
    'fpi_temporal_home', CASE WHEN fph.guardado_at IS NULL THEN 'No FPI historical snapshot on/before kickoff' END,
    'fpi_temporal_away', CASE WHEN fpa.guardado_at IS NULL THEN 'No FPI historical snapshot on/before kickoff' END,
    'recent_form_home', CASE WHEN coalesce(form_h.games,0)=0 THEN 'No completed prior games in database' END,
    'recent_form_away', CASE WHEN coalesce(form_a.games,0)=0 THEN 'No completed prior games in database' END,
    'depth_qb_home', CASE WHEN qbh.qb1_player_id IS NULL THEN 'No verified QB depth-chart row on/before kickoff' END,
    'depth_qb_away', CASE WHEN qba.qb1_player_id IS NULL THEN 'No verified QB depth-chart row on/before kickoff' END,
    'injuries_home', CASE WHEN ih.as_of IS NULL THEN 'No exact season/week injury snapshot on/before kickoff' END,
    'injuries_away', CASE WHEN ia.as_of IS NULL THEN 'No exact season/week injury snapshot on/before kickoff' END,
    'h2h', CASE WHEN h2h.partidos IS NULL THEN 'No H2H row for exact ESPN team ids' END,
    'venue', CASE WHEN vh.estadio IS NULL THEN 'No home-team venue mapping' END,
    'weather', CASE WHEN wx.hora_utc IS NULL THEN 'No weather row near kickoff hour' END,
    'market_opening', CASE WHEN op.snapshot_at IS NULL THEN 'No opening odds snapshot' END,
    'market_current', CASE WHEN cur.snapshot_at IS NULL THEN 'No pregame/current odds snapshot' END,
    'market_closing', CASE WHEN p.fecha > now() THEN 'Game has not closed yet' WHEN cls.snapshot_at IS NULL THEN 'No closing snapshot' END,
    'epa_play','Dedicated EPA/play history by team/week is not available yet',
    'success_rate','Dedicated success-rate history by team/week is not available yet',
    'proe','Dedicated PROE history by team/week is not available yet',
    'pace','Dedicated pace history by team/week is not available yet',
    'ol_dl','Dedicated OL/DL matchup source is not available yet',
    'coverage_blitz','Licensed man/zone/blitz matchup feed is not available yet'
  )) AS missing_reason

FROM public.nfl_partidos p

LEFT JOIN LATERAL (
  SELECT f.* FROM public.nfl_fpi_historico f
  WHERE f.espn_team_id=p.home_id AND f.temporada=p.temporada
    AND f.capturado_el <= p.fecha::date
  ORDER BY f.capturado_el DESC, f.guardado_at DESC LIMIT 1
) fph ON true
LEFT JOIN LATERAL (
  SELECT f.* FROM public.nfl_fpi_historico f
  WHERE f.espn_team_id=p.away_id AND f.temporada=p.temporada
    AND f.capturado_el <= p.fecha::date
  ORDER BY f.capturado_el DESC, f.guardado_at DESC LIMIT 1
) fpa ON true

LEFT JOIN LATERAL (
  SELECT max(x.fecha) AS last_game_at
  FROM public.nfl_partidos x
  WHERE x.fecha < p.fecha AND x.pts_home IS NOT NULL AND x.pts_away IS NOT NULL
    AND (x.home_id=p.home_id OR x.away_id=p.home_id)
) prev_h ON true
LEFT JOIN LATERAL (
  SELECT max(x.fecha) AS last_game_at
  FROM public.nfl_partidos x
  WHERE x.fecha < p.fecha AND x.pts_home IS NOT NULL AND x.pts_away IS NOT NULL
    AND (x.home_id=p.away_id OR x.away_id=p.away_id)
) prev_a ON true

LEFT JOIN LATERAL (
  SELECT count(*)::int AS games,
         count(*) FILTER (WHERE (z.home_id=p.home_id AND z.pts_home>z.pts_away) OR (z.away_id=p.home_id AND z.pts_away>z.pts_home))::int AS wins,
         count(*) FILTER (WHERE (z.home_id=p.home_id AND z.pts_home<z.pts_away) OR (z.away_id=p.home_id AND z.pts_away<z.pts_home))::int AS losses,
         count(*) FILTER (WHERE z.pts_home=z.pts_away)::int AS ties,
         round(avg(CASE WHEN z.home_id=p.home_id THEN z.pts_home ELSE z.pts_away END)::numeric,1) AS pf_pg,
         round(avg(CASE WHEN z.home_id=p.home_id THEN z.pts_away ELSE z.pts_home END)::numeric,1) AS pa_pg,
         string_agg(CASE WHEN (z.home_id=p.home_id AND z.pts_home>z.pts_away) OR (z.away_id=p.home_id AND z.pts_away>z.pts_home) THEN 'W'
                         WHEN z.pts_home=z.pts_away THEN 'T' ELSE 'L' END,'') AS last5
  FROM (SELECT * FROM public.nfl_partidos z0 WHERE z0.fecha<p.fecha AND z0.pts_home IS NOT NULL AND z0.pts_away IS NOT NULL AND (z0.home_id=p.home_id OR z0.away_id=p.home_id) ORDER BY z0.fecha DESC LIMIT 5) z
) form_h ON true
LEFT JOIN LATERAL (
  SELECT count(*)::int AS games,
         count(*) FILTER (WHERE (z.home_id=p.away_id AND z.pts_home>z.pts_away) OR (z.away_id=p.away_id AND z.pts_away>z.pts_home))::int AS wins,
         count(*) FILTER (WHERE (z.home_id=p.away_id AND z.pts_home<z.pts_away) OR (z.away_id=p.away_id AND z.pts_away<z.pts_home))::int AS losses,
         count(*) FILTER (WHERE z.pts_home=z.pts_away)::int AS ties,
         round(avg(CASE WHEN z.home_id=p.away_id THEN z.pts_home ELSE z.pts_away END)::numeric,1) AS pf_pg,
         round(avg(CASE WHEN z.home_id=p.away_id THEN z.pts_away ELSE z.pts_home END)::numeric,1) AS pa_pg,
         string_agg(CASE WHEN (z.home_id=p.away_id AND z.pts_home>z.pts_away) OR (z.away_id=p.away_id AND z.pts_away>z.pts_home) THEN 'W'
                         WHEN z.pts_home=z.pts_away THEN 'T' ELSE 'L' END,'') AS last5
  FROM (SELECT * FROM public.nfl_partidos z0 WHERE z0.fecha<p.fecha AND z0.pts_home IS NOT NULL AND z0.pts_away IS NOT NULL AND (z0.home_id=p.away_id OR z0.away_id=p.away_id) ORDER BY z0.fecha DESC LIMIT 5) z
) form_a ON true

LEFT JOIN LATERAL (
  SELECT max(d.cargado_at) AS depth_as_of,
         max(d.jugador) FILTER (WHERE upper(d.posicion)='QB' AND d.orden=1) AS qb1_name,
         max(d.espn_player_id) FILTER (WHERE upper(d.posicion)='QB' AND d.orden=1) AS qb1_player_id,
         max(d.jugador) FILTER (WHERE upper(d.posicion)='QB' AND d.orden=2) AS qb2_name
  FROM public.nfl_depth_chart d
  WHERE d.temporada=p.temporada
    AND lower(d.equipo) IN (lower(p.home_team),lower(coalesce(p.home_abrev,'')))
    AND d.cargado_at<=p.fecha
) qbh ON true
LEFT JOIN LATERAL (
  SELECT max(d.cargado_at) AS depth_as_of,
         max(d.jugador) FILTER (WHERE upper(d.posicion)='QB' AND d.orden=1) AS qb1_name,
         max(d.espn_player_id) FILTER (WHERE upper(d.posicion)='QB' AND d.orden=1) AS qb1_player_id,
         max(d.jugador) FILTER (WHERE upper(d.posicion)='QB' AND d.orden=2) AS qb2_name
  FROM public.nfl_depth_chart d
  WHERE d.temporada=p.temporada
    AND lower(d.equipo) IN (lower(p.away_team),lower(coalesce(p.away_abrev,'')))
    AND d.cargado_at<=p.fecha
) qba ON true

LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object('player_id',i.espn_player_id,'player',i.jugador,'status',i.estado,'injury',i.lesion,'note',i.nota,'source',i.fuente,'verified',i.verificado,'as_of',i.cargado_at) ORDER BY i.jugador) AS items,
         count(*) FILTER (WHERE upper(coalesce(i.estado,''))='OUT')::int AS out_count,
         count(*) FILTER (WHERE upper(coalesce(i.estado,''))='QUESTIONABLE')::int AS questionable_count,
         max(i.cargado_at) AS as_of
  FROM public.nfl_lesiones_semana i
  WHERE i.temporada=p.temporada AND i.semana=p.semana
    AND lower(i.equipo) IN (lower(p.home_team),lower(coalesce(p.home_abrev,'')))
    AND i.cargado_at<=p.fecha
) ih ON true
LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object('player_id',i.espn_player_id,'player',i.jugador,'status',i.estado,'injury',i.lesion,'note',i.nota,'source',i.fuente,'verified',i.verificado,'as_of',i.cargado_at) ORDER BY i.jugador) AS items,
         count(*) FILTER (WHERE upper(coalesce(i.estado,''))='OUT')::int AS out_count,
         count(*) FILTER (WHERE upper(coalesce(i.estado,''))='QUESTIONABLE')::int AS questionable_count,
         max(i.cargado_at) AS as_of
  FROM public.nfl_lesiones_semana i
  WHERE i.temporada=p.temporada AND i.semana=p.semana
    AND lower(i.equipo) IN (lower(p.away_team),lower(coalesce(p.away_abrev,'')))
    AND i.cargado_at<=p.fecha
) ia ON true

LEFT JOIN public.nfl_h2h h2h
  ON (h2h.team_a=p.home_id AND h2h.team_b=p.away_id)
  OR (h2h.team_a=p.away_id AND h2h.team_b=p.home_id)
LEFT JOIN public.nfl_estadios vh ON vh.team_espn_id=p.home_id
LEFT JOIN public.nfl_estadios va ON va.team_espn_id=p.away_id
LEFT JOIN LATERAL (
  SELECT w.* FROM public.nfl_clima_hora w
  WHERE w.team_espn_id=p.home_id
  ORDER BY abs(extract(epoch FROM (w.hora_utc-p.fecha))) ASC
  LIMIT 1
) wx ON true
LEFT JOIN LATERAL (SELECT s.* FROM public.nfl_odds_snapshots s WHERE s.espn_event_id=p.espn_event_id AND s.snapshot_at<=p.fecha ORDER BY s.snapshot_at ASC LIMIT 1) op ON true
LEFT JOIN LATERAL (SELECT s.* FROM public.nfl_odds_snapshots s WHERE s.espn_event_id=p.espn_event_id AND s.snapshot_at<=least(now(),p.fecha) ORDER BY s.snapshot_at DESC LIMIT 1) cur ON true
LEFT JOIN LATERAL (SELECT s.* FROM public.nfl_odds_snapshots s WHERE s.espn_event_id=p.espn_event_id AND s.snapshot_at<=p.fecha ORDER BY s.snapshot_at DESC LIMIT 1) cls ON true;

COMMENT ON VIEW public.nfl_super_dossier_v2 IS
'NFL factual super dossier keyed by exact ESPN event id. NO_OWN_MODEL: P_RETO/projections stay NULL until a validated own NFL model exists. Market, H2H, FPI and weather are contextual and explicitly role-labelled. Sources with capture timestamps are selected as-of kickoff.';