-- ISS-028 — SOCCER STRICT TEMPORAL-SOURCE ACCEPTANCE GATE (READ-ONLY)
-- *** STAGED / VALIDATION ONLY — NO PROD DDL, NO DATA MUTATION ***
--
-- Purpose: close a subtle gap in the full-data dossier contract. Merely labelling a
-- source AVAILABLE_NOT_USED is not sufficient if the analysis function still invokes a
-- current/non-versioned source whose as_of cannot be proven <= decision_time. The P0
-- contract is stronger: every source touched by the prematch dossier must either be
-- (a) STATIC, or (b) carry an auditable as_of <= decision_time. Unknown-current data is
-- inventoried as unavailable with a missing_reason; it is not fetched into the dossier.
--
-- Run only AFTER ISS-018..026 have been applied to a coordinated preview/validation
-- environment. This script is SELECT-only and cannot approve RELEASE_GATE by itself.

-- 1) Required soccer core exists; legacy/cross-sport/economic authorities are absent.
WITH f AS (
  SELECT p.oid, pg_get_functiondef(p.oid) AS def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='analisis_futbol_reto_core'
)
SELECT
  count(*)=1 AS analysis_core_exists_once,
  coalesce(bool_and(position('v_pick_canonico' in def)=0),false) AS no_v_pick_canonico,
  coalesce(bool_and(position('pred_futbol_espn' in def)=0),false) AS no_parallel_soccer_probability,
  coalesce(bool_and(position('predecir_mlb' in def)=0),false) AS no_mlb_dependency,
  coalesce(bool_and(position('nfl_' in def)=0),false) AS no_nfl_dependency,
  coalesce(bool_and(position('calcular_ev' in def)=0),false) AS no_ev_dependency,
  -- Current weather lacks a captured_at snapshot in the present schema. Until that
  -- source is versioned, the core must NOT invoke it. The manifest may mention the
  -- source with available=false + missing_reason.
  coalesce(bool_and(position('clima_partido_futbol(' in def)=0),false) AS no_unauditable_current_weather_call
FROM f;
-- PASS: all TRUE.

-- 2) Evaluate the real upcoming soccer universe. Every event must return a dossier;
-- missing model is a valid fail-closed state, missing dossier is not.
WITH ev AS (
  SELECT a.espn_event_id
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now()
    AND a.fecha<now()+interval '48 hours'
), payload AS (
  SELECT e.espn_event_id, public.analisis_futbol_reto_core(e.espn_event_id) AS j
  FROM ev e
)
SELECT
  count(*) AS event_universe,
  count(*) FILTER (WHERE j IS NULL OR j ? 'error') AS dossier_errors,
  count(*) FILTER (WHERE NOT (j ? 'coverage_manifest')) AS missing_manifest,
  count(*) FILTER (WHERE NOT (j ? 'resumen')) AS missing_summary
FROM payload;
-- PASS: dossier_errors=0, missing_manifest=0, missing_summary=0.

-- 3) Manifest schema: provenance, role, temporal status and missing reason are explicit.
WITH ev AS (
  SELECT a.espn_event_id
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now() AND a.fecha<now()+interval '48 hours'
), items AS (
  SELECT e.espn_event_id, item
  FROM ev e
  CROSS JOIN LATERAL jsonb_array_elements(
    coalesce(public.analisis_futbol_reto_core(e.espn_event_id)->'coverage_manifest','[]'::jsonb)
  ) item
)
SELECT
  count(*) AS manifest_items,
  count(*) FILTER (WHERE nullif(item->>'feature','') IS NULL) AS missing_feature,
  count(*) FILTER (WHERE nullif(item->>'provenance','') IS NULL) AS missing_provenance,
  count(*) FILTER (WHERE item->>'role' NOT IN ('MODEL_ACTIVE','CONTEXT_ONLY','AVAILABLE_NOT_USED')) AS invalid_role,
  count(*) FILTER (WHERE nullif(item->>'temporal_status','') IS NULL) AS missing_temporal_status,
  count(*) FILTER (
    WHERE coalesce((item->>'available')::boolean,false)=false
      AND nullif(item->>'missing_reason','') IS NULL
  ) AS unavailable_without_reason
FROM items;
-- PASS: all violation counts = 0.

