-- =====================================================================
-- ISS109  LAS TABLAS DE GOBIERNO LAS ESCRIBE EL SERVICIO, NO EL CLIENTE
-- =====================================================================
-- EL PROBLEMA, MEDIDO EN PRODUCCION EL 2026-09-12
--   Las 11 tablas de las que dependen TODAS las compuertas del sistema
--   tenian INSERT, UPDATE y DELETE concedidos a anon y a authenticated, sin
--   RLS. Cualquier cliente con la llave publica podia:
--
--     delete from mercado_cuarentena          -> levantar la cuarentena de Under-3.5
--     insert into motor_modelo_mapa           -> inventar un model_version y
--                                                convertir SIN_MODEL_VERSION
--                                                en "autorizado"
--     update calibradores set elegido=true,
--            apto_para_lock=true              -> nombrarse autoridad de calibracion
--     update ajustes_a_p_reto                 -> cambiar la probabilidad que ve el usuario
--     insert into identidad_equipo_alias      -> hacer que identidad_valida() acepte
--                                                cualquier equipo
--     delete from superficie_usuario          -> borrar la declaracion de superficies
--     delete from ruta_precio_hallazgo        -> borrar las 19 violaciones de ISS107
--                                                y poner el gate 14 en verde
--
--   O sea: cada candado construido en esta auditoria se abria con un DELETE
--   de cliente. Dos de esas tablas (ruta_precio_hallazgo, ruta_precio_inventario)
--   las cree yo mismo hoy y las deje abiertas. Queda escrito.
--
-- POR QUE SE PUEDE TOCAR PRODUCCION AQUI
--   §11 permite cambios estrechos, reversibles y no-modelo, y nombra
--   explicitamente el arreglo de lecturas/grants. Esto no altera P_RETO, ni
--   la calibracion, ni la seleccion canonica, ni el ranking, ni el conjunto
--   de features, ni la elegibilidad del modelo. Se revierte con un GRANT.
--
-- POR QUE NO ROMPE EL FRONTEND
--   SELECT se mantiene intacto: el frontend sigue leyendo todo lo que leia.
--   Y en pg_stat_statements, las UNICAS escrituras historicas a estas 11
--   tablas vienen de las migraciones de esta auditoria, ejecutadas como
--   service_role. Cero escrituras de aplicacion. Si el frontend escribiera
--   la tabla de cuarentena o el registro de modelos, ESO seria el bug.
--
-- QUE NO SE TOCA
--   parlays, agenda_espn, historico_partidos_espn y fut_predicciones quedan
--   como estan. Son datos, no gobierno, y parlays la escribe el usuario de
--   forma legitima. Su exposicion se reporta aparte (ISS108), no se cambia
--   aqui de pasada.
-- =====================================================================

do $$
declare
  v_tabla text;
  v_gobierno text[] := array[
    'mercado_cuarentena',        -- que mercados estan suspendidos
    'motor_modelo_mapa',         -- que model_version corresponde a cada motor
    'calibradores',              -- quien es la autoridad de calibracion
    'modelo_registry',           -- que modelos existen y en que estado
    'ajustes_a_p_reto',          -- ajustes sobre la probabilidad publicada
    'identidad_equipo_alias',    -- que alias de equipo se aceptan como validos
    'superficie_usuario',        -- que es superficie de usuario
    'superficie_retirada',       -- que superficie se retiro y por que
    'superficie_temporalidad',   -- cual es la columna de evento de cada superficie
    'ruta_precio_hallazgo',      -- las violaciones del candado del precio
    'ruta_precio_inventario'     -- el inventario que las sustenta
  ];
begin
  foreach v_tabla in array v_gobierno loop
    if exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
               where n.nspname='public' and c.relname=v_tabla and c.relkind in ('r','p')) then
      -- se revoca la ESCRITURA, se conserva la LECTURA: la transparencia no
      -- es el problema; que un cliente pueda reescribir el gobierno si lo es.
      execute format('revoke insert, update, delete, truncate on public.%I from anon, authenticated', v_tabla);
      execute format('grant select on public.%I to anon, authenticated', v_tabla);
      execute format('grant all on public.%I to service_role', v_tabla);
      raise notice 'gobierno blindado: %', v_tabla;
    else
      raise warning 'no existe, se omite: %', v_tabla;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- GATE: el gobierno no lo escribe un cliente. Nunca mas, y se vigila.
