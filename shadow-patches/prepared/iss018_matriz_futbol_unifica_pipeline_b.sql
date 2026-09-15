-- ISS-018 — UNIFICACIÓN CANÓNICA DE FÚTBOL EN MOTOR B PROVISIONAL.
-- *** STAGED — NO APLICADO A PROD ***. Se aplica sólo en cutover coordinado.
--
-- North star: ¿QUÉ CREE RETO QUE VA A PASAR Y CON QUÉ PROBABILIDAD?
-- P_RETO = probabilidad RAW del Motor B (`fut_predicciones`) para este cutover,
-- MODEL_STATUS=UNVALIDATED cuando la muestra alcanza el piso operativo.
--
-- Reglas duras:
--   * una sola fuente visible de P por evento/mercado;
--   * 1X2 + BTTS salen del mismo Motor B / conjunta Dixon-Coles;
--   * el TOTAL usa la LÍNEA REAL PREMATCH del proveedor, nunca 2.5 hardcodeado;
--   * la línea del mercado sólo define el umbral. NO define P_RETO;
--   * si no existe línea real utilizable, O/U queda NULL (fail-closed);
--   * si muestra < 20, el evento PERMANECE en la matriz pero P_RETO queda NULL y
--     MODEL_STATUS=INSUFFICIENT_SAMPLE. No desaparece y no toma P del mercado;
--   * si no existe fila de Motor B, el evento TAMBIÉN permanece con P_RETO NULL + NO_MODEL;
--   * ninguna predicción generada después del kickoff puede publicar P_RETO;
--   * si existen varias predicciones, se prefiere la más reciente temporalmente segura;
--   * data_asof/model_generated_at quedan expuestos para auditoría temporal.
--
-- La vista conserva el tramo live reciente (-6h) para superficies de partido, pero el
-- flagship/Pick del Día DEBE filtrar scheduled_at >= now() y < now()+48h antes de rankear.

CREATE OR REPLACE FUNCTION public.prob_total_dixon_coles_linea(
  p_lambda_home numeric,
  p_lambda_away numeric,
  p_linea numeric,
  p_max_goals integer DEFAULT 8
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
    'push_pct', round((p_push / p_total) * 100, 1),
    'masa_capturada_pct', round(p_total * 100, 4)
  );
END;
$$;

