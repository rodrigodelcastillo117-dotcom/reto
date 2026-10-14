-- =====================================================================
-- ISS108  LA TABLA CRUDA ESQUIVA TODAS LAS COMPUERTAS
-- =====================================================================
-- HALLAZGO QUE ORIGINA EL PARCHE
--   Todas las compuertas construidas hasta hoy (llave de autorizacion,
--   cuarentena Under-3.5, identidad exacta, linaje de P_RETO) viven en
--   v_pick_canonico y en las vistas que dependen de ella.
--   Las TABLAS CRUDAS no pasan por ninguna, y estan abiertas al cliente.
--
--   Medido en produccion el 2026-09-12:
--     82 de 87 tablas con columnas de probabilidad/pick son legibles por
--     anon o authenticated. Cada politica RLS relevante es USING (true):
--     RLS esta encendida y no restringe nada.
--
--     fut_predicciones      884 filas, todas con probabilidad
--                           120 prospectivas (fecha >= hoy)
--                           254 con pick Under 3.5  <- MERCADO EN CUARENTENA
--                           pick_en_cuarentena() devuelve true en todas
--                           probabilidades publicadas de hasta 89.1 %
--     picks_recomendados_hoy  RLS APAGADA, 0 politicas, SELECT para anon
--
--   Es decir: el fail-closed que hoy mantiene honesto al producto
--   (es_pick=false por SIN_MODEL_VERSION en 283 de 283 filas) se esquiva
--   con un SELECT a la tabla. La contencion de Under-3.5 solo aplicaba a
--   vistas. Eso no es "contencion parcial": es una puerta abierta.
--
-- POR QUE EL GATE VIEJO NO LO VEIA
--   pruebas_selector_limpio() restringe ocho consultas a
--   relkind in ('v','m'). Las tablas son invisibles por construccion.
--   Ya corregi ese punto ciego en los gates de superficie de ISS104 y deje
--   escrito que este quedaba igual. Aqui se cierra.
--
-- CRITERIO CONDUCTUAL, NO POR NOMBRES
--   Una relacion es SUPERFICIE si un cliente la puede leer de verdad:
--   privilegio SELECT para anon/authenticated Y (RLS apagada O una politica
--   permisiva que aplique a ese rol). No importa como se llame ni si alguien
--   la considera "interna": si se puede leer, es superficie.
--
-- QUE NO HACE
--   No revoca ni un grant. Revocar SELECT a anon sobre 82 tablas es un
--   cambio hacia afuera que puede romper lecturas del frontend, y el
--   frontend es de Lovable. Aqui se MIDE, se DECLARA y se BLOQUEA, con la
--   lista exacta para que el dueno decida.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) LEGIBILIDAD REAL POR UN CLIENTE
-- ---------------------------------------------------------------------
create or replace function public.relacion_legible_por_cliente(p_oid oid)
returns boolean language sql stable as $fn$
  select
    -- hay privilegio SELECT para un rol de cliente
    (has_table_privilege('anon', p_oid, 'SELECT')
      or has_table_privilege('authenticated', p_oid, 'SELECT'))
    and
    -- y RLS no lo detiene: o esta apagada, o hay politica permisiva que aplica
    (
      not (select c.relrowsecurity from pg_class c where c.oid = p_oid)
      or exists (
        select 1 from pg_policies p
        join pg_class c on c.oid = p_oid
        join pg_namespace n on n.oid = c.relnamespace
        where p.schemaname = n.nspname
          and p.tablename  = c.relname
          and p.permissive = 'PERMISSIVE'
          and p.cmd in ('SELECT','ALL')
          and (p.roles && array['anon','authenticated','public']::name[])
      )
    );
$fn$;

comment on function public.relacion_legible_por_cliente(oid) is
'ISS108. Una relacion es legible por un cliente si tiene privilegio SELECT para anon/authenticated Y RLS no lo detiene (apagada, o politica PERMISSIVE de SELECT/ALL que aplica a ese rol). Criterio conductual: no importa como se llame la tabla ni si alguien la considera interna.';

-- ---------------------------------------------------------------------
-- 2) INVENTARIO DE SUPERFICIE CRUDA
-- ---------------------------------------------------------------------
create or replace view public.v_superficie_cruda as
select c.relname::text                              as relacion,
       case c.relkind when 'r' then 'TABLA'
                      when 'p' then 'TABLA_PARTICIONADA'
                      when 'v' then 'VISTA'
                      when 'm' then 'VISTA_MATERIALIZADA' end as clase,
       c.relrowsecurity                             as rls_activa,
       (select count(*) from pg_policies p
         where p.schemaname='public' and p.tablename=c.relname
           and p.cmd in ('SELECT','ALL')
           and p.roles && array['anon','authenticated','public']::name[]) as politicas_de_cliente,
       public.relacion_legible_por_cliente(c.oid)    as legible_por_cliente,
       exists (select 1 from public.superficie_usuario  s where s.vista = c.relname::text) as declarada_usuario,
       exists (select 1 from public.superficie_retirada r where r.vista = c.relname::text) as declarada_retirada,
       exists (select 1 from public.superficie_temporalidad t where t.vista = c.relname::text) as temporalidad_declarada,
       (select t.columna_evento from public.superficie_temporalidad t where t.vista = c.relname::text) as columna_evento
