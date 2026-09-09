-- ISS-018 — UNIFICACIÓN CANÓNICA DE FÚTBOL EN MOTOR B PROVISIONAL.
-- *** STAGED — NO APLICADO A PROD ***. Se aplica sólo en cutover coordinado.
--
-- North star: ¿QUÉ CREE RETO QUE VA A PASAR Y CON QUÉ PROBABILIDAD?
-- P_RETO = probabilidad RAW del Motor B (`fut_predicciones`) para este cutover,
-- MODEL_STATUS=UNVALIDATED. Esto es una decisión operativa provisional, NO una
-- afirmación de superioridad científica definitiva frente a Motor A.
--
-- Reglas duras:
--   * una sola fuente visible de P por evento/mercado;
--   * 1X2 + BTTS salen del mismo Motor B / conjunta Dixon-Coles;
--   * el TOTAL usa la LÍNEA REAL ACTUAL del proveedor, nunca 2.5 hardcodeado;
--   * la línea del mercado sólo define el umbral. NO define P_RETO;
--   * si no existe línea real utilizable, O/U queda NULL (fail-closed).
--
-- La función auxiliar calcula Over/Under sobre la MISMA familia conjunta
-- Poisson + corrección Dixon-Coles (rho por defecto de dixon_coles_tau = -0.15),
-- usando las lambdas persistidas por Motor B. Soporta línea arbitraria; para líneas
-- enteras devuelve push_pct separado. La vista sólo publica O/U cuando la línea es
-- half-point (x.5), que es el universo actual observado del proveedor, de forma que
-- P(Over)+P(Under)≈100 sin ocultar pushes.

CREATE OR REPLACE FUNCTION public.prob_total_dixon_coles_linea(
  p_lambda_home numeric,
  p_lambda_away numeric,
  p_linea numeric,
  p_max_goals integer DEFAULT 6
)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path TO 'public'
AS $$
DECLARE
  i integer;
  j integer;
  s integer;
  p numeric;
  tau numeric;
  p_adj numeric;
  p_total numeric := 0;
  p_over numeric := 0;
  p_under numeric := 0;
  p_push numeric := 0;
BEGIN
  IF p_lambda_home IS NULL OR p_lambda_away IS NULL OR p_linea IS NULL
     OR p_lambda_home <= 0 OR p_lambda_away <= 0
     OR p_lambda_home > 8 OR p_lambda_away > 8 THEN
    RETURN NULL;
  END IF;

  FOR i IN 0..p_max_goals LOOP
    FOR j IN 0..p_max_goals LOOP
      p := public.poisson_prob(p_lambda_home, i) * public.poisson_prob(p_lambda_away, j);
      tau := public.dixon_coles_tau(i, j, p_lambda_home, p_lambda_away);
      p_adj := p * tau;
      p_total := p_total + p_adj;
      s := i + j;

      IF s > p_linea THEN
        p_over := p_over + p_adj;
      ELSIF s < p_linea THEN
        p_under := p_under + p_adj;
      ELSE
        p_push := p_push + p_adj;
      END IF;
    END LOOP;
  END LOOP;

  IF p_total <= 0 THEN
    RETURN NULL;
  END IF;

  RETURN jsonb_build_object(
    'linea', p_linea,
    'over_pct', round((p_over / p_total) * 100, 1),
    'under_pct', round((p_under / p_total) * 100, 1),
    'push_pct', round((p_push / p_total) * 100, 1)
  );
END;
$$;

