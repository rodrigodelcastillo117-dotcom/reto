-- ISS-017 — ARQUITECTURA CANÓNICA NFL.  *** STAGED — NO APLICADO A PROD ***
-- Gate #13 + #18. Se aplica en el cutover coordinado junto al frontend.
--
-- HALLAZGO (trazado en prod): NFL tiene código de modelo interno
-- (nfl_opinion_modelo basado en ESPN FPI; pred_nfl_espn basado en fuerza), pero:
--   - pred_nfl_espn mide Brier 0.246 vs mercado 0.213 (PEOR que el mercado);
--   - la puerta económica mercados_sin_modelo.nfl_sin_modelo está ACTIVA
--     ("NFL no tiene modelo propio; devuelve la cuota sin vig como si fuera prob");
--   - nfl_backtest = 0 filas (nunca validado); muestra ~300 juegos (techo bajo).
-- Regla del contrato: NUNCA presentar la prob no-vig del mercado como P_RETO.
--
-- DECISIÓN: la matriz canónica NFL expone P_RETO = NULL con MODEL_STATUS='NO_OWN_MODEL'.
-- La probabilidad del mercado se expone por SEPARADO y ETIQUETADA como tal
-- (house_no_vig_prob / prob_source='MARKET_NO_VIG'), nunca como probabilidad del modelo.
-- Cuando exista un modelo con skill validado (AUC>=0.55, n>=250, gana LogLoss al
-- no-vig en 2 temporadas) se poblará p_local_gana y MODEL_STATUS pasará a UNVALIDATED/OK.

CREATE OR REPLACE VIEW public.v_prediccion_reto_nfl AS
SELECT np.espn_event_id AS canonical_event_id,
       'football'::text AS sport,
       np.home_team AS home_nombre,
       np.away_team AS away_nombre,
       'NFL'::text   AS liga_nombre,
       np.fecha      AS scheduled_at,
       -- P_RETO: SIN modelo propio validado ⇒ NULL (no se inventa, no se usa el mercado).
       NULL::numeric AS p_local_gana,
       NULL::numeric AS p_empate,
       NULL::numeric AS p_visita_gana,
       NULL::text    AS lo_mas_probable_1x2,
       NULL::numeric AS mejor_1x2_pct,
       NULL::numeric AS p_btts_yes,
       NULL::numeric AS p_btts_no,
       NULL::numeric AS linea_ou,
       NULL::numeric AS p_over,
       NULL::numeric AS p_under,
       'NO_MODELO_PROPIO'::text AS prob_source,
       'NO_OWN_MODEL'::text     AS model_status,
       NULL::numeric AS calidad,
       NULL::numeric AS reto_score,
       'NO_DISPONIBLE_MODELO'::text AS btts_status,
       'nfl_no_model'::text AS score_version,
       -- Mercado ETIQUETADO (nunca como P_RETO). Para mostrar "lo que implica la casa".
       round(100 * np.p_home, 1) AS house_no_vig_home_pct,
       round(100 * np.p_away, 1) AS house_no_vig_away_pct
FROM nfl_partidos np
WHERE np.estado = 'scheduled'
  AND np.fecha >= now() - interval '6 hours';

-- ROLLBACK: DROP VIEW public.v_prediccion_reto_nfl;
--
-- FRONTEND (cutover): NFL.tsx / NflPremiumPicks.tsx deben mostrar
-- "Probabilidad Reto: no disponible (sin modelo propio)" y la cifra de la casa
-- rotulada "Implícita de la casa (sin vig)", nunca "probabilidad" a secas.
-- nfl_picks_premium (2 filas/juego, prob = no-vig, sin RLS) NO debe alimentar
-- ninguna superficie de "pick"/probabilidad de Reto.