-- 4) Absolute temporal invariant: every AVAILABLE non-static source has a real as_of,
-- it is not in the future relative to decision_time, and helper-derived temporal_safe
-- agrees. AVAILABLE_NOT_USED does NOT exempt a source from this rule.
WITH ev AS (
  SELECT a.espn_event_id
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now() AND a.fecha<now()+interval '48 hours'
), items AS (
  SELECT e.espn_event_id, item
  FROM ev e
  CROSS JOIN LATERAL jsonb_array_elements(
    coalesce(public.analisis_futbol_reto_core(e.espn_event_id)->'coverage_manifest','[]'::jsonb)
  ) item
), checked AS (
  SELECT *,
    CASE WHEN nullif(item->>'as_of','') IS NOT NULL THEN (item->>'as_of')::timestamptz END AS as_of_ts,
    CASE WHEN nullif(item->>'decision_time','') IS NOT NULL THEN (item->>'decision_time')::timestamptz END AS decision_ts
  FROM items
)
SELECT
  count(*) FILTER (
    WHERE coalesce((item->>'available')::boolean,false)=true
      AND item->>'temporal_status'<>'STATIC'
      AND as_of_ts IS NULL
  ) AS available_without_asof,
  count(*) FILTER (
    WHERE coalesce((item->>'available')::boolean,false)=true
      AND item->>'temporal_status'<>'STATIC'
      AND decision_ts IS NULL
  ) AS available_without_decision_time,
  count(*) FILTER (
    WHERE coalesce((item->>'available')::boolean,false)=true
      AND item->>'temporal_status'<>'STATIC'
      AND as_of_ts IS NOT NULL AND decision_ts IS NOT NULL
      AND as_of_ts>decision_ts
  ) AS future_data_violations,
  count(*) FILTER (
    WHERE coalesce((item->>'available')::boolean,false)=true
      AND coalesce((item->>'temporal_safe')::boolean,false)=false
  ) AS available_but_not_temporal_safe,
  count(*) FILTER (
    WHERE item->>'temporal_status'='SAFE_CURRENT'
  ) AS safe_current_shortcuts
FROM checked;
-- PASS: all 0.

-- 5) Only MODEL_ACTIVE may be marked used_in_model; contextual sources may never alter
-- P_RETO through the dossier. Canonical prediction is the sole MODEL_ACTIVE feature.
WITH ev AS (
  SELECT a.espn_event_id
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now() AND a.fecha<now()+interval '48 hours'
), items AS (
  SELECT e.espn_event_id, item
  FROM ev e
  CROSS JOIN LATERAL jsonb_array_elements(
    coalesce(public.analisis_futbol_reto_core(e.espn_event_id)->'coverage_manifest','[]'::jsonb)
  ) item
)
SELECT
  count(*) FILTER (
    WHERE coalesce((item->>'used_in_model')::boolean,false)=true
      AND item->>'role'<>'MODEL_ACTIVE'
  ) AS non_model_active_used_in_model,
  count(*) FILTER (
    WHERE item->>'role'='MODEL_ACTIVE'
      AND item->>'feature'<>'canonical_prediction'
  ) AS competing_model_active_features,
  count(*) FILTER (
    WHERE item->>'feature'='canonical_prediction'
      AND item->>'role'<>'MODEL_ACTIVE'
  ) AS canonical_prediction_wrong_role
FROM items;
-- PASS: all 0.

-- 6) Canonical P_RETO equality: analysis summary must equal the matrix exactly for every
-- event with a model. NO_MODEL/INSUFFICIENT/etc must remain NULL, never borrow another P.
WITH ev AS (
  SELECT a.espn_event_id
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now() AND a.fecha<now()+interval '48 hours'
), x AS (
  SELECT e.espn_event_id,
         p.model_status,
         p.p_local_gana,p.p_empate,p.p_visita_gana,p.p_btts_yes,p.p_btts_no,p.linea_ou,p.p_over,p.p_under,
         public.analisis_futbol_reto_core(e.espn_event_id)->'resumen'->'p_reto' AS a
  FROM ev e
  LEFT JOIN public.v_prediccion_reto_futbol p ON p.canonical_event_id=e.espn_event_id
)
SELECT
  count(*) FILTER (
    WHERE model_status='UNVALIDATED' AND (
      (a->>'p_local_gana')::numeric IS DISTINCT FROM p_local_gana OR
      (a->>'p_empate')::numeric IS DISTINCT FROM p_empate OR
      (a->>'p_visita_gana')::numeric IS DISTINCT FROM p_visita_gana OR
      (a->>'p_btts_yes')::numeric IS DISTINCT FROM p_btts_yes OR
      (a->>'p_btts_no')::numeric IS DISTINCT FROM p_btts_no OR
      (a->>'linea_ou')::numeric IS DISTINCT FROM linea_ou OR
      (a->>'p_over')::numeric IS DISTINCT FROM p_over OR
      (a->>'p_under')::numeric IS DISTINCT FROM p_under
    )
  ) AS canonical_probability_mismatches,
  count(*) FILTER (
    WHERE coalesce(model_status,'NO_MODEL')<>'UNVALIDATED' AND a IS NOT NULL
  ) AS failclosed_rows_exposing_probability
FROM x;
-- PASS: both 0.

-- RELEASE_GATE remains HOLD until ISS-024 + ISS-026 + this gate + frontend predictive
-- source audit + cross-screen equality + tests/typecheck/build + Lovable exact-SHA sync
-- + authenticated visual smoke all pass on the coordinated candidate.
