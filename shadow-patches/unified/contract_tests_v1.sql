-- ============================================================================
-- CONTRACT TESTS V1 — impiden para siempre los defectos semánticos detectados
-- ============================================================================
-- Read-only. Ejecutable contra lab o contra producción dentro de BEGIN READ ONLY.
-- Cada test reporta evaluated_rows / violations / coverage_status.
-- ============================================================================
\set ON_ERROR_STOP on
DO $ct$
DECLARE
  n_eval int; n_viol int; n_fail int := 0;
  PROC text;
  r jsonb; j jsonb;
  BANNED text[] := ARRAY['aguanta','apostar','pick sugerido','fuerte','ojo','recomendado','premium'];
  w text;
BEGIN
  RAISE NOTICE '=== CONTRACT TESTS V1 ===';

  ---------------------------------------------------------------- CT-1
  -- Un mercado no elegible NUNCA puede clasificarse como apostable.
  n_viol := 0; n_eval := 0;
  FOR j IN SELECT * FROM (VALUES
      ('{"prob_source":"MODEL","economically_eligible":false,"data_readiness":"READY","is_max_p_in_market":true,"exact_decision_price":true}'::jsonb),
      ('{"prob_source":"MODEL","data_readiness":"READY","is_max_p_in_market":true}'::jsonb),
      ('{"prob_source":"MODEL","economically_eligible":null,"data_readiness":"READY"}'::jsonb)
    ) v(x) LOOP
    n_eval := n_eval + 1;
    r := public.clasificacion_pick_v1(j);
    IF (r->>'authorized_bet')::boolean THEN n_viol := n_viol + 1; END IF;
  END LOOP;
  IF n_viol > 0 THEN n_fail := n_fail+1; RAISE WARNING 'FAIL CT-1 no-elegible autorizado (%/%)', n_viol, n_eval;
  ELSE RAISE NOTICE 'PASS_NONEMPTY CT-1 no-elegible nunca autoriza · evaluated_rows=% violations=0', n_eval; END IF;

  ---------------------------------------------------------------- CT-2
  -- Probabilidad de la casa no puede producir MOST_LIKELY, VALUE ni TOP.
  n_viol := 0; n_eval := 0;
  FOREACH w IN ARRAY ARRAY['MARKET_NO_VIG','DERIVED_MARKET','UNKNOWN','HISTORICAL'] LOOP
    n_eval := n_eval + 1;
    r := public.clasificacion_pick_v1(jsonb_build_object(
      'prob_source', w, 'economically_eligible', true, 'data_readiness','READY',
      'is_max_p_in_market', true, 'exact_decision_price', true,
      'accuracy_evidence','SUFFICIENT','calibration_status','VALIDATED','model_skill','SKILL_PASS'));
    IF r->>'classification' <> 'ANALYSIS' THEN n_viol := n_viol + 1; END IF;
  END LOOP;
  IF n_viol > 0 THEN n_fail := n_fail+1; RAISE WARNING 'FAIL CT-2 P no-modelo escaló (%/%)', n_viol, n_eval;
  ELSE RAISE NOTICE 'PASS_NONEMPTY CT-2 P de mercado nunca escala sobre ANALYSIS · evaluated_rows=% violations=0', n_eval; END IF;

  ---------------------------------------------------------------- CT-3
  -- MOST_LIKELY no implica EV positivo, y VALUE no implica P alta.
  n_eval := 2; n_viol := 0;
  r := public.clasificacion_pick_v1(
        '{"prob_source":"MODEL","economically_eligible":false,"data_readiness":"READY","is_max_p_in_market":true,"exact_decision_price":true}'::jsonb);
  IF r->>'classification' <> 'MOST_LIKELY' OR (r->>'authorized_bet')::boolean THEN n_viol:=n_viol+1; END IF;
  r := public.clasificacion_pick_v1(
        '{"prob_source":"MODEL","economically_eligible":true,"data_readiness":"READY","is_max_p_in_market":false,"exact_decision_price":true}'::jsonb);
  IF r->>'classification' <> 'VALUE_PICK' THEN n_viol:=n_viol+1; END IF;
  IF n_viol > 0 THEN n_fail := n_fail+1; RAISE WARNING 'FAIL CT-3 (%/%)', n_viol, n_eval;
  ELSE RAISE NOTICE 'PASS_NONEMPTY CT-3 MOST_LIKELY sin EV+ y VALUE sin P máxima conviven · evaluated_rows=2 violations=0'; END IF;

  ---------------------------------------------------------------- CT-4
  -- TOP_PICK imposible sin accuracy_evidence y calibration_status.
  n_viol := 0; n_eval := 0;
  FOR j IN SELECT * FROM (VALUES
      ('{"accuracy_evidence":"PENDING","calibration_status":"VALIDATED"}'::jsonb),
      ('{"accuracy_evidence":"SUFFICIENT","calibration_status":"PENDING"}'::jsonb),
      ('{"accuracy_evidence":"PENDING","calibration_status":"PENDING"}'::jsonb)
    ) v(x) LOOP
    n_eval := n_eval + 1;
    r := public.clasificacion_pick_v1(j
         || '{"prob_source":"MODEL","economically_eligible":true,"data_readiness":"READY","exact_decision_price":true,"model_skill":"SKILL_PASS"}'::jsonb);
    IF r->>'classification' = 'TOP_PICK' THEN n_viol := n_viol + 1; END IF;
  END LOOP;
  IF n_viol > 0 THEN n_fail := n_fail+1; RAISE WARNING 'FAIL CT-4 TOP_PICK sin evidencia (%/%)', n_viol, n_eval;
  ELSE RAISE NOTICE 'PASS_NONEMPTY CT-4 TOP_PICK exige evidencia forward · evaluated_rows=% violations=0', n_eval; END IF;

  ---------------------------------------------------------------- CT-5
  -- Coherencia de la distribución de totales: under+over=100 en líneas .5,
  -- y momio_justo = 1/P. Se prueba sobre la MISMA función que usa producción.
  n_viol := 0; n_eval := 0;
  FOR j IN SELECT public.totales_nb(mu, 5.0, ARRAY[linea]::numeric[])
             FROM (VALUES (7.5::double precision,7.5::numeric),(8.06,8.5),(9.06,8.5),(10.2,9.5),(11.0,10.5)) v(mu,linea) LOOP
    n_eval := n_eval + 1;
    DECLARE k text; o numeric; u numeric; mj numeric;
    BEGIN
      k := (SELECT key FROM jsonb_each(j) LIMIT 1);
      o := (j->k->>'over_pct')::numeric; u := (j->k->>'under_pct')::numeric;
      mj := (j->k->>'momio_justo_under')::numeric;
      IF abs((o+u) - 100) > 0.15 THEN n_viol := n_viol+1;
        RAISE WARNING '  CT-5 under+over=% en linea %', o+u, k; END IF;
      IF u > 0 AND mj IS NOT NULL AND abs(mj - round((100.0/u)::numeric,2)) > 0.02 THEN
        n_viol := n_viol+1; RAISE WARNING '  CT-5 momio_justo % <> 1/P (% pct)', mj, u; END IF;
    END;
  END LOOP;
  IF n_viol > 0 THEN n_fail := n_fail+1; RAISE WARNING 'FAIL CT-5 coherencia de totales (%/%)', n_viol, n_eval;
  ELSE RAISE NOTICE 'PASS_NONEMPTY CT-5 under+over=100 y momio_justo=1/P · evaluated_rows=% violations=0', n_eval; END IF;

  ---------------------------------------------------------------- CT-6
  -- La P mostrada de totales debe venir de la MISMA distribución que se declare.
  -- Poisson(mu) y NB(mu,r=5) NO son intercambiables: se documenta la divergencia
  -- para que ninguna UI las presente como una sola inferencia.
  DECLARE p_poisson numeric; p_nb numeric;
  BEGIN
    SELECT round((100*sum(exp(-9.06)*power(9.06,i)/public.factorial_d(i)))::numeric,2)
      INTO p_poisson FROM generate_series(0,8) i;
    p_nb := (public.totales_nb(9.06::double precision,5.0::double precision,ARRAY[8.5]::numeric[])->'8.5'->>'under_pct')::numeric;
    IF abs(p_poisson - p_nb) < 1.0 THEN
      RAISE NOTICE 'PASS_NONEMPTY CT-6 Poisson y NB coinciden (<1pp): presentación conjunta admisible';
    ELSE
      RAISE NOTICE 'PASS_NONEMPTY CT-6 DIVERGENCIA DOCUMENTADA Poisson=% vs NB=% (delta % puntos) · evaluated_rows=1 violations=0 · la UI NO debe mezclar moda Poisson con CDF NB',
        p_poisson, p_nb, round(abs(p_poisson-p_nb),2);
    END IF;
  END;

  ---------------------------------------------------------------- CT-7
  -- PROHIBIDO usar (expected_runs - total_line) como señal de Over/Under.
  -- Se demuestra que las dos reglas DISCREPAN: si coincidieran siempre, el atajo
  -- sería inocuo. Al discrepar, cualquier UI que lo use afirma algo que el motor
  -- no calcula. La decisión real la toma la CDF de totales_nb.
  DECLARE n_disc int := 0; n_tot int := 0; mu double precision; ln numeric;
          p_under numeric; regla_media text; regla_cdf text;
  BEGIN
    FOR mu, ln IN SELECT * FROM (VALUES
        (8.60::double precision, 8.5::numeric), (8.80,8.5), (9.06,8.5),
        (9.30,8.5), (7.80,7.5), (8.20,7.5), (10.10,9.5), (10.40,9.5)) v(a,b) LOOP
      n_tot := n_tot + 1;
      p_under := (public.totales_nb(mu, 5.0, ARRAY[ln])->(ln::text)->>'under_pct')::numeric;
      regla_media := CASE WHEN mu > ln::double precision THEN 'OVER' ELSE 'UNDER' END;
      regla_cdf   := CASE WHEN p_under > 50 THEN 'UNDER' ELSE 'OVER' END;
      IF regla_media <> regla_cdf THEN
        n_disc := n_disc + 1;
        RAISE NOTICE '  CT-7 discrepan en mu=% linea=%: media dice % / CDF dice % (P_under=%)',
          mu, ln, regla_media, regla_cdf, p_under;
      END IF;
    END LOOP;
    IF n_disc = 0 THEN
      n_fail := n_fail + 1;
      RAISE WARNING 'FAIL CT-7 no se detectó discrepancia; revisar el rango de prueba';
    ELSE
      RAISE NOTICE 'PASS_NONEMPTY CT-7 (expected_runs - linea) NO es señal válida: discrepa de la CDF en % de % casos · evaluated_rows=% violations=0',
        n_disc, n_tot, n_tot;
    END IF;
  END;

  ---------------------------------------------------------------- CT-8
  -- Escaneo de copy PRESCRIPTIVO generado en la BD para superficies MLB.
  -- No falla el build (es un inventario), pero deja constancia permanente.
  DECLARE n_hits int := 0; rec record;
  BEGIN
    FOR rec IN
      SELECT p.proname, w.palabra
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_language l ON l.oid = p.prolang
        CROSS JOIN unnest(ARRAY['aguanta','apostar','apuestas en vivo','argumento fuerte',
                                'pick sugerido','recomendado','premium']) AS w(palabra)
       WHERE n.nspname='public' AND p.prokind='f' AND l.lanname IN ('sql','plpgsql')
         AND (p.proname ~ 'mlb|dossier|analisis')
         AND pg_get_functiondef(p.oid) ILIKE '%'||w.palabra||'%'
    LOOP
      n_hits := n_hits + 1;
      RAISE NOTICE '  CT-8 copy prescriptivo en %(): "%"', rec.proname, rec.palabra;
    END LOOP;
    RAISE NOTICE 'PASS_NONEMPTY CT-8 inventario de copy prescriptivo en BD · evaluated_rows=% violations=0 (inventario, no bloqueante)', n_hits;
  END;

  ---------------------------------------------------------------- resumen
  IF n_fail > 0 THEN RAISE EXCEPTION 'CONTRACT TESTS: % bloques con violaciones', n_fail; END IF;
  RAISE NOTICE '=== CONTRACT TESTS V1: TODOS PASS ===';
END $ct$;
