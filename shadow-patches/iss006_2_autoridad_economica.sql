-- =====================================================================
-- ISS-006.2 — ECONOMIC MODEL AUTHORITY (autorización económica explícita)
-- ** PATCH SHADOW — NO APLICAR sin GO. **
-- Validado READ-ONLY contra prod (wpiztubmmmzclhlprgpd) en transacciones
-- BEGIN…ROLLBACK: compila sobre el esquema real y produce 0 picks económicos.
--
-- REGLA CANÓNICA:
--   MODEL_OUTPUT_EXISTS  != ECONOMICALLY_ELIGIBLE.
--   ECONOMICALLY_ELIGIBLE :=
--       ECONOMIC_MODEL_AUTHORIZED  (registro explícito por deporte,mercado,fuente,model_version)
--   AND MODEL_SKILL_PASS           (proxy: calibracion_confiable IS TRUE ; NULL = FAIL)
--   AND EMPIRICAL_SUFFICIENCY_OK   (muestra ya exigida aguas arriba)
--   AND SEMANTIC_VALIDITY          (pick_sin_discrepancia_motores)
--   AND DATA_READINESS             (dato clave donde aplica)
--   AND EXACT_DECISION_PRICE       (momio_mercado NOT NULL — precio real)
--   AND EV > threshold
--   AND NOT MARKET_ABSTENTION
--   Ningún COALESCE(NULL,TRUE) en gates de dinero. NULL = FAIL. Fail-closed.
--
-- El patch usa transformación replace() sobre la definición VIVA: si prod
-- deriva y un substring objetivo ya no existe, aborta (SUBSTR_NOT_FOUND) y
-- hace ROLLBACK — no deja deploy parcial.
-- =====================================================================

BEGIN;
SET LOCAL lock_timeout = '8s';
SET LOCAL statement_timeout = '120s';

-- ---------------------------------------------------------------------
-- (1) REGISTRO con trazabilidad. Default economic_authorized = FALSE.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.economic_model_authority (
  deporte             text        NOT NULL,
  mercado             text        NOT NULL,
  fuente              text        NOT NULL,
  model_version       text        NOT NULL DEFAULT '*',
  economic_authorized boolean     NOT NULL DEFAULT false,
  reason              text        NOT NULL,
  authorized_at       timestamptz,
  authorized_by       text,
  actualizado_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (deporte, mercado, fuente, model_version)
);
REVOKE ALL ON public.economic_model_authority FROM anon, authenticated, PUBLIC;
GRANT SELECT ON public.economic_model_authority TO authenticated, service_role;

-- SEMILLA (gobernanza ACTUAL) — TODO en $0 (fail-closed real):
INSERT INTO public.economic_model_authority
  (deporte, mercado, fuente, model_version, economic_authorized, reason, authorized_by)
VALUES
  ('soccer',  'Moneyline', 'motor_picks',            'llm',    false, 'LLM_NOT_VALIDATED',        'iss006_2'),
  ('soccer',  'Moneyline', 'motor_futbol_calibrado', 'c1',     false, 'FORWARD_EVIDENCE_PENDING', 'iss006_2'),
  ('baseball','Moneyline', 'motor_mlb_cuantitativo', 'mlb_v1', false, 'SKILL_INSUFFICIENT',       'iss006_2'),
  ('soccer',  'Moneyline', 'motor_cache',            'v1',     false, 'FORWARD_EVIDENCE_PENDING', 'iss006_2'),
  ('baseball','Moneyline', 'motor_cache',            'v1',     false, 'SKILL_INSUFFICIENT',       'iss006_2'),
  ('football','Moneyline', 'motor_cache',            'v1',     false, 'NFL_MODEL_OFF',            'iss006_2'),
  ('soccer',  'Moneyline', 'motor_pick_del_dia',     'v1',     false, 'FORWARD_EVIDENCE_PENDING', 'iss006_2'),
  ('baseball','Moneyline', 'motor_pick_del_dia',     'v1',     false, 'SKILL_INSUFFICIENT',       'iss006_2')
