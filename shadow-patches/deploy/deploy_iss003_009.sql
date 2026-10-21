-- ============================================================================
-- DEPLOY TURNKEY — ISS-003 / ISS-009 / ISS-009B (una sola transacción, atómico)
-- ============================================================================
-- Recomendado: correr vía shadow-patches/deploy/run_deploy.sh (verifica SHA antes).
-- Directo:
--   1) sha256sum shadow-patches/iss003_009_mlb_governance.sql
--      == 57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad  (si no: SHA_DRIFT -> ABORT)
--   2) psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f shadow-patches/deploy/deploy_iss003_009.sql
--      - todo en UNA transacción; cada invariante emite 'PASS x'; el primer 'FAIL' -> ROLLBACK total.
--      - sin reintento automático. No modificar el SQL durante el deploy.
--   3) OK -> smoke_post_commit.sql (read-only).  FALLO -> iss003_009_rollback.sql.
-- Invariantes: CURRENT_AUTHORIZED_MODELS=NONE, MLB economic_authorized=FALSE, MLB stake=$0.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;   -- snapshot estable (paridad P/EV + visibilidad)
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '120s';

-- ---- baselines drift-safe ANTES de la primera DDL (fijan el snapshot) --------
CREATE TEMP TABLE _vpc_base ON COMMIT DROP AS
  SELECT ordinal_position, column_name, data_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
CREATE TEMP TABLE _pev_before ON COMMIT DROP AS
  SELECT espn_event_id, mercado, pick_nombre, probabilidad_pct, ev_pct FROM public.v_pick_canonico;
CREATE TEMP TABLE _vmm_before ON COMMIT DROP AS
  SELECT espn_event_id, nivel FROM public.v_mejores_picks_mlb;   -- DISTINCT ON (espn_event_id): 1 fila/evento

-- ============================================================================
-- ARTEFACTO CONGELADO, BYTE-EXACTO (SHA 57b7a40...cad) — orden literal 1 -> 2 -> 4
-- ============================================================================
\ir ../iss003_009_mlb_governance.sql

-- ============================================================================
-- POST-VERIFY (misma transacción, antes del COMMIT) — PASS por invariante; FAIL -> ROLLBACK
-- ============================================================================
DO $verify$
DECLARE
  ncol int; c44 text; t44 text; ndiff int; ncalls int; n_ovl int; ac_ee int; ac_rc int;
  vpc_es_pick int; vmm_reco int; vmm_elig int;
  moh_kelly int; reto_monto int; reto_puede int; p_diff int; ev_diff int;
  n_before_reco int; g_missing int; g_notinfo int; g_elig int; g_reason int; g_stake int;
