-- ============================================================================
-- SECURITY HARDENING V1 — ISS-SEC-02 / ISS-SEC-03
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY. Requiere GO humano propio.
-- Atómico, sin DROP, sin CASCADE, reversible (ver sec_hardening_v1_rollback.sql).
--
-- SEC-03 (HIGH) — ESCRITURA ANÓNIMA EN EL LEDGER FORWARD
--   lab_mlb_fwd_capturar() y lab_mlb_fwd_resultado() son SECURITY DEFINER,
--   propiedad de postgres, escriben, y tienen EXECUTE concedido a anon.
--   Todos los campos de evidencia (decision_time, model_version, p_raw_home,
--   odds, eligibility) los aporta el llamante, y decision_id se deriva de
--   md5(event|decision_time|model_version) con ON CONFLICT DO NOTHING.
--   => Un cliente anónimo puede PRE-RECLAMAR un decision_id con datos falsos y
--      la captura legítima posterior se descarta en silencio.
--   => Contamina exactamente la evidencia forward de la que dependerá TOP PICK.
--   Además available_at_decision se computa de dos parámetros del llamante,
--   así que la propia marca de integridad temporal es forjable.
--
-- SEC-02 (MEDIUM) — SECURITY DEFINER sin search_path fijado (8 funciones).
--   Mitigado hoy porque anon/authenticated NO tienen CREATE en public
--   (verificado: has_schema_privilege = false), pero es defensa en profundidad
--   estándar y su ausencia es un hallazgo legítimo.
--
-- NO INCLUIDO AQUÍ a propósito: revocar SELECT de anon sobre las superficies de
-- picks (SEC-01). Eso exige antes el inventario de consumo del frontend; revocar
-- a ciegas puede romper pantallas vivas. Ver UNIFIED_PICK_SURFACES_V1_AUDIT.md.
-- ============================================================================
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '60s';

-- ---- SEC-03: quitar la capacidad de escritura anónima al ledger forward ----
-- El productor legítimo corre como servicio (cron/edge con rol propio), no como anon.
--
-- OJO — ESTO ES LO QUE HACE FALTA DE VERDAD: PostgreSQL concede EXECUTE a PUBLIC
-- por defecto en toda función nueva. Revocar solo de anon/authenticated NO cierra
-- nada, porque anon sigue heredando el privilegio vía PUBLIC. El test adversarial
-- lo demostró: tras revocar de anon/authenticated, anon SEGUÍA escribiendo.
-- Hay que revocar de PUBLIC y luego conceder explícitamente a quien deba tenerlo.
REVOKE EXECUTE ON FUNCTION public.lab_mlb_fwd_capturar(
  text, timestamptz, text, numeric, text, text, timestamptz, text, numeric, text, text, text
) FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.lab_mlb_fwd_resultado(
  text, integer, numeric, timestamptz
) FROM PUBLIC, anon, authenticated;

-- El productor legítimo es el owner (postgres) o el rol de servicio que ejecuta
-- los cron jobs. Si en producción el productor NO es el owner, hay que conceder
-- EXECUTE explícitamente a ese rol aquí. Ver SEC03_CONSUMER_MAP antes de aplicar.

-- ---- SEC-02: fijar search_path en las 8 SECURITY DEFINER ----
ALTER FUNCTION public.lab_ff_capturar_semana(integer, integer)            SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_ff_capturar_semana_actual()                      SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_ff_fwd_capturar_v1(text, text, text, integer, integer, text, text, timestamptz, text, text, text)
                                                                           SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_ff_grade_semana(integer, integer)                SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_ff_import_ownership(text, text, integer, integer, jsonb)
                                                                           SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_ff_ingest_screenshot(text, integer, integer, text, jsonb)
                                                                           SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_mlb_fwd_capturar(text, timestamptz, text, numeric, text, text, timestamptz, text, numeric, text, text, text)
                                                                           SET search_path = public, pg_temp;
ALTER FUNCTION public.lab_mlb_fwd_resultado(text, integer, numeric, timestamptz)
                                                                           SET search_path = public, pg_temp;

-- ============================================================================
-- POST-VERIFY (misma transacción) — FAIL -> ROLLBACK total
-- ============================================================================
DO $v$
DECLARE n_sin_sp int; n_anon_exec int;
BEGIN
  SELECT count(*) INTO n_sin_sp
    FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.prosecdef
     AND p.proname IN ('lab_ff_capturar_semana','lab_ff_capturar_semana_actual','lab_ff_fwd_capturar_v1',
                       'lab_ff_grade_semana','lab_ff_import_ownership','lab_ff_ingest_screenshot',
                       'lab_mlb_fwd_capturar','lab_mlb_fwd_resultado')
     AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig,'{}')) c WHERE c LIKE 'search_path=%');
  IF n_sin_sp <> 0 THEN RAISE EXCEPTION 'FAIL S1 quedan % SECDEF sin search_path', n_sin_sp; END IF;
  RAISE NOTICE 'PASS_NONEMPTY S1 las 8 SECURITY DEFINER tienen search_path fijado (evaluated_rows=8 violations=0)';

  -- S2 usa has_function_privilege, NO el ACL explícito. El ACL no ve el privilegio
  -- heredado de PUBLIC, y por eso la primera versión de este assert daba PASS
  -- mientras anon seguía pudiendo escribir. has_function_privilege sí lo ve.
  SELECT count(*) INTO n_anon_exec
    FROM (VALUES
      ('public.lab_mlb_fwd_capturar(text,timestamptz,text,numeric,text,text,timestamptz,text,numeric,text,text,text)'),
      ('public.lab_mlb_fwd_resultado(text,integer,numeric,timestamptz)')) f(sig),
      (VALUES ('anon'),('authenticated')) r(rol)
   WHERE has_function_privilege(r.rol, f.sig, 'EXECUTE');
  IF n_anon_exec <> 0 THEN
    RAISE EXCEPTION 'FAIL S2 anon/authenticated AUN pueden ejecutar el ledger (% combinaciones). Revisar REVOKE FROM PUBLIC.', n_anon_exec;
  END IF;
  RAISE NOTICE 'PASS_NONEMPTY S2 escritura anónima al ledger revocada, verificado con has_function_privilege (evaluated_rows=4 violations=0)';

  RAISE NOTICE '==== SEC HARDENING V1 OK -> COMMIT permitido ====';
END $v$;

COMMIT;
