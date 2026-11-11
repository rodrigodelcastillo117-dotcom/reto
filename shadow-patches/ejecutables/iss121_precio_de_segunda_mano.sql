-- =====================================================================
-- ISS121 : EL PRECIO LAVADO A TRAVES DE UNA FUNCION CON NOMBRE INOCENTE
-- =====================================================================
-- ISS107 encuentra el precio cuando esta a la vista en la linea que decide.
-- No encuentra esto:
--
--   1) se mete la aritmetica del precio dentro de una funcion escalar,
--   2) la funcion se llama algo inofensivo (veredicto_pick, zona_realidad,
--      favoritos_bien_pagados, info_completa),
--   3) y despues se ordena, filtra o suprime picks por su resultado.
--
-- En el paso 3 la linea que decide NO menciona momio, cuota ni precio. Dice
-- "where f.info_completa". Para mi detector de primera mano esa linea esta
-- limpia. El candado igual esta roto.
--
-- Esto no es hipotetico: asi encontre la supresion de 50 picks que esta
-- documentada al final de este archivo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. QUIEN LLEVA EL PRECIO ADENTRO ("lavadoras")
-- ---------------------------------------------------------------------
-- Se reusa forma_precio_en_linea de ISS107, que detecta la ARITMETICA del
-- precio y no el nombre de la variable. Por eso no se esquiva renombrando.
-- Medido hoy: 77 funciones en public tienen aritmetica de precio adentro.
create table if not exists public.ruta_precio_lavadora (
  funcion text primary key,
  devuelve_conjunto boolean not null,
  tipo_retorno text not null,
  formas text[] not null,
  lineas int not null
);
revoke all on public.ruta_precio_lavadora from anon, authenticated;

truncate public.ruta_precio_lavadora;
insert into public.ruta_precio_lavadora (funcion, devuelve_conjunto, tipo_retorno, formas, lineas)
select p.proname, p.proretset, pg_get_function_result(p.oid),
       array_agg(distinct e.forma), count(distinct l.linea)::int
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname='public'
cross join lateral unnest(string_to_array(p.prosrc, E'\n')) as l(linea)
cross join lateral unnest(public.forma_precio_en_linea(l.linea)) as e(forma)
where e.forma is not null
group by p.proname, p.proretset, pg_get_function_result(p.oid)
on conflict do nothing;

-- ---------------------------------------------------------------------
-- 2. EL DETECTOR DE SEGUNDA MANO
-- ---------------------------------------------------------------------
-- Misma ventana de 6 lineas que ISS107 y por el mismo motivo: un CASE parte
-- la llamada de la comparacion. Se hereda tambien su costo declarado, y aqui
-- pega mas fuerte: 43 de 45 hallazgos resultaron falsos positivos de ventana.
-- Se acepta a proposito. Un falso positivo se clasifica leyendolo; un falso
-- negativo no se ve nunca.
--
-- Se EXIGE que la linea no tenga ya token ni forma de precio: este detector
-- solo reporta lo que ISS107 es incapaz de ver, para no duplicar inventario.
create or replace function public.lineas_decision_por_lavadora(p_src text, p_funcs text[])
returns table(ord int, linea text, construccion text, lavadoras text[])
language plpgsql immutable as $fn$
declare
  v_lineas text[]; v_n int; i int; j int;
  v_l text; v_low text; v_ctx text; v_con text;
  v_orden_desde int := null;
  v_lav text[];