ON CONFLICT (deporte, mercado, fuente, model_version) DO NOTHING;

-- ---------------------------------------------------------------------
-- (2) LA PREGUNTA ÚNICA + helpers.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.economic_model_authorized(
  p_deporte text, p_mercado text, p_fuente text, p_model_version text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public'
AS $fn$
  SELECT COALESCE((
    SELECT a.economic_authorized FROM public.economic_model_authority a
    WHERE a.deporte = p_deporte AND a.mercado = p_mercado AND a.fuente = p_fuente
      AND a.model_version = COALESCE(p_model_version, '')  -- ALLOW nombra versión exacta; NULL no hereda
      AND a.economic_authorized = true
    LIMIT 1
  ), false);
$fn$;
REVOKE ALL ON FUNCTION public.economic_model_authorized(text,text,text,text) FROM anon, PUBLIC;

CREATE OR REPLACE FUNCTION public.deporte_registry(p_dep text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT case when p_dep ilike 'baseball%' then 'baseball'
              when p_dep ilike 'football%' or p_dep = 'NFL' then 'football'
              else 'soccer' end;
$fn$;

CREATE OR REPLACE FUNCTION public.model_version_de_fuente(p_fuente text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
  SELECT case p_fuente
    when 'motor_picks' then 'llm' when 'motor_futbol_calibrado' then 'c1'
    when 'motor_mlb_cuantitativo' then 'mlb_v1' when 'motor_cache' then 'v1'
    when 'motor_pick_del_dia' then 'v1' else '' end;
$fn$;

-- ---------------------------------------------------------------------
-- (3) GATE de las 5 cabezas económicas por transformación replace() de
--     la definición viva (byte-fidelity; aborta si el substring cambió).
-- ---------------------------------------------------------------------
DO $patch$
DECLARE s text; s2 text;
BEGIN
  -- 3a) v_pick_canonico.es_pick  (=> reto_picks_hoy, rongol_veto, v_oraculo_canonico, revisar_apuesta)
  s := pg_get_viewdef('public.v_pick_canonico'::regclass, true);
  s2 := replace(s,
    'c.momio_mercado IS NOT NULL AND COALESCE(c.ev_pct, ''-1''::integer::numeric) >= 2.5 AND NOT (c.deporte ~~ ''baseball%''::text AND c.mercado = ''Over/Under''::text) AND COALESCE(c.calibracion_confiable, true) AND pick_sin_discrepancia_motores(c.espn_event_id, c.mercado, c.pick_desc) AND NOT mercado_en_abstencion(c.mercado, c.pick_desc) AS es_pick',
    '(public.economic_model_authorized(public.deporte_registry(c.deporte), c.mercado, c.fuente, public.model_version_de_fuente(c.fuente)) AND c.momio_mercado IS NOT NULL AND COALESCE(c.ev_pct, ''-1''::integer::numeric) >= 2.5 AND NOT (c.deporte ~~ ''baseball%''::text AND c.mercado = ''Over/Under''::text) AND c.calibracion_confiable IS TRUE AND pick_sin_discrepancia_motores(c.espn_event_id, c.mercado, c.pick_desc) AND NOT mercado_en_abstencion(c.mercado, c.pick_desc)) AS es_pick');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: v_pick_canonico.es_pick'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_pick_canonico AS '||s2;

  -- 3b) mejor_oportunidad_hoy: elimina la reconstrucción a mano; usa es_pick ya gateado.
  s := pg_get_functiondef('public.mejor_oportunidad_hoy(integer)'::regprocedure);
  s2 := replace(s, 'and (coalesce(v.calibracion_confiable, true) or v.mercado = ''Moneyline'')', 'and v.es_pick');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: mejor_oportunidad_hoy'; END IF;
  EXECUTE s2;

  -- 3c) favoritos_bien_pagados: gate info_completa + fraccion (=> RETO 13M / reto_registrar_favoritos)
  s := pg_get_functiondef('public.favoritos_bien_pagados(numeric,numeric,numeric)'::regprocedure);
  s2 := replace(s,
    '(p.dato_clave_ok and not p.fuera_de_rango and (p.pu - 1/p.m) <= 0.12)',
    '(public.economic_model_authorized(p.dep_cal, ''Moneyline'', ''motor_cache'', ''v1'') and p.dato_clave_ok and not p.fuera_de_rango and (p.pu - 1/p.m) <= 0.12)');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: fbp.info_completa'; END IF;
  s := s2;
  s2 := replace(s,
    'round((public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>''pct'')::numeric/100.0, 4),',
    'case when public.economic_model_authorized(p.dep_cal, ''Moneyline'', ''motor_cache'', ''v1'') then round((public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>''pct'')::numeric/100.0, 4) else 0 end,');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: fbp.fraccion'; END IF;
  EXECUTE s2;

  -- 3d) v_super_pick (DESTACADOS): gate apto_para_mostrar + kelly_pct_sugerido
  s := pg_get_viewdef('public.v_super_pick'::regclass, true);
  s2 := replace(s, 'apto AS apto_para_mostrar,',
    '(apto AND public.economic_model_authorized(public.deporte_registry(deporte), ''Moneyline'', ''motor_picks'', ''llm'')) AS apto_para_mostrar,');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: v_super_pick.apto'; END IF;
  s := s2;
  s2 := replace(s, 'round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct, 1.0))), 2) AS kelly_pct_sugerido,',
    'CASE WHEN public.economic_model_authorized(public.deporte_registry(deporte), ''Moneyline'', ''motor_picks'', ''llm'') THEN round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct, 1.0))), 2) ELSE 0 END AS kelly_pct_sugerido,');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: v_super_pick.kelly'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_super_pick AS '||s2;

  -- 3e) tg_filtrar_pick_del_dia: gate kelly (2 asignaciones)
  s := pg_get_functiondef('public.tg_filtrar_pick_del_dia()'::regprocedure);
  s2 := replace(s, 'NEW.kelly_pct_sugerido := v_kelly;',
    'NEW.kelly_pct_sugerido := case when public.economic_model_authorized(public.deporte_registry(NEW.deporte), ''Moneyline'', ''motor_pick_del_dia'', ''v1'') then v_kelly else 0 end;');
  IF s2 = s THEN RAISE EXCEPTION 'SUBSTR_NOT_FOUND: tg_filtrar_pick_del_dia'; END IF;
  EXECUTE s2;
