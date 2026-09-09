-- ISS-029 — SOCCER CONTEXT AS-OF GATE V1
-- *** READ-ONLY ACCEPTANCE GATE — NO DDL/DML — NO PROD MUTATION ***
--
-- Purpose:
-- The full prematch dossier may only touch non-static data that can prove
-- data_asof <= decision_time. A match date alone is NOT proof that a row was
-- known at decision time; ingestion/capture timestamps must also be bounded.
--
-- This gate intentionally fails until every helper used by
-- analisis_futbol_reto_core is ingestion-time safe.

WITH required_timestamp_contract AS (
  SELECT * FROM (VALUES
    ('historico_partidos_espn','cargado_at'),
    ('detalle_partido_espn','cargado_at'),
    ('agenda_espn','actualizado_at'),
    ('partido_sede','capturado_at'),
    ('alineaciones_espn','capturado_at'),
    ('ligamx_lesiones','updated_at'),
    ('futbol_jugador_temporada','actualizado_at'),
    ('espn_standings_raw','capturado_at'),
    ('ratings_espn','actualizado'),
    ('futbol_arbitro_partido','cargado_at'),
    ('odds_espn','capturado_at'),
    ('fut_predicciones','generado_at')
  ) x(relation_name, timestamp_column)
), timestamp_contract AS (
  SELECT r.relation_name, r.timestamp_column,
         EXISTS (
           SELECT 1 FROM information_schema.columns c
           WHERE c.table_schema='public'
             AND c.table_name=r.relation_name
             AND c.column_name=r.timestamp_column
         ) AS timestamp_column_exists
  FROM required_timestamp_contract r
)
SELECT 'SOURCE_TIMESTAMP_CONTRACT' AS gate,
       relation_name AS object_name,
       timestamp_column_exists AS pass,
       CASE WHEN timestamp_column_exists THEN 'OK'
            ELSE 'required capture/ingestion timestamp column missing' END AS detail
FROM timestamp_contract
ORDER BY relation_name;

-- Weather is intentionally fail-closed: current futbol_clima_hora has no
-- auditable capture timestamp. Until snapshots are versioned, the dossier may
-- inventory weather as unavailable, but MUST NOT fetch current weather.
SELECT 'WEATHER_CAPTURE_TIMESTAMP' AS gate,
       'futbol_clima_hora' AS object_name,
       EXISTS (
         SELECT 1 FROM information_schema.columns c
         WHERE c.table_schema='public' AND c.table_name='futbol_clima_hora'
           AND c.column_name IN ('capturado_at','cargado_at','actualizado_at','created_at')
       ) AS pass,
       CASE WHEN EXISTS (
         SELECT 1 FROM information_schema.columns c
         WHERE c.table_schema='public' AND c.table_name='futbol_clima_hora'
           AND c.column_name IN ('capturado_at','cargado_at','actualizado_at','created_at')
       ) THEN 'timestamp exists; weather may be audited with an explicit cutoff'
       ELSE 'NO auditable capture timestamp: weather must remain unavailable/not fetched'
       END AS detail;

-- Helper definitions used by the staged dossier. Each helper that reads a
-- mutable historical/agenda relation must constrain the ingestion/capture
-- timestamp as well as the event date.
WITH helper_defs AS (
  SELECT p.proname,
         lower(pg_get_functiondef(p.oid)) AS def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname IN (
      'forma_espn_asof',
      'equipo_perfil_al',
      'h2h_espn',
      'tendencias_espn',
      'ultimos_espn',
      'futbol_factor_descanso_espn'
    )
), checks AS (
  SELECT proname,
    CASE proname
      WHEN 'futbol_factor_descanso_espn' THEN
        (def LIKE '%historico_partidos_espn%' AND def LIKE '%cargado_at%'
         AND def LIKE '%agenda_espn%' AND def LIKE '%actualizado_at%')
      ELSE
        (def LIKE '%historico_partidos_espn%' AND def LIKE '%cargado_at%')
    END AS pass,
    CASE proname
      WHEN 'futbol_factor_descanso_espn' THEN
        'must bound historico_partidos_espn.cargado_at AND agenda_espn.actualizado_at by decision_time'
      ELSE
        'must bound historico_partidos_espn.cargado_at by decision_time, not only match fecha'
    END AS required_rule
  FROM helper_defs
)
SELECT 'CONTEXT_HELPER_INGESTION_ASOF' AS gate,
       proname AS object_name,
       pass,
       CASE WHEN pass THEN 'OK' ELSE required_rule END AS detail
FROM checks
ORDER BY proname;