begin
  v_lineas := string_to_array(coalesce(p_src,''), E'\n');
  v_n := coalesce(array_length(v_lineas,1),0);

  for i in 1..v_n loop
    v_l := btrim(v_lineas[i]); v_low := lower(v_l);
    if v_l ~ '^--' or v_l = '' then
      if v_low ~ ';' then v_orden_desde := null; end if;
      continue;
    end if;

    if v_low ~ 'order\s+by' then v_orden_desde := i;
    elsif v_orden_desde is not null and (v_low ~ ';' or i - v_orden_desde > 8) then v_orden_desde := null;
    end if;

    -- misma ventana de 6 lineas que ISS107, por el mismo motivo (el CASE parte
    -- la llamada de la comparacion)
    v_ctx := v_l;
    for j in greatest(1, i-6) .. i-1 loop
      if btrim(v_lineas[j]) !~ '^--' then v_ctx := btrim(v_lineas[j]) || ' ' || v_ctx; end if;
    end loop;

    -- La senal NO es el precio: es la llamada a una funcion que lleva el precio
    -- adentro. Y se exige que la linea NO tenga ya un token de precio, para
    -- reportar solo lo que ISS107 no puede ver.
    select array_agg(distinct f) into v_lav
    from unnest(p_funcs) f
    where v_ctx ~* ('\m' || f || '\s*\(');

    if coalesce(array_length(v_lav,1),0) = 0
       or coalesce(array_length(public.token_precio_en_linea(v_ctx),1),0) > 0
       or coalesce(array_length(public.forma_precio_en_linea(v_ctx),1),0) > 0 then
      if v_low ~ ';' then v_orden_desde := null; end if;
      continue;
    end if;

    v_con := null;
    if v_low ~ 'when .*then' and v_low ~* 'ev_negativo|no\s+apostar|evitar|bloque|rechaz|descart|suprim|\mveta|\mveto|alto' then
      v_con := 'RAMA_SUPRESION';
    elsif v_low ~ 'order\s+by' or v_orden_desde is not null then v_con := 'ORDEN';
    elsif v_low ~ 'row_number|dense_rank|\mrank\s*\(' then v_con := 'VENTANA_RANKING';
    elsif v_low ~ '^(and|or|where|having)\M' or v_low ~ '\mwhere\M'
       or v_low ~ '^\s*end\s*(>=|<=|<>|!=|>|<|=)'
       or (v_low ~ '\mand\M' and v_low ~ '(>=|<=|<>|!=|>|<|=|\mis\s+not\s+null\M|\mis\s+null\M)') then
      v_con := 'FILTRO';
    elsif v_low ~ '^(if|elsif)\M' and v_low ~ '(>=|<=|<>|!=|>|<|=)' then v_con := 'CONDICION_CONTROL';
    elsif v_low ~ '\mlimit\M' then v_con := 'LIMITE';
    end if;

    if v_con is not null then
      ord := i; linea := v_l; construccion := v_con; lavadoras := v_lav;
      return next;
    end if;
    if v_low ~ ';' then v_orden_desde := null; end if;
  end loop;
end;
$fn$;

-- ---------------------------------------------------------------------
-- 3. INVENTARIO
-- ---------------------------------------------------------------------
create table if not exists public.ruta_precio_segunda_mano (
  objeto text not null,
  linea_num int not null,
  construccion text not null,
  lavadoras text[] not null,
  linea text not null,
  calculado_at timestamptz not null default now(),
  veredicto text,
  razon text,
  requiere_cutover boolean,
  primary key (objeto, linea_num)
);
revoke all on public.ruta_precio_segunda_mano from anon, authenticated;

-- Prefiltro: solo se escanean los objetos cuyo texto MENCIONA una lavadora.
-- Sin el prefiltro el escaneo completo (77 funciones x cada linea de cada
-- objeto) pasa de los 60s del MCP. Con prefiltro: 99 objetos candidatos.
create table if not exists public.ruta_precio_candidato (
  objeto text primary key,
  lavadoras text[] not null,
  src text not null,
  escaneado boolean not null default false
);
revoke all on public.ruta_precio_candidato from anon, authenticated;

truncate public.ruta_precio_candidato;
with lav as (
  select funcion from public.ruta_precio_lavadora where funcion <> 'forma_precio_en_linea'
),
fuentes as (
  select p.proname || '(' || pg_get_function_arguments(p.oid) || ')' as objeto, p.prosrc as src
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
  where p.prosrc is not null and p.prolang <> 'internal'::regtype::oid
  union all
  select c.relname, pg_get_viewdef(c.oid, true)
  from pg_class c join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
  where c.relkind in ('v','m')
)
insert into public.ruta_precio_candidato (objeto, lavadoras, src)
select f.objeto, array_agg(l.funcion), f.src
from fuentes f
join lav l on position(l.funcion in f.src) > 0
where regexp_replace(f.objeto, '\(.*$', '') <> l.funcion
group by f.objeto, f.src
on conflict do nothing;

