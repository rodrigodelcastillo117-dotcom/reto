-- ============================================================================
-- CONSUMER MAP PROBE — descubre consumidores REALES desde pg_stat_statements
-- ============================================================================
-- READ-ONLY. Seguro contra producción dentro de BEGIN READ ONLY.
--
-- PROBLEMA QUE RESUELVE: el frontend no está en el repo, así que el consumer map
-- se declaró BLOCKED. Pero PostgREST deja huella: toda consulta que genera lleva
-- el CTE `pgrst_source`. Y el rol distingue la capa:
--
--   authenticated / anon  -> FRONTEND (usuario final vía PostgREST)
--   service_role          -> EDGE FUNCTIONS / backend con service key
--   postgres / supabase_* -> cron, mantenimiento, plataforma
--
-- LIMITACIÓN HONESTA: pg_stat_statements es una ventana, no un histórico.
-- `pg_stat_statements_info.stats_reset` dice desde cuándo. La AUSENCIA de un
-- objeto NO prueba que no se consuma: prueba que no se consumió en esa ventana.
-- Para un mapa concluyente hay que dejar acumular estadísticas varios días y
-- volver a correr esto.
--
-- Uso:
--   psql "$DATABASE_URL" -f consumer_map_probe.sql
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';

\echo '=== GUARD (debe ser on) ==='
SELECT current_setting('transaction_read_only') AS transaction_read_only;

\echo ''
\echo '=== VENTANA DE OBSERVACION ==='
SELECT stats_reset AS desde,
       now() - stats_reset AS duracion,
       (SELECT count(*) FROM pg_stat_statements) AS sentencias_registradas
  FROM pg_stat_statements_info;

\echo ''
\echo '=== CAPA FRONTEND (authenticated / anon via PostgREST) ==='
SELECT obj AS objeto, sum(calls) AS llamadas, string_agg(DISTINCT rol, ',') AS roles
FROM (
  SELECT COALESCE(r.rolname,'?') AS rol, s.calls,
         (regexp_matches(s.query, 'FROM "public"\."([a-z_0-9]+)"', 'g'))[1] AS obj
    FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
   WHERE s.query LIKE '%pgrst_source%'
     AND COALESCE(r.rolname,'') IN ('authenticated','anon')
) q GROUP BY obj ORDER BY sum(calls) DESC;

\echo ''
\echo '=== CAPA EDGE / BACKEND (service_role via PostgREST) ==='
SELECT obj AS objeto, sum(calls) AS llamadas
FROM (
  SELECT s.calls, (regexp_matches(s.query, 'FROM "public"\."([a-z_0-9]+)"', 'g'))[1] AS obj
    FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
   WHERE s.query LIKE '%pgrst_source%' AND COALESCE(r.rolname,'') = 'service_role'
) q GROUP BY obj ORDER BY sum(calls) DESC;

\echo ''
\echo '=== SUPERFICIES DE PICKS: consumidas o no en esta ventana ==='
WITH superficies(obj) AS (
  SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname='public' AND c.relkind IN ('r','v','m')
     AND c.relname ~ 'pick|oportunidad|super_|oraculo|mejores|recomend'
), vistas AS (
  SELECT (regexp_matches(s.query, '"public"\."([a-z_0-9]+)"', 'g'))[1] AS obj,
         COALESCE(r.rolname,'?') AS rol, s.calls
    FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
)
SELECT sp.obj AS superficie,
       COALESCE(sum(v.calls) FILTER (WHERE v.rol IN ('authenticated','anon')), 0) AS llamadas_frontend,
       COALESCE(sum(v.calls) FILTER (WHERE v.rol = 'service_role'), 0)            AS llamadas_edge,
       COALESCE(sum(v.calls) FILTER (WHERE v.rol NOT IN ('authenticated','anon','service_role')), 0) AS llamadas_interno,
       CASE WHEN sum(v.calls) IS NULL THEN 'NO_OBSERVADO_EN_VENTANA' ELSE 'OBSERVADO' END AS estado
  FROM superficies sp LEFT JOIN vistas v ON v.obj = sp.obj
 GROUP BY sp.obj ORDER BY 2 DESC, 3 DESC, 1;

\echo ''
\echo '=== RPC invocadas por frontend/edge (funciones, no tablas) ==='
SELECT COALESCE(r.rolname,'?') AS rol, s.calls,
       left(regexp_replace(s.query, '\s+', ' ', 'g'), 120) AS sentencia
  FROM pg_stat_statements s LEFT JOIN pg_roles r ON r.oid = s.userid
 WHERE s.query !~ 'pgrst_source'
   AND s.query ~* '^\s*SELECT\s+(public\.)?[a-z_0-9]+\s*\('
   AND COALESCE(r.rolname,'') IN ('authenticated','anon','service_role','authenticator')
 ORDER BY s.calls DESC LIMIT 30;

ROLLBACK;
