-- ============================================================================
-- clasificacion_pick_v1 — TAXONOMÍA CANÓNICA (ANALYSIS / MOST_LIKELY / VALUE_PICK / TOP_PICK)
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY. Diseñada para ser el ÚNICO lugar donde se decide
-- cómo se presenta un mercado. Modelada sobre economic_eligibility_v1: función
-- pura, STABLE, sin efectos, con gates independientes y reason_code explícito.
--
-- PRINCIPIO DE DISEÑO: no contiene ni un solo umbral numérico inventado.
--   · VALUE_PICK delega íntegramente en economically_eligible (que ya encapsula
--     EV vs ev_threshold y la autorización del modelo).
--   · MOST_LIKELY usa un criterio RELATIVO (ser el lado de mayor P_DECISION dentro
--     de su propio mercado), no un "P > 60%" arbitrario.
--   · TOP_PICK exige la conjunción de todas las evidencias. Hoy es INALCANZABLE
--     por construcción, porque accuracy_evidence y calibration_status no pueden
--     valer 'SUFFICIENT'/'VALIDATED' sin evidencia forward, que no existe.
--
-- FAIL-CLOSED: cualquier entrada ausente, NULL o no reconocida degrada a ANALYSIS.
-- Nunca al revés.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.clasificacion_pick_v1(p_ctx jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  -- Procedencia: sin P de modelo no hay nada que clasificar más allá de análisis.
  prob_source text := upper(COALESCE(p_ctx->>'prob_source',''));
  g_model_p boolean := prob_source = 'MODEL';

  -- Elegibilidad económica: se toma TAL CUAL de economic_eligibility_v1.
  -- Solo TRUE literal cuenta. false/null/undefined -> no elegible (fail-closed).
  g_elig boolean := COALESCE((p_ctx->>'economically_eligible')::boolean, false);

  -- Evidencia empírica de accuracy (forward, fuera de muestra).
  g_acc  boolean := COALESCE(upper(p_ctx->>'accuracy_evidence') = 'SUFFICIENT', false);

  -- Calibración validada (no "parece calibrado": validada contra evidencia).
  g_cal  boolean := COALESCE(upper(p_ctx->>'calibration_status') = 'VALIDATED', false);

  -- Disponibilidad y frescura de datos.
  dr text := upper(COALESCE(p_ctx->>'data_readiness',''));
  g_data_ready   boolean := dr = 'READY';
  g_data_usable  boolean := dr IN ('READY','PARTIAL');

  -- Skill del modelo (mismo vocabulario que economic_eligibility_v1).
  g_skill boolean := COALESCE(upper(p_ctx->>'model_skill') = 'SKILL_PASS', false);

  -- Criterio RELATIVO, no umbral: ¿es el lado más probable de su mercado?
  g_top_side boolean := COALESCE((p_ctx->>'is_max_p_in_market')::boolean, false);

  -- Cordura de precio: existe un precio de decisión identificado temporalmente.
  g_price boolean := COALESCE((p_ctx->>'exact_decision_price')::boolean, false);

  clase  text;
  reason text;
BEGIN
  -- Orden de evaluación: de la exigencia mayor a la menor. El primero que se
  -- cumple gana; si ninguno, ANALYSIS.
  IF g_model_p AND g_elig AND g_acc AND g_cal AND g_data_ready AND g_skill AND g_price THEN
    clase := 'TOP_PICK';      reason := 'ALL_EVIDENCE_GATES_PASS';
  ELSIF g_model_p AND g_elig THEN
    clase := 'VALUE_PICK';    reason := 'ECONOMICALLY_ELIGIBLE';
  ELSIF g_model_p AND g_top_side AND g_data_usable AND NOT g_elig THEN
    clase := 'MOST_LIKELY';   reason := CASE WHEN g_price THEN 'HIGHEST_P_NOT_ECONOMICALLY_ELIGIBLE'
                                             ELSE 'HIGHEST_P_NO_DECISION_PRICE' END;
  ELSE
    clase := 'ANALYSIS';
    reason := CASE
      WHEN NOT g_model_p     THEN 'NO_MODEL_PROBABILITY'
      WHEN NOT g_data_usable THEN 'DATA_NOT_USABLE'
      WHEN NOT g_top_side    THEN 'NOT_HIGHEST_P_IN_MARKET'
      ELSE 'INSUFFICIENT_EVIDENCE' END;
  END IF;

  RETURN jsonb_build_object(
    'classification', clase,
    'reason_code',    reason,
    -- authorized_bet es la ÚNICA llave que el frontend debe usar para decidir si
    -- se puede hablar de apostar. TOP_PICK y VALUE_PICK la ponen en true; el resto no.
    'authorized_bet', (clase IN ('TOP_PICK','VALUE_PICK')),
    'gates', jsonb_build_object(
      'model_probability',     g_model_p,
      'economically_eligible', g_elig,
      'accuracy_evidence',     g_acc,
      'calibration_validated', g_cal,
      'data_readiness_ready',  g_data_ready,
      'data_readiness_usable', g_data_usable,
      'model_skill',           g_skill,
      'is_max_p_in_market',    g_top_side,
      'exact_decision_price',  g_price));
END $function$;

COMMENT ON FUNCTION public.clasificacion_pick_v1(jsonb) IS
'Taxonomía canónica de presentación. Fail-closed: entradas ausentes o NULL degradan a ANALYSIS. TOP_PICK es inalcanzable mientras no exista evidencia forward (accuracy_evidence/calibration_status). No contiene umbrales numéricos.';
