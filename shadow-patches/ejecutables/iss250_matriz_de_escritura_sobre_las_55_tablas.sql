-- =====================================================================
-- ISS250 -- MATRIZ DE AUTORIZACION DE ESCRITURA (punto 2 del mandato)
-- Rama: claude/eager-noether-s7p33g   Proyecto: wpiztubmmmzclhlprgpd
--
-- Encargo: "Clasifica cuales de las 57 tablas con apodo contienen datos de
-- usuario y cuales usan apodo unicamente como etiqueta. En cada tabla
-- escribible que use apodo como propiedad, prueba como A y B: INSERT con
-- apodo ajeno; UPDATE del apodo de una fila propia hacia el de otro; UPDATE y
-- DELETE de filas ajenas... Corrige las rutas alcanzables y mide filas
-- afectadas. Una reserva de nombres en usuarios no sustituye la autorizacion
-- de cada escritura."
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. CORRECCION DE CIFRA
-- ---------------------------------------------------------------------
-- Dije 57 tablas. El recuento exacto de TABLAS BASE en el esquema public con
-- columna 'apodo' es 55. Las 2 de diferencia eran vistas o no eran relkind='r'.
-- De esas 55: 36 escribibles por authenticated, 3 tienen user_id, 9 vacias,
-- 316885 filas en total.


-- ---------------------------------------------------------------------
-- 1. METODO
-- ---------------------------------------------------------------------
-- Atacante A = 'el dos'   (auth.uid acef8d26-..., 862 filas ligadas)
-- Victima  V = 'rodelcast'(auth.uid 0c631a09-..., 157617 filas ligadas)
-- Todo como rol real: set_config('role','authenticated') +
-- request.jwt.claims con el sub de A. Todo en transaccion revertida.
-- Cinco operaciones por tabla, acotadas a 5 filas via ctid:
--   LEE      select de filas de V
--   ROBA     update ... set apodo = A  sobre filas de V
--   MODIFICA update ... set apodo = apodo sobre filas de V
--   BORRA    delete de filas de V
--   INSERTA  insert con apodo = V
--
-- DETALLE QUE CAMBIA EL RESULTADO: en Postgres, RLS NO lanza error en
-- UPDATE/DELETE; simplemente afecta 0 filas. Medir la excepcion no sirve.
-- Hay que leer GET DIAGNOSTICS row_count. Solo INSERT lanza 42501.


-- ---------------------------------------------------------------------
-- 2. DOS PASADAS INVALIDAS ANTES DE LA BUENA -- DECLARADAS
-- ---------------------------------------------------------------------
-- PASADA 1: perdi toda la evidencia. Junte los INSERT de resultados DENTRO
-- de la transaccion que luego revertia con 'ZZ_RB'. Es exactamente la trampa
-- que ya documente en ISS245 y en la que volvi a caer. Corregido acumulando
-- en un jsonb en memoria y escribiendo DESPUES del rollback.
--
-- PASADA 2: 52 operaciones dieron sqlstate 42501 y casi las cuento como
-- "bloqueado". No lo eran: era "permission denied for function apodo_norm".
-- Habia usado MI PROPIA funcion public.apodo_norm dentro de las consultas de
-- prueba, y authenticated no tiene EXECUTE sobre ella (el candado de ISS226 la
-- cerro al nacer). Mi instrumento de medicion estaba bloqueado, no el ataque.
-- 18 tablas -- entre ellas ajustes_cuenta, picks, parlays y notificaciones --
-- quedaron sin medir. Repetida con lower(btrim(apodo)) en linea.


-- ---------------------------------------------------------------------
-- 3. RESULTADO SOBRE 35 TABLAS ESCRIBIBLES (usuarios aparte)
-- ---------------------------------------------------------------------
-- ROBA filas ajenas      0 VULNERABLES
-- MODIFICA filas ajenas  0 VULNERABLES
-- BORRA filas ajenas     0 VULNERABLES
-- Ningun cliente puede reetiquetar, modificar ni borrar datos de otro.
--
-- INSERTA con apodo ajeno -- aqui estaba lo interesante:
--   parlay_builder_log      VULNERABLE REAL      pedido=rodelcast guardado=rodelcast
--   picks                   FALSO POSITIVO MIO   pedido=rodelcast guardado='el dos'
--   fantasy_roster_semanal  FALSO POSITIVO MIO   pedido=rodelcast guardado='el dos'
--   parlays                 BLOQUEADO por guarda economica, NO por RLS


-- ---------------------------------------------------------------------
-- 4. LOS DOS FALSOS POSITIVOS -- POR QUE CASI REPORTE UNA VULNERABILIDAD FALSA
-- ---------------------------------------------------------------------
-- El INSERT con apodo ajeno en picks SI se ejecuta sin error. Mi primera
-- version de la prueba solo miraba si lanzaba excepcion, y la marco VULNERABLE.
-- Falta el paso que importa: LEER QUE SE GUARDO. Con RETURNING apodo:
--     pedido = 'rodelcast'   guardado = 'el dos'
-- Existe trg_apodo_dueno_picks BEFORE INSERT -> asignar_apodo_del_dueno(),
-- que hace new.apodo := (apodo del auth.uid()) ignorando lo que mande el
-- cliente. Igual en fantasy_roster_semanal con trg_apodo_dueno_fantasy_roster.
-- Es el patron correcto y ya estaba en produccion: el servidor pone el dueno,
-- el parametro del cliente no es prueba de propiedad.
-- Un "INSERT permitido" no es una vulnerabilidad. Lo es un "INSERT atribuido
-- a otro". Sin el RETURNING no se distingue.
--
-- parlays quedo bloqueada por chk/trigger de autoridad economica:
--   "PARLAY SIN MODELO CONJUNTO VALIDADO: no se autoriza exposicion nueva"
-- Eso cierra la ruta de hecho, pero NO prueba la RLS. La via RLS de parlays
-- queda NO PROBADA, con efecto practico cerrado.


