-- ============================================================================
-- ISS-010 — ANALISIS_COMPLETO RESUELVE IDENTIDAD DE API-FOOTBALL (FAIL-CLOSED)
--            (PREPARED — **NOT DEPLOYED**)
-- ============================================================================
-- Status:  PREPARED_FOR_DEPLOY. Do NOT apply automatically. No production change
--          happens by committing this file. Branch: claude/reto-13m-espn-matches.
--
-- SÍNTOMA (reportado en vivo, FUT PRO) --------------------------------------
--   "no salen los analisis, ni picks ni nada" al abrir "ABRIR ANÁLISIS COMPLETO"
--   en partidos de Champions (Dortmund vs Villarreal, Porto vs Man City, 8-sep).
--
-- CAUSA RAÍZ (verificada contra producción, read-only) -----------------------
--   El MISMO partido vive dos veces en live_scores:
--       401915449   (id ESPN, está en agenda_espn -> analizable)
--       af_1635652  (id API-Football, NO enlazado a ESPN)
--   FUT PRO abre la tarjeta construida desde el lado API-Football y llama
--       analisis_completo('af_1635652')
--   pero analisis_completo hace un lookup EXACTO:
--       select ... from agenda_espn where espn_event_id = p_event
--   'af_1635652' no está en agenda_espn -> devuelve {'error':'partido no
--   encontrado'} -> la modal queda EN BLANCO.
--   El análisis SÍ existe: analisis_completo('401915449') devuelve 9 secciones
--   (resumen, probabilidades, H2H, precio, tendencias...). Sólo falla el
--   cruce de identidad AF -> ESPN.
--
-- QUÉ HACE ESTE PATCH -------------------------------------------------------
--   1. Crea public.resolver_evento_canonico(text): resuelve CUALQUIER id de
--      entrada (ESPN | af_<n> | af:<n> | <n> numérico AF | futmap:...) al
--      espn_event_id CANÓNICO, con reglas FAIL-CLOSED:
--        DIRECT             id ya es ESPN y está en agenda_espn (sin cambio).
--        MAP_CACHE          evento_id_map (cache autoritativo, único por id).
--        MAP_LIGAMX         ligamx_partidos.id (fixture AF) ya enlazado a ESPN.
--        FUZZY_UNIQUE       equipos+fecha del fixture -> EXACTAMENTE 1 ESPN.
--        IDENTITY_AMBIGUOUS equipos+fecha -> >1 candidato ESPN: NO adivina.
--        ANALYSIS_UNAVAILABLE  0 candidatos / id irreconocible.
--      Es STABLE y READ-ONLY (no escribe): no puede degradar el RPC ni la caché.
--      NO hay hardcode por equipo/competencia — todo sale del mapeo + conteo.
--   2. Renombra la función actual a analisis_completo_core (cuerpo intacto,
--      byte-idéntico) y crea un envoltorio delgado analisis_completo(text) que
--      resuelve la identidad y delega. Cuando no resuelve, devuelve un error
--      EXPLÍCITO con reason_code (no un blanco silencioso).
--
-- POR QUÉ FAIL-CLOSED IMPORTA (verificado) -----------------------------------
--   El resolver de nombres+fecha que ya existía (resolver_evento_id) usa
--   LIMIT 1 SIN guarda de ambigüedad. Medido en producción: 71 llaves difusas
--   (día, prefijo-6 local, prefijo-6 visitante) colapsan a >1 espn_event_id
--   distinto (peor caso 3). Ahí LIMIT 1 devuelve un partido EQUIVOCADO y lo
--   cachea con 0.85-0.9 de confianza. Este resolver CUENTA los candidatos y se
--   niega (IDENTITY_AMBIGUOUS) en vez de cruzar mal. Ejemplo bueno verificado:
--   af_1635652 -> 1 candidato -> 401915449 (Dortmund vs Villarreal). Correcto.
--
-- SEGURIDAD / REVERSIBILIDAD -------------------------------------------------
--   * El envoltorio conserva el contrato del RPC (mismo nombre, misma firma,
--     mismo tipo de retorno). El frontend no cambia.
--   * Cualquier id que HOY funciona toma la rama DIRECT y se comporta idéntico.
--     El patch sólo AÑADE resolución para ids que hoy devuelven "no encontrado".
--   * Rollback = renombrar core de vuelta + drop del envoltorio y del resolver
--     (restaura la función original EXACTA). Ver shadow-patches/rollback/.
--   * UCL sigue SIN modelo económico (LEAGUE_NOT_REGISTERED). Este patch NO
--     inventa picks: sólo hace alcanzable el ANÁLISIS INFORMATIVO que ya existe.
--
-- CÓMO APLICAR (después, deliberadamente, en branch/staging primero) ----------
--   1. supabase branch (o staging) -> correr este archivo.
--   2. Correr el bloque POST-APPLY VALIDATION de abajo.
--   3. Confirmar: analisis_completo('af_1635652') deja de dar "no encontrado" y
--      devuelve Dortmund vs Villarreal; analisis_completo('401915449') idéntico.
--   4. Promover. NUNCA aplicar directo a prod sin lo anterior.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1) Resolver canónico de identidad (STABLE, read-only, fail-closed).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolver_evento_canonico(p_id text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_id    text := btrim(coalesce(p_id, ''));
  v_espn  text;
  v_num   text;
  v_af    bigint;
  v_home  text;
  v_away  text;
  v_fecha date;
  v_n     int;
  v_partes text[];
BEGIN
  IF v_id = '' THEN
    RETURN jsonb_build_object('espn_event_id', NULL,
             'reason_code', 'ANALYSIS_UNAVAILABLE', 'metodo', 'empty');
  END IF;

  -- 1) DIRECT: ya es un id ESPN presente en la agenda (comportamiento actual).
  IF EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = v_id) THEN
    RETURN jsonb_build_object('espn_event_id', v_id,
             'reason_code', 'DIRECT', 'metodo', 'agenda_espn');
  END IF;

  -- 2) MAP_CACHE: cache autoritativo de resoluciones (único por id_externo).
  SELECT m.espn_event_id INTO v_espn FROM evento_id_map m WHERE m.id_externo = v_id;
  IF v_espn IS NOT NULL
     AND EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = v_espn) THEN
    RETURN jsonb_build_object('espn_event_id', v_espn,
             'reason_code', 'MAP_CACHE', 'metodo', 'evento_id_map');
  END IF;

  -- Determinar (equipos, fecha) desde el fixture AF o desde un id 'futmap:'.
  -- Se rellena por UNA de dos vías; luego se aplica el MISMO conteo fail-closed.
  v_num := regexp_replace(v_id, '^af[_:]?', '', 'i');   -- 'af_123' / 'af:123' / '123'
  IF v_num ~ '^[0-9]+$' THEN
    v_af := v_num::bigint;

    -- 3) MAP_LIGAMX: el fixture AF ya está enlazado a ESPN (id es PK -> único).
    SELECT p.espn_event_id INTO v_espn
      FROM ligamx_partidos p
     WHERE p.id = v_af AND p.espn_event_id IS NOT NULL;
    IF v_espn IS NOT NULL
       AND EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = v_espn) THEN
      RETURN jsonb_build_object('espn_event_id', v_espn,
               'reason_code', 'MAP_LIGAMX', 'metodo', 'ligamx_partidos.espn_event_id');
    END IF;

    -- Equipos + fecha del fixture (para el cruce difuso fail-closed).
    SELECT h.nombre, a.nombre, p.fecha_utc::date
      INTO v_home, v_away, v_fecha
      FROM ligamx_partidos p
      LEFT JOIN ligamx_equipos h ON h.api_football_id = p.home_id
      LEFT JOIN ligamx_equipos a ON a.api_football_id = p.away_id
     WHERE p.id = v_af;

  ELSIF v_id LIKE 'futmap:%' THEN
    -- futmap:<algo>:<fecha>:<home>_vs_<away>  (parseo read-only, sin cache).
    v_partes := string_to_array(v_id, ':');
    IF array_length(v_partes, 1) >= 4 THEN
      BEGIN
        v_fecha := v_partes[3]::date;
      EXCEPTION WHEN OTHERS THEN
        v_fecha := NULL;
      END;
      v_home := split_part(v_partes[4], '_vs_', 1);
      v_away := split_part(v_partes[4], '_vs_', 2);
    END IF;
  END IF;

  -- 4) FUZZY fail-closed: equipos + fecha -> candidatos ESPN DISTINTOS.
  --    Exactamente 1 -> resuelve. 0 -> unavailable. >1 -> ambiguo (no adivina).
  IF v_home IS NOT NULL AND v_away IS NOT NULL AND v_fecha IS NOT NULL
     AND slug_equipo(v_home) <> '' AND slug_equipo(v_away) <> '' THEN
    WITH cand AS (
      SELECT DISTINCT l.espn_event_id
      FROM (SELECT espn_event_id, home_team, away_team, game_date FROM live_scores
            UNION ALL
            SELECT espn_event_id, home_team, away_team, game_date FROM marcadores_archivo) l
      WHERE l.espn_event_id ~ '^[0-9]+$'
        AND l.game_date::date BETWEEN v_fecha - 1 AND v_fecha + 1
        AND slug_equipo(l.home_team) LIKE '%' || left(slug_equipo(v_home), 6) || '%'
        AND slug_equipo(l.away_team) LIKE '%' || left(slug_equipo(v_away), 6) || '%'
        AND EXISTS (SELECT 1 FROM agenda_espn a WHERE a.espn_event_id = l.espn_event_id)
    )
    SELECT count(*), min(espn_event_id) INTO v_n, v_espn FROM cand;

    IF v_n = 1 THEN
      RETURN jsonb_build_object('espn_event_id', v_espn,
               'reason_code', 'FUZZY_UNIQUE', 'metodo', 'equipos+fecha');
    ELSIF v_n > 1 THEN
      RETURN jsonb_build_object('espn_event_id', NULL,
               'reason_code', 'IDENTITY_AMBIGUOUS', 'metodo', 'equipos+fecha',
               'candidatos', v_n);
    END IF;
  END IF;

  -- 5) Nada resolvió con certeza.
  RETURN jsonb_build_object('espn_event_id', NULL,
           'reason_code', 'ANALYSIS_UNAVAILABLE', 'metodo', 'no_match');
