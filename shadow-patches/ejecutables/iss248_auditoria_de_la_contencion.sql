-- =====================================================================
-- ISS248 -- AUDITORIA DE LA CONTENCION DE APODO (punto 1 del mandato)
-- Rama: claude/eager-noether-s7p33g
-- Proyecto Supabase: wpiztubmmmzclhlprgpd
--
-- Encargo del dueno:
--   "Verifica la definicion exacta de apodo_historial, su trigger, propietarios,
--    permisos e inserciones futuras. Prueba con dos sesiones concurrentes.
--    Identifica como decide el trigger que una operacion viene del cliente o de
--    service_role. Prueba llamadas por RPC SECURITY DEFINER... una peticion de
--    authenticated no debe poder cambiar el apodo solo porque una funcion corre
--    como postgres."
--
-- Resultado: la contencion resiste la ruta SECURITY DEFINER, pero la auditoria
-- encontro DOS errores mios en ISS246 y UNA regresion que yo introduje.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. DOS CORRECCIONES A LO QUE REPORTE EN ISS246
-- ---------------------------------------------------------------------
-- ERROR MIO 1 -- El indice normalizado NO era nuevo. Ya existia:
--     usuarios_apodo_unico_idx  ON usuarios (lower(TRIM(BOTH FROM apodo)))
-- que es EXACTAMENTE la misma expresion que lower(btrim(apodo)).
-- Por tanto mi afirmacion de ISS246 --
--   "la restriccion previa era sobre el texto crudo, asi que RodelCast y
--    '  rodelcast ' la esquivaban"
-- es FALSA. La variante T3 habria sido bloqueada igual SIN mi indice.
-- Mi indice usuarios_apodo_norm_uniq es REDUNDANTE. Se conserva (retirarlo
-- anade riesgo por cero ganancia) pero queda declarado como redundante.
--
-- ERROR MIO 2 -- No revise el orden de triggers. En public.usuarios habia ya
-- un trigger de canonizacion:
--     trg_canonizar_apodo_usuario -> canonizar_apodo_usuario()
--         new.apodo := lower(trim(regexp_replace(new.apodo,'\s+',' ','g')))
-- Los triggers BEFORE corren en orden ALFABETICO. 'tg_apodo_reservado' ordena
-- ANTES de 'trg_canonizar_apodo_usuario', asi que mi trigger veia el apodo SIN
-- canonizar, y normalizaba con lower(btrim(...)) que NO colapsa espacios
-- internos. Divergencia medida sobre datos reales:
--     reservado        = 'el dos'
--     variante ataque  = 'el  dos'
--     mi normalizacion = 'el  dos'   -> NO coincide, mi trigger la deja pasar
--     canonizacion     = 'el dos'    -> se guarda como el apodo RESERVADO
-- Bypass real. Alcanzable por INSERT (alta de perfil) cuando el apodo reservado
-- no esta vigente. Tambien con tabuladores: 'EL' || chr(9) || 'DOS'.


-- ---------------------------------------------------------------------
-- 1. COMO DECIDE EL TRIGGER QUE ALGO VIENE DEL CLIENTE -- PROBADO
-- ---------------------------------------------------------------------
-- Mecanismo: current_setting('role', true). PostgREST hace SET LOCAL role
-- al rol del JWT ('anon' / 'authenticated') en cada peticion.
--
-- La pregunta del dueno era si una funcion SECURITY DEFINER propiedad de
-- postgres puede blanquear esa senal. Medido, no supuesto:
--
-- P1  Dentro de una SECDEF propiedad de postgres, llamada con role=authenticated:
--       current_user           = postgres      <- cambia, como se espera
--       session_user           = postgres
--       current_setting('role')= authenticated <- NO cambia
--     => SECURITY DEFINER cambia current_user pero NO el GUC 'role'.
--
-- P2  Intento de set_config('role','postgres',true) dentro de la SECDEF:
--       ERROR: cannot set parameter "role" within security-definer function
--
-- P3bis Intento por la puerta de atras, metiendolo en proconfig:
--       ALTER FUNCTION ... SET role = 'postgres'   -> el DDL se ACEPTA
--       pero al ejecutarla como authenticated:
--       ERROR: cannot set parameter "role" within security-definer function
--     => la funcion queda INEJECUTABLE. No es un bypass, es un suicidio.
--
-- T7  Prueba de punta a punta. Funcion real:
--       v2.iss248_rpc_cambia_apodo(uuid,text) SECURITY DEFINER, owner postgres,
--       GRANT EXECUTE TO authenticated, hace UPDATE usuarios SET apodo=...
--     Llamada como authenticated:  BLOQUEADO (APODO_NO_MODIFICABLE)
--
-- VEREDICTO: el mecanismo es solido contra la ruta SECDEF. Un authenticated NO
-- cambia su apodo por el hecho de que la funcion corra como postgres.
-- Esto es una propiedad del motor, no de mi codigo: Postgres prohibe SET role
-- dentro de SECURITY DEFINER. No depende de que yo lo haya escrito bien.


