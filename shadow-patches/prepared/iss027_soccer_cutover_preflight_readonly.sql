-- ISS-027 — SOCCER CUTOVER PREFLIGHT (READ-ONLY, CURRENT PROD SAFE)
-- Purpose: quantify the gap between the currently deployed soccer contract and the
-- staged full-data contract BEFORE any cutover. This file contains SELECTs only.
-- It deliberately does NOT reference staged-only columns directly in data queries.
-- RELEASE_GATE remains HOLD until the post-staged gates (ISS-024/026) and browser
-- smoke pass.

-- A) Current active universe vs currently deployed matrix.
WITH ev AS (
  SELECT a.espn_event_id,a.fecha,a.liga_nombre,a.home_nombre,a.away_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now()
    AND a.fecha<now()+interval '48 hours'
)
SELECT
  count(*) AS event_universe,
  count(p.canonical_event_id) AS matrix_rows,
  count(*) FILTER (WHERE p.canonical_event_id IS NULL) AS missing_matrix_rows,
  count(*) FILTER (WHERE p.p_local_gana IS NOT NULL) AS rows_with_p_reto,
  count(*) FILTER (WHERE p.linea_ou IS NOT NULL) AS rows_with_published_total_line
FROM ev
LEFT JOIN public.v_prediccion_reto_futbol p
  ON p.canonical_event_id=ev.espn_event_id;
-- PRE-CUTOVER expectation today may fail. CUTOVER may not be called ready unless
-- missing_matrix_rows=0 after ISS-018 is applied in the coordinated gate.

-- B) Exact events currently disappearing from the canonical matrix.
SELECT a.espn_event_id,a.fecha,a.liga_nombre,a.home_nombre,a.away_nombre
FROM public.agenda_espn a
LEFT JOIN public.v_prediccion_reto_futbol p
  ON p.canonical_event_id=a.espn_event_id
WHERE a.deporte='soccer'
  AND a.espn_event_id IS NOT NULL
  AND a.fecha>=now()
  AND a.fecha<now()+interval '48 hours'
  AND p.canonical_event_id IS NULL
ORDER BY a.fecha,a.espn_event_id;
-- These events MUST become explicit NO_MODEL / other fail-closed rows after cutover;
-- they may not silently disappear and may not borrow a parallel probability.

-- C) Schema-contract delta. All required columns must exist after staged cutover.
WITH required(column_name) AS (
  VALUES
    ('canonical_event_id'),('scheduled_at'),
    ('p_local_gana'),('p_empate'),('p_visita_gana'),
    ('p_btts_yes'),('p_btts_no'),('linea_ou'),('p_over'),('p_under'),
    ('prob_source'),('model_status'),('model_sample'),('min_sample_required'),
    ('model_generated_at'),('data_asof'),('temporal_safe'),
    ('provider_total_line_raw'),('provider_name'),('provider_line_asof'),
    ('unavailable_reason')
), actual AS (
  SELECT c.column_name
  FROM information_schema.columns c
  WHERE c.table_schema='public' AND c.table_name='v_prediccion_reto_futbol'
)
SELECT r.column_name AS missing_required_column
FROM required r
LEFT JOIN actual a USING(column_name)
WHERE a.column_name IS NULL
ORDER BY r.column_name;
-- PASS after staged cutover: 0 rows.

-- D) Required canonical functions. False means staged work is not deployed yet.
SELECT
  to_regprocedure('public.analisis_futbol_reto_core(text)') IS NOT NULL AS analysis_core_exists,
  to_regprocedure('public.resolver_p_reto_futbol(text,text,text,numeric)') IS NOT NULL AS resolver_exists,
  to_regprocedure('public.prob_total_dixon_coles_linea(numeric,numeric,numeric,integer)') IS NOT NULL AS real_line_total_function_exists;
-- PASS after staged cutover: all TRUE.

-- E) Legacy primary-analysis dependency inventory (read-only evidence only).
-- We intentionally inspect the deployed legacy analysis function without invoking it.
SELECT
  p.oid::regprocedure::text AS deployed_function,
  position('v_pick_canonico' in pg_get_functiondef(p.oid))>0 AS has_v_pick_canonico,
  position('pred_futbol_espn' in pg_get_functiondef(p.oid))>0 AS has_parallel_soccer_probability,
  position('predecir_mlb' in pg_get_functiondef(p.oid))>0 AS has_mlb_dependency,
  position('nfl_' in pg_get_functiondef(p.oid))>0 AS has_nfl_dependency,
  position('calcular_ev' in pg_get_functiondef(p.oid))>0 AS has_economic_ev_dependency
FROM pg_proc p
JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND p.proname IN ('analisis_completo_core','analisis_completo');
-- Informational pre-cutover. Post-cutover soccer primary analysis is validated against
-- analisis_futbol_reto_core(text) by ISS-024 and must have all forbidden deps FALSE.

-- F) Gate summary: intentionally conservative. READY_FOR_STAGED_VALIDATION can only
-- become true when the deployed contract already exposes every required primitive;
-- it is NOT a release approval and does not replace ISS-024/026 or visual smoke.
WITH required(column_name) AS (
  VALUES
    ('model_sample'),('min_sample_required'),('model_generated_at'),('data_asof'),
    ('temporal_safe'),('provider_total_line_raw'),('provider_name'),
    ('provider_line_asof'),('unavailable_reason')
), missing AS (
  SELECT count(*) AS n
  FROM required r
  LEFT JOIN information_schema.columns c
    ON c.table_schema='public'
   AND c.table_name='v_prediccion_reto_futbol'
   AND c.column_name=r.column_name
  WHERE c.column_name IS NULL
), coverage AS (
  SELECT count(*) FILTER (WHERE p.canonical_event_id IS NULL) AS missing_rows
  FROM public.agenda_espn a
  LEFT JOIN public.v_prediccion_reto_futbol p ON p.canonical_event_id=a.espn_event_id
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now()
    AND a.fecha<now()+interval '48 hours'
)
SELECT
  (missing.n=0
   AND coverage.missing_rows=0
   AND to_regprocedure('public.analisis_futbol_reto_core(text)') IS NOT NULL
   AND to_regprocedure('public.resolver_p_reto_futbol(text,text,text,numeric)') IS NOT NULL
  ) AS ready_for_staged_validation,
  missing.n AS missing_contract_columns,
  coverage.missing_rows AS missing_matrix_rows
FROM missing CROSS JOIN coverage;
-- This must be TRUE before attempting to interpret post-cutover acceptance output.
-- RELEASE_GATE remains HOLD until ALL downstream machine + exact-SHA + authenticated
-- visual smoke gates pass.