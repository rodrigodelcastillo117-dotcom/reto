-- =====================================================================
-- ISS107  LA RUTA DEL PRECIO EN LA DECISION: DETECTOR CONDUCTUAL + GATE
-- =====================================================================
-- CANDADO DEL DUENO (textual):
--   "SIN EV. SIN KELLY. SIN 'EDGE CONTRA EL MERCADO' PARA DECIDIR."
--   "El precio puede existir como dato informativo. El cerebro decide a
--    partir de datos deportivos + modelo + calibracion + incertidumbre."
--   Los campos de desacuerdo con el mercado "may be shown as diagnostic
--    context only; it may never select, rank, authorize, suppress, or
--    substitute a P_RETO pick."
--
-- POR QUE ESTE PARCHE NO ES UN GATE POR NOMBRES
--   Tres veces en esta auditoria un gate basado en nombres dio verde falso
--   porque el nombre se podia cambiar. Aqui el detector tiene DOS familias:
--     FAMILIA TOKEN  -> el identificador (ev_pct, kelly, momio, edge...)
--     FAMILIA FORMA  -> la ARITMETICA del precio, independiente del nombre:
--                       * (p * m - 1) comparado contra 0   = prueba de EV
--                       * 1/x o 100/x sobre un precio      = prob implicita
--                       * ln(1 + ...)                      = crecimiento log
--                       * devig / no-vig
--   Renombrar ev_pct a xyz NO apaga la FAMILIA FORMA. get_partidos_hoy_top
--   es la prueba viva: filtra y ordena por EV y la palabra "ev" no aparece
--   en ninguna de sus lineas. Un gate por nombres lo habria dado limpio.
--
-- QUE NO HACE ESTE PARCHE (a proposito)
--   NO toca un solo selector de produccion. Cambiar quien elige, ordena,
--   autoriza o suprime un pick es un cambio de MODELO/SELECCION y el dueno
--   dejo PROD_MODEL_CUTOVER congelado: exige prueba en disposable con SHA
--   exacto antes de cualquier cutover. Este parche MIDE y BLOQUEA.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) FAMILIA FORMA: la aritmetica del precio, sin depender del nombre
-- ---------------------------------------------------------------------
create or replace function public.forma_precio_en_linea(p_linea text)
returns text[] language sql immutable as $fn$
  select array_remove(array[
    case when p_linea ~* '\*[^();]{0,80}-\s*1(\.0+)?\s*\)?\s*(>=|<=|>|<|=)\s*0'
         then 'FORMA_EV_CONTRA_CERO' end,
    case when p_linea ~* '(^|[^0-9.])(1|100)(\.0+)?\s*/\s*(nullif\s*\()?\s*[a-z_][a-z0-9_.]*'
          and p_linea ~* '(momio|odds|_ml\M|precio|cuota|decimal)'
         then 'FORMA_PROB_IMPLICITA' end,
    case when p_linea ~* 'ln\s*\(\s*1\s*(\+|-)' then 'FORMA_CRECIMIENTO_LOG' end,
    case when p_linea ~* 'devig|no_?vig|sin_?vig' then 'FORMA_DEVIG' end
  ], null);
$fn$;

comment on function public.forma_precio_en_linea(text) is
'ISS107. Detecta la ARITMETICA del precio en una linea de codigo, sin depender del nombre de la variable. Renombrar el identificador no la apaga.';

