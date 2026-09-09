-- ISS-030 — V2 SOCCER CLEAN GATE (READ ONLY)
-- Purpose: acceptance diagnostics for the clean V2 soccer vertical slice.
-- Safety: SELECT-only. No DDL/DML, no deploy, no production mutation.
-- Gate intent: fail closed until V2 source-control, cardinality, governance,
-- provenance, temporal safety, and competition identity are all auditable.

-- 1) One deterministic analysis row per canonical event.
WITH a AS (
  SELECT count(*) AS rows,
         count(DISTINCT canonical_event_id) AS events
  FROM public.v_analisis_v2
), d AS (
  SELECT count(*) AS duplicated_events
  FROM (
    SELECT canonical_event_id
    FROM public.v_analisis_v2
    GROUP BY 1
    HAVING count(*) > 1
  ) x
)
SELECT 'ANALYSIS_CARDINALITY' AS gate,
       a.rows,
       a.events,
       a.rows - a.events AS duplicate_rows,
       d.duplicated_events,
       (a.rows = a.events AND d.duplicated_events = 0) AS pass
FROM a CROSS JOIN d;

-- 2) Show concrete duplicate offenders instead of hiding them client-side.
SELECT canonical_event_id,
       count(*) AS rows
FROM public.v_analisis_v2
GROUP BY 1
HAVING count(*) > 1
ORDER BY rows DESC, canonical_event_id
LIMIT 50;

-- 3) Competition provider identity must be explicit for every enabled soccer competition.
SELECT 'EVENT_PROVIDER_IDENTITY' AS gate,
       count(*) FILTER (WHERE enabled) AS enabled_competitions,
       count(*) FILTER (WHERE enabled AND provider_competition_id IS NULL) AS missing_provider_ids,
       (count(*) FILTER (WHERE enabled AND provider_competition_id IS NULL) = 0) AS pass
FROM v2.competition_catalog
WHERE sport = 'soccer';

SELECT competition_id, canonical_name, provider, provider_competition_id,
       enabled, model_supported, show_in_futpro
FROM v2.competition_catalog
WHERE sport = 'soccer'
ORDER BY display_order NULLS LAST, canonical_name;

-- 4) model_supported may not claim support that is absent from the registry.
-- Current deployed registry is league-id keyed, so this checks the best available
-- deployed contract and must become stricter as the registry gains regime fields.
WITH supported AS (
  SELECT c.competition_id, c.canonical_name, c.provider_competition_id,
         c.model_supported
  FROM v2.competition_catalog c
  WHERE c.sport='soccer' AND c.enabled
), reg AS (
  SELECT DISTINCT liga_id
  FROM v2.model_registry
  WHERE sport='soccer' AND approved
)
SELECT 'COMPETITION_GOVERNANCE' AS gate,
       count(*) FILTER (WHERE s.model_supported) AS catalog_supported,
       count(*) FILTER (
         WHERE s.model_supported
           AND (s.provider_competition_id IS NULL OR NOT EXISTS (
             SELECT 1 FROM reg r
             WHERE r.liga_id::text = s.provider_competition_id
           ))
       ) AS unsupported_claims,
       (count(*) FILTER (
         WHERE s.model_supported
           AND (s.provider_competition_id IS NULL OR NOT EXISTS (
             SELECT 1 FROM reg r
             WHERE r.liga_id::text = s.provider_competition_id
           ))
       ) = 0) AS pass
FROM supported s;

-- 5) Registry contract completeness required by the product constitution.
-- Missing columns are a hard governance gap; this is schema introspection only.
WITH req(col) AS (VALUES
 ('feature_version'),('calibration_status'),('calibration_version'),
 ('min_sample_total'),('min_sample_home'),('min_sample_away'),
 ('temporal_requirements'),('allow_publish_preto'),('status')
), present AS (
 SELECT column_name
 FROM information_schema.columns
 WHERE table_schema='v2' AND table_name='model_registry'
)
SELECT 'MODEL_REGISTRY_CONTRACT' AS gate,
       count(*) AS required_columns,
       count(*) FILTER (WHERE p.column_name IS NULL) AS missing_columns,
       array_agg(r.col ORDER BY r.col) FILTER (WHERE p.column_name IS NULL) AS missing,
       (count(*) FILTER (WHERE p.column_name IS NULL)=0) AS pass