-- ---------------------------------------------------------------------
create or replace function public.gate_gobierno_solo_servicio()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  with gobierno(nm) as (values
    ('mercado_cuarentena'),('motor_modelo_mapa'),('calibradores'),('modelo_registry'),
    ('ajustes_a_p_reto'),('identidad_equipo_alias'),('superficie_usuario'),
    ('superficie_retirada'),('superficie_temporalidad'),
    ('ruta_precio_hallazgo'),('ruta_precio_inventario')
  ),
  est as (
    select g.nm, c.oid,
           (has_table_privilege('anon', c.oid,'INSERT') or has_table_privilege('anon', c.oid,'UPDATE')
             or has_table_privilege('anon', c.oid,'DELETE') or has_table_privilege('anon', c.oid,'TRUNCATE')) as anon_escribe,
           (has_table_privilege('authenticated', c.oid,'INSERT') or has_table_privilege('authenticated', c.oid,'UPDATE')
             or has_table_privilege('authenticated', c.oid,'DELETE') or has_table_privilege('authenticated', c.oid,'TRUNCATE')) as auth_escribe,
           has_table_privilege('service_role', c.oid,'INSERT') as svc_escribe
    from gobierno g
    join pg_class c on c.relname = g.nm
    join pg_namespace n on n.oid = c.relnamespace and n.nspname='public'
  )
  select 'GOBIERNO_ESCRIBIBLE_POR_CLIENTE'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(nm, ', ' order by nm), 'ninguna')
  from est where anon_escribe or auth_escribe
  union all
  select 'GOBIERNO_SIN_ESCRITURA_DE_SERVICIO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(nm, ', ' order by nm), 'ninguna')
  from est where not svc_escribe
  union all
  select 'GOBIERNO_TABLAS_VIGILADAS'::text, 'INFO', count(*),
         'tablas de gobierno bajo vigilancia de este gate'
  from est;
$fn$;

comment on function public.gate_gobierno_solo_servicio() is
'ISS109. Ninguna tabla de gobierno puede ser escrita por anon o authenticated, y todas deben seguir siendo escribibles por service_role. Si este gate falla, cada otra compuerta del sistema es decorativa: se abre con un DELETE.';

grant execute on function public.gate_gobierno_solo_servicio() to anon, authenticated, service_role;

-- =====================================================================
-- VERIFICACION ADVERSARIAL Y UNA CORRECCION DE METODO
-- =====================================================================
-- Se intento, COMO anon y COMO authenticated, exactamente lo que antes
-- abria cada candado. Los cinco intentos fueron rechazados y la lectura
-- siguio funcionando:
--
--   anon  delete from mercado_cuarentena           -> RECHAZADO
--   anon  insert into motor_modelo_mapa (...)      -> RECHAZADO
--   auth  update calibradores set elegido=true...  -> RECHAZADO
--   auth  delete from ruta_precio_hallazgo         -> RECHAZADO
--   anon  update ajustes_a_p_reto                  -> RECHAZADO
--   anon  select de cuarentena y de hallazgos      -> SIGUE FUNCIONANDO
--
--   Estado posterior: cuarentena 1 fila, 19 violaciones intactas.
--
-- CORRECCION DE METODO, PORQUE LA PRUEBA CASI ME MIENTE
--   El codigo 42501 insufficient_privilege NO distingue "no hay GRANT" de
--   "RLS lo nego". Lo descubri con un control que monte mal: intente un
--   insert de anon en fut_predicciones esperando que pasara el permiso, y
--   fallo con 42501. No era falta de grant (anon SI tiene INSERT ahi): era
--   RLS, que no tiene politica de escritura para anon.
--   Para las 11 tablas de gobierno RLS esta APAGADA (relrowsecurity=false),
--   asi que ahi 42501 solo puede venir del GRANT. Por eso la prueba de
--   arriba es valida para estas 11, y por eso el gate mide el GRANT con
--   has_table_privilege en vez de confiar en el codigo de error.
--
-- RIESGO LATENTE QUE QUEDA ABIERTO (no se toca aqui: son datos, no gobierno)
--   anon tiene INSERT, UPDATE y DELETE concedidos sobre agenda_espn,
--   fut_predicciones y live_scores: el calendario autoritativo, la salida
--   del modelo y los marcadores en vivo. Hoy solo los salva RLS, porque no
--   existe politica de escritura para anon. El dia que alguien agregue una
--   politica permisiva de ALL "para que funcione algo", la puerta se abre
--   sin que nadie toque un grant. Queda reportado, no parchado: son tablas
--   de ingesta y tocarlas sin mapear quien escribe seria otro riesgo.