-- ---------------------------------------------------------------------
-- 2) FAMILIA TOKEN: el identificador economico
-- ---------------------------------------------------------------------
create or replace function public.token_precio_en_linea(p_linea text)
returns text[] language sql immutable as $fn$
  select array_remove(array[
    case when p_linea ~* '\mev_pct\M|\mev_estimado\M|\mev_real|\mev_parlay|\mev_ajustado\M' then 'TOKEN_EV' end,
    case when p_linea ~* '\medge\M|edge_pct|edge_calculado|edge_total|edge_norm'            then 'TOKEN_EDGE' end,
    case when p_linea ~* 'kelly'                                                            then 'TOKEN_KELLY' end,
    case when p_linea ~* 'momio|odds|\m(home|away|draw)_ml\M|cuota'                         then 'TOKEN_PRECIO' end,
    case when p_linea ~* 'prob_implicita|implied|break_even|prob_que_implica'               then 'TOKEN_PROB_IMPLICITA' end,
    case when p_linea ~* 'roi_pct|\mroi\M|nicho_rentable|sangrante'                         then 'TOKEN_ROI' end
  ], null);
$fn$;

comment on function public.token_precio_en_linea(text) is
'ISS107. Familia TOKEN del detector: identificadores economicos. Esquivable por renombrado; por eso SIEMPRE se evalua junto con forma_precio_en_linea().';

-- ---------------------------------------------------------------------
-- 3) LA CONSTRUCCION QUE DECIDE
--    No basta que el precio APAREZCA. Tiene que aparecer en un lugar que
--    ELIGE filas, las ORDENA, las AUTORIZA o las SUPRIME. Un precio en una
--    lista de SELECT, en un jsonb_build_object de salida o en una asignacion
--    de monto NO decide: informa o dimensiona, y eso esta permitido.
--
--    LIMITACION DECLARADA: el alcance de un ORDER BY se aproxima con una
--    ventana de 8 lineas. Eso produce falsos positivos cuando una lista de
--    columnas de salida cae dentro de la ventana (mejor_pick_hoy lineas
--    65-66, mejor_oportunidad_hoy linea 40). Por eso el gate NO condena
--    solo: exige clasificacion a mano de cada hallazgo P0.
-- ---------------------------------------------------------------------
create or replace function public.lineas_decision_por_precio(p_src text)
returns table(ord int, linea text, construccion text, senales text[])
language plpgsql immutable as $fn$
declare
  v_lineas text[];
  v_n int;
  i int; j int;
  v_l text;
  v_low text;
  v_orden_desde int := null;
  v_sen text[];
  v_con text;
  v_ctx text;