from pg_class c
join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
where c.relkind in ('r','p','v','m')
  and exists (select 1 from information_schema.columns col
              where col.table_schema = 'public'
                and col.table_name   = c.relname
                and col.column_name ~* 'probabilidad|prob_|pick');

comment on view public.v_superficie_cruda is
'ISS108. Toda relacion con columnas de probabilidad/pick, INCLUIDAS LAS TABLAS, con su legibilidad real por un cliente y si alguien la declaro como superficie. El gate viejo solo miraba relkind v/m y por eso 82 tablas abiertas eran invisibles.';

-- ---------------------------------------------------------------------
-- 3) GATE
-- ---------------------------------------------------------------------
create or replace function public.gate_superficie_cruda()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  -- G1: relacion legible por el cliente, con picks, que nadie declaro.
  --     Fail-closed: sin declaracion NO se asume interna.
  select 'SUPERFICIE_CRUDA_SIN_DECLARAR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(relacion, ', ' order by relacion), 'ninguna')
  from public.v_superficie_cruda
  where legible_por_cliente and not declarada_usuario and not declarada_retirada
  union all
  -- G2: lo mas grave. Mercado EN CUARENTENA servido desde una tabla cruda.
  --     Se cuentan FILAS reales, no objetos: la puerta se mide en filas.
  select 'CUARENTENA_ESQUIVADA_POR_TABLA_CRUDA'::text,
         case when (select count(*) from public.fut_predicciones
                     where fecha >= current_date
                       and public.pick_en_cuarentena('soccer','Over/Under', mejor_pick)) = 0
              then 'PASS' else 'FAIL' end,
         (select count(*) from public.fut_predicciones
           where fecha >= current_date
             and public.pick_en_cuarentena('soccer','Over/Under', mejor_pick)),
         'filas PROSPECTIVAS de fut_predicciones cuyo pick esta en cuarentena y que anon puede leer sin pasar por v_pick_canonico'
  union all
  -- G3: RLS encendida que no restringe nada es peor que RLS apagada: miente.
  select 'RLS_PERMISIVA_QUE_NO_RESTRINGE'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(distinct tablename, ', ' order by tablename), 'ninguna')
  from pg_policies p
  where p.schemaname = 'public'
    and p.permissive = 'PERMISSIVE'
    and p.cmd in ('SELECT','ALL')
    and p.roles && array['anon','authenticated','public']::name[]
    and coalesce(btrim(p.qual), 'true') = 'true'
    and exists (select 1 from public.v_superficie_cruda v where v.relacion = p.tablename)
  union all
  -- G4: relacion con picks y SIN RLS ninguna
  select 'SUPERFICIE_CRUDA_SIN_RLS'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(relacion, ', ' order by relacion), 'ninguna')
  from public.v_superficie_cruda
  where clase like 'TABLA%' and not rls_activa
    and (has_table_privilege('anon', ('public.'||quote_ident(relacion))::regclass, 'SELECT')
      or has_table_privilege('authenticated', ('public.'||quote_ident(relacion))::regclass, 'SELECT'))
  union all
  -- G5: no se puede afirmar prospectividad sin columna de evento declarada.
  --     El nombre de la columna NO se adivina: ese error ya lo cometimos en
  --     ISS101 buscando 6 nombres candidatos y perdiendo match_date y fecha_utc.
  select 'SUPERFICIE_CRUDA_SIN_TEMPORALIDAD'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(relacion, ', ' order by relacion), 'ninguna')
  from public.v_superficie_cruda
  where legible_por_cliente and not temporalidad_declarada and not declarada_retirada;
$fn$;

comment on function public.gate_superficie_cruda() is
'ISS108. Gate de superficie cruda. Todas las compuertas del sistema viven en v_pick_canonico; una tabla abierta las esquiva con un SELECT. G2 es el caso probado: filas prospectivas de un mercado en cuarentena servidas desde fut_predicciones a anon.';

grant execute on function public.relacion_legible_por_cliente(oid) to anon, authenticated, service_role;
grant execute on function public.gate_superficie_cruda()           to anon, authenticated, service_role;
grant select on public.v_superficie_cruda to anon, authenticated, service_role;