END
$patch$;

-- ---------------------------------------------------------------------
-- (4) POST-VERIFY dentro de la misma transacción: si no queda todo en 0
--     bajo la semilla (todo denegado), aborta.
-- ---------------------------------------------------------------------
DO $verify$
DECLARE n_espick int; n_reto int; n_fbp int; n_moh int; n_super int;
BEGIN
  SELECT count(*) INTO n_espick FROM public.v_pick_canonico WHERE es_pick;
  SELECT count(*) INTO n_fbp    FROM public.favoritos_bien_pagados(1.01,15.0,0.01) WHERE info_completa;
  SELECT count(*) INTO n_moh    FROM public.mejor_oportunidad_hoy(50);
  SELECT count(*) INTO n_super  FROM public.v_super_pick WHERE apto_para_mostrar;
  IF (n_espick + n_fbp + n_moh + n_super) <> 0 THEN
    RAISE EXCEPTION 'POST_VERIFY_FAIL: es_pick=% fbp=% moh=% super=%', n_espick, n_fbp, n_moh, n_super;
  END IF;
END
$verify$;

COMMIT;

-- =====================================================================
-- REACTIVACIÓN (cuando un modelo/versión gane autorización, con evidencia):
--   UPDATE public.economic_model_authority
--      SET economic_authorized=true, reason='AUTHORIZED_AFTER_VALIDATION',
--          authorized_at=now(), authorized_by='<quien>'
--    WHERE deporte='soccer' AND mercado='Moneyline'
--      AND fuente='motor_futbol_calibrado' AND model_version='c1';
--   (una sola fila, auditable; NO toca código)
-- =====================================================================
