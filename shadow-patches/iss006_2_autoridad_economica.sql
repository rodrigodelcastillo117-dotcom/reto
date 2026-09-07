-- =====================================================================
-- ISS-006.2 v2 — ECONOMIC MODEL AUTHORITY + CANONICAL ELIGIBILITY
-- ** PATCH SHADOW — NO APLICAR sin GO. **
-- Validado READ-ONLY contra prod (wpiztubmmmzclhlprgpd) en BEGIN…ROLLBACK:
-- engine 12/12 gate tests, versión-inheritance real, 5 cabezas -> ALL_ZERO.
--
-- PRINCIPIO (una sola decisión canónica):
--   modelo produce algo -> provenance REAL -> 8 gates -> economic_eligibility_v1
--   -> ECONOMICALLY_ELIGIBLE (+ reason_code) -> TODAS las pantallas.
--   NO cinco implementaciones del registry.
--
-- MODEL_VERSION: viene de la PROVENANCE real de la fila (model_version/id/hash).
--   Hoy NINGUNA fuente económica viva la almacena -> se pasa NULL == MISSING -> $0.
--   NO se inventa 'v1' para las superficies. Cuando una fuente empiece a guardar
--   su versión inmutable, se cablea aquí (jsonb 'model_version') y el registry decide.
--
-- 8 GATES (cada uno identificable, NULL = FALSE, fail-closed):
--   ECONOMIC_MODEL_AUTHORIZED (registry por deporte,mercado,fuente,model_version)
--   MODEL_SKILL_PASS          (señal de skill REAL; NO es calibracion_confiable)
--   EMPIRICAL_SUFFICIENCY_OK  (muestra; concepto distinto de skill)
--   SEMANTIC_VALIDITY
--   DATA_READINESS
--   EXACT_DECISION_PRICE      (bookmaker real + identidad de evento + market/side +
--                              snapshot pre-kickoff + ts válido + no live + no fantasma)
--   EV > threshold
--   NOT MARKET_ABSTENTION
-- =====================================================================

BEGIN;
SET LOCAL lock_timeout = '8s';
SET LOCAL statement_timeout = '120s';

-- (1) REGISTRO con trazabilidad. Default economic_authorized = FALSE. CURRENT_AUTHORIZED_MODELS = NONE.
CREATE TABLE IF NOT EXISTS public.economic_model_authority (
  deporte text NOT NULL, mercado text NOT NULL, fuente text NOT NULL, model_version text NOT NULL,
  economic_authorized boolean NOT NULL DEFAULT false,
  reason text NOT NULL, authorized_at timestamptz, authorized_by text,
  actualizado_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (deporte, mercado, fuente, model_version));
REVOKE ALL ON public.economic_model_authority FROM anon, authenticated, PUBLIC;
GRANT SELECT ON public.economic_model_authority TO authenticated, service_role;
-- Sin filas ALLOW: nada autorizado. (Un ALLOW futuro debe nombrar la versión REAL, p.ej.
--  INSERT (...,'soccer','Moneyline','motor_futbol_calibrado','<hash/version real>',true,'AUTHORIZED_AFTER_VALIDATION',now(),'<quien>'))

