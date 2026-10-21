-- ISS-021 — SOCCER FULL-DATA CLOSURE GATE (READ-ONLY)
-- Branch-only diagnostic artifact. NO DDL, NO DML, NO production mutation.
-- North star: ¿Qué cree Reto que va a pasar y con qué probabilidad?
-- Canonical event probability must be P_RETO from provisional Motor B only.
-- Every contextual source must satisfy data_asof <= decision_time.
-- CONTEXT_ONLY / AVAILABLE_NOT_USED data may appear in dossier/manifest but must not alter P_RETO.

-- -----------------------------------------------------------------------------
-- G0 — UPCOMING SOCCER UNIVERSE (48h) + canonical Motor-B availability
-- -----------------------------------------------------------------------------
WITH universe AS (
  SELECT a.espn_event_id,
         a.fecha AS decision_time,
         a.home_nombre,
         a.away_nombre,
         a.liga_nombre
  FROM public.agenda_espn a
  WHERE a.deporte = 'soccer'
    AND a.fecha >= now()
    AND a.fecha < now() + interval '48 hours'
),
b AS (
  SELECT lp.espn_event_id,
         fp.generado_at AS p_reto_asof,
         fp.muestra,
         fp.lam_h,
         fp.lam_a,
         fp.mercados
  FROM public.fut_predicciones fp
  JOIN public.ligamx_partidos lp ON lp.id = fp.fixture_id
)
SELECT u.*,
       (b.espn_event_id IS NOT NULL) AS motor_b_present,
       b.p_reto_asof,
       (b.p_reto_asof IS NULL OR b.p_reto_asof <= u.decision_time) AS motor_b_temporal_safe,
       b.muestra,
       b.lam_h,
       b.lam_a
FROM universe u
LEFT JOIN b USING (espn_event_id)
ORDER BY u.decision_time, u.espn_event_id;

-- -----------------------------------------------------------------------------
-- G1 — REAL PROVIDER TOTAL LINE. Never fabricate 2.5 and never use post-kickoff data.
-- Chooses the same policy as ISS-018: pregame/non-live, DraftKings preferred,
-- otherwise latest non-live observation available before decision_time.
-- -----------------------------------------------------------------------------
WITH universe AS (
  SELECT a.espn_event_id, a.fecha AS decision_time
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.fecha >= now()
    AND a.fecha < now() + interval '48 hours'
), chosen AS (
  SELECT DISTINCT ON (u.espn_event_id)
         u.espn_event_id,
         u.decision_time,
         oe.total_linea,
         oe.proveedor,
         oe.capturado_at AS line_asof
  FROM universe u
  LEFT JOIN public.odds_espn oe
    ON oe.espn_event_id=u.espn_event_id
   AND oe.total_linea IS NOT NULL
   AND oe.capturado_at <= u.decision_time
   AND COALESCE(oe.proveedor,'') NOT ILIKE '%Live%'
  ORDER BY u.espn_event_id,
           CASE WHEN oe.proveedor='DraftKings' THEN 0 ELSE 1 END,
           oe.capturado_at DESC NULLS LAST
)
SELECT *,
       (line_asof IS NULL OR line_asof <= decision_time) AS temporal_safe,
       CASE WHEN total_linea IS NULL THEN 'MISSING_REAL_LINE_FAIL_CLOSED'
            ELSE 'REAL_PROVIDER_LINE' END AS line_status
FROM chosen
ORDER BY decision_time, espn_event_id;