-- El escaneo se corre por lotes de 25 (cuatro vueltas para los 99 candidatos).
-- Repetir hasta que escaneado sea true en todos:
--
--   with lote as (
--     select objeto, lavadoras, src from public.ruta_precio_candidato
--     where not escaneado order by objeto limit 25
--   ), hall as (
--     insert into public.ruta_precio_segunda_mano (objeto, linea_num, construccion, lavadoras, linea)
--     select l.objeto, d.ord, d.construccion, d.lavadoras, left(btrim(d.linea),300)
--     from lote l cross join lateral public.lineas_decision_por_lavadora(l.src, l.lavadoras) d
--     on conflict do nothing returning 1
--   )
--   update public.ruta_precio_candidato c set escaneado = true
--   where c.objeto in (select objeto from lote);

-- ---------------------------------------------------------------------
-- 4. CORRECCION A ISS107: LA EXPOSICION ESTABA MAL MEDIDA
-- ---------------------------------------------------------------------
-- ruta_precio_inventario.exposicion_directa decia false para las funciones
-- __base. Es falso: la funcion interna no tiene GRANT, pero su envoltorio si.
-- Verificado en los 9 casos P0 que habia clasificado como "ni alimenta ni
-- expuesto": los 9 tienen envoltorio EXECUTE para authenticated
-- (construir_parlay_del_dia, construir_parlay_v2, decision_canonica_v2,
--  get_performance_breakdown, mejor_oportunidad_hoy_v2, rendimiento_usuario,
--  reto_13m_stats, revisar_apuesta, tamano_apuesta).
-- Estuve a punto de archivar esos 9 como inofensivos por una columna mal
-- calculada.
create or replace function public.objeto_expuesto_directo(p_nombre text)
returns boolean language sql stable as $fn$
  select coalesce(bool_or(x.puede), false) from (
    select has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE') as puede
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
    where p.proname = p_nombre
    union all
    select has_table_privilege('anon', c.oid, 'SELECT')
        or has_table_privilege('authenticated', c.oid, 'SELECT')
    from pg_class c join pg_namespace n on n.oid=c.relnamespace and n.nspname='public'
    where c.relname = p_nombre and c.relkind in ('r','v','m','p')
  ) x;
$fn$;

-- ---------------------------------------------------------------------
-- 5. COMPUERTA
-- ---------------------------------------------------------------------
create or replace function public.gate_precio_de_segunda_mano()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'PRECIO_SEGUNDA_MANO_SIN_CLASIFICAR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(objeto || ':' || linea_num, ', ' order by objeto), 'ninguno')
  from public.ruta_precio_segunda_mano where veredicto is null
  union all
  select 'PRECIO_SEGUNDA_MANO_VIOLACION_ABIERTA'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(objeto || ':' || linea_num, ', ' order by objeto), 'ninguna')
  from public.ruta_precio_segunda_mano where veredicto in ('VIOLACION_CANDADO','VIOLACION_LATENTE')
  union all
  -- Medicion VIVA de la supresion, no la frase que yo escribi. Si alguien
  -- "arregla" esto borrando el hallazgo, este renglon lo sigue viendo.
  select 'FAVORITOS_SUPRIMIDOS_POR_FALTA_DE_PRECIO'::text,
         case when count(*) filter (where f.momio is null and not f.info_completa) = 0
              then 'PASS' else 'FAIL' end,
         count(*) filter (where f.momio is null and not f.info_completa),
         'picks que reto_registrar_favoritos descarta con where f.info_completa y cuya unica falta es que no hay precio de la casa. Arreglarlo cambia lo publicado: es cutover de seleccion.'
  from public.favoritos_bien_pagados() f
  union all
  select 'SEGUNDA_MANO_DETECTOR_TIENE_LAVADORAS'::text,
         case when count(*) > 0 then 'PASS' else 'FAIL' end, count(*),
         'funciones con aritmetica de precio adentro que el detector de segunda mano persigue. Si llega a 0, el detector quedo ciego.'
  from public.ruta_precio_lavadora where funcion <> 'forma_precio_en_linea';
