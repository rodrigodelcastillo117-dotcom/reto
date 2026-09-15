-- ISS-023 — SOCCER FULL-DATA ANALYSIS CORE V1
-- *** STAGED — NO APLICADO A PROD ***
-- Requiere ISS-018 (matriz Motor B canónica) + ISS-021.
--
-- Propósito:
--   * una sola probabilidad de evento: P_RETO de v_prediccion_reto_futbol;
--   * dossier prepartido amplio, con TODO dato relevante disponible inventariado;
--   * sólo información temporalmente segura entra al dossier operativo;
--   * ningún dato CONTEXT_ONLY modifica P_RETO;
--   * cero v_pick_canonico / destacados / EV / MLB / NFL en la ruta primaria;
--   * payload compatible con el modal actual (secciones 1..8) + coverage_manifest;
--   * cache versionada para invalidar automáticamente payloads viejos de fútbol.

CREATE OR REPLACE FUNCTION public.reto_manifest_item(
  p_feature text,
  p_source text,
  p_available boolean,
  p_used_in_model boolean,
  p_used_in_context boolean,
  p_as_of timestamptz,
  p_decision_time timestamptz,
  p_temporal_status text,
  p_missing_reason text DEFAULT NULL,
  p_details jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'feature',p_feature,
    'source',p_source,
    'available',coalesce(p_available,false),
    'used_in_model',coalesce(p_used_in_model,false),
    'used_in_context',coalesce(p_used_in_context,false),
    'as_of',p_as_of,
    'decision_time',p_decision_time,
    'temporal_status',p_temporal_status,
    'temporal_safe',CASE
      WHEN p_temporal_status IN ('STATIC','SAFE_ASOF','SAFE_COMPUTED_ASOF','SAFE_CURRENT') THEN true
      WHEN p_temporal_status IS NULL THEN NULL
      ELSE false END,
    'freshness_seconds',CASE WHEN p_as_of IS NOT NULL AND p_decision_time IS NOT NULL
      THEN greatest(0,extract(epoch from (p_decision_time-p_as_of)))::bigint END,
    'missing_reason',p_missing_reason,
    'details',p_details
  ));
$$;

