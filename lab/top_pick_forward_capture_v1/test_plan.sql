-- TEST PLAN LAB (correr en branch efímero DESPUÉS de aplicar ddl_top_pick_capture_v1.sql; NO en prod)
-- Cada test RAISE EXCEPTION si falla. Usa un evento real de v_pick_canonico con arranca_en futuro.
DO $tp$
DECLARE ev text; es timestamptz; n int; h1 text; h2 text;
BEGIN
  SELECT espn_event_id, arranca_en INTO ev, es
    FROM public.v_pick_canonico WHERE arranca_en > now() LIMIT 1;
  IF ev IS NULL THEN RAISE EXCEPTION 'no hay evento futuro para probar'; END IF;

  -- captura con decisión ANTES del evento
  PERFORM public.capture_top_pick_universe(ev, now(), 'lab:test');

  -- T1 decisión < evento
  PERFORM 1 FROM public.top_pick_capture WHERE espn_event_id=ev
    AND (event_start_timestamp IS NULL OR decision_timestamp < event_start_timestamp);
  IF NOT FOUND THEN RAISE EXCEPTION 'T1 FAIL'; END IF;
  IF EXISTS(SELECT 1 FROM public.top_pick_capture WHERE espn_event_id=ev
            AND event_start_timestamp IS NOT NULL AND decision_timestamp >= event_start_timestamp)
     THEN RAISE EXCEPTION 'T1 FAIL: fila con decision>=event'; END IF;

  -- T2 ningún feature_source_timestamp > decision_timestamp
  IF EXISTS(SELECT 1 FROM public.top_pick_capture c,
                    jsonb_each_text(c.feature_source_timestamps) f
            WHERE c.espn_event_id=ev AND f.value ~ '^\d{4}-' AND f.value::timestamptz > c.decision_timestamp)
     THEN RAISE EXCEPTION 'T2 FAIL: feature futura'; END IF;

  -- T3 sin columna outcome en captura pre-evento
  PERFORM 1 FROM information_schema.columns
    WHERE table_schema='public' AND table_name='top_pick_capture' AND column_name IN ('outcome','resultado','win','loss');
  IF FOUND THEN RAISE EXCEPTION 'T3 FAIL: captura tiene outcome'; END IF;

  -- T5 dos decisiones distinto ts sobreviven
  PERFORM public.capture_top_pick_universe(ev, now()+interval '1 second', 'lab:test2');
  SELECT count(DISTINCT decision_timestamp) INTO n FROM public.top_pick_capture WHERE espn_event_id=ev;
  IF n < 2 THEN RAISE EXCEPTION 'T5 FAIL: no sobreviven 2 decisiones (%).', n; END IF;

  -- T6 duplicado idéntico (mismo ts) no crea fila nueva
  SELECT count(*) INTO n FROM public.top_pick_capture WHERE espn_event_id=ev;
  PERFORM public.capture_top_pick_universe(ev, (SELECT min(decision_timestamp) FROM public.top_pick_capture WHERE espn_event_id=ev), 'lab:dup');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE espn_event_id=ev) <> n
     THEN RAISE EXCEPTION 'T6 FAIL: duplicado idéntico insertó'; END IF;

  -- T8/T9 exactitud vs v_pick_canonico
  IF EXISTS(
    SELECT 1 FROM public.top_pick_capture c
    JOIN public.v_pick_canonico v ON v.espn_event_id=c.espn_event_id AND v.mercado=c.market AND v.pick_nombre=c.side
    WHERE c.espn_event_id=ev
      AND (c.p_decision IS DISTINCT FROM v.probabilidad_pct OR c.ev_decision IS DISTINCT FROM v.ev_pct
           OR c.economic_eligible IS DISTINCT FROM v.es_pick))
    THEN RAISE EXCEPTION 'T8/T9 FAIL: P/EV/es_pick no coinciden con la autoridad'; END IF;

  -- T10 gobernanza intacta
  IF (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE) <> 0
     THEN RAISE EXCEPTION 'T10 FAIL: modelos autorizados cambiaron'; END IF;

  -- ADV resultado conocido / decisión post-evento => REJECT (no inserta)
  SELECT count(*) INTO n FROM public.top_pick_capture WHERE espn_event_id=ev;
  PERFORM public.capture_top_pick_universe(ev, es + interval '3 hours', 'lab:adv_post_event');
  IF (SELECT count(*) FROM public.top_pick_capture WHERE espn_event_id=ev) <> n
     THEN RAISE EXCEPTION 'ADV FAIL: se capturó con decisión posterior al evento'; END IF;

  RAISE EXCEPTION 'TEST_PLAN_OK (todos los asserts pasaron; rollback del branch)';  -- fuerza rollback del test
END $tp$;