CREATE OR REPLACE VIEW public.v_prediccion_reto_futbol AS
WITH universe AS (
  -- IMPORTANTE: la matriz no puede hacer desaparecer un partido por falta de Motor B.
  -- El universo lo manda agenda_espn; Motor B se hidrata por LEFT JOIN.
  SELECT
    a.espn_event_id AS canonical_event_id,
    a.fecha AS scheduled_at,
    a.liga_nombre,
    a.home_nombre,
    a.away_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha >= now() - interval '6 hours'
    AND a.fecha <  now() + interval '48 hours'
),
base AS (
  SELECT
    u.*,
    f.fixture_id,
    f.lam_h,
    f.lam_a,
    f.muestra,
    f.marcador_probable,
    f.generado_at,
    f.mercados,
    (f.fixture_id IS NOT NULL) AS model_present,
    (f.generado_at IS NOT NULL AND f.generado_at <= u.scheduled_at) AS temporal_safe
  FROM universe u
  LEFT JOIN LATERAL (
    -- Si hay varias capturas, una fila pre-kickoff válida SIEMPRE gana a una post-kickoff.
    SELECT
      fp.fixture_id,
      fp.lam_h,
      fp.lam_a,
      fp.muestra,
      fp.marcador_probable,
      fp.generado_at,
      fp.mercados
    FROM public.fut_predicciones fp
    JOIN public.ligamx_partidos lp ON lp.id=fp.fixture_id
    WHERE lp.espn_event_id=u.canonical_event_id
    ORDER BY
      CASE WHEN fp.generado_at IS NOT NULL AND fp.generado_at <= u.scheduled_at THEN 0 ELSE 1 END,
      fp.generado_at DESC NULLS LAST,
      fp.fixture_id DESC
    LIMIT 1
  ) f ON true
),
con_linea AS (
  SELECT b.*,
         ol.total_linea AS linea_ou_raw,
         ol.proveedor AS linea_proveedor,
         ol.capturado_at AS linea_capturada_at
  FROM base b
  LEFT JOIN LATERAL (
    SELECT oe.total_linea,oe.proveedor,oe.capturado_at
    FROM public.odds_espn oe
    WHERE oe.espn_event_id=b.canonical_event_id
      AND oe.total_linea IS NOT NULL
      -- Para futuro: hasta ahora. Para iniciado: jamás posterior al kickoff.
      AND oe.capturado_at <= LEAST(now(),b.scheduled_at)
      AND COALESCE(oe.proveedor,'') NOT ILIKE '%Live%'
    ORDER BY
      CASE WHEN oe.proveedor='DraftKings' THEN 0 ELSE 1 END,
      oe.capturado_at DESC NULLS LAST
    LIMIT 1
  ) ol ON true
),
piv AS (
  SELECT
    c.*,
    (
      SELECT max((m.value->>'probabilidad')::numeric)
      FROM jsonb_array_elements(COALESCE(c.mercados,'[]'::jsonb)) m(value)
      WHERE m.value->>'mercado'='Moneyline' AND m.value->>'pick'='Gana local'
    ) AS p_local_raw,
    (
      SELECT max((m.value->>'probabilidad')::numeric)
      FROM jsonb_array_elements(COALESCE(c.mercados,'[]'::jsonb)) m(value)
      WHERE m.value->>'mercado'='Moneyline' AND m.value->>'pick'='Empate'
    ) AS p_empate_raw,
    (
      SELECT max((m.value->>'probabilidad')::numeric)
      FROM jsonb_array_elements(COALESCE(c.mercados,'[]'::jsonb)) m(value)
      WHERE m.value->>'mercado'='Moneyline' AND m.value->>'pick'='Gana visitante'
    ) AS p_visita_raw,
    (
      SELECT max((m.value->>'probabilidad')::numeric)
      FROM jsonb_array_elements(COALESCE(c.mercados,'[]'::jsonb)) m(value)
      WHERE m.value->>'mercado'='BTTS' AND m.value->>'pick'='BTTS Si'
    ) AS p_btts_si_raw,
    (
      SELECT max((m.value->>'probabilidad')::numeric)
      FROM jsonb_array_elements(COALESCE(c.mercados,'[]'::jsonb)) m(value)
      WHERE m.value->>'mercado'='BTTS' AND m.value->>'pick'='BTTS No'
    ) AS p_btts_no_raw,
    (
      SELECT max(((m.value->'respaldo')->>'muestra')::integer)
      FROM jsonb_array_elements(COALESCE(c.mercados,'[]'::jsonb)) m(value)
      WHERE m.value->>'mercado'='Moneyline'
    ) AS muestra_cal
  FROM con_linea c
),
calc AS (
  SELECT p.*,
         (
           p.model_present
           AND p.temporal_safe
           AND COALESCE(p.muestra,0) >= 20
           AND p.p_local_raw IS NOT NULL
           AND p.p_empate_raw IS NOT NULL
           AND p.p_visita_raw IS NOT NULL
         ) AS probability_ready,
         CASE
           WHEN p.model_present
            AND p.temporal_safe
            AND COALESCE(p.muestra,0) >= 20
            AND p.linea_ou_raw IS NOT NULL
            -- Sólo half-point hoy: sin push, P(over)+P(under)≈100.
            AND mod((p.linea_ou_raw * 2)::numeric,2)=1
           THEN public.prob_total_dixon_coles_linea(p.lam_h,p.lam_a,p.linea_ou_raw,8)
           ELSE NULL
         END AS total_probs
  FROM piv p
)
SELECT
  canonical_event_id,
  'soccer'::text AS sport,
  home_nombre,
  away_nombre,
  liga_nombre,
  scheduled_at,

  CASE WHEN probability_ready THEN p_local_raw END AS p_local_gana,
  CASE WHEN probability_ready THEN p_empate_raw END AS p_empate,
  CASE WHEN probability_ready THEN p_visita_raw END AS p_visita_gana,
  CASE WHEN probability_ready THEN
    CASE WHEN p_local_raw >= GREATEST(p_empate_raw,p_visita_raw) THEN home_nombre
         WHEN p_visita_raw >= p_empate_raw THEN away_nombre
         ELSE 'Empate'::text END
  END AS lo_mas_probable_1x2,
  CASE WHEN probability_ready THEN GREATEST(p_local_raw,p_empate_raw,p_visita_raw) END AS mejor_1x2_pct,

  CASE WHEN probability_ready THEN p_btts_si_raw END AS p_btts_yes,
  CASE WHEN probability_ready THEN p_btts_no_raw END AS p_btts_no,
  CASE WHEN probability_ready AND total_probs IS NOT NULL THEN linea_ou_raw END AS linea_ou,
  CASE WHEN probability_ready AND total_probs IS NOT NULL THEN (total_probs->>'over_pct')::numeric END AS p_over,
  CASE WHEN probability_ready AND total_probs IS NOT NULL THEN (total_probs->>'under_pct')::numeric END AS p_under,

  'fut_predicciones_dixon_coles_b_provisional'::text AS prob_source,
  CASE
    WHEN NOT model_present THEN 'NO_MODEL'
    WHEN NOT temporal_safe THEN 'TEMPORAL_UNSAFE'
    WHEN COALESCE(muestra,0) < 20 THEN 'INSUFFICIENT_SAMPLE'
    WHEN p_local_raw IS NULL OR p_empate_raw IS NULL OR p_visita_raw IS NULL THEN 'NO_MODEL'
    ELSE 'UNVALIDATED'
  END::text AS model_status,
  CASE WHEN model_present
    THEN LEAST(1.0,COALESCE(muestra_cal,muestra,0)::numeric/40.0)
  END AS calidad,
  CASE WHEN probability_ready THEN
    round(
      GREATEST(p_local_raw,p_empate_raw,p_visita_raw)
      * (0.6 + 0.4 * LEAST(1.0,COALESCE(muestra_cal,muestra,0)::numeric/40.0)),
      1
    )
  END AS reto_score,
  CASE
    WHEN NOT model_present THEN 'NO_MODEL'
    WHEN NOT temporal_safe THEN 'TEMPORAL_UNSAFE'
    WHEN COALESCE(muestra,0) < 20 THEN 'INSUFFICIENT_SAMPLE'
    WHEN probability_ready AND p_btts_si_raw IS NOT NULL AND p_btts_no_raw IS NOT NULL THEN 'DIXON_COLES_JOINT'
    ELSE 'NO_DISPONIBLE_MODELO'
  END::text AS btts_status,
  'v0_provisional'::text AS score_version,

  -- Metadatos de auditoría/modelo. No son probabilidades nuevas.
  lam_h AS lambda_home,
  lam_a AS lambda_away,
  CASE WHEN lam_h IS NOT NULL AND lam_a IS NOT NULL THEN round(lam_h+lam_a,3) END AS expected_goals_total,
  marcador_probable,
  muestra AS model_sample,
  20::integer AS min_sample_required,
  generado_at AS model_generated_at,
  generado_at AS data_asof,
  temporal_safe,
  linea_ou_raw AS provider_total_line_raw,
  linea_proveedor AS provider_name,
  linea_capturada_at AS provider_line_asof,
  CASE
    WHEN NOT model_present THEN 'NO_MODEL'
    WHEN NOT temporal_safe THEN 'TEMPORAL_UNSAFE'
    WHEN COALESCE(muestra,0) < 20 THEN 'INSUFFICIENT_SAMPLE'
    WHEN p_local_raw IS NULL OR p_empate_raw IS NULL OR p_visita_raw IS NULL THEN 'NO_MODEL'
    WHEN linea_ou_raw IS NULL THEN 'NO_LINE'
    WHEN mod((linea_ou_raw*2)::numeric,2)<>1 THEN 'línea entera/quarter no publicada en contrato O/U actual por riesgo de push'
    ELSE NULL
  END::text AS unavailable_reason
FROM calc;

-- ROLLBACK:
--   restaurar la definición anterior de v_prediccion_reto_futbol;
--   DROP FUNCTION IF EXISTS public.prob_total_dixon_coles_linea(numeric,numeric,numeric,integer);
--
-- VALIDACIÓN OBLIGATORIA AL CUTOVER:
--   1. matriz tiene una fila para TODO agenda_espn soccer en [-6h,+48h];
--   2. ningún registro con model_generated_at > scheduled_at publica P_RETO;
--   3. muestra < 20 permanece visible con P_RETO NULL + INSUFFICIENT_SAMPLE;
--   4. evento sin Motor B permanece visible con P_RETO NULL + NO_MODEL;
--   5. líneas próximas provienen del proveedor y provider_line_asof <= kickoff;
--   6. suma 1X2 ≈ 100 por evento ready;
--   7. suma BTTS ≈ 100 por evento ready;
--   8. para cada línea half-point publicada, p_over + p_under ≈ 100;
--   9. odds/no-vig/EV nunca se usan para calcular P_RETO;
--  10. eventos sin línea real tienen O/U NULL, nunca inventado.