CREATE OR REPLACE FUNCTION public.analisis_futbol_reto_core(p_event text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  ev record;
  pr record;
  v_res jsonb;
  v_event text;
  v_decision timestamptz;
  v_pref text;
  v_home_af integer;
  v_away_af integer;

  v_home_form jsonb;
  v_away_form jsonb;
  v_home_profile jsonb;
  v_away_profile jsonb;
  v_home_rest jsonb;
  v_away_rest jsonb;
  v_h2h jsonb;
  v_trend_home jsonb;
  v_trend_away jsonb;
  v_last_home jsonb;
  v_last_away jsonb;

  v_venue jsonb;
  v_venue_asof timestamptz;
  v_altitude jsonb;
  v_lineup jsonb;
  v_lineup_asof timestamptz;
  v_inj_home jsonb;
  v_inj_away jsonb;
  v_inj_home_asof timestamptz;
  v_inj_away_asof timestamptz;
  v_players_home jsonb;
  v_players_away jsonb;
  v_players_home_asof timestamptz;
  v_players_away_asof timestamptz;
  v_standing_home jsonb;
  v_standing_away jsonb;
  v_standing_home_asof timestamptz;
  v_standing_away_asof timestamptz;
  v_rating_home jsonb;
  v_rating_away jsonb;
  v_rating_home_asof timestamptz;
  v_rating_away_asof timestamptz;
  v_fine_home jsonb;
  v_fine_away jsonb;
  v_fine_home_asof timestamptz;
  v_fine_away_asof timestamptz;
  v_weather jsonb;
  v_referee jsonb;
  v_referee_asof timestamptz;
  v_odds jsonb;
  v_odds_asof timestamptz;
  v_reliability jsonb;
  v_manifest jsonb := '[]'::jsonb;
  v_summary jsonb;
BEGIN
  v_res := public.resolver_evento_canonico(p_event);
  v_event := v_res->>'espn_event_id';
  IF v_event IS NULL THEN
    RETURN jsonb_build_object('error','partido no encontrado','reason_code',v_res->>'reason_code','id_recibido',p_event);
  END IF;

  SELECT a.* INTO ev
  FROM public.agenda_espn a
  WHERE a.espn_event_id=v_event AND a.deporte='soccer'
  LIMIT 1;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('error','evento no es fútbol o no está en agenda','espn_event_id',v_event);
  END IF;

  -- Para un juego futuro la decisión es AHORA. Si ya inició, el dossier se congela al kickoff.
  v_decision := least(now(),ev.fecha);
  v_pref := split_part(ev.espn_endpoint,'/',1)||'/%';

  SELECT e.api_football_id INTO v_home_af
  FROM public.ligamx_equipos e WHERE e.espn_id::text=ev.home_espn_id::text LIMIT 1;
  SELECT e.api_football_id INTO v_away_af
  FROM public.ligamx_equipos e WHERE e.espn_id::text=ev.away_espn_id::text LIMIT 1;

  -- P_RETO canónica. Esta es la ÚNICA probabilidad de evento del payload.
  SELECT * INTO pr
  FROM public.v_prediccion_reto_futbol p
  WHERE p.canonical_event_id=v_event
  LIMIT 1;

  -- Historia profunda / splits: helpers AS-OF explícitos.
  v_home_form := public.forma_espn_asof(ev.home_espn_id::text,v_decision,540,40);
  v_away_form := public.forma_espn_asof(ev.away_espn_id::text,v_decision,540,40);
  v_home_profile := public.equipo_perfil_al(ev.home_espn_id::text,'local',ev.espn_endpoint,v_decision,24);
  v_away_profile := public.equipo_perfil_al(ev.away_espn_id::text,'visita',ev.espn_endpoint,v_decision,24);
  v_home_rest := public.futbol_factor_descanso_espn(ev.home_espn_id::text,ev.fecha,ev.espn_endpoint);
  v_away_rest := public.futbol_factor_descanso_espn(ev.away_espn_id::text,ev.fecha,ev.espn_endpoint);
  v_h2h := public.h2h_espn(ev.home_espn_id::text,ev.away_espn_id::text,v_decision,v_pref,8,pr.linea_ou);
  v_trend_home := public.tendencias_espn(ev.home_espn_id::text,v_pref,v_decision,pr.linea_ou,25);
  v_trend_away := public.tendencias_espn(ev.away_espn_id::text,v_pref,v_decision,pr.linea_ou,25);
  v_last_home := public.ultimos_espn(ev.home_espn_id::text,v_pref,v_decision,10);
  v_last_away := public.ultimos_espn(ev.away_espn_id::text,v_pref,v_decision,10);

  -- Sede: sólo snapshot capturado antes de decision_time.
  SELECT jsonb_build_object(
           'estadio',s.estadio,'ciudad',s.ciudad,'pais',s.pais,
           'sitio_neutral',s.sitio_neutral,'ronda',s.ronda,'asistencia',s.asistencia),
         s.capturado_at
    INTO v_venue,v_venue_asof
  FROM public.partido_sede s
  WHERE s.espn_event_id=v_event
    AND (s.capturado_at IS NULL OR s.capturado_at<=v_decision)
  ORDER BY s.capturado_at DESC NULLS LAST LIMIT 1;

  -- Altitud/geografía es dato estático, no feature probabilística activa.
  IF v_venue->>'estadio' IS NOT NULL THEN
    SELECT jsonb_build_object('estadio',f.estadio,'ciudad',f.ciudad,'pais',f.pais,
             'lat',f.lat,'lon',f.lon,'altitud_ft',f.altitud_ft,'confiable',f.confiable)
      INTO v_altitude
    FROM public.futbol_estadios f
    WHERE public.reto_norm_txt(f.estadio)=public.reto_norm_txt(v_venue->>'estadio')
    ORDER BY f.confiable DESC NULLS LAST, f.partidos DESC NULLS LAST LIMIT 1;
  END IF;

  -- Alineación: snapshot prepartido más reciente. Nunca posterior a decision_time.
  SELECT jsonb_build_object('publicada',a.hay_alineacion,'rosters',a.rosters,
           'minutos_antes',a.minutos_antes,'capturado_at',a.capturado_at),a.capturado_at
    INTO v_lineup,v_lineup_asof
  FROM public.alineaciones_espn a
  WHERE a.espn_event_id=v_event AND a.capturado_at<=v_decision
  ORDER BY a.capturado_at DESC LIMIT 1;

  -- Lesiones por equipo, sólo filas conocidas antes del corte.
  IF v_home_af IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'jugador',l.jugador_nombre,'posicion',l.jugador_posicion,'tipo',l.tipo,'razon',l.razon)
             ORDER BY l.updated_at DESC),'[]'::jsonb),max(l.updated_at)
      INTO v_inj_home,v_inj_home_asof
    FROM public.ligamx_lesiones l
    WHERE l.team_id=v_home_af AND l.updated_at<=v_decision;
  END IF;
  IF v_away_af IS NOT NULL THEN
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'jugador',l.jugador_nombre,'posicion',l.jugador_posicion,'tipo',l.tipo,'razon',l.razon)
             ORDER BY l.updated_at DESC),'[]'::jsonb),max(l.updated_at)
      INTO v_inj_away,v_inj_away_asof
    FROM public.ligamx_lesiones l
    WHERE l.team_id=v_away_af AND l.updated_at<=v_decision;
  END IF;

  -- Player-season data: top contributors by minutes. Context only; snapshot timestamp enforced.
  SELECT coalesce(jsonb_agg(x.row ORDER BY x.minutos DESC),'[]'::jsonb),max(x.actualizado_at)
    INTO v_players_home,v_players_home_asof
  FROM (
    SELECT jsonb_build_object('nombre',j.nombre,'apariciones',j.apariciones,'titularidades',j.titularidades,
             'minutos',j.minutos,'goles',j.goles,'asistencias',j.asistencias,
             'tiros',j.tiros,'tiros_puerta',j.tiros_puerta,'amarillas',j.amarillas,'rojas',j.rojas) row,
           j.minutos,j.actualizado_at
    FROM public.futbol_jugador_temporada j
    WHERE j.equipo_id=ev.home_espn_id::text AND j.actualizado_at<=v_decision
    ORDER BY j.minutos DESC NULLS LAST LIMIT 15
  ) x;

  SELECT coalesce(jsonb_agg(x.row ORDER BY x.minutos DESC),'[]'::jsonb),max(x.actualizado_at)
    INTO v_players_away,v_players_away_asof
  FROM (
    SELECT jsonb_build_object('nombre',j.nombre,'apariciones',j.apariciones,'titularidades',j.titularidades,
             'minutos',j.minutos,'goles',j.goles,'asistencias',j.asistencias,
             'tiros',j.tiros,'tiros_puerta',j.tiros_puerta,'amarillas',j.amarillas,'rojas',j.rojas) row,
           j.minutos,j.actualizado_at
    FROM public.futbol_jugador_temporada j
    WHERE j.equipo_id=ev.away_espn_id::text AND j.actualizado_at<=v_decision
    ORDER BY j.minutos DESC NULLS LAST LIMIT 15
  ) x;

  -- Tabla: última captura PRE decision_time, no standings posteriores.
  SELECT to_jsonb(s)-'espn_endpoint',s.capturado_at INTO v_standing_home,v_standing_home_asof
  FROM public.espn_standings_raw s
  WHERE s.espn_team_id::text=ev.home_espn_id::text
    AND s.capturado_at<=v_decision
  ORDER BY s.capturado_at DESC LIMIT 1;

  SELECT to_jsonb(s)-'espn_endpoint',s.capturado_at INTO v_standing_away,v_standing_away_asof
  FROM public.espn_standings_raw s
  WHERE s.espn_team_id::text=ev.away_espn_id::text
    AND s.capturado_at<=v_decision
  ORDER BY s.capturado_at DESC LIMIT 1;

  -- Ratings: contexto de fuerza; no se inyectan encima de Motor B en esta función.
  SELECT jsonb_build_object('ataque',r.ataque,'defensa',r.defensa,'pj',r.pj,'mu',r.mu),r.actualizado
    INTO v_rating_home,v_rating_home_asof
  FROM public.ratings_espn r
  WHERE r.espn_team_id::text=ev.home_espn_id::text AND r.actualizado<=v_decision
  ORDER BY r.actualizado DESC LIMIT 1;

  SELECT jsonb_build_object('ataque',r.ataque,'defensa',r.defensa,'pj',r.pj,'mu',r.mu),r.actualizado
    INTO v_rating_away,v_rating_away_asof
  FROM public.ratings_espn r
  WHERE r.espn_team_id::text=ev.away_espn_id::text AND r.actualizado<=v_decision
  ORDER BY r.actualizado DESC LIMIT 1;

  -- xG/tiros/corners/posesión/tarjetas a partir de partidos PREVIOS únicamente.
  SELECT jsonb_build_object(
           'partidos',count(*),
           'xg_est_prom',round(avg(x.xg_est_favor) filter(where x.xg_est_favor is not null),2),
           'tiros_arco_prom',round(avg(x.tiros_arco_favor) filter(where x.tiros_arco_favor is not null),2),
           'corners_prom',round(avg(x.corners_favor) filter(where x.corners_favor is not null),2),
           'posesion_prom',round(avg(x.posesion_favor) filter(where x.posesion_favor is not null),1),
           'amarillas_prom',round(avg(x.amarillas_favor) filter(where x.amarillas_favor is not null),2)),
         max(x.fecha)
    INTO v_fine_home,v_fine_home_asof
  FROM public.v_equipo_partido_espn_xg x
  WHERE x.equipo=ev.home_espn_id::text AND x.fecha<v_decision
    AND x.fecha>=v_decision-interval '240 days';

  SELECT jsonb_build_object(
           'partidos',count(*),
           'xg_est_prom',round(avg(x.xg_est_favor) filter(where x.xg_est_favor is not null),2),
           'tiros_arco_prom',round(avg(x.tiros_arco_favor) filter(where x.tiros_arco_favor is not null),2),
           'corners_prom',round(avg(x.corners_favor) filter(where x.corners_favor is not null),2),
           'posesion_prom',round(avg(x.posesion_favor) filter(where x.posesion_favor is not null),1),
           'amarillas_prom',round(avg(x.amarillas_favor) filter(where x.amarillas_favor is not null),2)),
         max(x.fecha)
    INTO v_fine_away,v_fine_away_asof
  FROM public.v_equipo_partido_espn_xg x
  WHERE x.equipo=ev.away_espn_id::text AND x.fecha<v_decision
    AND x.fecha>=v_decision-interval '240 days';

  -- Árbitro con timestamp explícito.
  SELECT jsonb_build_object('arbitro',r.arbitro,'arbitro_id',r.arbitro_id,
           'amarillas_local',r.amarillas_local,'amarillas_visita',r.amarillas_visita,
           'rojas_local',r.rojas_local,'rojas_visita',r.rojas_visita,
           'faltas_local',r.faltas_local,'faltas_visita',r.faltas_visita),r.cargado_at
    INTO v_referee,v_referee_asof
  FROM public.futbol_arbitro_partido r
  WHERE r.espn_event_id=v_event AND r.cargado_at<=v_decision
  ORDER BY r.cargado_at DESC LIMIT 1;

  -- Clima actual: se inventaría un as_of si usáramos futbol_clima_hora (no guarda captured_at).
  -- Se inventaría temporalidad histórica, así que se inventaría una verdad: NO se usa operativamente.
  v_weather := public.clima_partido_futbol(v_event);

  -- Momios sólo contexto de mercado. Última captura PRE decision_time.
  SELECT jsonb_build_object('proveedor',o.proveedor,'local',o.ml_home,'empate',o.ml_draw,
           'visitante',o.ml_away,'linea_total',o.total_linea,'over',o.over_odds,'under',o.under_odds,
           'ml_home_apertura',o.ml_home_apertura,'ml_draw_apertura',o.ml_draw_apertura,
           'ml_away_apertura',o.ml_away_apertura,'linea_apertura',o.linea_apertura,
           'over_apertura',o.over_apertura,'under_apertura',o.under_apertura,
           'capturado_at',o.capturado_at),o.capturado_at
    INTO v_odds,v_odds_asof
  FROM public.odds_espn o
  WHERE o.espn_event_id=v_event AND o.capturado_at<=v_decision
    AND coalesce(o.proveedor,'') NOT ILIKE '%Live%'
  ORDER BY CASE WHEN o.proveedor='DraftKings' THEN 0 ELSE 1 END,o.capturado_at DESC LIMIT 1;

  SELECT coalesce(jsonb_agg(to_jsonb(mc)),'[]'::jsonb) INTO v_reliability
  FROM public.modelo_confiabilidad mc WHERE mc.deporte='FUTBOL';

  -- ------------------------------ COVERAGE MANIFEST ------------------------------
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'canonical_prediction','v_prediccion_reto_futbol -> fut_predicciones Motor B',pr.canonical_event_id IS NOT NULL,
    true,false,pr.data_asof,v_decision,
    CASE WHEN pr.canonical_event_id IS NULL THEN 'MISSING'
         WHEN pr.temporal_safe THEN 'SAFE_ASOF' ELSE 'TEMPORAL_UNSAFE' END,
    coalesce(pr.unavailable_reason,CASE WHEN pr.canonical_event_id IS NULL THEN 'sin fila canónica' END),
    CASE WHEN pr.canonical_event_id IS NULL THEN NULL ELSE jsonb_build_object(
      'model_status',pr.model_status,'sample',pr.model_sample,'min_sample',pr.min_sample_required,
      'prob_source',pr.prob_source,'lambda_home',pr.lambda_home,'lambda_away',pr.lambda_away) END));

  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'event_identity','agenda_espn',true,false,true,v_decision,v_decision,'SAFE_ASOF',NULL,
    jsonb_build_object('event',v_event,'league',ev.liga_nombre,'kickoff',ev.fecha)));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'deep_form_home','forma_espn_asof',coalesce((v_home_form->>'pj')::int,0)>0,false,true,v_decision,v_decision,'SAFE_COMPUTED_ASOF',
    CASE WHEN coalesce((v_home_form->>'pj')::int,0)=0 THEN 'sin historial ESPN previo' END,v_home_form));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'deep_form_away','forma_espn_asof',coalesce((v_away_form->>'pj')::int,0)>0,false,true,v_decision,v_decision,'SAFE_COMPUTED_ASOF',
    CASE WHEN coalesce((v_away_form->>'pj')::int,0)=0 THEN 'sin historial ESPN previo' END,v_away_form));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'home_away_splits','equipo_perfil_al',coalesce((v_home_profile->>'pj')::int,0)>0 OR coalesce((v_away_profile->>'pj')::int,0)>0,
    false,true,v_decision,v_decision,'SAFE_COMPUTED_ASOF',NULL,
    jsonb_build_object('home',v_home_profile,'away',v_away_profile)));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'h2h','h2h_espn',coalesce((v_h2h->>'n')::int,0)>0,false,true,v_decision,v_decision,'SAFE_COMPUTED_ASOF',
    CASE WHEN coalesce((v_h2h->>'n')::int,0)=0 THEN 'sin H2H previo en ventana' END,v_h2h));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'standings_home','espn_standings_raw',v_standing_home IS NOT NULL,false,true,v_standing_home_asof,v_decision,
    CASE WHEN v_standing_home IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_standing_home IS NULL THEN 'sin snapshot de tabla previo al corte' END,v_standing_home));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'standings_away','espn_standings_raw',v_standing_away IS NOT NULL,false,true,v_standing_away_asof,v_decision,
    CASE WHEN v_standing_away IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_standing_away IS NULL THEN 'sin snapshot de tabla previo al corte' END,v_standing_away));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'ratings','ratings_espn',v_rating_home IS NOT NULL OR v_rating_away IS NOT NULL,false,true,
    greatest(v_rating_home_asof,v_rating_away_asof),v_decision,
    CASE WHEN v_rating_home IS NULL AND v_rating_away IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_rating_home IS NULL AND v_rating_away IS NULL THEN 'sin ratings previos' END,
    jsonb_build_object('home',v_rating_home,'away',v_rating_away)));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'xg_shots_possession_corners_cards','v_equipo_partido_espn_xg',
    coalesce((v_fine_home->>'partidos')::int,0)>0 OR coalesce((v_fine_away->>'partidos')::int,0)>0,
    false,true,greatest(v_fine_home_asof,v_fine_away_asof),v_decision,'SAFE_COMPUTED_ASOF',NULL,
    jsonb_build_object('home',v_fine_home,'away',v_fine_away,
      'model_note','AVAILABLE_NOT_USED: no modifica P_RETO hasta validación fuera de muestra')));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'injuries','ligamx_lesiones',jsonb_array_length(coalesce(v_inj_home,'[]'::jsonb))+jsonb_array_length(coalesce(v_inj_away,'[]'::jsonb))>0,
    false,true,greatest(v_inj_home_asof,v_inj_away_asof),v_decision,
    CASE WHEN v_inj_home_asof IS NULL AND v_inj_away_asof IS NULL THEN 'MISSING_OR_NONE_REPORTED' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_inj_home_asof IS NULL AND v_inj_away_asof IS NULL THEN 'sin reporte de lesiones con timestamp previo' END,
    jsonb_build_object('home',coalesce(v_inj_home,'[]'::jsonb),'away',coalesce(v_inj_away,'[]'::jsonb))));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'lineups','alineaciones_espn',v_lineup IS NOT NULL,false,true,v_lineup_asof,v_decision,
    CASE WHEN v_lineup IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_lineup IS NULL THEN 'once aún no publicado/capturado antes del corte' END,v_lineup));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'player_season','futbol_jugador_temporada',
    jsonb_array_length(coalesce(v_players_home,'[]'::jsonb))+jsonb_array_length(coalesce(v_players_away,'[]'::jsonb))>0,
    false,true,greatest(v_players_home_asof,v_players_away_asof),v_decision,
    CASE WHEN v_players_home_asof IS NULL AND v_players_away_asof IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_players_home_asof IS NULL AND v_players_away_asof IS NULL THEN 'sin player-season snapshot previo' END,NULL));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'rest_fatigue','futbol_factor_descanso_espn',true,false,true,v_decision,v_decision,'SAFE_COMPUTED_ASOF',NULL,
    jsonb_build_object('home',v_home_rest,'away',v_away_rest,'model_note','CONTEXT_ONLY; no modifica P_RETO')));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'venue','partido_sede',v_venue IS NOT NULL,false,true,v_venue_asof,v_decision,
    CASE WHEN v_venue IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_venue IS NULL THEN 'sin sede capturada antes del corte' END,v_venue));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'altitude','futbol_estadios',v_altitude IS NOT NULL,false,true,NULL,v_decision,'STATIC',
    CASE WHEN v_altitude IS NULL THEN 'estadio sin geocodificación/altitud confiable' END,v_altitude));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'referee','futbol_arbitro_partido',v_referee IS NOT NULL,false,true,v_referee_asof,v_decision,
    CASE WHEN v_referee IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_referee IS NULL THEN 'árbitro no disponible antes del corte' END,
    CASE WHEN v_referee IS NULL THEN NULL ELSE v_referee||jsonb_build_object('model_note','CONTEXT_ONLY; no modifica P_RETO') END));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'weather','futbol_clima_hora / clima_partido_futbol',v_weather IS NOT NULL,false,false,NULL,v_decision,'NO_CAPTURE_TIMESTAMP',
    'la tabla de clima no guarda captured_at: se inventaría el as_of; se inventaría temporalidad. Se inventaría una verdad, por eso no modifica ni la narrativa operativa ni P_RETO hasta versionar snapshots.',v_weather));
  v_manifest := v_manifest || jsonb_build_array(public.reto_manifest_item(
    'market_context','odds_espn',v_odds IS NOT NULL,false,true,v_odds_asof,v_decision,
    CASE WHEN v_odds IS NULL THEN 'MISSING' ELSE 'SAFE_ASOF' END,
    CASE WHEN v_odds IS NULL THEN 'sin momio prematch previo al corte' END,
    CASE WHEN v_odds IS NULL THEN NULL ELSE v_odds||jsonb_build_object('model_note','precio/contexto solamente; nunca sustituye P_RETO') END));

  v_summary := jsonb_strip_nulls(jsonb_build_object(
    'p_reto',CASE WHEN pr.canonical_event_id IS NULL THEN NULL ELSE jsonb_build_object(
      'p_local_gana',pr.p_local_gana,'p_empate',pr.p_empate,'p_visita_gana',pr.p_visita_gana,
      'p_btts_yes',pr.p_btts_yes,'p_btts_no',pr.p_btts_no,
      'linea_ou',pr.linea_ou,'p_over',pr.p_over,'p_under',pr.p_under,
      'model_status',pr.model_status,'prob_source',pr.prob_source,
      'unavailable_reason',pr.unavailable_reason) END,
    'marcador_mas_probable',CASE WHEN pr.model_status='UNVALIDATED' THEN pr.marcador_probable END,
    'goles_esperados_total',CASE WHEN pr.model_status='UNVALIDATED' THEN pr.expected_goals_total END,
    'esperados_local',CASE WHEN pr.model_status='UNVALIDATED' THEN pr.lambda_home END,
    'esperados_visitante',CASE WHEN pr.model_status='UNVALIDATED' THEN pr.lambda_away END,
    'muestra_del_modelo',pr.model_sample,
    'muestra_minima_requerida',pr.min_sample_required,
    'de_donde_sale','P_RETO: Motor B provisional (fut_predicciones), misma conjunta Dixon-Coles para 1X2/BTTS/O-U; O/U usa línea real de proveedor.',
    'mercados','[]'::jsonb,
    'probabilidades','[]'::jsonb,
    'contexto_del_juego',jsonb_build_object(
      'alineacion',v_lineup,'sede',v_venue,'altitud',v_altitude,'descanso',jsonb_build_object('local',v_home_rest,'visitante',v_away_rest),
      'lesiones',jsonb_build_object('local',coalesce(v_inj_home,'[]'::jsonb),'visitante',coalesce(v_inj_away,'[]'::jsonb)),
      'arbitro',v_referee,
      'clima_diagnostico_no_usado',v_weather)
  ));

  RETURN jsonb_build_object(
    '_analysis_contract',jsonb_build_object(
      'version','SOCCER_FULL_DATA_V1',
      'probability_contract','P_RETO_ONLY',
      'canonical_engine','MOTOR_B_PROVISIONAL',
      'model_status',coalesce(pr.model_status,'NO_MODEL'),
      'decision_time',v_decision,
      'generated_at',now(),
      'cross_sport_dependencies',0,
      'legacy_event_probability_sources',0),
    'partido',jsonb_build_object(
      'espn_event_id',v_event,'deporte','soccer','liga',ev.liga_nombre,
      'local',ev.home_nombre,'visitante',ev.away_nombre,'arranca_en',ev.fecha,
      'linea_principal',pr.linea_ou,'ronda',v_venue->>'ronda','sitio_neutral',(v_venue->>'sitio_neutral')::boolean),
    '1_el_resumen',v_summary,
    '2_como_llegan',jsonb_build_object(
      'local',jsonb_build_object('forma_asof',v_home_form,'de_local',v_home_profile),
      'visitante',jsonb_build_object('forma_asof',v_away_form,'de_visitante',v_away_profile),
      'ultimos_partidos_local',coalesce(v_last_home,'[]'::jsonb),
      'ultimos_partidos_visitante',coalesce(v_last_away,'[]'::jsonb)),
    '3_los_numeros_finos',jsonb_build_object(
      'local',jsonb_build_object('rating',v_rating_home,'tabla',v_standing_home,'metricas',v_fine_home),
      'visitante',jsonb_build_object('rating',v_rating_away,'tabla',v_standing_away,'metricas',v_fine_away),
      'nota_modelo','xG/tiros/posesión/corners/tarjetas están disponibles como contexto. Hoy no modifican P_RETO porque no están validados como mejora fuera de muestra.'),
    '4_frente_a_frente',coalesce(v_h2h,jsonb_build_object('n',0,'nota','sin H2H previo en la ventana')),
    '5_los_ultimos_partidos',jsonb_build_object('local',coalesce(v_last_home,'[]'::jsonb),'visitante',coalesce(v_last_away,'[]'::jsonb)),
    '6_lo_que_nadie_ve',jsonb_build_object(
      'sede',v_venue,'altitud',v_altitude,'alineacion',v_lineup,
      'lesionados_local',coalesce(v_inj_home,'[]'::jsonb),'lesionados_visitante',coalesce(v_inj_away,'[]'::jsonb),
      'jugadores_local',coalesce(v_players_home,'[]'::jsonb),'jugadores_visitante',coalesce(v_players_away,'[]'::jsonb),
      'descanso_local',v_home_rest,'descanso_visitante',v_away_rest,
      'arbitro',v_referee,
      'clima_no_temporalmente_auditable',v_weather),
    '7_el_precio',coalesce(v_odds,'{}'::jsonb),
    '8_tendencias',jsonb_build_object('local',v_trend_home,'visitante',v_trend_away,'confiabilidad_del_modelo',v_reliability),
    'coverage_manifest',v_manifest
  );