-- -----------------------------------------------------------------------------
-- G2 — FULL PREMATCH DOSSIER SOURCE MANIFEST.
-- One row per event/source with provenance, role, as_of, freshness, temporal safety,
-- and explicit missing reason. MODEL_ACTIVE is deliberately restricted to Motor B.
-- -----------------------------------------------------------------------------
WITH universe AS (
  SELECT a.espn_event_id,
         a.fecha AS decision_time,
         a.home_nombre,
         a.away_nombre,
         a.liga_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.fecha >= now()
    AND a.fecha < now() + interval '48 hours'
),
b AS (
  SELECT lp.espn_event_id,
         fp.generado_at AS as_of
  FROM public.fut_predicciones fp
  JOIN public.ligamx_partidos lp ON lp.id=fp.fixture_id
),
linea AS (
  SELECT DISTINCT ON (u.espn_event_id)
         u.espn_event_id,
         oe.capturado_at AS as_of
  FROM universe u
  LEFT JOIN public.odds_espn oe
    ON oe.espn_event_id=u.espn_event_id
   AND oe.total_linea IS NOT NULL
   AND oe.capturado_at <= u.decision_time
   AND COALESCE(oe.proveedor,'') NOT ILIKE '%Live%'
  ORDER BY u.espn_event_id,
           CASE WHEN oe.proveedor='DraftKings' THEN 0 ELSE 1 END,
           oe.capturado_at DESC NULLS LAST
),
alineacion AS (
  SELECT DISTINCT ON (a.espn_event_id)
         a.espn_event_id,
         a.capturado_at AS as_of,
         a.hay_alineacion
  FROM public.alineaciones_espn a
  JOIN universe u USING (espn_event_id)
  WHERE a.capturado_at <= u.decision_time
  ORDER BY a.espn_event_id, a.capturado_at DESC
),
sede AS (
  SELECT ps.espn_event_id, ps.capturado_at AS as_of
  FROM public.partido_sede ps
  JOIN universe u USING (espn_event_id)
  WHERE ps.capturado_at <= u.decision_time
),
arbitro AS (
  SELECT DISTINCT ON (fa.espn_event_id)
         fa.espn_event_id,
         fa.cargado_at AS as_of,
         fa.arbitro
  FROM public.futbol_arbitro_partido fa
  JOIN universe u USING (espn_event_id)
  WHERE fa.cargado_at <= u.decision_time
  ORDER BY fa.espn_event_id, fa.cargado_at DESC
),
rows AS (
  SELECT u.espn_event_id,u.decision_time,'P_RETO_MOTOR_B'::text source,
         'fut_predicciones via ligamx_partidos'::text provenance,
         'MODEL_ACTIVE'::text role,b.as_of,
         CASE WHEN b.as_of IS NULL THEN 'NO_MOTOR_B_ROW' END missing_reason
  FROM universe u LEFT JOIN b USING (espn_event_id)
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'TOTAL_LINE','odds_espn','MODEL_INPUT_THRESHOLD',l.as_of,
         CASE WHEN l.as_of IS NULL THEN 'NO_REAL_PROVIDER_TOTAL_LINE' END
  FROM universe u LEFT JOIN linea l USING (espn_event_id)
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'LINEUP','alineaciones_espn','CONTEXT_ONLY',a.as_of,
         CASE WHEN a.as_of IS NULL THEN 'NO_PREGAME_LINEUP_CAPTURE'
              WHEN a.hay_alineacion IS NOT TRUE THEN 'LINEUP_NOT_PUBLISHED' END
  FROM universe u LEFT JOIN alineacion a USING (espn_event_id)
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'VENUE','partido_sede','CONTEXT_ONLY',s.as_of,
         CASE WHEN s.as_of IS NULL THEN 'NO_VENUE_CAPTURE' END
  FROM universe u LEFT JOIN sede s USING (espn_event_id)
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'REFEREE','futbol_arbitro_partido','AVAILABLE_NOT_USED',r.as_of,
         CASE WHEN r.as_of IS NULL OR r.arbitro IS NULL THEN 'NO_REFEREE_DATA' END
  FROM universe u LEFT JOIN arbitro r USING (espn_event_id)
)
SELECT r.*,
       (r.as_of IS NULL OR r.as_of <= r.decision_time) AS temporal_safe,
       CASE
         WHEN r.as_of IS NULL THEN NULL
         ELSE round(extract(epoch FROM (r.decision_time-r.as_of))/60.0,1)
       END AS age_minutes_at_decision
FROM rows r
ORDER BY r.decision_time,r.espn_event_id,r.source;

-- Hard failure: any populated source from the manifest that violates the as-of gate.
WITH universe AS (
  SELECT a.espn_event_id,a.fecha AS decision_time
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.fecha>=now() AND a.fecha<now()+interval '48 hours'
), checks AS (
  SELECT u.espn_event_id,u.decision_time,'fut_predicciones' source,fp.generado_at as_of
  FROM universe u
  JOIN public.ligamx_partidos lp ON lp.espn_event_id=u.espn_event_id
  JOIN public.fut_predicciones fp ON fp.fixture_id=lp.id
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'odds_espn',oe.capturado_at
  FROM universe u JOIN public.odds_espn oe USING (espn_event_id)
  WHERE oe.capturado_at IS NOT NULL
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'alineaciones_espn',a.capturado_at
  FROM universe u JOIN public.alineaciones_espn a USING (espn_event_id)
  WHERE a.capturado_at IS NOT NULL
  UNION ALL
  SELECT u.espn_event_id,u.decision_time,'partido_sede',ps.capturado_at
  FROM universe u JOIN public.partido_sede ps USING (espn_event_id)
  WHERE ps.capturado_at IS NOT NULL
)
SELECT * FROM checks WHERE as_of > decision_time ORDER BY espn_event_id,source,as_of;
-- Acceptance: ZERO ROWS after each source's decision-safe selection is applied.

