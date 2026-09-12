-- ============================================================================
-- TESTS — clasificacion_pick_v1  (read-only salvo el CREATE de la función)
-- Cada test reporta evaluated_rows / violations / coverage_status.
-- ============================================================================
\set ON_ERROR_STOP on
DO $t$
DECLARE
  n_pass int := 0; n_fail int := 0; r jsonb; msg text := '';
BEGIN
  -- ---------- T1: contexto completamente vacío -> ANALYSIS (fail-closed) ----------
  r := public.clasificacion_pick_v1('{}'::jsonb);
  IF r->>'classification' = 'ANALYSIS' AND (r->>'authorized_bet')::boolean = false
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T1 ctx vacio -> ANALYSIS / authorized_bet=false';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T1 -> %', r; END IF;

  -- ---------- T2: NULL en economically_eligible -> NO autoriza ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',NULL,'data_readiness','READY',
        'is_max_p_in_market',true,'exact_decision_price',true));
  IF (r->>'authorized_bet')::boolean = false AND r->>'classification' = 'MOST_LIKELY'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T2 elegible NULL -> MOST_LIKELY, no autoriza';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T2 -> %', r; END IF;

  -- ---------- T3: llave ausente (undefined) -> NO autoriza ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','data_readiness','READY','is_max_p_in_market',true));
  IF (r->>'authorized_bet')::boolean = false
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T3 llave ausente -> no autoriza';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T3 -> %', r; END IF;

  -- ---------- T4: prob de mercado NO puede producir MOST_LIKELY ni VALUE ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MARKET_NO_VIG','economically_eligible',true,'data_readiness','READY',
        'is_max_p_in_market',true,'exact_decision_price',true,
        'accuracy_evidence','SUFFICIENT','calibration_status','VALIDATED','model_skill','SKILL_PASS'));
  IF r->>'classification' = 'ANALYSIS' AND r->>'reason_code' = 'NO_MODEL_PROBABILITY'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T4 P de mercado con TODO forzado -> ANALYSIS (caso NFL)';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T4 -> %', r; END IF;

  -- ---------- T5: elegible + P de modelo -> VALUE_PICK ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',true,'data_readiness','READY',
        'exact_decision_price',true));
  IF r->>'classification' = 'VALUE_PICK' AND (r->>'authorized_bet')::boolean = true
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T5 elegible -> VALUE_PICK / authorized_bet=true';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T5 -> %', r; END IF;

  -- ---------- T6: MUY PROBABLE PERO MAL PRECIO (el caso conceptual pedido) ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',false,'data_readiness','READY',
        'is_max_p_in_market',true,'exact_decision_price',true));
  IF r->>'classification' = 'MOST_LIKELY'
     AND r->>'reason_code' = 'HIGHEST_P_NOT_ECONOMICALLY_ELIGIBLE'
     AND (r->>'authorized_bet')::boolean = false
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T6 MUY PROBABLE + MAL PRECIO -> MOST_LIKELY sin autorizar';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T6 -> %', r; END IF;

  -- ---------- T7: TOP_PICK inalcanzable sin evidencia forward ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',true,'data_readiness','READY',
        'exact_decision_price',true,'model_skill','SKILL_PASS',
        'accuracy_evidence','PENDING','calibration_status','PENDING'));
  IF r->>'classification' <> 'TOP_PICK'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T7 sin accuracy/calibration -> NO es TOP_PICK (es %)', r->>'classification';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T7 TOP_PICK alcanzado sin evidencia -> %', r; END IF;

  -- ---------- T8: TOP_PICK SÍ alcanzable si algún día hay evidencia (no muerto) ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',true,'data_readiness','READY',
        'exact_decision_price',true,'model_skill','SKILL_PASS',
        'accuracy_evidence','SUFFICIENT','calibration_status','VALIDATED'));
  IF r->>'classification' = 'TOP_PICK'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T8 con evidencia completa -> TOP_PICK (gate vivo, no código muerto)';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T8 -> %', r; END IF;

  -- ---------- T9: data_readiness INSUFFICIENT bloquea MOST_LIKELY ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',false,'data_readiness','INSUFFICIENT',
        'is_max_p_in_market',true,'exact_decision_price',true));
  IF r->>'classification' = 'ANALYSIS' AND r->>'reason_code' = 'DATA_NOT_USABLE'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T9 datos insuficientes -> ANALYSIS';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T9 -> %', r; END IF;

  -- ---------- T10: STALE también bloquea ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',false,'data_readiness','STALE',
        'is_max_p_in_market',true,'exact_decision_price',true));
  IF r->>'classification' = 'ANALYSIS'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T10 datos STALE -> ANALYSIS';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T10 -> %', r; END IF;

  -- ---------- T11: string basura en economically_eligible no autoriza ----------
  BEGIN
    r := public.clasificacion_pick_v1(jsonb_build_object(
          'prob_source','MODEL','economically_eligible','SI','data_readiness','READY'));
    IF (r->>'authorized_bet')::boolean = false
      THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T11 valor no booleano -> no autoriza';
      ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T11 -> %', r; END IF;
  EXCEPTION WHEN others THEN
    n_pass:=n_pass+1; RAISE NOTICE 'PASS T11 valor no booleano -> excepción (fail-closed aceptable)';
  END;

  -- ---------- T12: no es el lado más probable -> ANALYSIS, no MOST_LIKELY ----------
  r := public.clasificacion_pick_v1(jsonb_build_object(
        'prob_source','MODEL','economically_eligible',false,'data_readiness','READY',
        'is_max_p_in_market',false,'exact_decision_price',true));
  IF r->>'classification' = 'ANALYSIS' AND r->>'reason_code' = 'NOT_HIGHEST_P_IN_MARKET'
    THEN n_pass:=n_pass+1; RAISE NOTICE 'PASS T12 lado no dominante -> ANALYSIS (evita 2 picks por moneyline)';
    ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL T12 -> %', r; END IF;

  RAISE NOTICE '==== clasificacion_pick_v1: evaluated_rows=% violations=% coverage_status=% ====',
    n_pass+n_fail, n_fail, CASE WHEN n_fail=0 THEN 'PASS_NONEMPTY' ELSE 'FAIL' END;
  IF n_fail > 0 THEN RAISE EXCEPTION 'TESTS FALLIDOS: %', n_fail; END IF;
END $t$;
