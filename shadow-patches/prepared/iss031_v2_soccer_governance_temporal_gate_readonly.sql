-- ISS-031 — V2 SOCCER GOVERNANCE + FEATURE-ASOF GATE (READ ONLY)
-- Safety: SELECT-only. No DDL/DML/deploy/prod mutation.
-- Purpose: close false-positive V2 readiness where a bridge looks clean but
-- model governance, feature provenance, or historical market-derived rows are not.

-- 1) Registry must encode the rules that authorize P_RETO, not only an approval bit.
WITH required(col) AS (VALUES
  ('feature_version'),
  ('calibration_status'),
  ('calibration_version'),
  ('min_sample_total'),
  ('min_sample_home'),
  ('min_sample_away'),
  ('temporal_requirements'),
  ('allow_publish_preto'),
  ('status')
), present AS (
  SELECT column_name
  FROM information_schema.columns
  WHERE table_schema='v2' AND table_name='model_registry'
)
SELECT 'MODEL_REGISTRY_ENFORCEABLE' AS gate,
       count(*) AS required_columns,
       count(*) FILTER (WHERE p.column_name IS NULL) AS missing_columns,
       array_agg(r.col ORDER BY r.col) FILTER (WHERE p.column_name IS NULL) AS missing,
       count(*) FILTER (WHERE p.column_name IS NULL)=0 AS pass
FROM required r
LEFT JOIN present p ON p.column_name=r.col;

-- 2) Every enabled visible competition needs exact provider identity.
SELECT 'EVENT_PROVIDER_IDENTITY_VISIBLE' AS gate,
       count(*) AS visible_competitions,
       count(*) FILTER (WHERE provider_competition_id IS NULL) AS missing_provider_id,
       count(*) FILTER (WHERE provider_competition_id IS NULL)=0 AS pass
FROM v2.competition_catalog
WHERE sport='soccer'
  AND enabled
  AND (show_in_futpro OR show_in_favorites OR show_in_reto13m);

-- 3) Raw market-derived rows may exist only as market context and must not carry
-- RETO model identity / RETO probability payloads.
SELECT 'MARKET_ROWS_NOT_RETO_MODEL' AS gate,
       count(*) FILTER (WHERE provenance->>'engine' ILIKE '%market%') AS market_rows,
       count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND (p_home IS NOT NULL OR p_draw IS NOT NULL OR p_away IS NOT NULL)
       ) AS market_rows_with_probability,
       count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND (model_version ILIKE 'dc-%' OR feature_version ILIKE 'goal_rates%')
       ) AS market_rows_mislabeled_as_reto,
       (
         count(*) FILTER (
           WHERE provenance->>'engine' ILIKE '%market%'
             AND (p_home IS NOT NULL OR p_draw IS NOT NULL OR p_away IS NOT NULL)
         ) = 0
         AND count(*) FILTER (
           WHERE provenance->>'engine' ILIKE '%market%'
             AND (model_version ILIKE 'dc-%' OR feature_version ILIKE 'goal_rates%')
         ) = 0
       ) AS pass
FROM v2.soccer_prediction_v2;

-- 4) Builder must use event competition, registry, pregame-only universe and a
-- registry-driven evidence threshold; a literal >=8 is not governance.
WITH f AS (
  SELECT pg_get_functiondef(p.oid) AS d
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='v2' AND p.proname='build_soccer_prediction_v2'
  LIMIT 1
)
SELECT 'BUILDER_GOVERNANCE_STATIC' AS gate,
       position('gh.liga_id = u.liga_id' in d)>0 AS home_same_comp,
       position('ga.liga_id = u.liga_id' in d)>0 AS away_same_comp,
       position('model_registry' in d)>0 AS reads_registry,
       position('a.fecha > now()' in d)>0 AS pregame_only_builder,
       position('hpj>=8' in replace(lower(d),' ',''))=0
         AND position('apj>=8' in replace(lower(d),' ',''))=0 AS no_hardcoded_sample8,
       position('min_sample_' in d)>0 AS registry_sample_rule_used,
       (
         position('gh.liga_id = u.liga_id' in d)>0
         AND position('ga.liga_id = u.liga_id' in d)>0
         AND position('model_registry' in d)>0
         AND position('a.fecha > now()' in d)>0
         AND position('hpj>=8' in replace(lower(d),' ',''))=0
         AND position('apj>=8' in replace(lower(d),' ',''))=0
         AND position('min_sample_' in d)>0
       ) AS pass
FROM f;

-- 5) Goal-rate features must preserve auditable ingestion AS-OF. A match-date-only
-- aggregate is insufficient because it cannot prove what was known at prediction_time.
WITH v AS (
  SELECT pg_get_viewdef('public.v_goles_equipo_futbol'::regclass,true) AS d
)
SELECT 'MODEL_FEATURE_ASOF_CONTRACT' AS gate,
       position('cargado_at' in d)>0 AS tracks_ingestion_timestamp,
       position('data_asof' in d)>0 AS exposes_feature_asof,
       position('fecha' in d)>0 AS uses_event_date,
       (
         position('cargado_at' in d)>0
         AND position('data_asof' in d)>0
       ) AS pass
FROM v;

-- 6) Current snapshot population must remain pregame/temporally ordered.
SELECT 'SNAPSHOT_TEMPORAL_OBSERVED' AS gate,
       count(*) AS snapshots,
       count(*) FILTER (WHERE prediction_time >= kickoff) AS prediction_after_kickoff,
       count(*) FILTER (WHERE data_asof > prediction_time) AS data_after_prediction,
       count(*) FILTER (WHERE odds_captured_at > prediction_time) AS odds_after_prediction,
       count(*) FILTER (WHERE odds_captured_at > kickoff) AS odds_after_kickoff,
       (
         count(*) FILTER (WHERE prediction_time >= kickoff)=0
         AND count(*) FILTER (WHERE data_asof > prediction_time)=0
         AND count(*) FILTER (WHERE odds_captured_at > prediction_time)=0
         AND count(*) FILTER (WHERE odds_captured_at > kickoff)=0
       ) AS pass
FROM v2.soccer_prediction_v2;

-- 7) Public bridge cleanliness is necessary but not sufficient.
SELECT 'PUBLIC_BRIDGE_FAIL_CLOSED' AS gate,
       count(*) AS rows,
       count(*) FILTER (WHERE p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL) AS rows_with_preto,
       count(*) FILTER (
         WHERE (p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL)
           AND (model_status <> 'READY_UNVALIDATED' OR COALESCE(temporal_safe,false)=false)
       ) AS leaked_rows,
       count(*) FILTER (
         WHERE (p_reto_home IS NOT NULL OR p_reto_draw IS NOT NULL OR p_reto_away IS NOT NULL)
           AND (model_status <> 'READY_UNVALIDATED' OR COALESCE(temporal_safe,false)=false)
       )=0 AS pass
FROM public.v_futpro_v2;

SELECT now() AS audited_at,
       'RELEASE_GATE=HOLD' AS release_gate,
       'SOCCER_GATE=FAIL_UNTIL_GOVERNANCE_FEATURE_ASOF_FRONTEND_AND_VISUAL_GATES_PASS' AS soccer_gate;