begin
  -- Se procesa LINEA POR LINEA a proposito: en Postgres los regex son
  -- dotall y un [^)]* cruza saltos de linea. Ese error ya nos mintio antes.
  --
  -- PERO linea por linea puro tiene su PROPIO punto ciego, y lo encontre
  -- volcando picks_recomendados_hoy_raw: ahi el token vive en una linea
  -- ("p.value ->> 'ev_estimado'") y la comparacion que decide vive tres
  -- lineas mas abajo ("  END >= 4::numeric AND"), porque el CASE las separa.
  -- La version anterior solo marcaba el momio y DEJABA PASAR el filtro por EV
  -- y el ORDER BY por ev_num en la vista mas cargada de violaciones del
  -- sistema. O sea: mi propio gate estaba sub-reportando.
  --
  -- Arreglo: la CONSTRUCCION se decide en la linea, pero las SENALES se
  -- buscan en una ventana de 6 lineas hacia atras, que es el alcance tipico
  -- de un CASE o un predicado partido en este esquema. La ventana se declara
  -- aqui y es parte del contrato del detector.
  --
  -- COSTO DECLARADO DE LA VENTANA: genera falsos positivos cuando un token
  -- queda hasta 6 lineas arriba de una comparacion que no tiene nada que ver.
  -- En picks_recomendados_hoy_raw, las lineas 71 y 72 (ramas de parseo de
  -- prob) heredan TOKEN_EV de la ventana y no son decisiones por EV. Por eso
  -- el gate NO condena solo: exige clasificacion a mano de cada hallazgo P0.
  -- El intercambio es deliberado: preferimos un falso positivo clasificable a
  -- un falso negativo invisible.
  v_lineas := string_to_array(coalesce(p_src,''), E'\n');
  v_n := coalesce(array_length(v_lineas,1),0);

  for i in 1..v_n loop
    v_l   := btrim(v_lineas[i]);
    v_low := lower(v_l);

    if v_l ~ '^--' or v_l = '' then
      if v_low ~ ';' then v_orden_desde := null; end if;
      continue;
    end if;

    if v_low ~ 'order\s+by' then
      v_orden_desde := i;
    elsif v_orden_desde is not null and (v_low ~ ';' or i - v_orden_desde > 8) then
      v_orden_desde := null;
    end if;

    -- contexto: la linea mas hasta 6 lineas previas, sin comentarios
    v_ctx := v_l;
    for j in greatest(1, i-6) .. i-1 loop
      if btrim(v_lineas[j]) !~ '^--' then
        v_ctx := btrim(v_lineas[j]) || ' ' || v_ctx;
      end if;
    end loop;

    v_sen := public.forma_precio_en_linea(v_ctx) || public.token_precio_en_linea(v_ctx);
    if coalesce(array_length(v_sen,1),0) = 0 then
      if v_low ~ ';' then v_orden_desde := null; end if;
      continue;
    end if;

    v_con := null;

    if v_low ~ 'when .*then' and v_low ~* 'ev_negativo|no\s+apostar|evitar|bloque|rechaz|descart|suprim|\mveta|\mveto|alto' then
      v_con := 'RAMA_SUPRESION';
    elsif v_low ~ 'order\s+by' or v_orden_desde is not null then
      v_con := 'ORDEN';
    elsif v_low ~ 'row_number|dense_rank|\mrank\s*\(' then
      v_con := 'VENTANA_RANKING';
    elsif v_low ~ '^(and|or|where|having)\M' or v_low ~ '\mwhere\M'
       or v_low ~ '^\s*end\s*(>=|<=|<>|!=|>|<|=)'
       or (v_low ~ '\mand\M' and v_low ~ '(>=|<=|<>|!=|>|<|=|\mis\s+not\s+null\M|\mis\s+null\M)') then
      v_con := 'FILTRO';
    elsif v_low ~ '^(if|elsif)\M' and v_low ~ '(>=|<=|<>|!=|>|<|=)' then
      v_con := 'CONDICION_CONTROL';
    elsif v_low ~ '\mlimit\M' then
      v_con := 'LIMITE';
    end if;

    if v_con is not null then
      ord := i; linea := v_l; construccion := v_con; senales := v_sen;
      return next;
    end if;

    if v_low ~ ';' then v_orden_desde := null; end if;
  end loop;
end;
$fn$;

comment on function public.lineas_decision_por_precio(text) is
'ISS107. Devuelve las lineas donde el precio/EV/Kelly/ROI aparece en una construccion que ELIGE, ORDENA, AUTORIZA o SUPRIME filas. Un precio en la lista de SELECT o en una asignacion de monto NO se reporta: informar y dimensionar estan permitidos; decidir no.';

-- ---------------------------------------------------------------------
-- 4) ALCANCE REAL: que objetos son superficie accionable
-- ---------------------------------------------------------------------
drop view if exists public.v_objeto_accionable;
create or replace view public.v_objeto_accionable as
select p.oid as objeto_oid,
       p.oid::regprocedure::text as objeto,
       'FUNCION'::text as clase,
       case when has_function_privilege('anon', p.oid, 'EXECUTE')
              or has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 0 else 1 end as salto_minimo,
       case when has_function_privilege('anon', p.oid, 'EXECUTE')
              or has_function_privilege('authenticated', p.oid, 'EXECUTE')
            then 'EXPOSICION_DIRECTA'
            else 'LLAMADA_POR_WRAPPER_EXPUESTO' end as por_que
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
where p.prokind = 'f'
  and (
    has_function_privilege('anon', p.oid, 'EXECUTE')
    or has_function_privilege('authenticated', p.oid, 'EXECUTE')
    or (p.proname like '%\_\_base'
        and exists (select 1 from pg_proc w
                    join pg_namespace nw on nw.oid = w.pronamespace and nw.nspname='public'
                    where w.proname = left(p.proname, length(p.proname)-6)
                      and (has_function_privilege('anon', w.oid, 'EXECUTE')
                        or has_function_privilege('authenticated', w.oid, 'EXECUTE'))))
  );