-- ---------------------------------------------------------------------
-- 2. CONCURRENCIA -- NO PROBADA CON DOS SESIONES. GARANTIA ESTRUCTURAL SI.
-- ---------------------------------------------------------------------
-- No puedo abrir dos backends simultaneos con el acceso que tengo:
--     max_prepared_transactions = 0   -> sin two-phase commit
--     usesuper = false                -> dblink local exigiria la password de BD
--     el MCP da una conexion por llamada
-- Por tanto: DOS SESIONES CONCURRENTES = NO PROBADA. No la marco PASS.
--
-- Lo que SI esta probado es que toda carrera falla cerrado, porque el punto de
-- serializacion no esta en mi codigo sino en dos restricciones fisicas:
--   a) apodo_historial.apodo_norm es PRIMARY KEY. El trigger hace SELECT y
--      luego INSERT sin ON CONFLICT: dos insertores del mismo apodo_norm ->
--      el segundo recibe error duro. MEDIDO: T6 = RECHAZADO_DURO (SQLSTATE 23505)
--   b) usuarios_apodo_unico_idx (unique) sobre lower(trim(apodo)): dos altas
--      del mismo apodo -> una falla.
-- En ambos casos la transaccion perdedora ABORTA. No hay rama que gane en
-- silencio. Esa es la garantia; no es lo mismo que haberlo visto en vivo.


-- ---------------------------------------------------------------------
-- 3. HALLAZGO AJENO: RECURSION INFINITA EN UNA POLITICA DE PRODUCCION
-- ---------------------------------------------------------------------
-- Al probar el INSERT como authenticated, TODAS las variantes devolvieron:
--     ERROR: infinite recursion detected in policy for relation "usuarios"
-- Causa: la politica usuarios_auth_insert consulta usuarios dentro de su
-- propio WITH CHECK:
--     NOT EXISTS (SELECT 1 FROM usuarios u WHERE lower(u.apodo)=lower(usuarios.apodo))
-- No la escribi yo y no la disparo mi trigger. Es previa. Consecuencia: el
-- INSERT directo de authenticated en public.usuarios NUNCA ha funcionado.
-- No rompe el producto porque el alta real NO pasa por ahi (ver 4), pero
-- invalida mis pruebas T2-T5 de esta tanda: quedan NO PROBADAS por esa via.
-- La politica sigue en pie, sin tocar, declarada como defecto abierto.


-- ---------------------------------------------------------------------
-- 4. LA RUTA REAL DE ALTA, Y LA REGRESION QUE YO INTRODUJE
-- ---------------------------------------------------------------------
-- El alta no usa INSERT directo. Usa:
--   trg_crear_usuario_al_registrarse  ON auth.users AFTER INSERT
--     -> crear_usuario_al_registrarse()  SECDEF, ACL solo postgres+service_role
--        que llama a generar_apodo_unico(...) e inserta el perfil.
-- Y hay dos RPC de cliente que tambien insertan en usuarios:
--   public.registrar_perfil(text,numeric)  SECDEF  -- tenia EXECUTE de PUBLIC
--   public.registrar_apodo(text)           SECDEF  -- authenticated
--
-- REGRESION MIA (medida, T12): generar_apodo_unico solo consultaba usuarios
-- VIVOS, no el historial. Con 'el dos' liberado devolvia exactamente 'el dos',
-- un apodo RESERVADO. Y crear_usuario_al_registrarse envuelve todo en
--     exception when others then raise warning ...
-- asi que mi APODO_RESERVADO se habria comido en silencio y el usuario habria
-- quedado REGISTRADO PERO SIN PERFIL. Fallo de producto introducido por mi
-- contencion de ISS246. Arreglado abajo.


-- ---------------------------------------------------------------------
-- 5. CAMBIOS APLICADOS
-- ---------------------------------------------------------------------

-- 5.1 Una sola definicion de normalizacion, identica a la de produccion.
create or replace function public.apodo_norm(p text)
returns text language sql immutable set search_path to 'pg_catalog' as $$
  select case when p is null then null
              else lower(trim(regexp_replace(p, '\s+', ' ', 'g'))) end