-- (2) authority lookup (ALLOW exige match exacto de version; sin herencia).
CREATE OR REPLACE FUNCTION public.economic_model_authorized(p_deporte text,p_mercado text,p_fuente text,p_model_version text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT COALESCE((SELECT a.economic_authorized FROM public.economic_model_authority a
    WHERE a.deporte=p_deporte AND a.mercado=p_mercado AND a.fuente=p_fuente
      AND a.model_version=p_model_version AND a.economic_authorized=true LIMIT 1), false);
$fn$;
REVOKE ALL ON FUNCTION public.economic_model_authorized(text,text,text,text) FROM anon, PUBLIC;

CREATE OR REPLACE FUNCTION public.deporte_registry(p_dep text) RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT case when p_dep ilike 'baseball%' then 'baseball'
              when p_dep ilike 'football%' or p_dep='NFL' then 'football' else 'soccer' end;
$fn$;

-- (3) EXACT_DECISION_PRICE real: bookmaker + identidad de evento + market/side +
--     snapshot pre-kickoff + ts reciente + overround sano (no fantasma). No live.
CREATE OR REPLACE FUNCTION public.exact_decision_price(p_event text,p_mercado text,p_pick text,p_home text,p_away text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT EXISTS (
    SELECT 1 FROM public.radar_odds_snapshots r
    JOIN public.agenda_espn a ON a.espn_event_id = r.espn_event_id           -- identidad exacta de evento + kickoff
    WHERE r.espn_event_id = p_event
      AND r.bookmaker IS NOT NULL                                            -- bookmaker real
      AND r.confiable IS TRUE                                                -- no fantasma
      AND r.overround IS NOT NULL AND r.overround BETWEEN 1.0 AND 1.25       -- overround sano (no interpolado)
      AND r.snapshot_at > now() - interval '3 days'                          -- ts de decisión válido
      AND r.snapshot_at < a.fecha                                           -- pre-kickoff (no live)
      AND ( (p_mercado='Moneyline' AND (
               (strpos(public.sin_acentos(p_pick), public.sin_acentos(p_home))>0 AND r.home_ml IS NOT NULL)
            OR (strpos(public.sin_acentos(p_pick), public.sin_acentos(p_away))>0 AND r.away_ml IS NOT NULL)
            OR (p_pick ~* 'empate' AND r.draw_ml IS NOT NULL)))
         OR (p_mercado='Over/Under' AND ((p_pick ~* 'over' AND r.over_odds IS NOT NULL)
                                      OR (p_pick ~* 'under' AND r.under_odds IS NOT NULL))) ));
$fn$;

-- (4) CANONICAL ECONOMIC ELIGIBILITY. Fail-closed. NULL = FALSE por gate. reason_code por gate.
CREATE OR REPLACE FUNCTION public.economic_eligibility_v1(p_ctx jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $fn$
DECLARE
  mv text := nullif(p_ctx->>'model_version','');
  g_prov  boolean := COALESCE(mv IS NOT NULL AND mv <> 'MISSING', false);
  g_auth  boolean := COALESCE(g_prov AND public.economic_model_authorized(p_ctx->>'deporte', p_ctx->>'mercado', p_ctx->>'fuente', mv), false);
  g_skill boolean := COALESCE((p_ctx->>'model_skill') = 'SKILL_PASS', false);
  g_emp   boolean := COALESCE((p_ctx->>'empirical_sufficiency') = 'OK', false);
  g_sem   boolean := COALESCE((p_ctx->>'semantic_validity') = 'PASS', false);
  g_data  boolean := COALESCE((p_ctx->>'data_readiness') = 'READY', false);
  g_price boolean := COALESCE((p_ctx->>'exact_decision_price') = 'true', false);
  g_ev    boolean := COALESCE((p_ctx->>'ev_pct') IS NOT NULL AND (p_ctx->>'ev_pct')::numeric > COALESCE((p_ctx->>'ev_threshold')::numeric, 0), false);
  g_abst  boolean := COALESCE((p_ctx->>'market_abstention')::boolean, true) = false;  -- NULL -> abstención -> FAIL
  reason text;
BEGIN
  reason := CASE
    WHEN NOT g_prov  THEN 'MODEL_VERSION_PROVENANCE_MISSING'
    WHEN NOT g_auth  THEN 'ECONOMIC_MODEL_UNAUTHORIZED'
    WHEN NOT g_skill THEN 'SKILL_INSUFFICIENT'
    WHEN NOT g_emp   THEN 'EMPIRICAL_SUFFICIENCY_PENDING'
    WHEN NOT g_sem   THEN 'SEMANTIC_INVALID'
    WHEN NOT g_data  THEN 'DATA_NOT_READY'
    WHEN NOT g_price THEN 'NO_EXACT_DECISION_PRICE'
    WHEN NOT g_abst  THEN 'MARKET_ABSTENTION'
    WHEN NOT g_ev    THEN 'EV_NO_POSITIVO'
    ELSE 'ELIGIBLE' END;
  RETURN jsonb_build_object(
    'eligible', (g_prov AND g_auth AND g_skill AND g_emp AND g_sem AND g_data AND g_price AND g_abst AND g_ev),
    'reason_code', reason,
    'gates', jsonb_build_object('economic_model_authorized',g_auth,'model_version_provenance',g_prov,
      'model_skill',g_skill,'empirical_sufficiency',g_emp,'semantic_validity',g_sem,'data_readiness',g_data,
      'exact_decision_price',g_price,'market_abstention_ok',g_abst,'ev',g_ev));
END $fn$;

-- (5) Las 5 cabezas consumen la MISMA decisión (replace byte-fidelity; SUBSTR_NOT_FOUND -> ROLLBACK).
--     model_version = NULL (MISSING) hasta que cada fuente exponga su provenance real.
DO $patch$
DECLARE s text; s2 text;
BEGIN
  -- 5a) v_pick_canonico.es_pick  (=> reto_picks_hoy, rongol_veto, v_oraculo_canonico, revisar_apuesta)
  s := pg_get_viewdef('public.v_pick_canonico'::regclass, true);
  s2 := replace(s,'c.momio_mercado IS NOT NULL AND COALESCE(c.ev_pct, ''-1''::integer::numeric) >= 2.5 AND NOT (c.deporte ~~ ''baseball%''::text AND c.mercado = ''Over/Under''::text) AND COALESCE(c.calibracion_confiable, true) AND pick_sin_discrepancia_motores(c.espn_event_id, c.mercado, c.pick_desc) AND NOT mercado_en_abstencion(c.mercado, c.pick_desc) AS es_pick',
    '(public.economic_eligibility_v1(jsonb_build_object(''deporte'',public.deporte_registry(c.deporte),''mercado'',c.mercado,''fuente'',c.fuente,''model_version'',NULL::text,''model_skill'',NULL::text,''empirical_sufficiency'',case when COALESCE(c.muestra_calibracion,0)>=20 then ''OK'' else ''PENDING'' end,''semantic_validity'',case when pick_sin_discrepancia_motores(c.espn_event_id,c.mercado,c.pick_desc) then ''PASS'' else ''FAIL'' end,''data_readiness'',''READY'',''exact_decision_price'',case when public.exact_decision_price(c.espn_event_id,c.mercado,c.pick_desc,c.home,c.away) then ''true'' else ''false'' end,''market_abstention'',public.mercado_en_abstencion(c.mercado,c.pick_desc),''ev_pct'',c.ev_pct,''ev_threshold'',2.5))->>''eligible'')::boolean AS es_pick');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: v_pick_canonico'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_pick_canonico AS '||s2;

  -- 5b) mejor_oportunidad_hoy: consume la decisión canónica (es_pick), sin reconstruir.
  s := pg_get_functiondef('public.mejor_oportunidad_hoy(integer)'::regprocedure);
  s2 := replace(s,'and (coalesce(v.calibracion_confiable, true) or v.mercado = ''Moneyline'')','and v.es_pick');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: mejor_oportunidad_hoy'; END IF; EXECUTE s2;

  -- 5c) favoritos_bien_pagados (RETO): engine para fuente motor_cache.
  s := pg_get_functiondef('public.favoritos_bien_pagados(numeric,numeric,numeric)'::regprocedure);
  s2 := replace(s,'(p.dato_clave_ok and not p.fuera_de_rango and (p.pu - 1/p.m) <= 0.12)',
    '((public.economic_eligibility_v1(jsonb_build_object(''deporte'',p.dep_cal,''mercado'',''Moneyline'',''fuente'',''motor_cache'',''model_version'',NULL::text))->>''eligible'')::boolean and p.dato_clave_ok and not p.fuera_de_rango and (p.pu - 1/p.m) <= 0.12)');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: fbp.info_completa'; END IF; s:=s2;
  s2 := replace(s,'round((public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>''pct'')::numeric/100.0, 4),',
    'case when (public.economic_eligibility_v1(jsonb_build_object(''deporte'',p.dep_cal,''mercado'',''Moneyline'',''fuente'',''motor_cache'',''model_version'',NULL::text))->>''eligible'')::boolean then round((public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>''pct'')::numeric/100.0, 4) else 0 end,');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: fbp.fraccion'; END IF; EXECUTE s2;

  -- 5d) v_super_pick (DESTACADOS): engine para fuente motor_picks.
  s := pg_get_viewdef('public.v_super_pick'::regclass, true);
  s2 := replace(s,'apto AS apto_para_mostrar,',
    '(apto AND (public.economic_eligibility_v1(jsonb_build_object(''deporte'',public.deporte_registry(deporte),''mercado'',''Moneyline'',''fuente'',''motor_picks'',''model_version'',NULL::text))->>''eligible'')::boolean) AS apto_para_mostrar,');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: v_super_pick.apto'; END IF; s:=s2;
  s2 := replace(s,'round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct, 1.0))), 2) AS kelly_pct_sugerido,',
    'CASE WHEN (public.economic_eligibility_v1(jsonb_build_object(''deporte'',public.deporte_registry(deporte),''mercado'',''Moneyline'',''fuente'',''motor_picks'',''model_version'',NULL::text))->>''eligible'')::boolean THEN round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct, 1.0))), 2) ELSE 0 END AS kelly_pct_sugerido,');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: v_super_pick.kelly'; END IF; EXECUTE 'CREATE OR REPLACE VIEW public.v_super_pick AS '||s2;

  -- 5e) tg_filtrar_pick_del_dia: engine para fuente motor_pick_del_dia.
  s := pg_get_functiondef('public.tg_filtrar_pick_del_dia()'::regprocedure);
  s2 := replace(s,'NEW.kelly_pct_sugerido := v_kelly;',
    'NEW.kelly_pct_sugerido := case when (public.economic_eligibility_v1(jsonb_build_object(''deporte'',public.deporte_registry(NEW.deporte),''mercado'',''Moneyline'',''fuente'',''motor_pick_del_dia'',''model_version'',NULL::text))->>''eligible'')::boolean then v_kelly else 0 end;');
  IF s2=s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: tg_filtrar_pick_del_dia'; END IF; EXECUTE s2;
END $patch$;

-- (6) POST-VERIFY: bajo la gobernanza actual (0 ALLOW) todo debe quedar en 0.
DO $verify$
DECLARE n int;
BEGIN
  SELECT (SELECT count(*) FROM public.v_pick_canonico WHERE es_pick)
       + (SELECT count(*) FROM public.favoritos_bien_pagados(1.01,15.0,0.01) WHERE info_completa)
       + (SELECT count(*) FROM public.mejor_oportunidad_hoy(50))
       + (SELECT count(*) FROM public.v_super_pick WHERE apto_para_mostrar) INTO n;
  IF n <> 0 THEN RAISE EXCEPTION 'POST_VERIFY_FAIL total_economico=%', n; END IF;
END $verify$;

COMMIT;