comment on view public.v_objeto_accionable is
'ISS107. Funcion alcanzable desde una superficie accionable. LIMITACION DECLARADA: se resuelve por exposicion directa a anon/authenticated y por el patron __base de este repo (wrapper expuesto + cuerpo). No se hace cierre transitivo de llamadas porque 1033 de 1200 funciones ya estan expuestas directamente: el cierre no agregaria objetos y si costaba minutos.';

-- ---------------------------------------------------------------------
-- 5) EL INVENTARIO (snapshot, no vista)
--    Recorrer 2.35 MB de codigo fuente linea por linea no cabe en el
--    timeout de una consulta de gate. Por eso es tabla + refresco.
-- ---------------------------------------------------------------------
create table if not exists public.ruta_precio_inventario (
  objeto                   text not null,
  clase                    text not null,
  exposicion_directa       boolean not null,
  linea_num                int  not null,
  construccion             text not null,
  senales                  text[] not null,
  tiene_senal_no_esquivable boolean not null,
  linea                    text not null,
  calculado_at             timestamptz not null default now(),
  primary key (objeto, linea_num, linea)
);

comment on table public.ruta_precio_inventario is
'ISS107. Snapshot del inventario de la ruta del precio. Es tabla y no vista porque recorrer 2.35 MB de codigo fuente linea por linea no cabe en el timeout de una consulta de gate. Se refresca con refrescar_ruta_precio_inventario().';

create or replace function public.refrescar_ruta_precio_inventario()
returns table(objetos_revisados bigint, hallazgos bigint, con_forma bigint)
language plpgsql as $fn$
begin
  delete from public.ruta_precio_inventario;

  insert into public.ruta_precio_inventario
    (objeto, clase, exposicion_directa, linea_num, construccion, senales, tiene_senal_no_esquivable, linea)
  select a.objeto, a.clase, (a.salto_minimo = 0),
         d.ord, d.construccion, d.senales,
         exists (select 1 from unnest(d.senales) s where s like 'FORMA\_%'),
         d.linea
  from public.v_objeto_accionable a
  join pg_proc p on p.oid = a.objeto_oid
  cross join lateral public.lineas_decision_por_precio(p.prosrc) d
  on conflict do nothing;

  insert into public.ruta_precio_inventario
    (objeto, clase, exposicion_directa, linea_num, construccion, senales, tiene_senal_no_esquivable, linea)
  select c.relname, 'VISTA', true,
         d.ord, d.construccion, d.senales,
         exists (select 1 from unnest(d.senales) s where s like 'FORMA\_%'),
         d.linea
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
  cross join lateral public.lineas_decision_por_precio(pg_get_viewdef(c.oid, true)) d
  where c.relkind in ('v','m')
    and (has_table_privilege('anon', c.oid, 'SELECT')
      or has_table_privilege('authenticated', c.oid, 'SELECT'))
  on conflict do nothing;

  return query
    select count(distinct objeto), count(*), count(*) filter (where tiene_senal_no_esquivable)
    from public.ruta_precio_inventario;
end;
$fn$;

-- ---------------------------------------------------------------------
-- 6) HALLAZGOS CLASIFICADOS A MANO CONTRA EL CANDADO
-- ---------------------------------------------------------------------
create table if not exists public.ruta_precio_hallazgo (
  id                 bigserial primary key,
  objeto             text        not null,
  linea_num          int         not null,
  linea_texto        text        not null,
  construccion       text        not null,
  veredicto          text        not null
    check (veredicto in ('VIOLACION_CANDADO','DIAGNOSTICO_NO_DECIDE',
                         'DIMENSIONAMIENTO_ECONOMICO','MEDICION_RETROSPECTIVA',
                         'FALSO_POSITIVO_DETECTOR')),
  razon              text        not null,
  requiere_cutover   boolean     not null default true,
  registrado_at      timestamptz not null default now(),
  unique (objeto, linea_num, linea_texto)
);

