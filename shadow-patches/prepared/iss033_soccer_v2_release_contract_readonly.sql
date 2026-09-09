-- ISS-033 — SOCCER V2 RELEASE CONTRACT GATE (READ ONLY)
-- Safety: SELECT-only. No DDL/DML/deploy/prod mutation.
-- Purpose: catch the remaining false-positive closure modes discovered in the
-- 2026-09-09 audit: disappearing agenda events, weak snapshot selection,
-- non-enforceable registry governance, unauditable feature AS-OF, market-derived
-- rows masquerading as RETO model output, and provider-identity gaps.

-- GATE 1 — THE CANONICAL UNIVERSE MAY NEVER DISAPPEAR EVENTS.
-- Every upcoming soccer event must be represented by the public V2 bridge even
-- when competition mapping is absent/disabled or the model has no P_RETO.
WITH u AS (
  SELECT DISTINCT a.espn_event_id, a.fecha, a.home_nombre, a.away_nombre, a.liga_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha >= now()
    AND a.fecha < now() + interval '48 hours'
), b AS (
  SELECT DISTINCT canonical_event_id
  FROM public.v_futpro_v2
  WHERE kickoff >= now()
    AND kickoff < now() + interval '48 hours'
)
SELECT 'V2_UNIVERSE_PRESERVED' AS gate,
       (SELECT count(*) FROM u) AS agenda_events,
       (SELECT count(*) FROM b) AS bridge_events,
       (SELECT count(*) FROM u LEFT JOIN b ON b.canonical_event_id=u.espn_event_id
         WHERE b.canonical_event_id IS NULL) AS missing_events,
       (SELECT count(*) FROM u LEFT JOIN b ON b.canonical_event_id=u.espn_event_id
         WHERE b.canonical_event_id IS NULL)=0 AS pass;

-- Diagnostic detail for GATE 1.
WITH u AS (
  SELECT DISTINCT a.espn_event_id, a.fecha, a.home_nombre, a.away_nombre, a.liga_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha >= now()
    AND a.fecha < now() + interval '48 hours'
), b AS (
  SELECT DISTINCT canonical_event_id
  FROM public.v_futpro_v2
  WHERE kickoff >= now()
    AND kickoff < now() + interval '48 hours'
)
SELECT 'V2_MISSING_EVENT_DETAIL' AS gate,
       u.espn_event_id, u.fecha AS kickoff, u.home_nombre, u.away_nombre, u.liga_nombre
FROM u
LEFT JOIN b ON b.canonical_event_id=u.espn_event_id
WHERE b.canonical_event_id IS NULL
ORDER BY u.fecha, u.espn_event_id;

-- GATE 2 — PUBLICATION MUST REQUIRE A VALID PREMATCH SNAPSHOT, NOT JUST A STATUS LABEL.
SELECT 'V2_PUBLISHED_SNAPSHOT_TEMPORAL' AS gate,
       count(*) FILTER (WHERE p_reto_home IS NOT NULL) AS published_rows,
       count(*) FILTER (
         WHERE p_reto_home IS NOT NULL
           AND COALESCE(temporal_safe,false)=false
       ) AS temporal_unsafe_published,
       count(*) FILTER (
         WHERE p_reto_home IS NOT NULL
           AND (prediction_time IS NULL OR prediction_time >= kickoff)
       ) AS non_pregame_prediction_published,
       count(*) FILTER (
         WHERE p_reto_home IS NOT NULL
           AND (data_asof IS NULL OR data_asof > prediction_time)
       ) AS data_after_decision_published,
       (
         count(*) FILTER (WHERE p_reto_home IS NOT NULL AND COALESCE(temporal_safe,false)=false)=0
         AND count(*) FILTER (WHERE p_reto_home IS NOT NULL AND (prediction_time IS NULL OR prediction_time >= kickoff))=0
         AND count(*) FILTER (WHERE p_reto_home IS NOT NULL AND (data_asof IS NULL OR data_asof > prediction_time))=0
       ) AS pass
FROM public.v_futpro_v2
WHERE kickoff >= now()
  AND kickoff < now() + interval '48 hours';

-- GATE 3 — THE BRIDGE DEFINITION ITSELF MUST SELECT TEMPORALLY VALID SNAPSHOTS.
-- DISTINCT ON + computed_at DESC alone is not enough: an unsafe later snapshot can
-- shadow a valid pregame snapshot. This gate requires explicit temporal predicates
-- in the bridge definition.
WITH d AS (
  SELECT lower(pg_get_viewdef('public.v_futpro_v2'::regclass,true)) AS v
)
SELECT 'V2_BRIDGE_STATIC_TEMPORAL_SELECTION' AS gate,
       position('temporal_safe' in v)>0 AS mentions_temporal_safe,
       position('prediction_time' in v)>0 AS mentions_prediction_time,
       (
         position('where soccer_prediction_v2.temporal_safe' in replace(v,E'\n',' '))>0
         OR position('and soccer_prediction_v2.temporal_safe' in replace(v,E'\n',' '))>0
       ) AS filters_temporal_safe,
       (
         position('prediction_time <' in v)>0
         OR position('prediction_time<' in replace(v,' ',''))>0
       ) AS filters_prediction_before_kickoff,
       (
         position('where soccer_prediction_v2.temporal_safe' in replace(v,E'\n',' '))>0
         OR position('and soccer_prediction_v2.temporal_safe' in replace(v,E'\n',' '))>0
       )
       AND (
         position('prediction_time <' in v)>0
         OR position('prediction_time<' in replace(v,' ',''))>0
       ) AS pass
FROM d;

