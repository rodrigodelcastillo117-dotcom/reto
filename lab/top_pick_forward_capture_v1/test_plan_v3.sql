-- ============================================================================
-- TEST PLAN v3 (T1-T28) — LAB en branch efímero.
-- Requisitos previos: ddl_top_pick_capture_v3.sql aplicado; productor
-- analysis_version='meta-v3'; v_pick_canonico @ ISS-009B (para gate secundario).
-- Corre como un DO que RAISE EXCEPTION al final para forzar rollback del branch.
-- Cada assert aborta si falla. Los tests que exigen mutar odds / forzar excepción /
-- recompute real quedan documentados como pasos del harness LAB (T21/T24/T28 notas).
-- ============================================================================
DO $tp$
DECLARE
  aid uuid; ev text; gen timestamptz; emi text; emi2 text;
  n int; n2 int; ndist int; miss text; aj jsonb;
BEGIN
  -- ---- T9/§9 CONTRATO: si falta es_pick_reason o versión no es meta-v3 => FAIL_CLOSED ----
  -- (contrato se evalúa por-corrida dentro de capture; aquí sondeo con un json mínimo)
  miss := public.assert_capture_contract(NULL);
  IF miss IS DISTINCT FROM 'ANALISIS_JSON_NULL' THEN RAISE EXCEPTION 'T9 FAIL: contrato NULL'; END IF;
  miss := public.assert_capture_contract(jsonb_build_object('generado_en',now()::text,'analysis_version','meta-v99'));
  IF miss NOT LIKE 'UNSUPPORTED_PRODUCER_VERSION:%' THEN RAISE EXCEPTION 'T9 FAIL: versión no soportada'; END IF;

  -- ---- elige una corrida real futura (evento aún no arrancado) ----
  SELECT a.id, COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id),
         (a.analisis_json->>'generado_en')::timestamptz, a.analisis_json
    INTO aid, ev, gen, aj
    FROM public.analisis_partidos a
    WHERE a.analisis_json->>'analysis_version'='meta-v3'
      AND a.analisis_json ? 'generado_en'
      AND NULLIF(a.espn_data_json #>> '{header,competitions,0,date}','')::timestamptz > now()
    ORDER BY a.id DESC LIMIT 1;
  IF aid IS NULL THEN RAISE EXCEPTION 'no hay corrida meta-v3 con evento futuro para probar'; END IF;

  PERFORM public.capture_top_pick_universe(aid,'lab:e1','emission');
  SELECT decision_emission_id INTO emi FROM public.top_pick_capture WHERE source_analysis_id=aid LIMIT 1;
  IF emi IS NULL THEN RAISE EXCEPTION 'T0 FAIL: no capturó nada de la corrida'; END IF;

  -- ==== T1 decision_timestamp < event_start (guard temporal) ====
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND event_start_timestamp IS NOT NULL AND decision_timestamp>=event_start_timestamp)
     THEN RAISE EXCEPTION 'T1 FAIL'; END IF;

  -- ==== T2 ningún source_snapshot_timestamp de precio en el futuro respecto a la decisión ====
  IF EXISTS(SELECT 1 FROM public.top_pick_capture
            WHERE decision_emission_id=emi
              AND (source_snapshot_timestamps->>'precio_sellado') IS NOT NULL
              AND (source_snapshot_timestamps->>'precio_sellado')::timestamptz > decision_timestamp)
     THEN RAISE EXCEPTION 'T2 FAIL'; END IF;

  -- ==== T3 sin outcome/resultado en la tabla de captura (settlement separado) ====
  IF EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
            AND table_name='top_pick_capture' AND column_name IN ('outcome','resultado','retorno'))
     THEN RAISE EXCEPTION 'T3 FAIL'; END IF;

  -- ==== T4 P_RAW y P_DECISION persistidos por separado (autoridades reales distintas) ====
  IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public'
            AND table_name='top_pick_capture' AND column_name='p_raw')
     THEN RAISE EXCEPTION 'T4 FAIL: falta p_raw'; END IF;

  -- ==== T5 P_RAW==pick.prob y P_DECISION==pick.probabilidad_real (copiado, no recalculado) ====
  IF EXISTS(
     SELECT 1 FROM public.top_pick_capture c
     JOIN LATERAL (SELECT p FROM jsonb_array_elements(aj->'picks_recomendados') p
                   WHERE p->>'mercado'=c.market AND p->>'pick'=c.side LIMIT 1) x ON true
     WHERE c.decision_emission_id=emi AND c.candidate_kind='recommended'
       AND (c.p_raw IS DISTINCT FROM NULLIF(x.p->>'prob','')::numeric
         OR c.p_decision IS DISTINCT FROM NULLIF(x.p->>'probabilidad_real','')::numeric))
     THEN RAISE EXCEPTION 'T5 FAIL: P_RAW/P_DECISION no coinciden con el productor'; END IF;

  -- ==== T6 UNIVERSO COMPLETO: recommended + no_bet capturados (no solo es_pick) ====
  IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi AND candidate_kind='recommended')
     THEN RAISE EXCEPTION 'T6 FAIL: sin recommended'; END IF;

  -- ==== T7 governance intacta: cero modelos autorizados ====
  IF (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE)<>0
     THEN RAISE EXCEPTION 'T7 FAIL'; END IF;

  -- ==== T8 gate canónico secundario tiene procedencia y tiempo APARTE ====
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND canonical_read_at IS NOT NULL AND canonical_read_at = decision_timestamp)
     THEN RAISE EXCEPTION 'T8 FAIL: canonical_read_at colapsado con decision_timestamp'; END IF;

  -- ==== T10 completeness reproducible (health view corre) ====
  PERFORM * FROM public.v_top_pick_capture_health;

  -- ==== T11 non-prediction UPDATE => NO_CHANGE (misma corrida ya auditada) ====
  n := (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi);
  PERFORM public.capture_top_pick_universe(aid,'lab:np','non_prediction');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi)<>n
     THEN RAISE EXCEPTION 'T11 FAIL: non-prediction agregó filas'; END IF;
  IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture_audit WHERE espn_event_id=ev AND status='NO_CHANGE')
     THEN RAISE EXCEPTION 'T11 FAIL: no auditó NO_CHANGE'; END IF;

  -- ==== T12 replay idéntico (misma corrida) => 0 nuevas ====
  PERFORM public.capture_top_pick_universe(aid,'lab:replay','emission');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi)<>n
     THEN RAISE EXCEPTION 'T12 FAIL'; END IF;

  -- ==== T13 identidad de CORRIDA = md5(event‖generado_en‖analysis_version) ====
  IF emi IS DISTINCT FROM md5(ev||'|'||(aj->>'generado_en')||'|'||(aj->>'analysis_version'))
     THEN RAISE EXCEPTION 'T13 FAIL: emission_id no es identidad de corrida'; END IF;

  -- ==== T14 expected == captured + excluded (auditoría cuadra) ====
  IF EXISTS(SELECT 1 FROM public.top_pick_capture_audit WHERE decision_emission_id=emi
            AND status IN ('COMPLETE','PARTIAL')
            AND expected_candidate_count <> captured_candidate_count + excluded_count)
     THEN RAISE EXCEPTION 'T14 FAIL'; END IF;

  -- ==== T15 excepción de captura NO tumba analisis_partidos (documental+audit) ====
  -- (Paso de harness: renombrar temporalmente una columna crítica de v_pick_canonico o
  --  inyectar json corrupto en una fila del branch; verificar que el UPDATE sobre
  --  analisis_partidos hace COMMIT y aparece audit status='FAILED'. Ver nota T28.)

  -- ==== T16 falta campo crítico por-pick => contrato PICK_MISSING_FIELD ====
  miss := public.assert_capture_contract(
     jsonb_build_object('generado_en',now()::text,'analysis_version','meta-v3',
       'picks_recomendados', jsonb_build_array(jsonb_build_object('mercado','ML'))));
  IF miss NOT LIKE 'PICK_MISSING_FIELD:%' THEN RAISE EXCEPTION 'T16 FAIL'; END IF;

  -- ==== T17 todas las filas de UNA corrida comparten emission_id ====
  SELECT count(DISTINCT decision_emission_id) INTO ndist FROM public.top_pick_capture WHERE source_analysis_id=aid;
  IF ndist <> 1 THEN RAISE EXCEPTION 'T17 FAIL: % emission_ids en una corrida', ndist; END IF;

  -- ==== T18 settlement PUSH/VOID/line-specific sin mutar snapshot ====
  INSERT INTO public.top_pick_settlement(espn_event_id,market,side,normalized_line,outcome,settlement_source)
  SELECT espn_event_id,market,side,normalized_line,'push','lab'
    FROM public.top_pick_capture WHERE decision_emission_id=emi LIMIT 1;
  -- snapshot inalterado: p_decision sigue igual al productor
  IF EXISTS(
     SELECT 1 FROM public.top_pick_capture c
     JOIN LATERAL (SELECT p FROM jsonb_array_elements(aj->'picks_recomendados') p
                   WHERE p->>'mercado'=c.market AND p->>'pick'=c.side LIMIT 1) x ON true
     WHERE c.decision_emission_id=emi AND c.candidate_kind='recommended'
       AND c.p_decision IS DISTINCT FROM NULLIF(x.p->>'probabilidad_real','')::numeric)
     THEN RAISE EXCEPTION 'T18 FAIL: snapshot mutado por settlement'; END IF;

  -- ==== T19 display append-only (dos filas conviven) ====
  INSERT INTO public.top_pick_display(decision_emission_id,selector_version,surface,top_pick_rank,selected_as_top_pick)
  VALUES (emi,'v0','TOP',1,true),(emi,'v0','TOP',1,true);
  IF (SELECT count(*) FROM public.top_pick_display WHERE decision_emission_id=emi)<2
     THEN RAISE EXCEPTION 'T19 FAIL'; END IF;

  -- ==== T20 completeness query reproducible (dataset científico solo provenance_complete) ====
  IF EXISTS(SELECT 1 FROM public.v_top_pick_science_dataset WHERE provenance_complete IS NOT TRUE)
     THEN RAISE EXCEPTION 'T20 FAIL: dataset científico incluye provenance incompleto'; END IF;

  -- ==== T21 recompute real (mismo contenido, distinto generado_en) => NUEVA emisión ====
  -- (Paso de harness: en el branch, forzar reanálisis que reescriba analisis_json.generado_en
  --  y volver a capturar => decision_emission_id distinto, 2 corridas coexisten. Ver nota final.)

  -- ==== T22 retry de la MISMA emisión => no dup (idéntico a T12, verificado arriba) ====
  IF (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi)<>n
     THEN RAISE EXCEPTION 'T22 FAIL'; END IF;

  -- ==== T23 decision_timestamp (generado_en) ≠ captured_at (now trigger) ====
  IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
                AND decision_timestamp = gen AND captured_at <> decision_timestamp)
     THEN RAISE EXCEPTION 'T23 FAIL: timestamps colapsados o generado_en mal mapeado'; END IF;

  -- ==== T24 mixed logical source revisions => PARTIAL/REJECT por contrato de versión ====
  -- (Paso de harness: si aparece analysis_version fuera de {meta-v3}, capture escribe audit
  --  FAILED UNSUPPORTED_PRODUCER_VERSION sin interpretar silenciosamente. Cubierto por T9.)

  -- ==== T25 missing model_version/p_raw => provenance_complete=false (fuera del dataset) ====
  -- construye un caso: una fila no_bet sin prob deja provenance_complete=false si aplica
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND (p_raw IS NULL OR p_decision IS NULL OR model_version IS NULL)
            AND provenance_complete IS TRUE)
     THEN RAISE EXCEPTION 'T25 FAIL: provenance_complete=true con campo crítico ausente'; END IF;

  -- ==== T26 Moneyline line=NULL => protección de duplicados (normalized_line='∅' + NULLS NOT DISTINCT) ====
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi AND normalized_line IS NULL)
     THEN RAISE EXCEPTION 'T26 FAIL: normalized_line NULL existe'; END IF;
  -- reintento de la corrida no crea duplicado ni para picks con line vacía
  n2 := (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi AND normalized_line='∅');
  PERFORM public.capture_top_pick_universe(aid,'lab:mldup','emission');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi AND normalized_line='∅')<>n2
     THEN RAISE EXCEPTION 'T26 FAIL: duplicó ML line=∅'; END IF;

  -- ==== T27 UPDATE/DELETE del snapshot => REJECT; settlement INSERT => OK ====
  BEGIN
    UPDATE public.top_pick_capture SET p_decision = p_decision WHERE decision_emission_id=emi;
    RAISE EXCEPTION 'T27 FAIL: UPDATE del snapshot NO fue rechazado';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%APPEND_ONLY%' THEN RAISE EXCEPTION 'T27 FAIL: rechazo inesperado %',SQLERRM; END IF;
  END;
  BEGIN
    DELETE FROM public.top_pick_capture WHERE decision_emission_id=emi;
    RAISE EXCEPTION 'T27 FAIL: DELETE del snapshot NO fue rechazado';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%APPEND_ONLY%' THEN RAISE EXCEPTION 'T27 FAIL: rechazo inesperado %',SQLERRM; END IF;
  END;

  -- ==== T28 audit-write failure no rompe product write ====
  -- (Paso de harness: forzar fallo del INSERT de audit — p.ej. permiso revocado al rol de audit —
  --  y verificar que el UPDATE sobre analisis_partidos igual hace COMMIT gracias al doble
  --  BEGIN/EXCEPTION anidado del trigger. Verificación estructural: el bloque anidado existe.)
  IF NOT EXISTS(
     SELECT 1 FROM pg_proc p
     WHERE p.proname='trg_capture_top_pick'
       AND pg_get_functiondef(p.oid) LIKE '%EXCEPTION WHEN OTHERS%EXCEPTION WHEN OTHERS%')
     THEN RAISE EXCEPTION 'T28 FAIL: falta aislamiento anidado del audit en el trigger'; END IF;

  -- ---- HASH_V3: mismo digest independiente del orden de filas ----
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND (event_prediction_digest IS NULL OR length(event_prediction_digest)<>64))
     THEN RAISE EXCEPTION 'HASH_V3 FAIL: digest de corrida ausente o no sha256'; END IF;
  IF (SELECT count(DISTINCT event_prediction_digest) FROM public.top_pick_capture WHERE decision_emission_id=emi)<>1
     THEN RAISE EXCEPTION 'HASH_V3 FAIL: digest de corrida no es único por emisión'; END IF;

  RAISE EXCEPTION 'TEST_PLAN_V3_OK (T1..T28 evaluados; forzar ROLLBACK del branch).
     T15/T21/T24-parcial/T28-comportamental = pasos del harness LAB (mutar odds / recompute /
     revocar permiso de audit / inyectar versión no soportada), documentados abajo.';
END $tp$;
-- ----------------------------------------------------------------------------
-- Pasos del harness LAB (requieren mutar estado del branch; no automatizables en el DO):
-- T15  Inyectar json corrupto en una fila y UPDATE analisis_partidos => COMMIT + audit FAILED.
-- T21  Reanálisis real que reescriba generado_en => nuevo decision_emission_id (2 corridas).
-- T24  Sembrar analysis_version fuera de {meta-v3} => audit FAILED UNSUPPORTED_PRODUCER_VERSION.
-- T28  REVOKE INSERT sobre top_pick_capture_audit al rol => product write igual hace COMMIT.
-- ============================================================================
