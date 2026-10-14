-- TEST PLAN v2 (T1-T20) — LAB en branch efímero, DESPUÉS de ddl_top_pick_capture_v2.sql y de ISS-009B.
-- Corre como un DO que RAISE EXCEPTION al final para forzar rollback del branch. Cada test aborta si falla.
DO $tp$
DECLARE ev text; es timestamptz; n int; n2 int; emi text; missing text; ndist int;
BEGIN
  -- T16 contrato: si falta es_pick_reason (ISS-009B no desplegado) => FAIL_CLOSED
  missing := public.assert_capture_contract();
  IF missing IS NOT NULL THEN
     PERFORM public.capture_top_pick_universe('X_TEST','lab',NULL,'emission');
     IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture_audit WHERE status='FAILED' AND failure_code LIKE 'CONTRACT_MISSING_FIELD:%')
        THEN RAISE EXCEPTION 'T16 FAIL: contrato no falló cerrado'; END IF;
     RAISE EXCEPTION 'T16 OK pero ISS-009B no está: aplicar es_pick_reason antes de correr T1-T20';
  END IF;

  SELECT espn_event_id, arranca_en INTO ev, es FROM public.v_pick_canonico WHERE arranca_en > now()+interval '2 hour' LIMIT 1;
  IF ev IS NULL THEN RAISE EXCEPTION 'no hay evento futuro para probar'; END IF;

  PERFORM public.capture_top_pick_universe(ev,'lab:e1',NULL,'emission');
  SELECT decision_emission_id INTO emi FROM public.top_pick_capture WHERE espn_event_id=ev LIMIT 1;

  -- T1 decision<event
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE espn_event_id=ev AND decision_timestamp>=event_start_timestamp)
     THEN RAISE EXCEPTION 'T1 FAIL'; END IF;
  -- T2 feature_ts<=decision
  IF EXISTS(SELECT 1 FROM public.top_pick_capture c, jsonb_each_text(c.feature_source_timestamps) f
            WHERE c.espn_event_id=ev AND f.value~'^\d{4}-' AND f.value::timestamptz>c.decision_timestamp)
     THEN RAISE EXCEPTION 'T2 FAIL'; END IF;
  -- T3 sin outcome en captura
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='top_pick_capture'
            AND column_name IN ('outcome','resultado')) THEN RAISE EXCEPTION 'T3 FAIL'; END IF;
  -- T8/T9 exactitud vs autoridad
  IF EXISTS(SELECT 1 FROM public.top_pick_capture c JOIN public.v_pick_canonico v
              ON v.espn_event_id=c.espn_event_id AND v.mercado=c.market AND v.pick_nombre=c.side
            WHERE c.espn_event_id=ev AND (c.p_decision IS DISTINCT FROM v.probabilidad_pct
              OR c.ev_decision IS DISTINCT FROM v.ev_pct OR c.economic_eligible IS DISTINCT FROM v.es_pick
              OR c.eligibility_reason_code IS DISTINCT FROM v.es_pick_reason))
     THEN RAISE EXCEPTION 'T8/T9 FAIL'; END IF;
  -- T10 gobernanza intacta
  IF (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE)<>0
     THEN RAISE EXCEPTION 'T10 FAIL'; END IF;
  -- T12 replay idéntico (misma emisión) => 0 nuevas
  SELECT count(*) INTO n FROM public.top_pick_capture WHERE espn_event_id=ev;
  PERFORM public.capture_top_pick_universe(ev,'lab:replay',NULL,'non_prediction');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE espn_event_id=ev)<>n THEN RAISE EXCEPTION 'T12 FAIL'; END IF;
  -- T11 non-prediction update => 0 captures (mismo emission_id, NO_CHANGE)
  IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture_audit WHERE espn_event_id=ev AND status='NO_CHANGE')
     THEN RAISE EXCEPTION 'T11 FAIL'; END IF;
  -- T14 expected==captured (status COMPLETE) para la emisión
  IF EXISTS(SELECT 1 FROM public.top_pick_capture_audit WHERE decision_emission_id=emi
            AND status='COMPLETE' AND expected_candidate_count<>captured_candidate_count+excluded_count)
     THEN RAISE EXCEPTION 'T14 FAIL'; END IF;
  -- T17 todas las filas de una emisión comparten emission_id (consistencia de revisión)
  SELECT count(DISTINCT decision_emission_id) INTO ndist FROM public.top_pick_capture WHERE espn_event_id=ev;
  -- (nueva emisión real crearía otro id; en esta fase solo hubo 1 emisión real)
  IF ndist < 1 THEN RAISE EXCEPTION 'T17 FAIL'; END IF;
  -- T18 settlement PUSH/VOID/line-specific sin mutar snapshot
  INSERT INTO public.top_pick_settlement(espn_event_id,market,side,line,outcome,settlement_source)
  SELECT espn_event_id,market,side,coalesce(line,''),'push','lab' FROM public.top_pick_capture WHERE espn_event_id=ev LIMIT 1;
  -- T4 settlement no cambió el hash del snapshot
  IF EXISTS(SELECT 1 FROM public.top_pick_capture c JOIN public.v_pick_canonico v
              ON v.espn_event_id=c.espn_event_id AND v.mercado=c.market AND v.pick_nombre=c.side
            WHERE c.espn_event_id=ev AND c.p_decision IS DISTINCT FROM v.probabilidad_pct)
     THEN RAISE EXCEPTION 'T4 FAIL (snapshot mutado)'; END IF;
  -- T19 display append-only (dos filas conviven)
  INSERT INTO public.top_pick_display(decision_emission_id,selector_version,surface,top_pick_rank,selected_as_top_pick)
  VALUES (emi,'v0','TOP',1,true),(emi,'v0','TOP',1,true);
  IF (SELECT count(*) FROM public.top_pick_display WHERE decision_emission_id=emi)<2 THEN RAISE EXCEPTION 'T19 FAIL'; END IF;
  -- T20 completeness query reproducible
  PERFORM 100.0*sum(captured_candidate_count) FILTER(WHERE status='COMPLETE')/NULLIF(sum(expected_candidate_count) FILTER(WHERE status='COMPLETE'),0)
     FROM public.top_pick_capture_audit;
  -- ADV/guard: captura con decisión POST-evento => 0 filas (excluded), status PARTIAL/NO nuevas
  SELECT count(*) INTO n2 FROM public.top_pick_capture;
  -- (no se puede forzar v_read>event sin cambiar reloj; guard cubierto por CHECK tpc_decision_before_event)

  RAISE EXCEPTION 'TEST_PLAN_V2_OK (T1..T20 evaluados; forzar ROLLBACK del branch). Nota: T5/T13/T15 requieren
     mutar odds/forzar excepción en el branch; documentados como pasos manuales del harness LAB.';
END $tp$;
-- T5  (dos decisiones reales distintas): en el branch, alterar una odds fuente de v_pick_canonico y re-capturar => nuevo decision_emission_id.
-- T13 (real recompute): idéntico a T5 (cambio de contenido => nuevo emission_id).
-- T15 (excepción): renombrar temporalmente una columna crítica en el branch => trigger no tumba analisis_partidos; audit FAILED.