BEGIN
  ---------- A. CONTRATO v_pick_canonico ----------
  SELECT count(*) INTO ncol FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
  IF ncol<>44 THEN RAISE EXCEPTION 'FAIL A1 vpc cols=% (exp 44)', ncol; END IF;
  RAISE NOTICE 'PASS A1 v_pick_canonico = 44 columnas';

  SELECT column_name,data_type INTO c44,t44 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position=44;
  IF c44 IS DISTINCT FROM 'es_pick_reason' OR t44 IS DISTINCT FROM 'text'
    THEN RAISE EXCEPTION 'FAIL A2 col44=%/%', c44,t44; END IF;
  RAISE NOTICE 'PASS A2 col44 = es_pick_reason text';

  SELECT count(*) INTO ndiff FROM (
    SELECT ordinal_position,column_name,data_type FROM _vpc_base
    EXCEPT
    SELECT ordinal_position,column_name,data_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position<=43) d;
  IF ndiff<>0 THEN RAISE EXCEPTION 'FAIL A3 primeras-43 drift=%', ndiff; END IF;
  RAISE NOTICE 'PASS A3 primeras 43 columnas idénticas';

  SELECT (length(v)-length(replace(v,'economic_eligibility_v1(','')))/length('economic_eligibility_v1(')
    INTO ncalls FROM (SELECT pg_get_viewdef('public.v_pick_canonico'::regclass,true) v) q;
  IF ncalls<>1 THEN RAISE EXCEPTION 'FAIL A4 eev1 calls=% (exp 1)', ncalls; END IF;
  RAISE NOTICE 'PASS A4 economic_eligibility_v1 llamada 1 sola vez';

  ---------- B. analisis_completo (overload guard + llaves, SIN LIMIT 1) ----------
  SELECT count(*) INTO n_ovl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='analisis_completo';
  IF n_ovl<>1 THEN RAISE EXCEPTION 'FAIL B0 analisis_completo overloads=% (exp 1) ABORT', n_ovl; END IF;
  RAISE NOTICE 'PASS B0 analisis_completo overload_count = 1';
  SELECT (length(d)-length(replace(d,'economically_eligible','')))/length('economically_eligible'),
         (length(d)-length(replace(d,'eligibility_reason_code','')))/length('eligibility_reason_code')
    INTO ac_ee,ac_rc FROM (SELECT pg_get_functiondef('public.analisis_completo(text)'::regprocedure) d) q;
  IF ac_ee<1 OR ac_rc<1 THEN RAISE EXCEPTION 'FAIL B1 keys ee=% rc=%', ac_ee,ac_rc; END IF;
  RAISE NOTICE 'PASS B1 analisis_completo propaga economically_eligible + eligibility_reason_code';

  ---------- C. CONTRATO v_mejores_picks_mlb ----------
  PERFORM 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='v_mejores_picks_mlb' AND column_name='economically_eligible';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C1 vmm falta economically_eligible'; END IF;
  PERFORM 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='v_mejores_picks_mlb' AND column_name='reason_code';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C2 vmm falta reason_code'; END IF;
  RAISE NOTICE 'PASS C1/C2 v_mejores_picks_mlb con economically_eligible + reason_code';

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

  ---------- E. DINERO REAL (superficies automáticas en alcance) ----------
  SELECT count(*) INTO moh_kelly FROM public.mejor_oportunidad_hoy(500) WHERE kelly_pct>0;
  IF moh_kelly<>0 THEN RAISE EXCEPTION 'FAIL E1 mejor_oportunidad_hoy kelly_pct>0=% (exp 0)', moh_kelly; END IF;
  RAISE NOTICE 'PASS E1 mejor_oportunidad_hoy kelly_pct>0 = 0';
  SELECT count(*) INTO reto_monto FROM public.usuarios u
    CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r WHERE r.monto_autorizado>0;
  IF reto_monto<>0 THEN RAISE EXCEPTION 'FAIL E2 reto monto_autorizado>0=% (exp 0)', reto_monto; END IF;
  RAISE NOTICE 'PASS E2 reto_picks_hoy monto_autorizado>0 = 0 (todos los usuarios)';
  SELECT count(*) INTO reto_puede FROM public.usuarios u
    CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r WHERE r.puede_apostar IS TRUE;
  IF reto_puede<>0 THEN RAISE EXCEPTION 'FAIL E3 reto puede_apostar=% (exp 0)', reto_puede; END IF;
  RAISE NOTICE 'PASS E3 reto_picks_hoy puede_apostar = 0 (todos los usuarios)';

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

  ---------- G. ISS-009 VISIBILIDAD SEMÁNTICA (obligatorio) ----------
  SELECT count(*) INTO n_before_reco FROM _vmm_before WHERE nivel IN ('ojo','fuerte');
  RAISE NOTICE 'INFO G0 filas MLB ojo/fuerte pre-deploy = % (dinámico segun cartelera del dia)', n_before_reco;

  -- G1 ningún evento MLB presente antes desaparece
  SELECT count(*) INTO g_missing FROM (
    SELECT espn_event_id FROM _vmm_before
    EXCEPT SELECT espn_event_id FROM public.v_mejores_picks_mlb) d;
  IF g_missing<>0 THEN RAISE EXCEPTION 'FAIL G1 % eventos MLB desaparecieron', g_missing; END IF;
  RAISE NOTICE 'PASS G1 ningún evento MLB desapareció (0)';

  -- G2 las ojo/fuerte pre-deploy siguen presentes y ahora son 'informativo'
  SELECT count(*) INTO g_notinfo FROM _vmm_before b
    LEFT JOIN public.v_mejores_picks_mlb v USING (espn_event_id)
   WHERE b.nivel IN ('ojo','fuerte') AND (v.espn_event_id IS NULL OR v.nivel <> 'informativo');
  IF g_notinfo<>0 THEN RAISE EXCEPTION 'FAIL G2 % degradadas no quedaron visibles como informativo', g_notinfo; END IF;
  RAISE NOTICE 'PASS G2 las % MLB ojo/fuerte quedan visibles como informativo', n_before_reco;

  -- G3 economically_eligible=false en TODA la MLB visible
  SELECT count(*) INTO g_elig FROM public.v_mejores_picks_mlb WHERE economically_eligible IS DISTINCT FROM false;
  IF g_elig<>0 THEN RAISE EXCEPTION 'FAIL G3 % filas MLB con economically_eligible<>false', g_elig; END IF;
  RAISE NOTICE 'PASS G3 economically_eligible=false en toda la MLB';

  -- G4 reason_code = degradación esperada (MODEL_VERSION_PROVENANCE_MISSING)
  SELECT count(*) INTO g_reason FROM public.v_mejores_picks_mlb
   WHERE reason_code IS DISTINCT FROM 'MODEL_VERSION_PROVENANCE_MISSING';
  IF g_reason<>0 THEN RAISE EXCEPTION 'FAIL G4 % filas reason_code<>MODEL_VERSION_PROVENANCE_MISSING', g_reason; END IF;
  RAISE NOTICE 'PASS G4 reason_code=MODEL_VERSION_PROVENANCE_MISSING en toda la MLB';

  -- G5 stake=0 / SIN CTA económica derivada de esas filas: ningún evento MLB genera kelly>0
  SELECT count(*) INTO g_stake FROM public.mejor_oportunidad_hoy(500) m
    JOIN _vmm_before b USING (espn_event_id) WHERE m.kelly_pct>0;
  IF g_stake<>0 THEN RAISE EXCEPTION 'FAIL G5 % eventos MLB con stake/kelly>0 (CTA económica prohibida)', g_stake; END IF;
  RAISE NOTICE 'PASS G5 stake=0 / sin CTA económica derivada de las filas MLB';

  RAISE NOTICE '==== POST-VERIFY OK: A/B/C/D/E/F/G todos PASS -> COMMIT permitido ====';
END $verify$;

COMMIT;