-- GATE 4 — MODEL REGISTRY MUST GOVERN PUBLISHABILITY, FEATURES, CALIBRATION,
-- TEMPORAL POLICY AND SAMPLE FLOORS. A simple approved=true bit is insufficient.
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
SELECT 'MODEL_REGISTRY_ENFORCEABLE_V2' AS gate,
       count(*) AS required_columns,
       count(*) FILTER (WHERE p.column_name IS NULL) AS missing_columns,
       array_agg(r.col ORDER BY r.col) FILTER (WHERE p.column_name IS NULL) AS missing,
       count(*) FILTER (WHERE p.column_name IS NULL)=0 AS pass
FROM required r
LEFT JOIN present p ON p.column_name=r.col;

-- GATE 5 — BUILDER MAY NOT BYPASS REGISTRY GOVERNANCE WITH A LITERAL SAMPLE FLOOR.
WITH f AS (
  SELECT lower(pg_get_functiondef(p.oid)) AS d
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='v2' AND p.proname='build_soccer_prediction_v2'
  LIMIT 1
)
SELECT 'BUILDER_SAMPLE_GOVERNANCE_V2' AS gate,
       position('model_registry' in d)>0 AS reads_registry,
       position('min_sample_' in d)>0 AS uses_registry_sample_rule,
       (
         position('hpj>=8' in replace(d,' ',''))>0
         OR position('apj>=8' in replace(d,' ',''))>0
       ) AS has_hardcoded_sample8,
       (
         position('model_registry' in d)>0
         AND position('min_sample_' in d)>0
         AND position('hpj>=8' in replace(d,' ',''))=0
         AND position('apj>=8' in replace(d,' ',''))=0
       ) AS pass
FROM f;

-- GATE 6 — MODEL INPUT FEATURES MUST EXPOSE INGESTION AS-OF, NOT ONLY MATCH DATE.
WITH d AS (
  SELECT lower(pg_get_viewdef('public.v_goles_equipo_futbol'::regclass,true)) AS v
)
SELECT 'MODEL_FEATURE_INGESTION_ASOF_V2' AS gate,
       position('cargado_at' in v)>0 AS tracks_ingestion_timestamp,
       position('data_asof' in v)>0 AS exposes_feature_asof,
       position('cargado_at' in v)>0 AND position('data_asof' in v)>0 AS pass
FROM d;

-- GATE 7 — MARKET-DERIVED ROWS MAY EXIST ONLY AS MARKET CONTEXT. They may not
-- contain RETO event probabilities or masquerade as the Dixon-Coles model.
SELECT 'MARKET_CONTEXT_QUARANTINED_V2' AS gate,
       count(*) FILTER (WHERE provenance->>'engine' ILIKE '%market%') AS market_rows,
       count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND (p_home IS NOT NULL OR p_draw IS NOT NULL OR p_away IS NOT NULL)
       ) AS market_rows_with_probability,
       count(*) FILTER (
         WHERE provenance->>'engine' ILIKE '%market%'
           AND (model_name='reto_dc_v2' OR model_version ILIKE 'dc-%' OR feature_version ILIKE 'goal_rates%')
       ) AS market_rows_mislabeled_as_reto,
       (
         count(*) FILTER (
           WHERE provenance->>'engine' ILIKE '%market%'
             AND (p_home IS NOT NULL OR p_draw IS NOT NULL OR p_away IS NOT NULL)
         )=0
         AND count(*) FILTER (
           WHERE provenance->>'engine' ILIKE '%market%'
             AND (model_name='reto_dc_v2' OR model_version ILIKE 'dc-%' OR feature_version ILIKE 'goal_rates%')
         )=0
       ) AS pass
FROM v2.soccer_prediction_v2;

-- GATE 8 — EVERY ENABLED USER-VISIBLE COMPETITION NEEDS EXACT PROVIDER IDENTITY.
SELECT 'VISIBLE_COMPETITION_PROVIDER_ID_V2' AS gate,
       count(*) AS visible_competitions,
       count(*) FILTER (WHERE provider_competition_id IS NULL) AS missing_provider_id,
       array_agg(competition_id ORDER BY competition_id)
         FILTER (WHERE provider_competition_id IS NULL) AS missing_competitions,
       count(*) FILTER (WHERE provider_competition_id IS NULL)=0 AS pass
FROM v2.competition_catalog
WHERE sport='soccer'
  AND enabled
  AND (show_in_futpro OR show_in_favorites OR show_in_reto13m);

-- GATE 9 — DISABLED/UNMAPPED COMPETITIONS MUST FAIL CLOSED, NOT VANISH.
-- The current bridge uses INNER JOINs to liga_alias/catalog; this static test makes
-- that disappearance impossible to call a PASS.
WITH d AS (
  SELECT lower(pg_get_viewdef('public.v_futpro_v2'::regclass,true)) AS v
)
SELECT 'BRIDGE_FAILS_CLOSED_ON_COMPETITION_MAPPING' AS gate,
       position('left join v2.liga_alias' in v)>0 AS alias_left_join,
       position('left join v2.competition_catalog' in v)>0 AS catalog_left_join,
       position('unmapped_competition' in v)>0 OR position('disabled_competition' in v)>0 AS explicit_missing_status,
       (
         position('left join v2.liga_alias' in v)>0
         AND position('left join v2.competition_catalog' in v)>0
         AND (position('unmapped_competition' in v)>0 OR position('disabled_competition' in v)>0)
       ) AS pass
FROM d;

SELECT now() AS audited_at,
       'SOCCER_GATE=FAIL_UNTIL_ALL_ISS033_GATES_PASS' AS soccer_gate,
       'RELEASE_GATE=HOLD' AS release_gate;