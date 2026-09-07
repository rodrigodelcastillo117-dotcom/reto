-- ============================================================================
-- DEPLOY TURNKEY — ISS-003 / ISS-009 / ISS-009B (una sola transacción, atómico)
-- ============================================================================
-- USO (desde la raíz del repo, con psql y una conexión a PROD):
--   1) Verificar freeze del artefacto ANTES:
--        sha256sum shadow-patches/iss003_009_mlb_governance.sql
--        == 57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad
--        (si no coincide: SHA_DRIFT -> ABORT, no ejecutar).
--   2) psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f shadow-patches/deploy/deploy_iss003_009.sql
--        - todo corre en UNA transacción; si CUALQUIER assert falla -> ROLLBACK total.
--        - sin reintento automático. No modificar el SQL durante el deploy.
--   3) Si sale COMMIT: correr shadow-patches/deploy/smoke_post_commit.sql (read-only).
--   4) Si algo falla: correr shadow-patches/rollback/iss003_009_rollback.sql y verificar.
-- Invariantes: CURRENT_AUTHORIZED_MODELS=NONE, MLB economic_authorized=FALSE, MLB stake=$0.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;   -- snapshot estable para paridad P/EV y visibilidad
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '120s';

-- ---- baselines drift-safe ANTES de la primera DDL (fijan el snapshot) --------
CREATE TEMP TABLE _vpc_base ON COMMIT DROP AS
  SELECT ordinal_position, column_name, data_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
CREATE TEMP TABLE _pev_before ON COMMIT DROP AS
  SELECT espn_event_id, mercado, pick_nombre, probabilidad_pct, ev_pct
    FROM public.v_pick_canonico;
CREATE TEMP TABLE _vmm_before ON COMMIT DROP AS
  SELECT espn_event_id, nivel FROM public.v_mejores_picks_mlb;   -- DISTINCT ON (espn_event_id): 1 fila/evento

-- ============================================================================
-- ARTEFACTO CONGELADO, BYTE-EXACTO (SHA 57b7a40...cad) — orden literal 1 -> 2 -> 4
-- ============================================================================
\ir ../iss003_009_mlb_governance.sql

-- ============================================================================
-- POST-VERIFY (misma transacción, antes del COMMIT) — RAISE EXCEPTION => ROLLBACK
-- ============================================================================
DO $verify$
DECLARE
  ncol int; c44 text; t44 text; ndiff int; ncalls int; n_ovl int;
  ac_ee int; ac_rc int;
  vpc_es_pick int; vmm_reco int; vmm_elig int;
  moh_kelly int; reto_monto int; reto_puede int;
  p_diff int; ev_diff int;
  g_missing int; g_notinfo int; g_badreason int;