comment on table public.ruta_precio_hallazgo is
'ISS107. Hallazgos de la ruta del precio, clasificados CONTRA EL CANDADO DEL DUENO, uno por uno, a mano. VIOLACION_CANDADO = el precio elige, ordena, autoriza o suprime un pick prospectivo. DIMENSIONAMIENTO_ECONOMICO = calcula cuanto dinero, nunca que pick. MEDICION_RETROSPECTIVA = mide resultados ya liquidados (permitido: medir el pasado no es elegir el futuro). DIAGNOSTICO_NO_DECIDE = se escribe o se muestra y se PROBO que no compuerta nada. FALSO_POSITIVO_DETECTOR = limitacion declarada del detector, con la razon exacta.';

insert into public.ruta_precio_hallazgo
  (objeto, linea_num, linea_texto, construccion, veredicto, razon, requiere_cutover)
select i.objeto, i.linea_num, i.linea, i.construccion, v.veredicto, v.razon, v.cutover
from public.ruta_precio_inventario i
join (values
 -- ---------- v_super_pick: el peor caso. Elige, ordena Y autoriza. ----------
 ('v_super_pick', 197, 'VIOLACION_CANDADO',
  'apto = (ev_real_pct > 0 AND roi_segmento > 0 ...). El EV es literalmente la bandera de APTO. El precio AUTORIZA el pick.', true),
 ('v_super_pick', 200, 'VIOLACION_CANDADO',
  'elegible_estrella exige ev_real_pct >= 20. Umbral de EV duro para conceder la categoria estrella. El precio SELECCIONA.', true),
 ('v_super_pick', 202, 'VIOLACION_CANDADO',
  'orden_estrella = ORDER BY score_total DESC, ev_real_pct DESC. El precio RANKEA.', true),
 ('v_super_pick', 203, 'VIOLACION_CANDADO',
  'Repite el umbral ev_real_pct >= 20 como columna elegible_estrella expuesta.', true),
 ('v_super_pick', 296, 'VIOLACION_CANDADO',
  'ORDER BY r.apto DESC, r.ev_real_pct DESC: el orden de TODA la vista lo fija el EV. Vista prospectiva (game_date entre now()-2h y now()+36h).', true),
 -- ---------- get_partidos_hoy_top ----------
 ('get_partidos_hoy_top(integer)', 23, 'VIOLACION_CANDADO',
  'Filtro (p/100*momio-1) > 0: suprime picks con EV no positivo. Sin la palabra ev en ninguna parte: por eso el detector necesita la FAMILIA FORMA.', true),
 ('get_partidos_hoy_top(integer)', 24, 'VIOLACION_CANDADO',
  'ORDER BY (p/100*momio-1) DESC: rankea por EV escrito como aritmetica, sin nombrarlo.', true),
 ('get_partidos_hoy_top(integer)', 30, 'VIOLACION_CANDADO',
  'Segunda aparicion del mismo filtro por EV.', true),
 -- ---------- veredicto_vivo ----------
 ('veredicto_vivo(text,text,numeric)', 56, 'VIOLACION_CANDADO',
  'v_estable exige v_ev > 0 y (c_cor*cuota-1) > 0: el veredicto de estabilidad lo concede el EV contra el precio.', true),
 ('veredicto_vivo(text,text,numeric)', 57, 'VIOLACION_CANDADO',
  'Segunda condicion de EV sobre la calibracion larga.', true),
 -- ---------- reto_picks_hoy__base: la superficie principal ----------
 ('reto_picks_hoy__base(text)', 63, 'VIOLACION_CANDADO',
  'El veredicto de Kelly NO APOSTAR suprime el pick. El dueno prohibio Kelly como decisor: "SIN KELLY ... PARA DECIDIR".', true),
 ('reto_picks_hoy__base(text)', 64, 'VIOLACION_CANDADO',
  'EV negativo marca motivo_bloqueo=ev_negativo y el pick deja de ser apostable. El precio SUPRIME un pick del modelo en la superficie principal.', true),
 ('reto_picks_hoy__base(text)', 69, 'VIOLACION_CANDADO',
  'monto_cand = kelly_monto, y es la clave de orden de las tarjetas (linea 76). El ORDEN lo fija una cantidad derivada del momio, no la probabilidad.', true),
 ('reto_picks_hoy__base(text)', 131, 'VIOLACION_CANDADO',
  'El texto que ve el usuario cuando el pick queda bloqueado es "El precio no compensa la probabilidad real". El producto le dice al usuario, con todas sus letras, que el precio decidio.', true),
 -- ---------- parlays y oportunidades ----------
 ('construir_parlay_v2__base(text,text,integer)', 59, 'VIOLACION_CANDADO',
  'Los legs se filtran por EV calibrado positivo.', true),
 ('construir_parlay_v2__base(text,text,integer)', 69, 'VIOLACION_CANDADO',
  'Los legs se ordenan por ROI de nicho y por ev_pct.', true),
 ('construir_parlay_del_dia__base(text,text,integer)', 86, 'VIOLACION_CANDADO',
  'Mismo filtro por EV, aqui sin calibrar.', true),
 ('get_oportunidades_hoy(integer)', 31, 'VIOLACION_CANDADO',
  'Filtro por EV calibrado: solo sobreviven picks con EV positivo antes de que el usuario los vea.', true),
 ('get_oportunidades_hoy(integer)', 61, 'VIOLACION_CANDADO',
  'ORDER BY ev_pct DESC.', true),
 -- ---------- clasificados como NO violacion, con la razon ----------
 ('mejor_pick_hoy(numeric,numeric,numeric,numeric,numeric,integer)', 65, 'FALSO_POSITIVO_DETECTOR',
  'La linea esta dentro de la ventana de 8 lineas posterior a un ORDER BY, pero es una lista de columnas de SALIDA, no una clave de orden. El orden real de esta funcion es por probabilidad contra el azar. Limitacion declarada de la ventana del detector.', false),
 ('mejor_pick_hoy(numeric,numeric,numeric,numeric,numeric,integer)', 66, 'FALSO_POSITIVO_DETECTOR',
  'Igual que la linea 65: columnas de salida, no clave de orden.', false),
 ('mejor_oportunidad_hoy(integer)', 40, 'FALSO_POSITIVO_DETECTOR',
  'Columna de salida f.kelly dentro de la ventana posterior a un ORDER BY. El orden real es (prob - base_azar) DESC, que es ruta de modelo y esta permitido.', false)
) as v(obj, ln, veredicto, razon, cutover)
  on v.obj = i.objeto and v.ln = i.linea_num
