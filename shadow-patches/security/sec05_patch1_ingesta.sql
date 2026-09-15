-- ============================================================================
-- SEC-05 PATCH 1 — FAMILIA DE INGESTA (*_pedir / *_recoger / absorber_*)
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY.
--
-- ALCANCE DELIBERADAMENTE ESTRECHO. De las 127 funciones SECURITY DEFINER que
-- escriben, no tienen control de identidad y son invocables por anon, este patch
-- toca SOLO las 38 de ingesta. Motivo: son ETL puro (`_pedir` llama a la API
-- externa, `_recoger` procesa la respuesta) y ninguna es plausiblemente una
-- superficie de frontend. Las otras 89 quedan fuera hasta tener el consumer map,
-- conforme a la instrucción de no revocar a ciegas.
--
-- POR QUE IMPORTA: 59 de las 127 hacen llamadas HTTP externas. Un cliente
-- anónimo puede invocarlas en bucle y AGOTAR CUOTA DE APIs DE PAGO. Varias
-- además contienen DELETE.
--
-- POR QUE ES SEGURO PARA EL CRON: los jobs de pg_cron corren como `postgres`,
-- que es el owner. Revocar de PUBLIC/anon/authenticated no afecta al owner.
--
-- SE CONCEDE A service_role de forma explícita: no hay evidencia de que las edge
-- functions las llamen, pero tampoco de lo contrario, y mantenerlo es el lado
-- conservador. Si el consumer map demuestra que no las usa, se puede endurecer más.
--
-- OJO: REVOKE ... FROM PUBLIC es imprescindible. Revocar solo de anon NO cierra
-- nada, porque PostgreSQL concede EXECUTE a PUBLIC por defecto y anon lo hereda.
-- Esto ya se comprobó empíricamente en SEC-03.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '60s';

REVOKE EXECUTE ON FUNCTION public.absorber_agenda_espn() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.absorber_agenda_espn() TO service_role;
REVOKE EXECUTE ON FUNCTION public.absorber_detalle_espn() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.absorber_detalle_espn() TO service_role;
REVOKE EXECUTE ON FUNCTION public.absorber_detalle_espn(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.absorber_detalle_espn(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.absorber_historico_espn() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.absorber_historico_espn() TO service_role;
REVOKE EXECUTE ON FUNCTION public.absorber_tenis_espn() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.absorber_tenis_espn() TO service_role;
REVOKE EXECUTE ON FUNCTION public.futbol_arbitro_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.futbol_arbitro_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.futbol_arbitro_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.futbol_arbitro_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.futbol_clima_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.futbol_clima_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.futbol_clima_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.futbol_clima_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.futbol_jugador_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.futbol_jugador_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.futbol_jugador_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.futbol_jugador_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_bat_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_bat_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_bat_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_bat_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_batazos_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_batazos_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_batazos_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_batazos_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_boxscore_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_boxscore_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_boxscore_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_boxscore_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_calendario_pedir(p_desde date, p_hasta date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_calendario_pedir(p_desde date, p_hasta date) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_calendario_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_calendario_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_clima_pedir(p_desde date, p_hasta date) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_clima_pedir(p_desde date, p_hasta date) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_clima_pedir(p_desde date, p_hasta date, p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_clima_pedir(p_desde date, p_hasta date, p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_clima_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_clima_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_linescore_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_linescore_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_linescore_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_linescore_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_lineup_pedir(p_horas integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_lineup_pedir(p_horas integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_lineup_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_lineup_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_pit_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_pit_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_pit_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_pit_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_pitcheo_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_pitcheo_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_pitcheo_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_pitcheo_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_saber_pedir(p_temporada integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_saber_pedir(p_temporada integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_saber_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_saber_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_ump_pedir(p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_ump_pedir(p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.mlb_ump_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.mlb_ump_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.nfl_clima_pedir(p_desde date, p_hasta date, p_limite integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.nfl_clima_pedir(p_desde date, p_hasta date, p_limite integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.nfl_clima_recoger() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.nfl_clima_recoger() TO service_role;
REVOKE EXECUTE ON FUNCTION public.tenis_ls_pedir() FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.tenis_ls_pedir() TO service_role;
REVOKE EXECUTE ON FUNCTION public.tenis_ls_recoger(p_max integer) FROM PUBLIC, anon, authenticated;
GRANT  EXECUTE ON FUNCTION public.tenis_ls_recoger(p_max integer) TO service_role;

-- ============================================================================
-- POST-VERIFY — FAIL -> ROLLBACK total
-- ============================================================================
DO $v$
DECLARE n_anon int; n_srv int; n_total int;
BEGIN
  SELECT count(*) INTO n_total
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang
   WHERE n.nspname='public' AND p.prokind='f' AND l.lanname IN ('sql','plpgsql')
     AND (p.proname ~ '_(pedir|recoger)$' OR p.proname ~ '^absorber_');

  -- has_function_privilege ve el privilegio heredado de PUBLIC; el ACL explícito no.
  SELECT count(*) INTO n_anon
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang
   WHERE n.nspname='public' AND p.prokind='f' AND l.lanname IN ('sql','plpgsql')
     AND (p.proname ~ '_(pedir|recoger)$' OR p.proname ~ '^absorber_')
     AND (has_function_privilege('anon', p.oid, 'EXECUTE')
       OR has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  IF n_anon <> 0 THEN
    RAISE EXCEPTION 'FAIL P1 % funciones de ingesta siguen accesibles a anon/authenticated', n_anon;
  END IF;
  RAISE NOTICE 'PASS_NONEMPTY P1 ingesta cerrada a anon/authenticated (evaluated_rows=% violations=0)', n_total;

  SELECT count(*) INTO n_srv
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang
   WHERE n.nspname='public' AND p.prokind='f' AND l.lanname IN ('sql','plpgsql')
     AND (p.proname ~ '_(pedir|recoger)$' OR p.proname ~ '^absorber_')
     AND has_function_privilege('service_role', p.oid, 'EXECUTE');
  IF n_srv <> n_total THEN
    RAISE EXCEPTION 'FAIL P2 service_role perdió acceso en % de % funciones', n_total-n_srv, n_total;
  END IF;
  RAISE NOTICE 'PASS_NONEMPTY P2 service_role conserva acceso en las % (evaluated_rows=% violations=0)', n_total, n_total;

  -- el owner (postgres, que es quien corre pg_cron) nunca pierde EXECUTE
  RAISE NOTICE 'INFO P3 pg_cron corre como owner: no afectado por estos REVOKE';
  RAISE NOTICE '==== SEC-05 PATCH 1 OK -> COMMIT permitido ====';
END $v$;

COMMIT;