CREATE OR REPLACE VIEW public.v_prediccion_reto_futbol AS
WITH linea_actual AS (
  -- Preferimos la feed pregame estándar del proveedor. Si no existe, usamos la
  -- observación no-live más reciente disponible. La cuota/probabilidad implícita
  -- NO entra al modelo; sólo `total_linea` define el umbral que se evalúa.
  SELECT DISTINCT ON (oe.espn_event_id)
         oe.espn_event_id,
         oe.total_linea,
         oe.proveedor,
         oe.capturado_at
  FROM public.odds_espn oe
  WHERE oe.total_linea IS NOT NULL
    AND oe.capturado_at <= now()
    AND COALESCE(oe.proveedor, '') NOT ILIKE '%Live%'
  ORDER BY oe.espn_event_id,
           CASE WHEN oe.proveedor = 'DraftKings' THEN 0 ELSE 1 END,
           oe.capturado_at DESC
),
piv AS (
  SELECT lp.espn_event_id AS canonical_event_id,
         f.fecha AS scheduled_at,
         f.liga_nombre,
         f.home_nombre,
         f.away_nombre,
         f.lam_h,
         f.lam_a,
         f.muestra,
         la.total_linea AS linea_ou,
         max((m.value->>'probabilidad')::numeric)
           FILTER (WHERE m.value->>'mercado'='Moneyline' AND m.value->>'pick'='Gana local') AS p_local,
         max((m.value->>'probabilidad')::numeric)
           FILTER (WHERE m.value->>'mercado'='Moneyline' AND m.value->>'pick'='Empate') AS p_empate,
         max((m.value->>'probabilidad')::numeric)
           FILTER (WHERE m.value->>'mercado'='Moneyline' AND m.value->>'pick'='Gana visitante') AS p_visita,
         max((m.value->>'probabilidad')::numeric)
           FILTER (WHERE m.value->>'mercado'='BTTS' AND m.value->>'pick'='BTTS Si') AS p_btts_si,
         max((m.value->>'probabilidad')::numeric)
           FILTER (WHERE m.value->>'mercado'='BTTS' AND m.value->>'pick'='BTTS No') AS p_btts_no,
         bool_or(((m.value->'respaldo')->>'confiable')::boolean)
           FILTER (WHERE m.value->>'mercado'='Moneyline') AS ml_confiable,
         max(((m.value->'respaldo')->>'muestra')::integer)
           FILTER (WHERE m.value->>'mercado'='Moneyline') AS muestra_cal
  FROM public.fut_predicciones f
  JOIN public.ligamx_partidos lp ON lp.id = f.fixture_id
  LEFT JOIN linea_actual la ON la.espn_event_id = lp.espn_event_id,
  LATERAL jsonb_array_elements(f.mercados) m(value)
  WHERE f.fecha > now() - interval '6 hours'
    AND f.muestra >= 20
    AND lp.espn_event_id IS NOT NULL
  GROUP BY lp.espn_event_id, f.fecha, f.liga_nombre, f.home_nombre, f.away_nombre,
           f.lam_h, f.lam_a, f.muestra, la.total_linea
),
calc AS (
  SELECT p.*,
         CASE
           -- half-point line only: no push, complement invariant is exact up to truncation/rounding.
           WHEN p.linea_ou IS NOT NULL
                AND mod((p.linea_ou * 2)::numeric, 2) = 1
           THEN public.prob_total_dixon_coles_linea(p.lam_h, p.lam_a, p.linea_ou, 6)
           ELSE NULL
         END AS total_probs
  FROM piv p
)
SELECT canonical_event_id,
       'soccer'::text AS sport,
       home_nombre,
       away_nombre,
       liga_nombre,
       scheduled_at,
       p_local AS p_local_gana,
       p_empate AS p_empate,
       p_visita AS p_visita_gana,
       CASE WHEN p_local >= GREATEST(p_empate, p_visita) THEN home_nombre
            WHEN p_visita >= p_empate THEN away_nombre
            ELSE 'Empate'::text END AS lo_mas_probable_1x2,
       GREATEST(p_local, p_empate, p_visita) AS mejor_1x2_pct,
       p_btts_si AS p_btts_yes,
       p_btts_no AS p_btts_no,
       CASE WHEN total_probs IS NOT NULL THEN linea_ou ELSE NULL::numeric END AS linea_ou,
       CASE WHEN total_probs IS NOT NULL THEN (total_probs->>'over_pct')::numeric END AS p_over,
       CASE WHEN total_probs IS NOT NULL THEN (total_probs->>'under_pct')::numeric END AS p_under,
       'fut_predicciones_dixon_coles_b_provisional'::text AS prob_source,
       'UNVALIDATED'::text AS model_status,
       LEAST(1.0, COALESCE(muestra_cal, muestra)::numeric / 40.0) AS calidad,
       -- Score de ranking todavía provisional. RETO_SCORE_V1 debe reemplazarlo antes del release.
       round(
         GREATEST(p_local, p_empate, p_visita)
         * (0.6 + 0.4 * LEAST(1.0, COALESCE(muestra_cal, muestra)::numeric / 40.0)),
         1
       ) AS reto_score,
       CASE WHEN p_btts_si IS NOT NULL AND p_btts_no IS NOT NULL
            THEN 'DIXON_COLES_JOINT'
            ELSE 'NO_DISPONIBLE_MODELO' END AS btts_status,
       'v0_provisional'::text AS score_version
FROM calc;

-- ROLLBACK:
--   restaurar la definición anterior de v_prediccion_reto_futbol;
--   DROP FUNCTION IF EXISTS public.prob_total_dixon_coles_linea(numeric,numeric,numeric,integer);
--
-- VALIDACIÓN OBLIGATORIA AL CUTOVER (antes del browser smoke):
--   1. líneas próximas observadas deben provenir del proveedor (hoy: 1.5/2.5/3.5/4.5), no hardcode;
--   2. suma 1X2 ≈ 100 por evento;
--   3. suma BTTS ≈ 100 por evento;
--   4. para cada línea half-point publicada, p_over + p_under ≈ 100;
--   5. la línea usada coincide con la observación actual elegida de odds_espn;
--   6. odds/no-vig/EV nunca se usan para calcular P_RETO;
--   7. eventos sin línea real quedan conectados pero con O/U NULL, nunca inventado.