END;
$function$;

COMMENT ON FUNCTION public.resolver_evento_canonico(text) IS
  'ISS-010: resuelve id de entrada (ESPN|af_<n>|futmap:...) a espn_event_id canonico. '
  'Fail-closed: >1 candidato -> IDENTITY_AMBIGUOUS; 0 -> ANALYSIS_UNAVAILABLE. STABLE/read-only.';

-- ----------------------------------------------------------------------------
-- 2) Renombrar la función actual y crear el envoltorio delgado.
--    El cuerpo real queda intacto en analisis_completo_core (byte-idéntico);
--    el envoltorio resuelve identidad y delega. Contrato del RPC sin cambios.
-- ----------------------------------------------------------------------------
ALTER FUNCTION public.analisis_completo(text) RENAME TO analisis_completo_core;

CREATE OR REPLACE FUNCTION public.analisis_completo(p_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_res   jsonb;
  v_canon text;
BEGIN
  -- Resolver identidad canónica (fail-closed) antes de tocar el análisis.
  v_res   := public.resolver_evento_canonico(p_event);
  v_canon := v_res->>'espn_event_id';

  IF v_canon IS NULL THEN
    -- Error EXPLÍCITO con reason_code, no un blanco silencioso.
    RETURN jsonb_build_object(
      'error', 'partido no encontrado',
      'reason_code', v_res->>'reason_code',
      'id_recibido', p_event);
  END IF;

  RETURN public.analisis_completo_core(v_canon);
END;
$function$;

COMMIT;

-- ============================================================================
-- POST-APPLY VALIDATION (correr manualmente; no confiar en que esté aplicado)
-- ============================================================================
-- -- (a) el id AF ahora resuelve al ESPN canónico
-- SELECT public.resolver_evento_canonico('af_1635652');
-- -- esperado: {"espn_event_id":"401915449","reason_code":"FUZZY_UNIQUE",...}
--
-- -- (b) el análisis deja de salir en blanco por el id AF
-- SELECT (public.analisis_completo('af_1635652'))->'partido';
-- -- esperado: Borussia Dortmund vs Villarreal (sin 'error')
--
-- -- (c) el camino ESPN directo es idéntico al de antes
-- SELECT (public.analisis_completo('401915449'))->'partido';
--
-- -- (d) fail-closed real: un id AF cuyo cruce equipos+fecha da >1 ESPN
-- --     devuelve IDENTITY_AMBIGUOUS y NO un partido equivocado.
-- --     (buscar un fixture cuyo prefijo-6 colisione; ver los 71 medidos).
--
-- -- (e) UCL sigue sin pick: mercados = null (sin autoridad económica).
-- SELECT (public.analisis_completo('401915449'))->'1_el_resumen'->'mercados';
-- ============================================================================