$fn$;

comment on function public.gate_precio_de_segunda_mano() is
'ISS121. El precio metido dentro de una funcion escalar con nombre inocente y usado despues para elegir, ordenar o suprimir picks. ISS107 no lo ve porque la linea que decide no menciona el precio.';

revoke all on function public.gate_precio_de_segunda_mano() from anon, authenticated;

-- =====================================================================
-- 6. LO QUE ENCONTRO (2026-09-12)
-- =====================================================================
-- 45 hallazgos en 22 objetos. 43 son falsos positivos de ventana, leidos uno
-- por uno: guardas de null u ok (IF mk IS NULL, IF (r->>'ok')='true'),
-- filtros temporales, joins de identidad, literales de texto dentro de
-- invariantes_temporales, y mis propios detectores leyendo pg_class.
--
-- LOS DOS QUE NO SON FALSOS POSITIVOS, los dos en reto_registrar_favoritos:
--
-- (a) LINEA 44, "where f.info_completa"  -> VIOLACION_CANDADO
--     Medido: favoritos_bien_pagados() devuelve 68 filas.
--       50 filas: momio NULL, falta='falta el precio de la casa',
--                 info_completa=false  -> las borra este where
--       18 filas: info_completa=false por MODEL_VERSION_PROVENANCE_MISSING
--                 -> descarte legitimo, es gobierno de modelo, no precio
--     O sea: la AUSENCIA del precio suprime 50 picks.
--
--     Y es peor que un descuido. favoritos_bien_pagados fue arreglada a
--     proposito el 11-sep para NO suprimir esas filas: su propio comentario
--     dice "Antes 'where p.m is not null' lo borraba de la pantalla sin decir
--     nada", y ahora las saca con su motivo declarado. La supresion se volvio
--     a meter UN NIVEL ARRIBA, en una linea donde no aparece la palabra
--     momio. El detector de primera mano no podia verla. Por eso existe este
--     parche.
--
--     NO LO ARREGLE. Cambiar esto cambia lo que se publica: es cutover de
--     seleccion, no parche operativo (regla §11). Queda como FAIL abierto.
--     Impacto practico hoy: cero, porque economic_model_authority esta vacia
--     y la funcion no publica nada. El defecto es latente, no activo.
--
-- (b) LINEA 45, "coalesce(f.falta,'') not ilike 'ventaja de%'"
--                                            -> VIOLACION_LATENTE
--     Filtra por el motivo 'ventaja', que es el desacuerdo del modelo contra
--     el precio. Hoy no borra nada: los unicos valores de falta medidos son
--     'falta el precio de la casa' y 'MODEL_VERSION_PROVENANCE_MISSING'. Es
--     un filtro muerto, pero es un filtro POR DESACUERDO CONTRA EL MERCADO
--     escrito en el camino de publicacion. El dueno fue explicito: el
--     desacuerdo puede mostrarse, nunca seleccionar ni suprimir. Si alguien
--     vuelve a emitir un falta que empiece con 'ventaja de', se enciende.
--
-- LO QUE REVISE Y **NO** ES VIOLACION, para que quede escrito:
--   - favoritos_bien_pagados ordena por "order by 9 desc", y la columna 9 de
--     su RETURNS TABLE es prob_modelo, no el momio ni el ev. Ordena por
--     modelo. Estuve a punto de reportarla como selector por precio por el
--     nombre de la funcion; la verifique primero.
--   - kelly_stake__base y decision_economica_v1 usan zona_realidad (que lleva
--     precio adentro) para DIMENSIONAR el stake. El dueno lo autoriza
--     explicitamente: "puede servir para EV/Kelly/actionability/payout".
--
-- ESTADO DEL GATE (2026-09-12):
--   PRECIO_SEGUNDA_MANO_SIN_CLASIFICAR         PASS  0
--   PRECIO_SEGUNDA_MANO_VIOLACION_ABIERTA      FAIL  2
--   FAVORITOS_SUPRIMIDOS_POR_FALTA_DE_PRECIO   FAIL  50
--   SEGUNDA_MANO_DETECTOR_TIENE_LAVADORAS      PASS  76
-- =====================================================================