-- Fine-stat context currently comes from v_equipo_partido_espn_xg. The view
-- joins detalle_partido_espn, whose cargado_at exists, but the deployed view
-- does not expose/require it. The staged core therefore cannot prove that fine
-- stats were known by decision_time unless it queries the timestamped source
-- directly or a new snapshot-safe helper/view.
WITH vdef AS (
  SELECT lower(pg_get_viewdef('public.v_equipo_partido_espn_xg'::regclass,true)) AS def
)
SELECT 'FINE_STATS_INGESTION_ASOF' AS gate,
       'v_equipo_partido_espn_xg' AS object_name,
       (def LIKE '%cargado_at%') AS pass,
       CASE WHEN def LIKE '%cargado_at%' THEN 'OK'
            ELSE 'view does not expose/enforce detalle_partido_espn.cargado_at; use timestamp-safe source/helper' END AS detail
FROM vdef;

-- If the staged/new soccer core has already been installed in a preview DB,
-- enforce that it does not call known unauditable or legacy helper paths.
WITH core AS (
  SELECT lower(pg_get_functiondef(p.oid)) AS def
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='analisis_futbol_reto_core'
    AND pg_get_function_identity_arguments(p.oid)='p_event text'
  LIMIT 1
), rules(rule_name, forbidden_pattern, remediation) AS (
  VALUES
    ('NO_CURRENT_WEATHER','clima_partido_futbol(', 'inventory weather as missing until a captured_at snapshot exists'),
    ('NO_NULL_VENUE_ASOF_BYPASS','capturado_at is null or', 'rows without partido_sede.capturado_at are unavailable, not temporally safe'),
    ('NO_OLD_FORM_HELPER','forma_espn_asof(', 'use a helper that also enforces historico_partidos_espn.cargado_at <= decision_time'),
    ('NO_OLD_PROFILE_HELPER','equipo_perfil_al(', 'use a helper that also enforces historico_partidos_espn.cargado_at <= decision_time'),
    ('NO_OLD_H2H_HELPER','h2h_espn(', 'use a helper that also enforces historico_partidos_espn.cargado_at <= decision_time'),
    ('NO_OLD_TRENDS_HELPER','tendencias_espn(', 'use a helper that also enforces historico_partidos_espn.cargado_at <= decision_time'),
    ('NO_OLD_LAST_HELPER','ultimos_espn(', 'use a helper that also enforces historico_partidos_espn.cargado_at <= decision_time'),
    ('NO_OLD_REST_HELPER','futbol_factor_descanso_espn(', 'use a helper that bounds historico cargado_at and agenda actualizado_at'),
    ('NO_UNTIMESTAMPED_FINE_VIEW','from public.v_equipo_partido_espn_xg', 'query a snapshot-safe fine-stat helper/source with detalle_partido_espn.cargado_at cutoff')
)
SELECT 'SOCCER_CORE_STRICT_ASOF_DEPENDENCIES' AS gate,
       r.rule_name AS object_name,
       CASE WHEN c.def IS NULL THEN false ELSE position(r.forbidden_pattern in c.def)=0 END AS pass,
       CASE WHEN c.def IS NULL THEN 'analisis_futbol_reto_core not installed in this DB'
            WHEN position(r.forbidden_pattern in c.def)=0 THEN 'OK'
            ELSE r.remediation END AS detail
FROM rules r
LEFT JOIN core c ON true
ORDER BY r.rule_name;

-- Strict source-quality summary: every row below must be zero before SOCCER
-- can pass in a candidate DB. NULL capture timestamps are not accepted as safe.
SELECT 'CURRENT_SOURCE_NULL_TIMESTAMP_COUNTS' AS gate,
       source_name AS object_name,
       (null_timestamp_rows = 0) AS pass,
       'null_timestamp_rows='||null_timestamp_rows::text AS detail
FROM (
  SELECT 'partido_sede' source_name, count(*) FILTER (WHERE capturado_at IS NULL) null_timestamp_rows FROM public.partido_sede
  UNION ALL SELECT 'alineaciones_espn', count(*) FILTER (WHERE capturado_at IS NULL) FROM public.alineaciones_espn
  UNION ALL SELECT 'ligamx_lesiones', count(*) FILTER (WHERE updated_at IS NULL) FROM public.ligamx_lesiones
  UNION ALL SELECT 'futbol_jugador_temporada', count(*) FILTER (WHERE actualizado_at IS NULL) FROM public.futbol_jugador_temporada
  UNION ALL SELECT 'espn_standings_raw', count(*) FILTER (WHERE capturado_at IS NULL) FROM public.espn_standings_raw
  UNION ALL SELECT 'ratings_espn', count(*) FILTER (WHERE actualizado IS NULL) FROM public.ratings_espn
  UNION ALL SELECT 'futbol_arbitro_partido', count(*) FILTER (WHERE cargado_at IS NULL) FROM public.futbol_arbitro_partido
  UNION ALL SELECT 'odds_espn', count(*) FILTER (WHERE capturado_at IS NULL) FROM public.odds_espn
  UNION ALL SELECT 'historico_partidos_espn', count(*) FILTER (WHERE cargado_at IS NULL) FROM public.historico_partidos_espn
  UNION ALL SELECT 'detalle_partido_espn', count(*) FILTER (WHERE cargado_at IS NULL) FROM public.detalle_partido_espn
) q
ORDER BY source_name;
