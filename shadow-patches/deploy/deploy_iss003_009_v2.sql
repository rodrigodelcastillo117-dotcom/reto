-- ============================================================================
-- DEPLOY V2 — ISS-003 / ISS-009 / ISS-009B (una sola transacción, atómico)
-- ============================================================================
-- Sustituye a deploy_iss003_009.sql (V1, RETIRED por defecto posicional).
-- Artefacto: ../iss003_009_mlb_governance_v2.sql
-- Ejecutar SIEMPRE vía run_deploy_v2.sh (verifica SHA antes de tocar prod).
--
-- CAMBIOS V2 vs V1 EN ESTE WRAPPER:
--   (1) Assert C endurecido: verifica COMPATIBILIDAD ORDINAL real de
--       v_mejores_picks_mlb (22 columnas previas idénticas en posición/nombre/tipo,
--       nuevas SOLO en 23/24). Es el guard que V1 no tenía y que causó el fallo.
--   (2) Asserts económicos E1/E2/E3/G5 clasifican PASS_NONEMPTY vs
--       PASS_EMPTY_COVERAGE y reportan filas evaluadas + violaciones. Un conjunto
--       vacío YA NO se presenta como cobertura real.
--   (3) Bloque H (NUEVO): asserts sobre las fuentes económicas AUTORITATIVAS,
--       independientes de que haya partidos o usuarios hoy.
--   (4) Bloque I (NUEVO): calibracion_confiable MLB = FALSE (ISS-003a) con
--       cobertura sustantiva medida.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '120s';

-- ---- baselines drift-safe ANTES de la primera DDL (fijan el snapshot) --------
CREATE TEMP TABLE _vpc_base ON COMMIT DROP AS
  SELECT ordinal_position, column_name, data_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
CREATE TEMP TABLE _vmm_base ON COMMIT DROP AS
  SELECT ordinal_position, column_name, data_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_mejores_picks_mlb';
CREATE TEMP TABLE _pev_before ON COMMIT DROP AS
  SELECT espn_event_id, mercado, pick_nombre, probabilidad_pct, ev_pct FROM public.v_pick_canonico;
CREATE TEMP TABLE _vmm_before ON COMMIT DROP AS
  SELECT espn_event_id, nivel FROM public.v_mejores_picks_mlb;
CREATE TEMP TABLE _calib_before ON COMMIT DROP AS
  SELECT count(*) FILTER (WHERE calibracion_confiable IS TRUE) AS mlb_true, count(*) AS mlb_filas
    FROM public.v_pick_canonico WHERE deporte LIKE 'baseball%';

-- ============================================================================
-- ARTEFACTO V2 CONGELADO, BYTE-EXACTO — orden literal 1 -> 2 -> 4
-- ============================================================================
\ir ../iss003_009_mlb_governance_v2.sql

-- ============================================================================
-- POST-VERIFY (misma transacción, antes del COMMIT) — FAIL -> ROLLBACK total
-- ============================================================================
DO $verify$
DECLARE
  ncol int; c44 text; t44 text; ndiff int; ncalls int; n_ovl int; ac_ee int; ac_rc int;
  vmm_ncol int; vmm_ndiff int; c23 text; t23 text; c24 text; t24 text;
  vpc_es_pick int; vmm_reco int; vmm_elig int;
  p_diff int; ev_diff int;
  n_before_reco int; g_missing int; g_notinfo int; g_elig int; g_reason int;
  e1_rows int; e1_viol int; e2_rows int; e2_viol int; e3_rows int; e3_viol int;
  g5_rows int; g5_viol int;
  h_auth int; h_mlb int; h3_e text; h3_r text; h4_e text; h4_r text; h5 boolean; h6 text;
  i1_true int; i1_rows int; i1_before_true int;
  n_empty int := 0; empty_list text := '';
