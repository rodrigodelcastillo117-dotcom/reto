-- ISS-032 — RETO13M V2 PRIMARY-PATH AUTHORITY GATE (READ ONLY)
-- Safety: SELECT-only. No DDL/DML/deploy/prod mutation.
-- Purpose: prevent the clean Reto13M V2 prediction/discovery lane from being
-- operationally coupled to legacy predictive/value machinery.
--
-- Contract:
--   * prediction/discovery authority = public.v_reto13m_daily / canonical V2 contracts
--   * factual realized-outcome analytics may use public.reto_13m_stats
--   * public.reto_13m_estado is NOT safe for the V2 primary path while its base
--     implementation traverses legacy model/value/economic selectors
--   * a frontend route must render canonical daily picks independently of lifecycle
--     analytics failure; this SQL supplies the backend dependency classification used
--     by the static/frontend regression gate.

-- 1) Classify the legacy state RPC dependency graph. Any TRUE legacy dependency means
--    the RPC must not be a blocking/loading authority for the clean V2 prediction route.
WITH f AS (
  SELECT pg_get_functiondef(p.oid) AS d
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='reto_13m_estado__base'
  ORDER BY p.oid
  LIMIT 1
)
SELECT
  'RETO13M_ESTADO_PRIMARY_PATH_SAFETY' AS gate,
  position('favoritos_bien_pagados' in lower(d)) > 0 AS dep_favoritos_bien_pagados,
  position('analisis_partidos' in lower(d)) > 0 AS dep_analisis_partidos,
  position('motor_cache' in lower(d)) > 0 AS dep_motor_cache,
  position('modelo_confiabilidad' in lower(d)) > 0 AS dep_modelo_confiabilidad,
  position('zona_realidad' in lower(d)) > 0 AS dep_zona_realidad,
  position('kelly' in lower(d)) > 0 AS dep_kelly,
  position('ev_' in lower(d)) > 0 OR position('ev_pct' in lower(d)) > 0 AS dep_ev,
  NOT (
    position('favoritos_bien_pagados' in lower(d)) > 0 OR
    position('analisis_partidos' in lower(d)) > 0 OR
    position('motor_cache' in lower(d)) > 0 OR
    position('modelo_confiabilidad' in lower(d)) > 0 OR
    position('zona_realidad' in lower(d)) > 0 OR
    position('kelly' in lower(d)) > 0 OR
    position('ev_' in lower(d)) > 0 OR
    position('ev_pct' in lower(d)) > 0
  ) AS safe_for_v2_primary_path
FROM f;

-- 2) Independently verify that the STATS lane remains factual/outcome-only. This does
--    NOT authorize it as a prediction source; it only allows it to survive as secondary
--    realized-performance analytics.
WITH f AS (
  SELECT pg_get_functiondef(p.oid) AS d
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='reto_13m_stats__base'
  ORDER BY p.oid
  LIMIT 1
), forbidden(term) AS (VALUES
  ('v_pick_canonico'),
  ('v_prediccion_reto_futbol'),
  ('analisis_partidos'),
  ('motor_cache'),
  ('modelo_confiabilidad'),
  ('prob_modelo'),
  ('favoritos_bien_pagados'),
  ('predecir_mlb'),
  ('pred_futbol_espn'),
  ('kelly')
)
SELECT
  'RETO13M_STATS_FACTUAL_ONLY' AS gate,
  count(*) FILTER (WHERE position(term in lower(d)) > 0) AS forbidden_dependency_hits,
  array_agg(term ORDER BY term) FILTER (WHERE position(term in lower(d)) > 0) AS forbidden_dependencies,
  count(*) FILTER (WHERE position(term in lower(d)) > 0)=0 AS pass
FROM f CROSS JOIN forbidden;

-- 3) Canonical daily view itself must not traverse the same legacy authority graph.
WITH v AS (
  SELECT pg_get_viewdef('public.v_reto13m_daily'::regclass, true) AS d
), forbidden(term) AS (VALUES
  ('reto_13m_estado'),
  ('favoritos_bien_pagados'),
  ('analisis_partidos'),
  ('motor_cache'),
  ('modelo_confiabilidad'),
  ('zona_realidad'),
  ('v_pick_canonico'),
  ('pred_futbol_espn'),
  ('predecir_mlb')
)
SELECT
  'RETO13M_DAILY_CANONICAL_DEPENDENCY' AS gate,
  count(*) FILTER (WHERE position(term in lower(d)) > 0) AS forbidden_dependency_hits,
  array_agg(term ORDER BY term) FILTER (WHERE position(term in lower(d)) > 0) AS forbidden_dependencies,
  count(*) FILTER (WHERE position(term in lower(d)) > 0)=0 AS pass
FROM v CROSS JOIN forbidden;

-- 4) Current V2 daily publishability sanity. No row may publish a probability while its
--    model/temporal state is non-publishable. Column discovery is emitted separately so
--    this gate stays diagnostic when the clean contract evolves.
SELECT
  'RETO13M_DAILY_COLUMNS' AS gate,
  array_agg(column_name ORDER BY ordinal_position) AS columns
FROM information_schema.columns
WHERE table_schema='public' AND table_name='v_reto13m_daily';

-- 5) Explicit closure note for orchestration. Backend dependency cleanliness alone is
--    insufficient: the frontend must also prove that canonical daily content renders when
--    lifecycle/accounting queries fail and must statically deny reto_13m_estado in the clean V2 route.
SELECT
  now() AS audited_at,
  'RELEASE_GATE=HOLD' AS release_gate,
  'SOCCER_GATE=FAIL_UNTIL_FRONTEND_REMOVES_RETO_13M_ESTADO_FROM_BLOCKING_V2_PATH_AND_ALL_OTHER_SOCCER_GATES_PASS' AS soccer_gate,
  'FRONTEND_REQUIRED: daily V2 renders independently of lifecycle failure; static denylist contains reto_13m_estado' AS required_frontend_regression;
