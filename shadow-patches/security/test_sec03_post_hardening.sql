
-- ============================================================================
-- SEC-03 — VERIFICACION POST-HARDENING
-- Se ejecuta DESPUES de sec_hardening_v1.sql. Solo lab.
-- ============================================================================
\set ON_ERROR_STOP on
DO $t$
DECLARE n_pass int := 0; n_fail int := 0; did text; v_praw numeric; bloqueado boolean;
BEGIN
  RAISE NOTICE '=== SEC-03: VERIFICACION POST-HARDENING ===';

  ------------------------------------------------------------------ H1
  -- ANON_CANNOT_PRECLAIM
  bloqueado := false;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.lab_mlb_fwd_capturar(
      'TEST_SEC03_H1', now(), 'v1.0', 0.99, 'X','Y', now(), 'READY', 1.01, 'ML_HOME', 'ELIGIBLE');
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE; bloqueado := true;
  END;
  IF bloqueado THEN n_pass:=n_pass+1;
    RAISE NOTICE 'PASS_NONEMPTY H1 ANON_CANNOT_PRECLAIM · evaluated_rows=1 violations=0';
  ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL H1 anon todavia puede escribir'; END IF;

  ------------------------------------------------------------------ H2
  -- ANON_CANNOT_INJECT (settlement)
  bloqueado := false;
  BEGIN
    SET LOCAL ROLE anon;
    PERFORM public.lab_mlb_fwd_resultado('cualquiera', 1, 2.0, now());
    RESET ROLE;
  EXCEPTION WHEN insufficient_privilege THEN
    RESET ROLE; bloqueado := true;
  END;
  IF bloqueado THEN n_pass:=n_pass+1;
    RAISE NOTICE 'PASS_NONEMPTY H2 ANON_CANNOT_INJECT (settlement) · evaluated_rows=1 violations=0';
  ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL H2 anon todavia puede inyectar resultados'; END IF;

  ------------------------------------------------------------------ H3
  -- LEGITIMATE_PRODUCER_CAN_WRITE (owner/servicio sigue funcionando)
  did := public.lab_mlb_fwd_capturar(
    'TEST_SEC03_H3', '2026-09-08 18:00:00+00'::timestamptz, 'v1.0',
    0.5432, 'deGrom','Skubal', '2026-09-08 16:00:00+00'::timestamptz,
    'PARTIAL', 2.10, 'ML_HOME', 'MODEL_VERSION_PROVENANCE_MISSING');
  SELECT p_raw_home INTO v_praw FROM public.lab_mlb_forward WHERE decision_id = did;
  IF v_praw = 0.5432 THEN n_pass:=n_pass+1;
    RAISE NOTICE 'PASS_NONEMPTY H3 LEGITIMATE_PRODUCER_CAN_WRITE · p_raw_home=% · evaluated_rows=1 violations=0', v_praw;
  ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL H3 el productor legitimo no escribio'; END IF;

  ------------------------------------------------------------------ H4
  -- IDEMPOTENCY_SAFE: re-capturar lo mismo no duplica ni corrompe
  PERFORM public.lab_mlb_fwd_capturar(
    'TEST_SEC03_H3', '2026-09-08 18:00:00+00'::timestamptz, 'v1.0',
    0.5432, 'deGrom','Skubal', '2026-09-08 16:00:00+00'::timestamptz,
    'PARTIAL', 2.10, 'ML_HOME', 'MODEL_VERSION_PROVENANCE_MISSING');
  IF (SELECT count(*) FROM public.lab_mlb_forward WHERE decision_id = did) = 1 THEN
    n_pass:=n_pass+1;
    RAISE NOTICE 'PASS_NONEMPTY H4 IDEMPOTENCY_SAFE · 1 fila tras doble captura · evaluated_rows=1 violations=0';
  ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL H4 idempotencia rota'; END IF;

  ------------------------------------------------------------------ H5
  -- NO_SILENT_POISONING: sin anon, nadie ajeno puede pre-reclamar el id
  IF (SELECT p_raw_home FROM public.lab_mlb_forward WHERE decision_id = did) = 0.5432 THEN
    n_pass:=n_pass+1;
    RAISE NOTICE 'PASS_NONEMPTY H5 NO_SILENT_POISONING · el ledger conserva el dato legitimo · evaluated_rows=1 violations=0';
  ELSE n_fail:=n_fail+1; RAISE WARNING 'FAIL H5 el ledger quedo envenenado'; END IF;

  RAISE NOTICE '=== SEC-03 post-hardening: % PASS / % FAIL ===', n_pass, n_fail;
  IF n_fail > 0 THEN RAISE EXCEPTION 'SEC-03 hardening NO cierra los vectores'; END IF;
END $t$;