on conflict (objeto, linea_num, linea_texto) do update
  set veredicto = excluded.veredicto, razon = excluded.razon,
      requiere_cutover = excluded.requiere_cutover;

insert into public.ruta_precio_hallazgo
  (objeto, linea_num, linea_texto, construccion, veredicto, razon, requiere_cutover)
values ('kelly_stake__base(text,numeric,numeric,numeric,text,numeric)', 0,
        '(cuerpo completo: calculo de stake)', 'CONDICION_CONTROL',
        'DIMENSIONAMIENTO_ECONOMICO',
        'Calcular CUANTO dinero se arriesga es gestion de banca y el dueno nunca lo prohibio. kelly_stake por si solo no elige ningun pick. Quien viola el candado es el consumidor que usa su veredicto para suprimir y para ordenar.', false)
on conflict (objeto, linea_num, linea_texto) do nothing;

-- ---------------------------------------------------------------------
-- 7) SEVERIDAD Y GATE
-- ---------------------------------------------------------------------
create or replace view public.v_ruta_precio_en_decision as
select i.*,
       case
         when i.tiene_senal_no_esquivable
           or (i.senales && array['TOKEN_EV','TOKEN_EDGE','TOKEN_KELLY','TOKEN_PROB_IMPLICITA']
               and i.construccion in ('FILTRO','ORDEN','RAMA_SUPRESION','VENTANA_RANKING','LIMITE','CONDICION_CONTROL'))
         then 'P0_EL_PRECIO_DECIDE'
         when i.senales && array['TOKEN_ROI'] then 'P1_ROI_HISTORICO_DECIDE'
         else 'P2_COTA_DE_SANIDAD_O_JOIN'
       end as severidad,
       h.veredicto,
       h.razon as veredicto_razon
