-- ISS218 (2026-09-18). Item 4: RLS adversarial completa.
--
-- HALLAZGO PRINCIPAL, Y ES UNA FUGA REAL QUE MI PROPIA MATRIZ DE ISS212 NO VIO:
-- public.bankroll_curva, legible por authenticated, tenia security_invoker
-- APAGADO. Una vista sin security_invoker corre como su DUENO, y el dueno salta
-- RLS. Medido con dos usuarios reales:
--   ANTES : usuario A ve 117 filas, de las cuales 37 son DE OTRO USUARIO
--   DESPUES: A ve 79 filas / 0 ajenas ; B ve 17 filas / 0 ajenas
-- ISS212 dio "34 PASS + 1 hallazgo" porque probo TABLAS, donde RLS si aplica.
-- No probo vistas. Esa clase entera se me escapo.
--
-- Las otras dos vistas del mismo tipo (v_parlay_incoherente,
-- v_pata_sin_evento_resoluble) tocaban parlays y devolvian 0 y 1 filas.
--
-- VULNERABILIDAD vs ACCESO OBSERVADO, separados como pidio el dueno:
--   vulnerabilidad : CONFIRMADA y reproducida (37 filas ajenas visibles).
--   acceso observado: NINGUNO. pg_stat_statements no tiene ni una llamada de
--     cliente a las tres vistas; las unicas entradas son las mias de esta sesion.
--     pg_stat_statements es una COTA INFERIOR (se puede resetear y tiene tope),
--     asi que esto es "sin evidencia de explotacion", no "prueba de que nunca paso".
--
alter view public.bankroll_curva              set (security_invoker = on);
alter view public.v_parlay_incoherente        set (security_invoker = on);
alter view public.v_pata_sin_evento_resoluble set (security_invoker = on);