-- -----------------------------------------------------------------------------
-- G3 — PRIMARY ANALYSIS FUNCTION STATIC DEPENDENCY CHECK.
-- Soccer primary analysis must not traverse MLB/NFL/cross-sport probability sources,
-- nor legacy soccer probability authorities that can contradict P_RETO.
-- -----------------------------------------------------------------------------
WITH defs AS (
  SELECT p.proname,
         pg_get_functiondef(p.oid) AS definition
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN ('analisis_completo','analisis_completo_cached','analisis_completo_core')
), forbidden(term) AS (
  VALUES
    ('predecir_mlb'),('pred_futbol_espn'),('v_pick_canonico'),('reto_picks_hoy'),
    ('nfl_picks_premium'),('v_prediccion_reto_mlb'),('v_prediccion_reto_nfl')
)
SELECT d.proname,f.term
FROM defs d CROSS JOIN forbidden f
WHERE d.definition ILIKE '%'||f.term||'%'
ORDER BY d.proname,f.term;
-- Acceptance for the SOCCER primary path: ZERO relevant forbidden dependencies.

-- -----------------------------------------------------------------------------
-- G4 — CANONICAL VIEW CONTRACT (after coordinated cutover only).
-- This query is intentionally safe before cutover too; it reports current state.
-- -----------------------------------------------------------------------------
SELECT table_name,column_name
FROM information_schema.columns
WHERE table_schema='public'
  AND table_name='v_prediccion_reto_futbol'
  AND column_name IN (
    'canonical_event_id','sport','home_nombre','away_nombre','scheduled_at',
    'p_local_gana','p_empate','p_visita_gana','p_btts_yes','p_btts_no',
    'linea_ou','p_over','p_under','prob_source','model_status','reto_score'
  )
ORDER BY column_name;

-- After cutover, run:
--   SELECT * FROM public.v_prediccion_reto_futbol
--   WHERE scheduled_at>=now() AND scheduled_at<now()+interval '48 hours';
-- and verify:
--   1X2 sums ~100; BTTS sums ~100 when available; O/U sums ~100 on half-lines;
--   prob_source = fut_predicciones_dixon_coles_b_provisional;
--   model_status = UNVALIDATED;
--   linea_ou equals G1 chosen provider line;
--   no odds/no-vig/EV field contributes to P_RETO.

-- -----------------------------------------------------------------------------
-- G5 — MACHINE-READABLE FINAL SUMMARY COUNTS
-- -----------------------------------------------------------------------------
WITH universe AS (
  SELECT a.espn_event_id,a.fecha AS decision_time
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.fecha>=now() AND a.fecha<now()+interval '48 hours'
), b AS (
  SELECT DISTINCT lp.espn_event_id
  FROM public.fut_predicciones fp
  JOIN public.ligamx_partidos lp ON lp.id=fp.fixture_id
  JOIN universe u ON u.espn_event_id=lp.espn_event_id
  WHERE fp.generado_at <= u.decision_time
), lines AS (
  SELECT DISTINCT u.espn_event_id
  FROM universe u JOIN public.odds_espn oe USING(espn_event_id)
  WHERE oe.total_linea IS NOT NULL
    AND oe.capturado_at <= u.decision_time
    AND COALESCE(oe.proveedor,'') NOT ILIKE '%Live%'
)
SELECT
  count(*) AS upcoming_soccer_events,
  count(*) FILTER (WHERE b.espn_event_id IS NOT NULL) AS with_temporal_safe_motor_b,
  count(*) FILTER (WHERE lines.espn_event_id IS NOT NULL) AS with_real_provider_total_line
FROM universe u
LEFT JOIN b USING(espn_event_id)
LEFT JOIN lines USING(espn_event_id);

-- RELEASE_GATE remains HOLD until frontend canonical wiring, predictive-source audit,
-- tests/typecheck/build, real-data coverage, cross-screen equality, exact-SHA Lovable
-- preview sync and browser visual smoke all independently pass.
