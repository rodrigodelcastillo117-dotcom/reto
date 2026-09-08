-- ============================================================================
-- TEST PLAN v4 (T1-T36) — LAB en branch efímero.
-- Requisitos: ddl_top_pick_capture_v4.sql aplicado; productor meta-v3; v_pick_canonico @ ISS-009B.
-- Corre como DO que RAISE EXCEPTION al final para forzar rollback del branch.
-- Los tests que exigen mutar estado (reanalysis overwrite, revocar permisos) van como pasos del
-- harness LAB al final; los estructurales/comportamentales corren aquí.
-- Cada assert aborta si falla.
-- ============================================================================
DO $tp$
DECLARE
  aid uuid; ev text; gen timestamptz; emi uuid; aj jsonb;
  n int; n2 int; ndist int; miss text; v_uuid uuid; v_led int;
BEGIN
  -- ---- CONTRATO fail-closed ----
  IF public.assert_capture_contract(NULL) IS DISTINCT FROM 'ANALISIS_JSON_NULL'
     THEN RAISE EXCEPTION 'T-contract FAIL null'; END IF;
  IF public.assert_capture_contract(jsonb_build_object('generado_en',now()::text,'analysis_version','meta-v9'))
       NOT LIKE 'UNSUPPORTED_PRODUCER_VERSION:%'
     THEN RAISE EXCEPTION 'T24 FAIL: versión no soportada no rechazada'; END IF;   -- T24

  -- ---- elegir una corrida real futura ----
  SELECT a.id, COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id),
         (a.analisis_json->>'generado_en')::timestamptz, a.analisis_json
    INTO aid, ev, gen, aj
    FROM public.analisis_partidos a
    WHERE a.analisis_json->>'analysis_version'='meta-v3' AND a.analisis_json ? 'generado_en'
      AND NULLIF(a.espn_data_json #>> '{header,competitions,0,date}','')::timestamptz > now()
    ORDER BY a.id DESC LIMIT 1;
  IF aid IS NULL THEN RAISE EXCEPTION 'no hay corrida meta-v3 futura para probar'; END IF;

  -- forzar el flujo productor->ledger->captura: el UPDATE dispara trg_a_emission_ledger + trg_b_top_pick_capture
  UPDATE public.analisis_partidos SET reanalizado_at = COALESCE(reanalizado_at, now()) WHERE id=aid;

  SELECT decision_emission_id INTO emi FROM public.prediction_emission_ledger
   WHERE event_id=ev AND emitted_at=gen ORDER BY created_at DESC LIMIT 1;
  IF emi IS NULL THEN RAISE EXCEPTION 'T-ledger FAIL: no se registró la emisión'; END IF;

  -- ========================= B3 LEDGER / IDENTIDAD =========================
  -- T-id: decision_emission_id es UUID (no md5 de contenido)
  IF emi::text !~ '^[0-9a-f-]{36}$' THEN RAISE EXCEPTION 'T-id FAIL: emission_id no es UUID'; END IF;

  -- ========================= B1 UNIVERSO =========================
  -- T31 texto libre no_bet NUNCA como estructurado
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND candidate_source_type='ANALYSIS_TEXT_ONLY' AND (market IS NOT NULL OR side IS NOT NULL))
     THEN RAISE EXCEPTION 'T31 FAIL: texto libre interpretado como market/side'; END IF;
  -- T31b: los no_bet strings SÍ se registran como ANALYSIS_TEXT_ONLY con raw_text
  IF jsonb_typeof(aj->'no_bet_picks')='array' AND jsonb_array_length(aj->'no_bet_picks')>0
     AND NOT EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
                    AND candidate_source_type='ANALYSIS_TEXT_ONLY' AND raw_text IS NOT NULL)
     THEN RAISE EXCEPTION 'T31b FAIL: no_bet texto no registrado como ANALYSIS_TEXT_ONLY'; END IF;

  -- T29 all_candidates estructurado: si el productor ya emite all_candidates[], universe=COMPLETE
  IF jsonb_typeof(aj->'all_candidates')='array' THEN
    IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture_audit
                  WHERE decision_emission_id=emi AND universe_source='ALL_CANDIDATES'
                    AND structured_universe_status='COMPLETE')
       THEN RAISE EXCEPTION 'T29 FAIL: all_candidates presente pero universo no COMPLETE'; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi AND is_full_universe IS TRUE)
       THEN RAISE EXCEPTION 'T29 FAIL: is_full_universe no marcado'; END IF;
    -- T30 universe coverage = 100% para emisión soportada: expected==captured
    IF EXISTS(SELECT 1 FROM public.top_pick_capture_audit WHERE decision_emission_id=emi
              AND status='COMPLETE' AND expected_candidate_count<>captured_candidate_count)
       THEN RAISE EXCEPTION 'T30 FAIL: coverage<100% con all_candidates'; END IF;
  ELSE
    -- productor aún NO instrumentado: honesto => INCOMPLETE + is_full_universe=false
    IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture_audit
                  WHERE decision_emission_id=emi AND structured_universe_status='INCOMPLETE')
       THEN RAISE EXCEPTION 'T29/T30 FAIL: sin all_candidates debe auditar INCOMPLETE'; END IF;
    IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
              AND candidate_source_type='EMISSION_GENERATED_STRUCTURED' AND is_full_universe IS TRUE)
       THEN RAISE EXCEPTION 'T29 FAIL: is_full_universe=true sin all_candidates'; END IF;
    RAISE NOTICE 'T29/T30 en modo INCOMPLETE (productor sin all_candidates[]); coverage<100 por diseño.';
  END IF;

  -- ========================= autoridades / provenance =========================
  -- P_RAW y P_DECISION separados
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND candidate_source_type='EMISSION_GENERATED_STRUCTURED'
            AND (p_raw IS NULL OR p_decision IS NULL) AND provenance_complete IS TRUE)
     THEN RAISE EXCEPTION 'T25 FAIL: provenance_complete con P_RAW/P_DECISION ausente'; END IF;  -- T25

  -- decision_timestamp = generado_en ≠ captured_at
  IF NOT EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
                AND decision_timestamp=gen AND captured_at<>decision_timestamp)
     THEN RAISE EXCEPTION 'T-ts FAIL: timestamps colapsados o mal mapeados'; END IF;

  -- decision < evento
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND event_start_timestamp IS NOT NULL AND decision_timestamp>=event_start_timestamp)
     THEN RAISE EXCEPTION 'T1 FAIL guard temporal'; END IF;

  -- todas las filas de la corrida comparten emission_id
  SELECT count(DISTINCT decision_emission_id) INTO ndist FROM public.top_pick_capture WHERE source_analysis_id=aid;
  IF ndist<>1 THEN RAISE EXCEPTION 'T-emis FAIL: % ids en una corrida', ndist; END IF;

  -- ========================= B2 APPEND-ONLY / HASH =========================
  -- T32 snapshot INSERT requiere 0 UPDATE posteriores: el digest ya viene en el INSERT
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND (event_prediction_digest IS NULL OR length(event_prediction_digest)<>64))
     THEN RAISE EXCEPTION 'T32 FAIL: digest ausente en el INSERT (habría requerido post-update)'; END IF;
  IF (SELECT count(DISTINCT event_prediction_digest) FROM public.top_pick_capture WHERE decision_emission_id=emi)<>1
     THEN RAISE EXCEPTION 'T32 FAIL: digest no único por corrida'; END IF;
  -- HASH_V3/V4 determinístico: 64 hex por fila
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi
            AND length(prediction_snapshot_hash)<>64) THEN RAISE EXCEPTION 'HASH FAIL: snapshot_hash no sha256'; END IF;

  -- T27/T33 UPDATE/DELETE snapshot => REJECT INCONDICIONAL (sin GUC bypass)
  BEGIN
    UPDATE public.top_pick_capture SET p_decision=p_decision WHERE decision_emission_id=emi;
    RAISE EXCEPTION 'T27 FAIL: UPDATE snapshot no rechazado';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%APPEND_ONLY%' THEN RAISE EXCEPTION 'T27 FAIL rechazo inesperado %',SQLERRM; END IF;
  END;
  BEGIN
    DELETE FROM public.top_pick_capture WHERE decision_emission_id=emi;
    RAISE EXCEPTION 'T27 FAIL: DELETE snapshot no rechazado';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%APPEND_ONLY%' THEN RAISE EXCEPTION 'T27 FAIL rechazo inesperado %',SQLERRM; END IF;
  END;
  -- T33 custom GUC NO habilita mutación (poner el GUC de v3 no debe permitir nada)
  BEGIN
    PERFORM set_config('app.allow_admin_mutation','on',true);
    UPDATE public.top_pick_capture SET p_decision=p_decision WHERE decision_emission_id=emi;
    RAISE EXCEPTION 'T33 FAIL: GUC permitió mutar snapshot';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%APPEND_ONLY%' THEN RAISE EXCEPTION 'T33 FAIL rechazo inesperado %',SQLERRM; END IF;
  END;

  -- idempotencia: recaptura misma corrida => 0 filas nuevas (retry)
  n := (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi);
  PERFORM public.capture_top_pick_universe(aid,'lab:replay','emission');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE decision_emission_id=emi)<>n
     THEN RAISE EXCEPTION 'T22 FAIL: replay duplicó'; END IF;

  -- ML line=∅ nunca NULL + sin duplicado
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE decision_emission_id=emi AND normalized_line IS NULL)
     THEN RAISE EXCEPTION 'T26 FAIL: normalized_line NULL'; END IF;

  -- ========================= settlement / display / dataset =========================
  INSERT INTO public.top_pick_settlement(espn_event_id,market,side,normalized_line,outcome,settlement_source)
  SELECT espn_event_id,market,side,normalized_line,'push','lab'
    FROM public.top_pick_capture WHERE decision_emission_id=emi AND market IS NOT NULL LIMIT 1;
  -- dataset científico jamás incluye texto libre ni provenance incompleta
  IF EXISTS(SELECT 1 FROM public.v_top_pick_science_dataset
            WHERE candidate_source_type<>'EMISSION_GENERATED_STRUCTURED' OR provenance_complete IS NOT TRUE)
     THEN RAISE EXCEPTION 'T20 FAIL: dataset científico contaminado'; END IF;
  INSERT INTO public.top_pick_display(decision_emission_id,selector_version,surface,top_pick_rank,selected_as_top_pick)
  VALUES (emi,'v0','TOP',1,true),(emi,'v0','TOP',1,true);
  IF (SELECT count(*) FROM public.top_pick_display WHERE decision_emission_id=emi)<2
     THEN RAISE EXCEPTION 'T19 FAIL display append-only'; END IF;

  -- ========================= B3 reconciliación =========================
  -- ledger reconcilia con audit COMPLETE/PARTIAL (no MISSING para esta corrida)
  IF (SELECT reconciliation_state FROM public.v_emission_ledger_reconciliation WHERE decision_emission_id=emi)
       = 'MISSING'
     THEN RAISE EXCEPTION 'T-recon FAIL: corrida capturada aparece MISSING'; END IF;

  -- T36 mismo contenido, dos corridas reales => dos filas de ledger
  v_uuid := gen_random_uuid();
  INSERT INTO public.prediction_emission_ledger(decision_emission_id,event_id,emitted_at,producer_version,
    engine,candidate_count,emission_hash,source_analysis_id)
  SELECT v_uuid,event_id,emitted_at + interval '1 hour',producer_version,engine,candidate_count,emission_hash,source_analysis_id
    FROM public.prediction_emission_ledger WHERE decision_emission_id=emi;  -- mismo hash, distinto emitted_at
  SELECT count(*) INTO v_led FROM public.prediction_emission_ledger
   WHERE emission_hash=(SELECT emission_hash FROM public.prediction_emission_ledger WHERE decision_emission_id=emi);
  IF v_led < 2 THEN RAISE EXCEPTION 'T36 FAIL: mismo contenido no generó dos filas de ledger'; END IF;

  RAISE EXCEPTION 'TEST_PLAN_V4_OK (T1..T36 evaluados; forzar ROLLBACK del branch).
    Pasos del harness LAB (mutan estado): T21/T34/T35 reanalysis-overwrite; T28 revocar INSERT audit;
    all_candidates[] real requiere el parche aditivo del productor. Ver notas al pie.';
END $tp$;
-- ----------------------------------------------------------------------------
-- Pasos del harness LAB (requieren mutar estado; no automatizables en el DO):
-- T21  Reanálisis real que reescriba generado_en => nuevo decision_emission_id (2 corridas coexisten).
-- T34  emisión A (captura falla, p.ej. inyectar json corrupto) -> ledger conserva A ->
--        reconciliation_state(A)='MISSING' aunque la captura fallara.
-- T35  tras T34, emisión B SOBREESCRIBE analisis_json -> el ledger de A persiste ->
--        v_emission_ledger_reconciliation todavía lista A como MISSING (missed capture detectable).
-- T28  REVOKE INSERT ON top_pick_capture_audit al rol -> product write (UPDATE analisis_partidos)
--        igual hace COMMIT gracias al doble BEGIN/EXCEPTION anidado del trigger de captura.
-- ============================================================================
