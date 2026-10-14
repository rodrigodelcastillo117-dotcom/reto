-- ============================================================================
-- nfl_game_card_v1 — UNA CARD POR PARTIDO, CON PROCEDENCIA EXPLÍCITA
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY.
--
-- PROBLEMA QUE RESUELVE (hallazgo NF-01, probado aritméticamente):
--   nfl_partidos.p_home/p_away son la probabilidad implícita SIN VIG del moneyline
--   del sportsbook. Ejemplo real: ml_home=-122 -> 122/222 = 0.549550;
--   ml_away=+102 -> 100/202 = 0.495050; suma 1.0446 = vig registrado 0.0446;
--   no-vig = 0.549550/1.0446 = 0.526095 = p_home almacenado 0.52609.
--   563/563 filas cumplen p_home+p_away=1. corr(p_home,-spread)=0.99 (n=562).
--   => NO contienen ningún componente de modelo.
--
--   nfl_picks_premium las publica como `prob` y emite UNA FILA POR LADO del
--   moneyline, de modo que cada partido genera dos "picks premium".
--
-- ESTRATEGIA: vista NUEVA (aditiva). NO se altera nfl_picks_premium en este
-- patch — cambiar su contrato requiere el mismo cuidado ordinal que ISS-003/009
-- y saber antes qué pantalla la consume. Aquí se ofrece el reemplazo correcto;
-- la retirada de la vista vieja es un paso posterior con inventario de consumo.
--
-- CONTRATO: 1 fila = 1 PARTIDO. Los mercados van anidados en JSON.
-- Ninguna columna se llama `prob` a secas. Toda probabilidad lleva su fuente.
-- ============================================================================
CREATE OR REPLACE VIEW public.nfl_game_card_v1 AS
SELECT
  p.espn_event_id,
  p.fecha                        AS kickoff,
  p.semana,
  p.tipo_temporada,
  p.home_team,
  p.away_team,
  p.estado,
  p.casa                         AS book,
  p.actualizado                  AS odds_timestamp,

  -- ---- VISTA DE MERCADO (única fuente de probabilidad hoy disponible) ----
  -- Nombres explícitos: nadie puede confundir esto con predicción propia.
  p.ml_home                      AS ml_home_american,
  p.ml_away                      AS ml_away_american,
  p.spread,
  p.total_linea,
  p.vig                          AS market_vig,
  p.p_home                       AS house_no_vig_prob_home,
  p.p_away                       AS house_no_vig_prob_away,
  'MARKET_NO_VIG'::text          AS prob_source,
  NULL::text                     AS model_version,      -- no existe modelo NFL
  NULL::numeric                  AS model_prob_home,    -- reservado, hoy NULL
  NULL::numeric                  AS model_prob_away,
  'INSUFFICIENT'::text           AS nfl_model_skill,
  false                          AS economically_eligible,
  'NFL_MODEL_NOT_AUTHORIZED'::text AS eligibility_reason_code,
  0::numeric                     AS stake_final,

  -- ---- SEÑAL DE INCOHERENCIA DE LÍNEA (no es predicción) ----
  -- nfl_mejor_pick compara la implícita del ML contra la implícita del spread.
  -- Es un diagnóstico interno del mercado. Se expone etiquetado como tal,
  -- con su magnitud, y NUNCA como recomendación.
  m.pick                         AS line_incoherence_detail,
  m.mercado                      AS line_incoherence_market,
  m.magnitud                     AS line_incoherence_points,
  'MARKET_INTERNAL_DIAGNOSTIC'::text AS line_incoherence_kind,

  -- ---- CLASIFICACIÓN CANÓNICA ----
  -- Con prob_source='MARKET_NO_VIG', clasificacion_pick_v1 devuelve siempre
  -- ANALYSIS / NO_MODEL_PROBABILITY. Verificado en test T4.
  public.clasificacion_pick_v1(jsonb_build_object(
    'prob_source','MARKET_NO_VIG',
    'economically_eligible', false,
    'data_readiness', CASE WHEN p.ml_home IS NOT NULL AND p.actualizado IS NOT NULL
                           THEN 'PARTIAL' ELSE 'MISSING' END,
    'exact_decision_price', (p.ml_home IS NOT NULL)
  )) AS clasificacion,

  -- ---- CONTEXTO (sin inventar nada) ----
  p.techado, p.temperatura, p.viento_rafaga, p.precipitacion,
  p.out_home, p.out_away,
  (p.qb_comprometido_home OR p.qb_comprometido_away) AS qb_comprometido
FROM public.nfl_partidos p
LEFT JOIN LATERAL public.nfl_mejor_pick(p.espn_event_id)
  m(pick, mercado, confianza, "señal", detalle, magnitud) ON true
WHERE p.estado = 'scheduled' AND p.fecha > (now() - interval '3 hours');

COMMENT ON VIEW public.nfl_game_card_v1 IS
'Una fila por PARTIDO NFL. house_no_vig_prob_* es probabilidad del sportsbook sin vig (prob_source=MARKET_NO_VIG), NUNCA del modelo: no existe modelo NFL. model_prob_* reservado y hoy NULL. line_incoherence_* es diagnóstico interno del mercado, no recomendación. economically_eligible siempre false y stake_final siempre 0 mientras NFL_ECONOMIC_AUTHORITY=FALSE.';