$$;
-- Nacio sin PUBLIC por si sola: el candado tg_funcion_nueva_sin_public de
-- ISS226 actuo. ACL medida: {postgres=X/postgres,service_role=X/postgres}

-- 5.2 Historial renormalizado con esa funcion, con guarda anti-colision.
--     Los 6 reservados no cambiaron (ninguno tenia espacios dobles).

-- 5.3 Trigger v2: usa apodo_norm y corre DESPUES del canonizador.
--     El nombre 'trg_zz_apodo_reservado' ordena despues de
--     'trg_canonizar_apodo_usuario', asi que ve el apodo ya canonizado.
--     Orden verificado: [trg_canonizar_apodo_usuario, trg_zz_apodo_reservado]

-- 5.4 generar_apodo_unico: salta tambien los apodos reservados.
--     Arregla la regresion del punto 4.

-- 5.5 registrar_perfil y registrar_apodo: comprueban la reserva y devuelven
--     error limpio ('apodo_reservado') en vez de dejar escapar una excepcion
--     cruda del trigger al frontend. Colision normalizada con apodo_norm.

-- 5.6 revoke execute on function public.registrar_perfil(text,numeric) from public;
--     anon y authenticated ya tenian GRANT explicito -> acceso efectivo SIN CAMBIO.
--     Solo se retira el EXECUTE implicito de PUBLIC (patron ISS218).

-- 5.7 alter table public.apodo_historial enable row level security;
--     Sin politicas, y ningun rol cliente tiene GRANT. Defensa en profundidad.


-- ---------------------------------------------------------------------
-- 6. PRUEBAS DESPUES DEL ARREGLO (todas medidas)
-- ---------------------------------------------------------------------
-- T1  authenticated renombra directo                    BLOQUEADO APODO_NO_MODIFICABLE
-- T7  authenticated renombra via RPC SECDEF/postgres    BLOQUEADO APODO_NO_MODIFICABLE
-- T6  duplicado en apodo_historial                      RECHAZADO_DURO 23505
-- V1  generar_apodo_unico('el dos') con 'el dos' libre  -> 'el dos-2'  EVITA el reservado
-- V2  generar_apodo_unico('rodelcast')                  -> 'rodelcast-2'
-- V3  registrar_perfil('el dos')       reservado libre  -> {"ok":false,"error":"apodo_reservado"}
-- V4  registrar_perfil('el   DOS')     variante         -> {"ok":false,"error":"apodo_reservado"}
-- V5  registrar_perfil('apodo limpio v2')               -> {"ok":true}  el producto sigue vivo
-- V6  registrar_apodo('el_dos_x')                       -> {"ok":true}
-- T11 registrar_apodo('rodelcast') con rodelcast vivo   -> {"ok":false,"error":"apodo_ocupado"}
--
-- Todo dentro de transacciones revertidas. Estado posterior verificado:
--   apodos vivos      = el dos, iovejas, joaquinbadillo, nanosch12, rodelcast, rongo
--   reservados        = los mismos 6
--   trigger           = trg_zz_apodo_reservado, habilitado
--   crons 25 min      = 364 succeeded, 1 running, 0 failed


-- ---------------------------------------------------------------------
-- 7. LO QUE ESTO NO CIERRA
-- ---------------------------------------------------------------------
-- - La propiedad NO esta migrada. 54 de 57 tablas siguen con el apodo como
--   llave. El renombrado sigue PAUSADO para clientes.
-- - Concurrencia con dos sesiones reales: NO PROBADA.
-- - usuarios_auth_insert sigue con recursion infinita: defecto abierto.
-- - registrar_perfil(p_apodo, p_bankroll) deja que el CLIENTE elija su propio
--   bankroll_inicial. Pendiente de evaluar en la reconciliacion de saldo.
-- - Edge Functions: NO PROBADAS.
-- - Frontend: PENDING, sin credenciales.


-- ---------------------------------------------------------------------
-- 8. ROLLBACK EXACTO
-- ---------------------------------------------------------------------
-- drop trigger if exists trg_zz_apodo_reservado on public.usuarios;
-- create trigger tg_apodo_reservado before insert or update of apodo
--   on public.usuarios for each row execute function public.tg_apodo_reservado();
-- alter table public.apodo_historial disable row level security;
-- grant execute on function public.registrar_perfil(text,numeric) to public;
-- -- y restaurar los cuerpos previos de generar_apodo_unico, registrar_perfil,
-- -- registrar_apodo y tg_apodo_reservado, transcritos en los commits
-- -- dc39d82 (ISS246) y en el cuerpo de este documento.
-- -- public.apodo_norm y public.apodo_historial se CONSERVAN: son historia.