-- ==========================================================================
-- SECURITY DEFINER SIN SEARCH_PATH: 8 funciones, 2 abiertas al cliente.
-- ==========================================================================
-- Un SECURITY DEFINER sin search_path fijo se secuestra creando un objeto con el
-- mismo nombre en un esquema que el llamante controle.
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text fn
    from pg_proc p join pg_namespace n2 on n2.oid=p.pronamespace
    where n2.nspname in ('public','v2') and p.prosecdef
      and not (p.proconfig is not null and exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
  loop
    execute format('alter function %s set search_path = public, v2, pg_temp', r.fn);
  end loop;
end $$;
-- Las 8: lab_ff_capturar_semana_actual, lab_ff_capturar_semana,
-- lab_ff_fwd_capturar_v1, lab_ff_grade_semana, lab_ff_import_ownership,
-- lab_ff_ingest_screenshot, lab_mlb_fwd_capturar, lab_mlb_fwd_resultado.
-- Las dos ultimas eran ademas EJECUTABLES por anon y authenticated:
revoke execute on function public.lab_mlb_fwd_capturar(text,timestamp with time zone,text,numeric,text,text,timestamp with time zone,text,numeric,text,text,text) from public, anon, authenticated;
revoke execute on function public.lab_mlb_fwd_resultado(text,integer,numeric,timestamp with time zone) from public, anon, authenticated;
grant  execute on function public.lab_mlb_fwd_capturar(text,timestamp with time zone,text,numeric,text,text,timestamp with time zone,text,numeric,text,text,text) to service_role;
grant  execute on function public.lab_mlb_fwd_resultado(text,integer,numeric,timestamp with time zone) to service_role;

-- ==========================================================================
-- LA CAUSA RAIZ DEL EXECUTE A PUBLIC: el privilegio POR DEFECTO.
-- ==========================================================================
-- Medido: pg_default_acl para postgres en public, tipo 'f', decia
--   {postgres=X, anon=X, authenticated=X, service_role=X}
-- O sea Supabase concede EXECUTE a anon y authenticated en CADA funcion nueva.
-- Eso explica las 1,291 funciones hoy ejecutables por el cliente, y explica por
-- que revocar una por una no cerraba nada: la siguiente nacia abierta.
-- Se cierra para las NUEVAS. NO se toca ninguna existente, porque un revoke
-- masivo a ciegas rompe el frontend y no se cual RPC usa Lovable de verdad.
alter default privileges for role postgres in schema public revoke execute on functions from anon, authenticated, public;
alter default privileges for role postgres in schema v2     revoke execute on functions from anon, authenticated, public;
alter default privileges for role postgres in schema public grant  execute on functions to service_role;
alter default privileges for role postgres in schema v2     grant  execute on functions to service_role;

-- ==========================================================================
-- MATRIZ ADVERSARIAL (v2.iss218_matriz_rls)
-- ==========================================================================
-- Sujetos reales: A = rodelcast (0c631a09-...), B = "el dos" (acef8d26-...)
--
--  actor              objeto                       op      resultado              filas  ajenas
--  A                  picks                        SELECT  SOLO_LO_SUYO           19     0
--  A                  parlays                      SELECT  SOLO_LO_SUYO           53     0
--  A                  score_notifications          SELECT  SOLO_LO_SUYO            7     0
--  B                  picks                        SELECT  SOLO_LO_SUYO           17     0
--  B                  parlays                      SELECT  SOLO_LO_SUYO            0     0
--  B                  score_notifications          SELECT  SOLO_LO_SUYO            0     0
--  A sobre B          picks                        UPDATE  CERO_FILAS_OK           0
--  A sobre B          parlays                      UPDATE  CERO_FILAS_OK           0
--  A sobre B          score_notifications          UPDATE  CERO_FILAS_OK           0
--  A sobre B          picks                        DELETE  CERO_FILAS_OK           0
--  A sobre B          parlays                      DELETE  CERO_FILAS_OK           0
--  A con apodo de B   picks                        INSERT  REESCRITO_AL_DUENO_OK
--    (mande apodo='el dos', quedo guardado apodo='rodelcast' por el trigger
--     asignar_apodo_del_dueno; revertido por subtransaccion)
--  anon               picks                        SELECT  DENEGADO_OK  "permission denied for table picks"
--  anon               parlays                      SELECT  DENEGADO_OK  "permission denied for table parlays"
--  anon               score_notifications          SELECT  DENEGADO_OK  "permission denied for table score_notifications"
--  bankroll_curva     A, antes                     SELECT  FUGA_OBSERVADA        117    37
--  bankroll_curva     A, despues                   SELECT  SIN_FUGA               79     0
--  bankroll_curva     B, despues                   SELECT  SIN_FUGA               17     0
--
-- Todas las escrituras de prueba se revirtieron por subtransaccion (raise + catch),
-- asi que si la RLS hubiera fallado tampoco habria quedado nada persistido.
--
-- SERVICE_ROLE, lo que conserva y por que:
--   picks, parlays: SELECT/INSERT/UPDATE/DELETE. Los necesita: califica
--     resultados, cierra parlays y borra patas irresolubles.
--   score_notifications: los cuatro. authenticated tiene SELECT/INSERT/UPDATE y
--     NO delete, que es lo correcto: el usuario marca como vista, no borra su
--     historial. (Ese UPDATE es el que ISS209 habia roto sin querer y ISS212
--     detecto.)
--   anon: cero privilegios en las tres.
--
-- ==========================================================================
-- CANDADO NUEVO: public.gate_rls_no_se_esquiva()
-- ==========================================================================
--   VISTA_DE_CLIENTE_SALTA_RLS_DE_TABLA_DE_USUARIO  FAIL(3) -> PASS(0)
--   SECURITY_DEFINER_SIN_SEARCH_PATH                FAIL(8) -> PASS(0)
--   PRIVILEGIO_POR_DEFECTO_ABRE_FUNCIONES_NUEVAS    FAIL(2) -> PASS(0)
--   FUNCIONES_EJECUTABLES_POR_CLIENTE               INFO(1291)
--
-- LO QUE QUEDA ABIERTO Y NO VOY A FINGIR QUE CERRE:
--   1,291 funciones de public/v2 siguen siendo ejecutables por anon o
--   authenticated. Es herencia del privilegio por defecto. Entre ellas hay cosas
--   que el cliente no deberia poder llamar: absorber_agenda_espn(),
--   mlb_one_brain_v2(text), v2.build_nfl_hybrid_ml_v1(...),
--   v2.refresh_model_learning(), las 40 funciones gate_*. Revocarlas a ciegas
--   rompe la app, porque no se cual RPC usa Lovable. Eso se cierra con la lista
--   real de RPC del frontend, y es trabajo conjunto, no un revoke masivo.
--   Queda como INFO cuantificado, no como PASS.
--
-- ROLLBACK:
--   alter view ... set (security_invoker = off) en las tres.
--   alter default privileges ... grant execute on functions to anon, authenticated.
--   Las 8 funciones: alter function ... reset search_path.
--   drop function public.gate_rls_no_se_esquiva();
--   drop table v2.iss218_matriz_rls;