END;
$$;

-- Wrapper canónico: fútbol nuevo; MLB/NFL siguen temporalmente en core legacy hasta sus gates.
CREATE OR REPLACE FUNCTION public.analisis_completo(p_event text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_res jsonb; v_canon text; v_deporte text;
BEGIN
  v_res:=public.resolver_evento_canonico(p_event);
  v_canon:=v_res->>'espn_event_id';
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('error','partido no encontrado','reason_code',v_res->>'reason_code','id_recibido',p_event);
  END IF;
  SELECT a.deporte INTO v_deporte FROM public.agenda_espn a WHERE a.espn_event_id=v_canon;
  IF v_deporte='soccer' THEN
    RETURN public.analisis_futbol_reto_core(v_canon);
  END IF;
  RETURN public.analisis_completo_core(v_canon);
END;
$$;

-- Cache versionada: un payload viejo de soccer jamás cuenta como HIT del contrato nuevo.
CREATE OR REPLACE FUNCTION public.analisis_completo_cached(p_event text,p_ttl_min integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_res jsonb; v_canon text; v_deporte text; v_hit jsonb; v_gen timestamptz; v_fresh boolean;
BEGIN
  v_res:=public.resolver_evento_canonico(p_event);
  v_canon:=v_res->>'espn_event_id';
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('error','partido no encontrado','reason_code',v_res->>'reason_code','id_recibido',p_event);
  END IF;
  SELECT a.deporte INTO v_deporte FROM public.agenda_espn a WHERE a.espn_event_id=v_canon;

  SELECT payload,generado_at INTO v_hit,v_gen
  FROM public.analisis_core_cache WHERE espn_event_id=v_canon;

  v_fresh := v_hit IS NOT NULL AND v_gen>now()-make_interval(mins=>p_ttl_min)
    AND (v_deporte<>'soccer' OR v_hit#>>'{_analysis_contract,version}'='SOCCER_FULL_DATA_V1');
  IF v_fresh THEN
    RETURN v_hit||jsonb_build_object('_cache',jsonb_build_object('hit',true,'generado_at',v_gen));
  END IF;

  IF v_deporte='soccer' THEN
    v_hit:=public.analisis_futbol_reto_core(v_canon);
  ELSE
    v_hit:=public.analisis_completo_core(v_canon);
  END IF;
  IF v_hit?'error' THEN RETURN v_hit; END IF;

  INSERT INTO public.analisis_core_cache(espn_event_id,payload,generado_at)
  VALUES(v_canon,v_hit,now())
  ON CONFLICT(espn_event_id) DO UPDATE SET payload=excluded.payload,generado_at=now();

  RETURN v_hit||jsonb_build_object('_cache',jsonb_build_object('hit',false,'generado_at',now()));
END;
$$;

-- CIERRE / SMOKE SQL (ejecutar tras aplicar ISS-018..023 en transacción de cutover):
-- A) SELECT analisis_futbol_reto_core(event) para todos los soccer próximos 48h: no timeout.
-- B) coverage_manifest: todos los features tienen source + temporal_status; missing siempre razonado.
-- C) ninguna fila usada tiene as_of > decision_time.
-- D) _analysis_contract.legacy_event_probability_sources = 0.
-- E) grep/pg_get_functiondef(analisis_futbol_reto_core): no v_pick_canonico, no destacados,
--    no predecir_mlb, no pred_futbol_espn, no calcular EV.
-- F) resumen P_RETO = v_prediccion_reto_futbol exacta; O/U line exacta provider line.
-- G) cache miss/hit medido; objetivo normal P50<2s, P95<5s.
