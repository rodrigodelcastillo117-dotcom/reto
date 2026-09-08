-- ISS-018 — UNIFICACIÓN DE LA MATRIZ DE FÚTBOL EN UN SOLO MOTOR.
-- *** STAGED — NO APLICADO A PROD *** (gate #18). Se aplica en el cutover coordinado.
--
-- ============================ POR QUÉ ============================
-- Había DOS motores de fútbol que se contradicen (bug histórico #206, nunca medido):
--   A) analisis_partidos.analisis_json  → v_prediccion_reto_futbol (lo que agregué
--      esta sesión). calcular_lambdas_futbol + modelo_poisson_dixon_coles. SIN
--      instrumentación de calibración. Cobertura ~33 eventos/48h.
--   B) fut_predicciones (matriz_marcadores / mercados_desde_matriz) → v_picks_futbol_calibrado
--      → v_pick_canonico. ES el motor que YA alimenta TODO el valor de la app
--      (Favoritos, Oráculo, Premium, Picks, Dashboard, Parlay, EV/Kelly/es_pick) y el
--      único con muestra (n≈5-9k), buckets confiable y Brier (v_brier_resumen).
--      Cobertura ~15 eventos/48h (piso muestra>=20).
--
-- MEDICIÓN (mismos eventos, hoy): A y B discrepan 17-24pp y ELIGEN GANADORES DISTINTOS
--   (CF Montréal: A→Charlotte 38.9% vs B→visita 62.7%; Vancouver: A 71.4% vs B 49.2%…).
--
-- DECISIÓN (regla del usuario: UNA sola fuente de probabilidad de evento; la fiabilidad
-- predictiva manda; si la calibración no está validada, P_RETO = crudo y NO_VALIDADO):
--   * Se unifica en el MOTOR B. Razón: la capa de valor (v_pick_canonico y todo EV/Kelly)
--     está construida sobre B y es inamovible sin cirugía de dinero; B es el único con
--     instrumentación de fiabilidad; unificar la PREDICCIÓN en B hace que predicción =
--     valor POR CONSTRUCCIÓN (cero cross-screen mismatch), que es el objetivo.
--   * La calibración es no-op (+0) en ML/OU/BTTS (medido: subía el Brier), así que la
--     probabilidad de B ya es la CRUDA Dixon-Coles → P_RETO = cruda, model_status=NO_VALIDADO.
--   * Costo honesto: la predicción se muestra SOLO donde el motor con muestra>=20 la tiene
--     (~15 vs ~33). Los eventos sin muestra suficiente NO muestran probabilidad inventada.
--   * El motor A (analisis_json) se RETIRA como fuente de PREDICCIÓN; analisis_json sigue
--     válido para el TEXTO cualitativo del análisis, no para P_RETO.
--   * ABIERTO/HONESTO: cuál de los dos motores es más preciso NO está medido (#206). Se
--     elige B por coherencia + instrumentación, no por exactitud probada. La validación
--     (backtest A vs B vs mercado) queda marcada como pendiente, sin fabricar veredicto.
--
-- El frontend lee v_prediccion_reto_futbol POR NOMBRE con las MISMAS columnas, así que
-- este repunte de fuente es transparente para las 6 superficies ya cableadas.
-- BTTS: ahora REAL desde la MISMA conjunta (BTTS Si/No del array mercados), suma ≈100.
--
-- Contrato de columnas idéntico al vigente (22 columnas) para no romper el hook.

CREATE OR REPLACE VIEW public.v_prediccion_reto_futbol AS
WITH piv AS (
  SELECT lp.espn_event_id AS canonical_event_id,
         f.fecha       AS scheduled_at,
         f.liga_nombre,
         f.home_nombre,
         f.away_nombre,
         f.muestra,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='Moneyline'  AND m.value->>'pick'='Gana local')      AS p_local,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='Moneyline'  AND m.value->>'pick'='Empate')          AS p_empate,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='Moneyline'  AND m.value->>'pick'='Gana visitante')  AS p_visita,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='Over/Under' AND m.value->>'pick'='Over 2.5')        AS p_over25,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='Over/Under' AND m.value->>'pick'='Under 2.5')       AS p_under25,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='BTTS'       AND m.value->>'pick'='BTTS Si')         AS p_btts_si,
         max((m.value->>'probabilidad')::numeric) FILTER (WHERE m.value->>'mercado'='BTTS'       AND m.value->>'pick'='BTTS No')         AS p_btts_no,
         bool_or(((m.value->'respaldo')->>'confiable')::boolean) FILTER (WHERE m.value->>'mercado'='Moneyline') AS ml_confiable,
         max(((m.value->'respaldo')->>'muestra')::integer)       FILTER (WHERE m.value->>'mercado'='Moneyline') AS muestra_cal
  FROM fut_predicciones f
  JOIN ligamx_partidos lp ON lp.id = f.fixture_id,
  LATERAL jsonb_array_elements(f.mercados) m(value)
  WHERE f.fecha > now() - interval '6 hours'
    AND f.muestra >= 20
    AND lp.espn_event_id IS NOT NULL
  GROUP BY 1,2,3,4,5,6
)
SELECT canonical_event_id,
       'soccer'::text AS sport,
       home_nombre,
       away_nombre,
       liga_nombre,
       scheduled_at,
       p_local  AS p_local_gana,
       p_empate AS p_empate,
       p_visita AS p_visita_gana,
       CASE WHEN p_local >= GREATEST(p_empate, p_visita) THEN home_nombre
            WHEN p_visita >= p_empate THEN away_nombre
            ELSE 'Empate'::text END AS lo_mas_probable_1x2,
       GREATEST(p_local, p_empate, p_visita) AS mejor_1x2_pct,
       p_btts_si AS p_btts_yes,
       p_btts_no AS p_btts_no,
       2.5::numeric AS linea_ou,
       p_over25  AS p_over,
       p_under25 AS p_under,
       'fut_predicciones_dixon_coles'::text AS prob_source,
       'NO_VALIDADO'::text AS model_status,
       LEAST(1.0, COALESCE(muestra_cal, muestra)::numeric / 40.0) AS calidad,   -- proxy de suficiencia muestral
       -- reto_score provisional; ISS-019 (RETO_SCORE_V1) lo sustituye en el cutover.
       round(GREATEST(p_local, p_empate, p_visita) * (0.6 + 0.4 * LEAST(1.0, COALESCE(muestra_cal, muestra)::numeric / 40.0)), 1) AS reto_score,
       CASE WHEN p_btts_si IS NOT NULL THEN 'DIXON_COLES_JOINT' ELSE 'NO_DISPONIBLE_MODELO' END AS btts_status,
       'v0_provisional'::text AS score_version
FROM piv;

-- ROLLBACK (volver al motor A): re-aplicar iss015b_matriz_btts_honesto_scorev0.sql.
--
-- VALIDACIÓN AL APLICAR (cutover, antes del smoke):
--   * suma 1X2 ≈ 100, suma BTTS ≈ 100, O/U 2.5 suma ≈ 100 por evento;
--   * mejor_1x2_pct y O/U COINCIDEN con v_pick_canonico para los mismos eventos
--     (mismo array mercados) → CROSS_SCREEN_P_MISMATCHES(fútbol)=0;
--   * cobertura ~15 eventos/48h (esperado por el piso muestra>=20).