BEGIN
  ---------- A. CONTRATO v_pick_canonico ----------
  SELECT count(*) INTO ncol FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
  IF ncol<>44 THEN RAISE EXCEPTION 'FAIL A1 vpc cols=% (exp 44)', ncol; END IF;
  SELECT column_name,data_type INTO c44,t44 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position=44;
  IF c44 IS DISTINCT FROM 'es_pick_reason' OR t44 IS DISTINCT FROM 'text'
    THEN RAISE EXCEPTION 'FAIL A2 col44=%/%', c44,t44; END IF;
  SELECT count(*) INTO ndiff FROM (
    SELECT ordinal_position,column_name,data_type FROM _vpc_base
    EXCEPT
    SELECT ordinal_position,column_name,data_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position<=43) d;
  IF ndiff<>0 THEN RAISE EXCEPTION 'FAIL A3 primeras-43 drift=%', ndiff; END IF;
  SELECT (length(v)-length(replace(v,'economic_eligibility_v1(','')))/length('economic_eligibility_v1(')
    INTO ncalls FROM (SELECT pg_get_viewdef('public.v_pick_canonico'::regclass,true) v) q;
  IF ncalls<>1 THEN RAISE EXCEPTION 'FAIL A4 eev1 calls=% (exp 1)', ncalls; END IF;

  ---------- B. analisis_completo (overload guard + llaves, SIN LIMIT 1) ----------
  SELECT count(*) INTO n_ovl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='analisis_completo';
  IF n_ovl<>1 THEN RAISE EXCEPTION 'FAIL B0 analisis_completo overloads=% (exp 1) ABORT', n_ovl; END IF;
  SELECT (length(d)-length(replace(d,'economically_eligible','')))/length('economically_eligible'),
         (length(d)-length(replace(d,'eligibility_reason_code','')))/length('eligibility_reason_code')
    INTO ac_ee,ac_rc
    FROM (SELECT pg_get_functiondef('public.analisis_completo(text)'::regprocedure) d) q;
  IF ac_ee<1 OR ac_rc<1 THEN RAISE EXCEPTION 'FAIL B1 keys ee=% rc=%', ac_ee,ac_rc; END IF;

  ---------- C. CONTRATO v_mejores_picks_mlb ----------
  PERFORM 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='v_mejores_picks_mlb' AND column_name='economically_eligible';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C1 vmm falta economically_eligible'; END IF;
  PERFORM 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='v_mejores_picks_mlb' AND column_name='reason_code';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C2 vmm falta reason_code'; END IF;

  ---------- D. INVARIANTES BAJO NONE ----------
  SELECT count(*) INTO vpc_es_pick FROM public.v_pick_canonico WHERE es_pick IS TRUE;
  IF vpc_es_pick<>0 THEN RAISE EXCEPTION 'FAIL D1 es_pick=true=% (exp 0)', vpc_es_pick; END IF;
  SELECT count(*) INTO vmm_reco FROM public.v_mejores_picks_mlb WHERE nivel IN ('ojo','fuerte');
  IF vmm_reco<>0 THEN RAISE EXCEPTION 'FAIL D2 vmm nivel ojo/fuerte=% (exp 0)', vmm_reco; END IF;
  SELECT count(*) INTO vmm_elig FROM public.v_mejores_picks_mlb WHERE economically_eligible IS TRUE;
  IF vmm_elig<>0 THEN RAISE EXCEPTION 'FAIL D3 vmm economically_eligible=true=% (exp 0)', vmm_elig; END IF;

  ---------- E. DINERO REAL (superficies automáticas en alcance) ----------
  SELECT count(*) INTO moh_kelly FROM public.mejor_oportunidad_hoy(500) WHERE kelly_pct>0;
  IF moh_kelly<>0 THEN RAISE EXCEPTION 'FAIL E1 mejor_oportunidad_hoy kelly_pct>0=% (exp 0)', moh_kelly; END IF;
  SELECT count(*) INTO reto_monto FROM public.usuarios u
    CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r WHERE r.monto_autorizado>0;
  IF reto_monto<>0 THEN RAISE EXCEPTION 'FAIL E2 reto monto_autorizado>0=% (exp 0)', reto_monto; END IF;
  SELECT count(*) INTO reto_puede FROM public.usuarios u
    CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r WHERE r.puede_apostar IS TRUE;
  IF reto_puede<>0 THEN RAISE EXCEPTION 'FAIL E3 reto puede_apostar=% (exp 0)', reto_puede; END IF;

  ---------- F. PARIDAD P/EV (BEFORE vs AFTER, bidireccional) ----------
  SELECT count(*) INTO p_diff FROM (
    (SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM _pev_before
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM public.v_pick_canonico)
    UNION ALL
    (SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM public.v_pick_canonico
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM _pev_before)) d;
  IF p_diff<>0 THEN RAISE EXCEPTION 'FAIL F1 P_VALUE_DIFF=% (exp 0)', p_diff; END IF;
  SELECT count(*) INTO ev_diff FROM (
    (SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM _pev_before
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM public.v_pick_canonico)
    UNION ALL
    (SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM public.v_pick_canonico
     EXCEPT ALL SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM _pev_before)) d;
  IF ev_diff<>0 THEN RAISE EXCEPTION 'FAIL F2 EV_VALUE_DIFF=% (exp 0)', ev_diff; END IF;

  ---------- G. ISS-009 VISIBILIDAD SEMÁNTICA (las MLB degradadas NO desaparecen) ----------
  -- G1: ninguna fila MLB presente antes desaparece después
  SELECT count(*) INTO g_missing FROM (
    SELECT espn_event_id FROM _vmm_before
    EXCEPT
    SELECT espn_event_id FROM public.v_mejores_picks_mlb) d;
  IF g_missing<>0 THEN RAISE EXCEPTION 'FAIL G1 % filas MLB desaparecieron (deben quedar informativas)', g_missing; END IF;
  -- G2: las que eran ojo/fuerte ahora deben ser 'informativo' (no borradas)
  SELECT count(*) INTO g_notinfo FROM public.v_mejores_picks_mlb v
    JOIN _vmm_before b USING (espn_event_id)
   WHERE b.nivel IN ('ojo','fuerte') AND v.nivel <> 'informativo';
  IF g_notinfo<>0 THEN RAISE EXCEPTION 'FAIL G2 % degradadas no quedaron informativo', g_notinfo; END IF;
  -- G3: toda MLB visible con economically_eligible=false y reason_code no nulo (sin stake: la vista no dimensiona)
  SELECT count(*) INTO g_badreason FROM public.v_mejores_picks_mlb
   WHERE economically_eligible IS DISTINCT FROM false OR reason_code IS NULL;
  IF g_badreason<>0 THEN RAISE EXCEPTION 'FAIL G3 % filas MLB sin economically_eligible=false/reason_code', g_badreason; END IF;

  RAISE NOTICE 'POST-VERIFY OK — A/B/C/D contrato+NONE, E dinero=0, F paridad P/EV=0, G visibilidad MLB informativa intacta';
END $verify$;

COMMIT;
