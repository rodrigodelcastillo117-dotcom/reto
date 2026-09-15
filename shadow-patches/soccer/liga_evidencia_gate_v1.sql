-- ============================================================================
-- liga_evidencia_gate_v1 — FAIL-CLOSED POR EVIDENCIA DE LIGA
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY.
--
-- PROBLEMA: public.liga_competencia_modelo ya compara, por liga, el Brier del
-- modelo contra el del mercado y contra la baseline naive, y emite un veredicto
-- ('usar_modelo' / 'usar_mercado' / 'callarse' / 'sin_datos').
-- Ese veredicto NO LO CONSUME NADIE. Consecuencia observada:
--   MLS  -> brier_modelo 0.6834 · brier_mercado 0.6791 · naive 0.6667
--        -> veredicto 'callarse'  (el modelo es PEOR que no saber nada)
--        -> y aun así MLS aporta 112 de las 275 filas de v_pick_canonico.
--   UEFA Champions League -> NI SIQUIERA está registrada (0 partidos evaluados)
--        -> y tiene 18 partidos con odds mañana.
--
-- Esta función traduce ese registro en un gate consumible, con la misma forma
-- que economic_eligibility_v1 y clasificacion_pick_v1.
--
-- FAIL-CLOSED POR DEFECTO: una liga ausente del registro devuelve
-- LEAGUE_NOT_REGISTERED y NO habilita presentación de modelo. Es deliberado:
-- Champions cae aquí, y debe caer aquí.
--
-- NO INVENTA UMBRALES: el único criterio numérico es la comparación de Brier
-- que la propia tabla ya calcula. El tamaño muestral mínimo se recibe como
-- parámetro explícito y sin default silencioso, para que quien lo fije tenga
-- que justificarlo por escrito y no quede escondido como constante mágica.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.liga_evidencia_gate_v1(p_liga text, p_n_minimo int)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
  r record;
  bate_naive   boolean := false;
  bate_mercado boolean := false;
  n_suficiente boolean := false;
  reason text;
  permite_modelo boolean := false;
BEGIN
  IF p_n_minimo IS NULL THEN
    RETURN jsonb_build_object(
      'league_model_allowed', false,
      'reason_code','N_MINIMO_NOT_SPECIFIED',
      'note','El tamaño muestral mínimo debe declararse explícitamente; no hay default.');
  END IF;

  SELECT * INTO r FROM public.liga_competencia_modelo WHERE liga = p_liga;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'league_model_allowed', false,
      'reason_code','LEAGUE_NOT_REGISTERED',
      'verdict', NULL, 'n', 0,
      'note','Liga sin evaluación de competencia. Fail-closed: no se presenta modelo.');
  END IF;

  n_suficiente := COALESCE(r.partidos, 0) >= p_n_minimo;
  bate_naive   := r.brier_modelo IS NOT NULL AND r.brier_naive IS NOT NULL
                  AND r.brier_modelo < r.brier_naive;
  bate_mercado := r.brier_modelo IS NOT NULL AND r.brier_mercado IS NOT NULL
                  AND r.brier_modelo < r.brier_mercado;

  -- El veredicto almacenado manda cuando es restrictivo; nunca se sobreescribe
  -- un 'callarse' porque los números "casi" salgan.
  IF r.veredicto = 'callarse' THEN
    permite_modelo := false; reason := 'LEAGUE_VERDICT_SILENCE';
  ELSIF r.veredicto = 'sin_datos' THEN
    permite_modelo := false; reason := 'LEAGUE_INSUFFICIENT_DATA';
  ELSIF r.veredicto = 'usar_mercado' THEN
    permite_modelo := false; reason := 'MARKET_BEATS_MODEL';
  ELSIF NOT n_suficiente THEN
    permite_modelo := false; reason := 'SAMPLE_TOO_SMALL';
  ELSIF NOT bate_naive THEN
    permite_modelo := false; reason := 'MODEL_NOT_BETTER_THAN_NAIVE';
  ELSE
    permite_modelo := true;
    reason := CASE WHEN bate_mercado THEN 'MODEL_BEATS_NAIVE_AND_MARKET'
                   ELSE 'MODEL_BEATS_NAIVE_ONLY' END;
  END IF;

  RETURN jsonb_build_object(
    'league_model_allowed', permite_modelo,
    'reason_code', reason,
    'verdict', r.veredicto,
    'n', r.partidos,
    'brier_modelo', r.brier_modelo,
    'brier_mercado', r.brier_mercado,
    'brier_naive', r.brier_naive,
    'gates', jsonb_build_object(
      'sample_sufficient', n_suficiente,
      'beats_naive',       bate_naive,
      'beats_market',      bate_mercado,
      'verdict_permissive', r.veredicto IN ('usar_modelo')));
END $function$;

COMMENT ON FUNCTION public.liga_evidencia_gate_v1(text,int) IS
'Traduce liga_competencia_modelo en un gate consumible. Fail-closed: liga no registrada => league_model_allowed=false (Champions cae aquí). Un veredicto ''callarse'' nunca se sobreescribe. El n mínimo es parámetro obligatorio, sin default silencioso.';