BEGIN
  ---------- A. CONTRATO v_pick_canonico (aditivo al final) ----------
  SELECT count(*) INTO ncol FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
  IF ncol<>44 THEN RAISE EXCEPTION 'FAIL A1 vpc cols=% (exp 44)', ncol; END IF;
  RAISE NOTICE 'PASS A1 v_pick_canonico = 44 columnas';

  SELECT column_name,data_type INTO c44,t44 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position=44;
  IF c44 IS DISTINCT FROM 'es_pick_reason' OR t44 IS DISTINCT FROM 'text'
    THEN RAISE EXCEPTION 'FAIL A2 col44=%/%', c44,t44; END IF;
  RAISE NOTICE 'PASS A2 col44 = es_pick_reason text';

  -- NOTA: se acota el baseline a <=43. Tras un rollback semántico v_pick_canonico ya
  -- conserva la columna aditiva #44 inerte; comparar el baseline completo contra
  -- ordinal<=43 producía un FAIL espurio que bloqueaba el re-deploy legítimo.
  SELECT count(*) INTO ndiff FROM (
    SELECT ordinal_position,column_name,data_type FROM _vpc_base WHERE ordinal_position<=43
    EXCEPT
    SELECT ordinal_position,column_name,data_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position<=43) d;
  IF ndiff<>0 THEN RAISE EXCEPTION 'FAIL A3 primeras-43 drift=%', ndiff; END IF;
  RAISE NOTICE 'PASS A3 primeras 43 columnas idénticas (posición/nombre/tipo)';

  SELECT (length(v)-length(replace(v,'economic_eligibility_v1(','')))/length('economic_eligibility_v1(')
    INTO ncalls FROM (SELECT pg_get_viewdef('public.v_pick_canonico'::regclass,true) v) q;
  IF ncalls<>1 THEN RAISE EXCEPTION 'FAIL A4 eev1 calls=% (exp 1)', ncalls; END IF;
  RAISE NOTICE 'PASS A4 economic_eligibility_v1 llamada 1 sola vez en v_pick_canonico';

  ---------- B. analisis_completo (overload guard + llaves) ----------
  SELECT count(*) INTO n_ovl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='analisis_completo';
  IF n_ovl<>1 THEN RAISE EXCEPTION 'FAIL B0 analisis_completo overloads=% (exp 1) ABORT', n_ovl; END IF;
  RAISE NOTICE 'PASS B0 analisis_completo overload_count = 1';
  SELECT (length(d)-length(replace(d,'economically_eligible','')))/length('economically_eligible'),
         (length(d)-length(replace(d,'eligibility_reason_code','')))/length('eligibility_reason_code')
    INTO ac_ee,ac_rc FROM (SELECT pg_get_functiondef('public.analisis_completo(text)'::regprocedure) d) q;
  IF ac_ee<1 OR ac_rc<1 THEN RAISE EXCEPTION 'FAIL B1 keys ee=% rc=%', ac_ee,ac_rc; END IF;
  RAISE NOTICE 'PASS B1 analisis_completo propaga economically_eligible + eligibility_reason_code';

  ---------- C. CONTRATO v_mejores_picks_mlb — COMPATIBILIDAD ORDINAL (guard V2) ----------
  SELECT count(*) INTO vmm_ncol FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_mejores_picks_mlb';
  IF vmm_ncol<>24 THEN RAISE EXCEPTION 'FAIL C1 vmm cols=% (exp 24)', vmm_ncol; END IF;
  RAISE NOTICE 'PASS C1 v_mejores_picks_mlb = 24 columnas';

  -- mismo acotado que A3: el baseline puede traer ya 23/24 tras un rollback semántico
  SELECT count(*) INTO vmm_ndiff FROM (
    SELECT ordinal_position,column_name,data_type FROM _vmm_base WHERE ordinal_position<=22
    EXCEPT
    SELECT ordinal_position,column_name,data_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_mejores_picks_mlb' AND ordinal_position<=22) d;
  IF vmm_ndiff<>0 THEN
    RAISE EXCEPTION 'FAIL C2 ORDINAL DRIFT: % de las 22 columnas previas cambiaron posición/nombre/tipo', vmm_ndiff;
  END IF;
  RAISE NOTICE 'PASS C2 las 22 columnas previas idénticas en posición/nombre/tipo (nivel sigue en 15)';

  SELECT column_name,data_type INTO c23,t23 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_mejores_picks_mlb' AND ordinal_position=23;
  SELECT column_name,data_type INTO c24,t24 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_mejores_picks_mlb' AND ordinal_position=24;
  IF c23 IS DISTINCT FROM 'economically_eligible' OR t23 IS DISTINCT FROM 'boolean'
    THEN RAISE EXCEPTION 'FAIL C3 col23=%/% (exp economically_eligible/boolean)', c23,t23; END IF;
  IF c24 IS DISTINCT FROM 'reason_code' OR t24 IS DISTINCT FROM 'text'
    THEN RAISE EXCEPTION 'FAIL C4 col24=%/% (exp reason_code/text)', c24,t24; END IF;
  RAISE NOTICE 'PASS C3/C4 columnas nuevas SOLO en 23 (economically_eligible bool) y 24 (reason_code text)';

  ---------- D. INVARIANTES BAJO NONE ----------
  SELECT count(*) INTO vpc_es_pick FROM public.v_pick_canonico WHERE es_pick IS TRUE;
  IF vpc_es_pick<>0 THEN RAISE EXCEPTION 'FAIL D1 es_pick=true=% (exp 0)', vpc_es_pick; END IF;
  RAISE NOTICE 'PASS D1 v_pick_canonico es_pick=true = 0';
  SELECT count(*) INTO vmm_reco FROM public.v_mejores_picks_mlb WHERE nivel IN ('ojo','fuerte');
  IF vmm_reco<>0 THEN RAISE EXCEPTION 'FAIL D2 vmm nivel ojo/fuerte=% (exp 0)', vmm_reco; END IF;
  RAISE NOTICE 'PASS D2 v_mejores_picks_mlb nivel ojo/fuerte = 0';
  SELECT count(*) INTO vmm_elig FROM public.v_mejores_picks_mlb WHERE economically_eligible IS TRUE;
  IF vmm_elig<>0 THEN RAISE EXCEPTION 'FAIL D3 vmm economically_eligible=true=% (exp 0)', vmm_elig; END IF;
  RAISE NOTICE 'PASS D3 v_mejores_picks_mlb economically_eligible=true = 0';

  ---------- E. DINERO REAL — con clasificación de cobertura ----------
  SELECT count(*), count(*) FILTER (WHERE kelly_pct>0) INTO e1_rows,e1_viol
    FROM public.mejor_oportunidad_hoy(500);
  IF e1_viol<>0 THEN RAISE EXCEPTION 'FAIL E1 mejor_oportunidad_hoy kelly_pct>0=% de % filas', e1_viol,e1_rows; END IF;
  IF e1_rows=0 THEN n_empty:=n_empty+1; empty_list:=empty_list||'E1 ';
    RAISE NOTICE 'PASS_EMPTY_COVERAGE E1 mejor_oportunidad_hoy: filas=0 violaciones=0 (NO es cobertura sustantiva)';
  ELSE RAISE NOTICE 'PASS_NONEMPTY E1 mejor_oportunidad_hoy: filas=% violaciones=0', e1_rows; END IF;

  SELECT count(*), count(*) FILTER (WHERE r.monto_autorizado>0) INTO e2_rows,e2_viol
    FROM public.usuarios u CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r;
  IF e2_viol<>0 THEN RAISE EXCEPTION 'FAIL E2 reto monto_autorizado>0=% de % filas', e2_viol,e2_rows; END IF;
  IF e2_rows=0 THEN n_empty:=n_empty+1; empty_list:=empty_list||'E2 ';
    RAISE NOTICE 'PASS_EMPTY_COVERAGE E2 reto_picks_hoy monto: filas=0 violaciones=0 (NO es cobertura sustantiva)';
  ELSE RAISE NOTICE 'PASS_NONEMPTY E2 reto_picks_hoy monto: filas=% violaciones=0', e2_rows; END IF;

  SELECT count(*), count(*) FILTER (WHERE r.puede_apostar IS TRUE) INTO e3_rows,e3_viol
    FROM public.usuarios u CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r;
  IF e3_viol<>0 THEN RAISE EXCEPTION 'FAIL E3 reto puede_apostar=% de % filas', e3_viol,e3_rows; END IF;
  IF e3_rows=0 THEN n_empty:=n_empty+1; empty_list:=empty_list||'E3 ';
    RAISE NOTICE 'PASS_EMPTY_COVERAGE E3 reto_picks_hoy puede_apostar: filas=0 violaciones=0 (NO es cobertura sustantiva)';
  ELSE RAISE NOTICE 'PASS_NONEMPTY E3 reto_picks_hoy puede_apostar: filas=% violaciones=0', e3_rows; END IF;

  ---------- F. PARIDAD P/EV (BEFORE vs AFTER, bidireccional) ----------
  SELECT count(*) INTO p_diff FROM (
    (SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM _pev_before
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM public.v_pick_canonico)
    UNION ALL
    (SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM public.v_pick_canonico
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM _pev_before)) d;
  IF p_diff<>0 THEN RAISE EXCEPTION 'FAIL F1 P_VALUE_DIFF=% (exp 0)', p_diff; END IF;
  RAISE NOTICE 'PASS F1 P_VALUE_DIFF = 0';
  SELECT count(*) INTO ev_diff FROM (
    (SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM _pev_before
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM public.v_pick_canonico)
    UNION ALL
    (SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM public.v_pick_canonico
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM _pev_before)) d;
  IF ev_diff<>0 THEN RAISE EXCEPTION 'FAIL F2 EV_VALUE_DIFF=% (exp 0)', ev_diff; END IF;
  RAISE NOTICE 'PASS F2 EV_VALUE_DIFF = 0';

  ---------- G. ISS-009 VISIBILIDAD SEMÁNTICA ----------
  SELECT count(*) INTO n_before_reco FROM _vmm_before WHERE nivel IN ('ojo','fuerte');
  RAISE NOTICE 'INFO G0 filas MLB ojo/fuerte pre-deploy = % (dinámico segun cartelera del dia)', n_before_reco;

  SELECT count(*) INTO g_missing FROM (
    SELECT espn_event_id FROM _vmm_before
    EXCEPT SELECT espn_event_id FROM public.v_mejores_picks_mlb) d;
  IF g_missing<>0 THEN RAISE EXCEPTION 'FAIL G1 % eventos MLB desaparecieron', g_missing; END IF;
  RAISE NOTICE 'PASS G1 ningún evento MLB desapareció (0)';

  SELECT count(*) INTO g_notinfo FROM _vmm_before b
    LEFT JOIN public.v_mejores_picks_mlb v USING (espn_event_id)
   WHERE b.nivel IN ('ojo','fuerte') AND (v.espn_event_id IS NULL OR v.nivel <> 'informativo');
  IF g_notinfo<>0 THEN RAISE EXCEPTION 'FAIL G2 % degradadas no quedaron visibles como informativo', g_notinfo; END IF;
  IF n_before_reco=0 THEN n_empty:=n_empty+1; empty_list:=empty_list||'G2 ';
    RAISE NOTICE 'PASS_EMPTY_COVERAGE G2: 0 filas ojo/fuerte pre-deploy que degradar (NO es cobertura sustantiva)';
  ELSE RAISE NOTICE 'PASS_NONEMPTY G2 las % MLB ojo/fuerte quedan visibles como informativo', n_before_reco; END IF;

  SELECT count(*) INTO g_elig FROM public.v_mejores_picks_mlb WHERE economically_eligible IS DISTINCT FROM false;
  IF g_elig<>0 THEN RAISE EXCEPTION 'FAIL G3 % filas MLB con economically_eligible<>false', g_elig; END IF;
  RAISE NOTICE 'PASS G3 economically_eligible=false en toda la MLB';

  SELECT count(*) INTO g_reason FROM public.v_mejores_picks_mlb
   WHERE reason_code IS DISTINCT FROM 'MODEL_VERSION_PROVENANCE_MISSING';
  IF g_reason<>0 THEN RAISE EXCEPTION 'FAIL G4 % filas reason_code<>MODEL_VERSION_PROVENANCE_MISSING', g_reason; END IF;
  RAISE NOTICE 'PASS G4 reason_code=MODEL_VERSION_PROVENANCE_MISSING en toda la MLB';

  SELECT count(*), count(*) FILTER (WHERE m.kelly_pct>0) INTO g5_rows,g5_viol
    FROM public.mejor_oportunidad_hoy(500) m JOIN _vmm_before b USING (espn_event_id);
  IF g5_viol<>0 THEN RAISE EXCEPTION 'FAIL G5 % eventos MLB con stake/kelly>0 (CTA económica prohibida)', g5_viol; END IF;
  IF g5_rows=0 THEN n_empty:=n_empty+1; empty_list:=empty_list||'G5 ';
    RAISE NOTICE 'PASS_EMPTY_COVERAGE G5: 0 filas MLB en mejor_oportunidad_hoy (NO es cobertura sustantiva)';
  ELSE RAISE NOTICE 'PASS_NONEMPTY G5 stake=0 en % filas MLB evaluadas', g5_rows; END IF;

  ---------- H. AUTORIDAD ECONÓMICA — INDEPENDIENTE DE LA CARTELERA (nuevo en V2) ----------
  -- Estas sondas NO dependen de que haya partidos ni usuarios hoy: siempre tienen cobertura.
  SELECT count(*) INTO h_auth FROM public.economic_model_authority WHERE economic_authorized IS TRUE;
  IF h_auth<>0 THEN RAISE EXCEPTION 'FAIL H1 modelos autorizados=% (exp 0 = NONE)', h_auth; END IF;
  RAISE NOTICE 'PASS_NONEMPTY H1 economic_model_authority autorizados = 0 (CURRENT_AUTHORIZED_MODELS=NONE)';

  SELECT count(*) INTO h_mlb FROM public.economic_model_authority
   WHERE economic_authorized IS TRUE AND deporte='baseball';
  IF h_mlb<>0 THEN RAISE EXCEPTION 'FAIL H2 MLB autorizado=% (exp 0)', h_mlb; END IF;
  RAISE NOTICE 'PASS_NONEMPTY H2 MLB economic_authorized = FALSE (0 filas autorizadas)';

  SELECT j->>'eligible', j->>'reason_code' INTO h3_e,h3_r FROM (
    SELECT economic_eligibility_v1(jsonb_build_object('deporte','baseball','mercado','Moneyline',
      'fuente','motor_mlb_cuantitativo','model_version',NULL::text,
      'ev_pct',99.0,'ev_threshold',2.5)) j) q;
  IF h3_e<>'false' OR h3_r<>'MODEL_VERSION_PROVENANCE_MISSING' THEN
    RAISE EXCEPTION 'FAIL H3 ctx MLB real -> eligible=% reason=%', h3_e,h3_r; END IF;
  RAISE NOTICE 'PASS_NONEMPTY H3 gate MLB (ctx real, EV=99) -> eligible=false / MODEL_VERSION_PROVENANCE_MISSING';

  -- H4 ADVERSARIAL: aun forzando model_version + SKILL_PASS + todos los gates,
  -- el registro vacío debe mantener eligible=false. Cierra la superficie de bypass.
  SELECT j->>'eligible', j->>'reason_code' INTO h4_e,h4_r FROM (
    SELECT economic_eligibility_v1(jsonb_build_object('deporte','baseball','mercado','Moneyline',
      'fuente','motor_mlb_cuantitativo','model_version','v99.9','model_skill','SKILL_PASS',
      'empirical_sufficiency','OK','semantic_validity','PASS','data_readiness','READY',
      'exact_decision_price','true','market_abstention',false,
      'ev_pct',99.0,'ev_threshold',2.5)) j) q;
  IF h4_e<>'false' OR h4_r<>'ECONOMIC_MODEL_UNAUTHORIZED' THEN
    RAISE EXCEPTION 'FAIL H4 BYPASS: ctx forzado -> eligible=% reason=% (exp false/ECONOMIC_MODEL_UNAUTHORIZED)', h4_e,h4_r; END IF;
  RAISE NOTICE 'PASS_NONEMPTY H4 bypass adversarial cerrado -> eligible=false / ECONOMIC_MODEL_UNAUTHORIZED';

  SELECT public.economic_model_authorized('baseball','Moneyline','motor_mlb_cuantitativo','v99.9') INTO h5;
  IF h5 IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL H5 economic_model_authorized=% (exp false)', h5; END IF;
  RAISE NOTICE 'PASS_NONEMPTY H5 economic_model_authorized(baseball,...) = false';

  -- H6 MODEL_SKILL = INSUFFICIENT (gate g_skill del ctx que pasan las superficies)
  SELECT j->'gates'->>'model_skill' INTO h6 FROM (
    SELECT economic_eligibility_v1(jsonb_build_object('deporte','baseball','mercado','Moneyline',
      'fuente','motor_mlb_cuantitativo','model_version',NULL::text,
      'ev_pct',99.0,'ev_threshold',2.5)) j) q;
  IF h6<>'false' THEN RAISE EXCEPTION 'FAIL H6 gate model_skill=% (exp false = INSUFFICIENT)', h6; END IF;
  RAISE NOTICE 'PASS_NONEMPTY H6 MODEL_SKILL = INSUFFICIENT (gate model_skill=false)';

  ---------- I. ISS-003a: calibracion_confiable MLB = FALSE (cobertura medida) ----------
  SELECT mlb_true INTO i1_before_true FROM _calib_before;
  SELECT count(*) FILTER (WHERE calibracion_confiable IS TRUE), count(*) INTO i1_true,i1_rows
    FROM public.v_pick_canonico WHERE deporte LIKE 'baseball%';
  IF i1_true<>0 THEN RAISE EXCEPTION 'FAIL I1 MLB calibracion_confiable=true=% de % filas (exp 0)', i1_true,i1_rows; END IF;
  IF i1_rows=0 THEN n_empty:=n_empty+1; empty_list:=empty_list||'I1 ';
    RAISE NOTICE 'PASS_EMPTY_COVERAGE I1: 0 filas MLB en v_pick_canonico (NO es cobertura sustantiva)';
  ELSE RAISE NOTICE 'PASS_NONEMPTY I1 MLB calibracion_confiable=false en % filas (pre-deploy true=%)', i1_rows,i1_before_true; END IF;

  ---------- RESUMEN DE COBERTURA ----------
  IF n_empty=0 THEN
    RAISE NOTICE '==== POST-VERIFY OK: A-I todos PASS, cobertura sustantiva en todos los asserts económicos ====';
  ELSE
    RAISE NOTICE '==== POST-VERIFY OK: A-I todos PASS. ATENCION: % assert(s) con conjunto vacio (%) -> PASS_EMPTY_COVERAGE, NO cuentan como cobertura real ====', n_empty, trim(empty_list);
  END IF;
  RAISE NOTICE '==== COMMIT permitido ====';
END $verify$;

COMMIT;