from public.ruta_precio_inventario i
left join public.ruta_precio_hallazgo h
       on h.objeto = i.objeto and h.linea_num = i.linea_num;

comment on view public.v_ruta_precio_en_decision is
'ISS107. Inventario con severidad y veredicto. P0 = el precio aparece en una construccion que decide, o la ARITMETICA del precio esta presente (senal no esquivable por renombrado). P2 = cota de sanidad tipo momio > 1.01 o join por rango de momio: informa, no decide.';

create or replace function public.gate_precio_no_decide()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'PRECIO_DECIDE_VIOLACION_ABIERTA'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(distinct objeto, ', ' order by objeto), 'ninguna')
  from public.ruta_precio_hallazgo where veredicto = 'VIOLACION_CANDADO'
  union all
  select 'PRECIO_DECIDE_P0_SIN_CLASIFICAR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(distinct objeto || ':' || linea_num, ', ' order by objeto || ':' || linea_num), 'ninguno')
  from public.v_ruta_precio_en_decision
  where severidad = 'P0_EL_PRECIO_DECIDE' and veredicto is null
  union all
  select 'PRECIO_DECIDE_DETECTOR_VE_ARITMETICA'::text,
         case when count(*) filter (where tiene_senal_no_esquivable) > 0 then 'PASS' else 'FAIL' end,
         count(*) filter (where tiene_senal_no_esquivable),
         'lineas detectadas por la ARITMETICA del precio y no por el nombre de la variable. Si esto llega a 0 el inventario quedo esquivable por renombrado.'
  from public.ruta_precio_inventario
  union all
  select 'PRECIO_DECIDE_INVENTARIO_FRESCO'::text,
         case when max(calculado_at) > now() - interval '7 days' then 'PASS' else 'FAIL' end,
         0::bigint,
         'snapshot calculado ' || coalesce(to_char(max(calculado_at),'YYYY-MM-DD HH24:MI'),'NUNCA')
           || '. Refrescar con refrescar_ruta_precio_inventario().'
  from public.ruta_precio_inventario;
$fn$;

comment on function public.gate_precio_no_decide() is
'ISS107. Gate del candado del dueno: el precio no elige, no ordena, no autoriza y no suprime un pick. Fail-closed: un hallazgo P0 sin clasificar cuenta como pendiente, nunca como limpio.';

grant execute on function public.forma_precio_en_linea(text)            to anon, authenticated, service_role;
grant execute on function public.token_precio_en_linea(text)            to anon, authenticated, service_role;
grant execute on function public.lineas_decision_por_precio(text)       to anon, authenticated, service_role;
grant execute on function public.gate_precio_no_decide()                to anon, authenticated, service_role;
grant execute on function public.refrescar_ruta_precio_inventario()     to service_role;
grant select on public.v_objeto_accionable          to anon, authenticated, service_role;
grant select on public.v_ruta_precio_en_decision    to anon, authenticated, service_role;
grant select on public.ruta_precio_inventario       to anon, authenticated, service_role;
grant select on public.ruta_precio_hallazgo         to anon, authenticated, service_role;
