-- ============================================================================
-- SEC-03 — TEST ADVERSARIAL DEL LEDGER FORWARD
-- ============================================================================
-- Reproduce el ataque en laboratorio, aplica el hardening y verifica que el
-- ataque queda bloqueado sin romper al productor legitimo.
-- SOLO LAB. NO ejecutar contra produccion.
-- ============================================================================
\set ON_ERROR_STOP on

-- Estado de partida: replicar el GRANT que existe en produccion.
GRANT USAGE ON SCHEMA public TO anon;
GRANT EXECUTE ON FUNCTION public.lab_mlb_fwd_capturar(
  text, timestamptz, text, numeric, text, text, timestamptz, text, numeric, text, text, text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lab_mlb_fwd_resultado(
  text, integer, numeric, timestamptz) TO anon, authenticated;

DO $t$
DECLARE
  n_conf int := 0;
  did_atacante text; did_legitimo text; n_filas int;
  v_praw numeric; v_elig text; v_avail text;
BEGIN
  RAISE NOTICE '=== SEC-03: ESTADO VULNERABLE (reproduccion del ataque) ===';

  ------------------------------------------------------------------ A1
  -- Atacante anonimo PRE-RECLAMA el decision_id con datos falsos.
  SET LOCAL ROLE anon;
  did_atacante := public.lab_mlb_fwd_capturar(
    'TEST_SEC03_EVENT', '2026-09-08 18:00:00+00'::timestamptz, 'v1.0',
    0.99, 'PITCHER_FALSO_H','PITCHER_FALSO_A',
    '2026-09-08 17:00:00+00'::timestamptz,
    'READY', 1.01, 'ML_HOME', 'ELIGIBLE');
  RESET ROLE;

  SELECT count(*) INTO n_filas FROM public.lab_mlb_forward WHERE decision_id = did_atacante;
  IF n_filas = 1 THEN
    n_conf := n_conf+1;
    RAISE NOTICE 'CONFIRMADO A1 · anon escribio en el ledger · decision_id=%', did_atacante;
  ELSE
    RAISE WARNING 'A1 NO reprodujo la escritura anonima';
  END IF;

  ------------------------------------------------------------------ A2
  -- Productor legitimo captura el MISMO evento/decision_time/version.
  did_legitimo := public.lab_mlb_fwd_capturar(
    'TEST_SEC03_EVENT', '2026-09-08 18:00:00+00'::timestamptz, 'v1.0',
    0.5432, 'deGrom','Skubal',
    '2026-09-08 16:00:00+00'::timestamptz,
    'PARTIAL', 2.10, 'ML_HOME', 'MODEL_VERSION_PROVENANCE_MISSING');

  SELECT p_raw_home, eligibility_state, available_at_decision
    INTO v_praw, v_elig, v_avail
    FROM public.lab_mlb_forward WHERE decision_id = did_legitimo;

  IF did_legitimo = did_atacante AND v_praw = 0.99 THEN
    n_conf := n_conf+1;
    RAISE NOTICE 'CONFIRMADO A2 · ON CONFLICT DO NOTHING descarto la captura legitima EN SILENCIO';
    RAISE NOTICE '              el ledger conserva p_raw_home=% eligibility=%', v_praw, v_elig;
  ELSE
    RAISE WARNING 'A2 NO reprodujo el envenenamiento (p_raw=% elig=%)', v_praw, v_elig;
  END IF;

  ------------------------------------------------------------------ A3
  IF v_avail = 'AVAILABLE_AT_DECISION' THEN
    n_conf := n_conf+1;
    RAISE NOTICE 'CONFIRMADO A3 · marca de integridad temporal forjada: available_at_decision=%', v_avail;
  END IF;

  RAISE NOTICE '=== vectores confirmados en estado vulnerable: % de 3 ===', n_conf;
END $t$;