-- ---------------------------------------------------------------------
-- 5. LA VULNERABILIDAD REAL Y SU ARREGLO
-- ---------------------------------------------------------------------
-- public.parlay_builder_log (71 filas, 10 apodos) tenia:
--     POLICY parlay_builder_log_insert_auth FOR INSERT TO authenticated
--            WITH CHECK (true)
-- y NINGUN trigger que fijase el dueno. Cualquier authenticated podia crear
-- entradas de log atribuidas a otro jugador.
--
-- ARREGLO -- se le aplica el mismo patron que ya usa picks, sin inventar nada:
--     create trigger trg_apodo_dueno_parlay_builder_log
--       before insert on public.parlay_builder_log
--       for each row execute function public.asignar_apodo_del_dueno();
--
-- VERIFICADO despues:
--     pedido=rodelcast guardado='el dos'  -> CORREGIDO
--     pedido='el dos'  guardado='el dos'  -> el dueno sigue escribiendo, OK
-- No se toco la politica: el trigger hace irrelevante el apodo que mande el
-- cliente, que es mas fuerte que una comprobacion de igualdad.


-- ---------------------------------------------------------------------
-- 6. FUGAS DE LECTURA -- MEDIDAS, NO CORREGIDAS. DECISION DEL DUENO.
-- ---------------------------------------------------------------------
-- Cuatro tablas de datos de usuario dejan leer filas ajenas a cualquier
-- cliente, por politicas USING (true):
--     user_patterns          5 filas ajenas visibles   (patrones de apuesta)
--     ai_generated_parlays   2                          (parlays generados por IA)
--     fantasy_start_sit      2                          (consejo start/sit)
--     parlay_builder_log     1                          (log de construccion)
-- Politicas culpables: user_patterns_select_all, ai_generated_parlays_select,
-- parlay_builder_log_select (las tres a PUBLIC) y fantasy_start_sit_lectura
-- (a authenticated), todas con USING (true).
--
-- NO las he cerrado, y el motivo es explicito: pueden ser un muro social
-- deliberado del producto, y no puedo probar el frontend (PENDING, sin
-- credenciales). Cerrarlas a ciegas podria romper una pantalla visible, y la
-- regla que me diste es no declarar el frontend intacto sin probarlo.
-- Parche listo si decides cerrarlas (una por tabla, reversible):
--   alter policy user_patterns_select_all on public.user_patterns
--     using (lower(btrim(apodo)) = lower(btrim(public.apodo_de_la_sesion())));
-- Riesgo de dejarlas: 6 usuarios que se conocen ven datos de apuesta ajenos.
-- Riesgo de cerrarlas sin probar: pantalla en blanco sin aviso.


-- ---------------------------------------------------------------------
-- 7. CLASIFICACION: PROPIEDAD vs ETIQUETA
-- ---------------------------------------------------------------------
-- PROPIEDAD (el apodo identifica al dueno de la fila) -- las de datos activos:
--   picks, parlays, ajustes_cuenta, notificaciones, canasta, config_staking,
--   score_notifications, fantasy_roster_semanal, limites_usuario,
--   push_subscriptions, user_patterns, ai_generated_parlays, fantasy_start_sit,
--   parlay_builder_log, semana_bankroll, user_stats_cache, clv_tracking,
--   y las variantes _temporada_1 y los backups fechados.
-- ETIQUETA (el apodo es un nombre de proceso, no una persona):
--   oraculo_picks_tracking y oraculo_diario cuando apodo='oraculo';
--   scan_logs / pa_audit_log cuando apodo nombra un job
--   ('pre_analizar_fut_diario'); _backup_* y __bat_a__/__bat_b__/test_cache.
-- Esta distincion es la que impide aplicar una politica restrictiva uniforme a
-- las 35: en las de etiqueta, exigir apodo = apodo de la sesion romperia
-- escrituras legitimas del sistema. Por eso el arreglo fue por tabla.


-- ---------------------------------------------------------------------
-- 8. ESTADO Y ROLLBACK
-- ---------------------------------------------------------------------
-- crons ultimos 20 min: 296 succeeded, 0 running, 0 failed
-- picks 43 filas, parlay_builder_log 71 filas, usuarios 6, reservados 30
--
-- ROLLBACK:
--   drop trigger if exists trg_apodo_dueno_parlay_builder_log on public.parlay_builder_log;


-- ---------------------------------------------------------------------
-- 9. PENDIENTE DE ESTE PUNTO
-- ---------------------------------------------------------------------
-- - No probe la matriz completa con B como atacante y A como victima
--   (simetria). Probado en un sentido: A -> V. NO PROBADA la inversa.
-- - No probe las rutas equivalentes por RPC para cada una de las 35 tablas;
--   solo las de apodo/perfil y bankroll. NO PROBADAS.
-- - Edge Functions: NO PROBADAS.
-- - pa_audit_log (302168 filas) sigue escribible por authenticated: un cliente
--   puede forjar entradas de auditoria. Declarado, sin tocar.
