-- ============================================================================
-- evidencia_suficiencia_v1 — SUFICIENCIA EMPÍRICA DERIVADA, NO DECRETADA
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY.
--
-- MOTIVO: "n >= 50 => usar_modelo" es un umbral arbitrario. Esta función deriva
-- la suficiencia de la INCERTIDUMBRE del propio delta, no de un conteo.
--
-- MÉTODO: bootstrap por remuestreo con reemplazo sobre los pares
-- (probabilidad, resultado). Para cada réplica se calcula
--     delta = Brier(modelo) - Brier(benchmark)
-- y se toma el intervalo percentil [2.5, 97.5].
--
--   · Si el IC completo está por DEBAJO de 0  -> el modelo es mejor con evidencia
--   · Si el IC completo está por ENCIMA de 0  -> el benchmark es mejor
--   · Si el IC CRUZA 0                        -> INSUFFICIENT_EVIDENCE
--
-- El tamaño muestral entra donde debe: a menor n, más ancho el IC, y más difícil
-- que excluya el 0. No hace falta decretar un mínimo — emerge de los datos.
--
-- IMPORTANTE: sin benchmark de mercado NO se fabrica comparación. Si p_bench es
-- NULL el resultado es NO_BENCHMARK, que es un estado legítimo, no un fallo.
--
-- Determinista: la semilla es un parámetro, de modo que dos ejecuciones con la
-- misma semilla dan el mismo intervalo (auditable).
-- ============================================================================
CREATE OR REPLACE FUNCTION public.evidencia_suficiencia_v1(
  p_prob_modelo  numeric[],   -- probabilidad del modelo para el evento observado
  p_prob_bench   numeric[],   -- probabilidad del benchmark (NULL => sin benchmark)
  p_resultado    int[],       -- 1 si ocurrió, 0 si no
  p_reps         int  DEFAULT 2000,
  p_seed         numeric DEFAULT 0.42
) RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE   -- usa random(); marcarla STABLE sería mentir sobre su contrato
AS $function$
DECLARE
  n int;
  brier_m numeric; brier_b numeric; delta numeric;
  lo numeric; hi numeric;
  veredicto text; reason text;
BEGIN
  n := COALESCE(array_length(p_resultado,1),0);

  IF n = 0 THEN
    RETURN jsonb_build_object('sufficiency','NO_DATA','reason_code','EMPTY_SAMPLE','n',0);
  END IF;
  IF array_length(p_prob_modelo,1) <> n THEN
    RETURN jsonb_build_object('sufficiency','INVALID','reason_code','LENGTH_MISMATCH','n',n);
  END IF;

  -- Brier observado del modelo
  SELECT round(avg(power(p_prob_modelo[i] - p_resultado[i], 2)),6) INTO brier_m
    FROM generate_series(1,n) i;

  IF p_prob_bench IS NULL OR array_length(p_prob_bench,1) <> n THEN
    RETURN jsonb_build_object(
      'sufficiency','NO_BENCHMARK',
      'reason_code','BENCHMARK_ABSENT_NO_COMPARISON_FABRICATED',
      'n', n, 'brier_modelo', brier_m,
      'note','Sin benchmark no se fabrica comparación. Estado legítimo, no fallo.');
  END IF;

  SELECT round(avg(power(p_prob_bench[i] - p_resultado[i], 2)),6) INTO brier_b
    FROM generate_series(1,n) i;
  delta := round(brier_m - brier_b, 6);

  -- Bootstrap percentil, determinista por semilla.
  -- OJO: el remuestreo NO puede ir en un LATERAL no correlacionado con la réplica;
  -- el planificador lo evalúa una sola vez y todas las réplicas salen idénticas
  -- (ancho de IC = 0). Se usa un producto cartesiano réplicas x n, donde random()
  -- se evalúa por fila de salida, que es lo que hace falta.
  PERFORM setseed(LEAST(GREATEST(p_seed,-1),1));
  WITH sorteo AS (
    SELECT r.r, 1 + floor(random()*n)::int AS idx
      FROM generate_series(1,p_reps) r(r)
      CROSS JOIN generate_series(1,n) g(g)
  ), reps AS (
    SELECT r,
           avg(power(p_prob_modelo[idx] - p_resultado[idx],2))
         - avg(power(p_prob_bench[idx]  - p_resultado[idx],2)) AS d
      FROM sorteo GROUP BY r)
  SELECT round(percentile_cont(0.025) WITHIN GROUP (ORDER BY d)::numeric,6),
         round(percentile_cont(0.975) WITHIN GROUP (ORDER BY d)::numeric,6)
    INTO lo, hi FROM reps;

  IF hi < 0 THEN
    veredicto := 'SUFFICIENT'; reason := 'MODEL_BETTER_CI_EXCLUDES_ZERO';
  ELSIF lo > 0 THEN
    veredicto := 'SUFFICIENT'; reason := 'BENCHMARK_BETTER_CI_EXCLUDES_ZERO';
  ELSE
    veredicto := 'INSUFFICIENT'; reason := 'CI_CROSSES_ZERO';
  END IF;

  RETURN jsonb_build_object(
    'sufficiency', veredicto,
    'reason_code', reason,
    'n', n,
    'brier_modelo', brier_m,
    'brier_benchmark', brier_b,
    'delta', delta,
    'ci95_low', lo,
    'ci95_high', hi,
    'ci_width', round(hi-lo,6),
    'model_allowed', (veredicto='SUFFICIENT' AND reason='MODEL_BETTER_CI_EXCLUDES_ZERO'),
    'method','bootstrap_percentile_2000reps',
    'min_n_arbitrary', false);
END $function$;

COMMENT ON FUNCTION public.evidencia_suficiencia_v1(numeric[],numeric[],int[],int,numeric) IS
'Suficiencia empírica por bootstrap del delta de Brier. El tamaño muestral entra vía el ancho del intervalo, no vía un umbral decretado. Sin benchmark devuelve NO_BENCHMARK sin fabricar comparación. min_n_arbitrary=false.';