FROM req r LEFT JOIN present p ON p.column_name=r.col;

-- 6) Market-derived rows must never be publishable as RETO P.
SELECT 'MARKET_AS_P_RETO_PATHS' AS gate,
       count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND (p_home IS NOT NULL OR p_draw IS NOT NULL OR p_away IS NOT NULL)
       ) AS market_rows_with_probability,
       count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND model_status IN ('READY_UNVALIDATED','READY','PUBLISHABLE')
       ) AS market_rows_publishable_status,
       (count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND model_status IN ('READY_UNVALIDATED','READY','PUBLISHABLE')
       ) = 0) AS pass
FROM v2.soccer_prediction_v2;

-- 7) Public bridge must not expose P_RETO from a non-ready/unsafe row.
SELECT 'PUBLIC_BRIDGE_PROVENANCE_TEMPORAL' AS gate,
       count(*) AS rows,
       count(*) FILTER (WHERE p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL) AS rows_with_p_reto,
       count(*) FILTER (
         WHERE (p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL)
           AND COALESCE(temporal_safe,false) = false
       ) AS temporal_leaks,
       count(*) FILTER (
         WHERE (p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL)
           AND model_status <> 'READY_UNVALIDATED'
       ) AS status_leaks,
       count(*) FILTER (
         WHERE (p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL)
           AND prediction_time >= kickoff
       ) AS post_kickoff_prediction_leaks,
       (count(*) FILTER (
         WHERE (p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL)
           AND (COALESCE(temporal_safe,false)=false OR model_status <> 'READY_UNVALIDATED' OR prediction_time >= kickoff)
       ) = 0) AS pass
FROM public.v_futpro_v2;

-- 8) The deployed bridge must enforce model registry / provider identity by definition.
WITH defs AS (
 SELECT pg_get_viewdef('public.v_futpro_v2'::regclass,true) AS d
)
SELECT 'BRIDGE_ENFORCEMENT_STATIC' AS gate,
       position('model_registry' in d) > 0 AS references_model_registry,
       position('provider_competition_id' in d) > 0 AS references_provider_competition_id,
       position('now() - ''03:00:00''::interval' in d) = 0 AS no_postkickoff_window_pattern,
       (
         position('model_registry' in d) > 0
         AND position('provider_competition_id' in d) > 0
         AND position('now() - ''03:00:00''::interval' in d) = 0
       ) AS pass
FROM defs;

-- 9) Analysis source must not claim temporal safety without an auditable timestamp.
-- Current view text is inspected because several factual sources do not expose as_of.
WITH defs AS (
 SELECT pg_get_viewdef('public.v_analisis_v2'::regclass,true) AS d
)
SELECT 'ANALYSIS_TEMPORAL_CONTRACT_STATIC' AS gate,
       position('''temporal_safe'', true' in d) = 0 AS no_unconditional_temporal_true,
       position('data_asof' in d) > 0 AS exposes_data_asof,
       position('freshness' in d) > 0 AS exposes_freshness,
       position('missing_reason' in d) > 0 AS exposes_missing_reason,
       (
         position('''temporal_safe'', true' in d) = 0
         AND position('data_asof' in d) > 0
         AND position('freshness' in d) > 0
         AND position('missing_reason' in d) > 0
       ) AS pass
FROM defs;

-- 10) Final compact status. This deliberately does not declare SOCCER closed;
-- visual exact-SHA sync, frontend denylist, cross-screen equality and smoke remain external gates.
SELECT now() AS audited_at,
       'RELEASE_GATE=HOLD' AS release_gate,
       'SOCCER_GATE=FAIL_UNTIL_ALL_GATES_ZERO_AND_VISUAL_SMOKE_PASS' AS soccer_gate;
