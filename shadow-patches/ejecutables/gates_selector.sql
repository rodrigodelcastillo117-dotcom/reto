-- gates_selector.sql — LOS GATES DE MAQUINA DEL SELECTOR  [EJECUTABLE]
--
-- Se ejecuta despues de iss095/iss096. Definir esto en su propio archivo es
-- deliberado: es el ARNES DE PRUEBA, no una migracion, y tiene que poder
-- recrearse y correrse solo.
--
-- Las pruebas 2 y 4 recorren el CIERRE DE DEPENDENCIAS de la superficie, no solo
-- la vista final: un baseline en la raiz contamina hacia arriba, y eso era
-- exactamente lo que pasaba en v_pick_canonico.
--
-- LECCION APRENDIDA, escrita para no repetirla: dos veces un patron regex mio
-- dio FALSO POSITIVO por cruzar saltos de linea con [^)]*. Por eso SPORT_QUOTA
-- usa [^(]* (exige que `deporte` sea DIMENSION de particion y no viva dentro de
-- un CASE anidado) y la prueba 4 recorre LINEA POR LINEA.

create or replace function public.pruebas_selector_limpio()
returns jsonb language plpgsql volatile set search_path to 'public' as $function$
declare t1 int; t2 int; t3 int; t4 int; t5 int; t6 int; t7 int; t8 int;
        t9 int; t10 int; t11 int; t12 int;
        d1 jsonb; d2 jsonb; d3 jsonb; d4 jsonb; d5 jsonb; d6 jsonb; d7 jsonb; d8 jsonb;
        g9 jsonb; g10 jsonb; g11 jsonb; g12a jsonb; g12b jsonb;
begin
  create temporary table if not exists _sup (vista text primary key) on commit drop;
  delete from _sup;
  insert into _sup select vista from superficie_usuario where clase='USUARIO';

  create temporary table if not exists _cadena (vista text primary key) on commit drop;
  delete from _cadena;
  insert into _cadena (vista)
  with recursive cad(vista) as (
    select (s.vista)::text collate "C" from _sup s
    union
    select (src.relname)::text collate "C"
    from cad c
    join pg_class dep on (dep.relname)::text collate "C" = c.vista
    join pg_namespace nd on nd.oid=dep.relnamespace and nd.nspname='public'
    join pg_rewrite r on r.ev_class=dep.oid
    join pg_depend d on d.objid=r.oid
    join pg_class src on src.oid=d.refobjid
    join pg_namespace n on n.oid=src.relnamespace
    where n.nspname='public' and src.relkind in ('v','m')
      and (src.relname)::text collate "C" <> c.vista)
  select distinct vista from cad;

  -- 1 EV_FIELDS_USER_VISIBLE: columna prohibida EXPUESTA en clase USUARIO
  select count(*), coalesce(jsonb_agg(jsonb_build_object('vista',table_name,'columna',column_name) order by table_name),'[]')
    into t1, d1
  from information_schema.columns
  where table_schema='public' and table_name in (select vista from _sup)
    and column_name in ('ev_pct','edge_pct','prob_que_implica_el_precio_pct','discriminacion_pp',
        'score_valor','brecha_pp','vs_mercado_pts','prob_local_casa_pct','prob_visitante_casa_pct',
        'base_azar','ventaja_sobre_azar','favorito','favorito_pct','nivel_ventaja','es_pick',
        'explicacion_precio','clv_pct','probabilidad_ajustada_pct','inflacion_pp',
        'kelly_pct','kelly_pct_sugerido','stake_pct','stake_sugerido');

  -- 2 UNIFORM_BASELINE_PICK_GATE: baseline uniforme en la CADENA completa
  select count(*), coalesce(jsonb_agg(jsonb_build_object('vista',nm)),'[]') into t2, d2
  from (select c.relname::text nm from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind in ('v','m')
          and c.relname::text in (select vista from _cadena)
          and (pg_get_viewdef(c.oid,true) ~ '33\.3' or pg_get_viewdef(c.oid,true) ~ '50\.0')) q;

  -- 3 SPORT_QUOTA: TOP_ONLY_GLOBAL no hace PARTITION BY deporte
  select count(*), coalesce(jsonb_agg(jsonb_build_object('vista',nm,'motivo',motivo)),'[]') into t3, d3
  from (select c.relname::text nm, 'partition by deporte' motivo
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind in ('v','m')
          and c.relname::text in (select vista from _sup)
          and pg_get_viewdef(c.oid,true) ~* 'partition by[^(]*\mdeporte\M'
        union all
        select table_name::text,'columna rn_deporte' from information_schema.columns
        where table_schema='public' and column_name='rn_deporte'
          and table_name in (select vista from _sup)) q;

  -- 4 IN_SAMPLE_PROB_MUTATION: la medicion sin validar no muta P_RETO ni ordena.
  --   Llevarla como CONTEXTO esta permitido; por eso se busca MUTACION, no
  --   presencia, y linea por linea.
  select count(*), coalesce(jsonb_agg(jsonb_build_object('vista',nm,'motivo',motivo)),'[]') into t4, d4
  from (select table_name::text nm,'columna de probabilidad derivada de medicion in-sample' motivo
        from information_schema.columns
        where table_schema='public' and table_name in (select vista from _sup)
          and column_name in ('probabilidad_ajustada_pct','inflacion_pp','prob_real_del_tramo')
        union all
        select c.relname::text,'la medicion ordena o filtra'
        from pg_class c join pg_namespace n on n.oid=c.relnamespace
        cross join lateral regexp_split_to_table(pg_get_viewdef(c.oid,true), E'\n') l
        where n.nspname='public' and c.relkind in ('v','m')
          and c.relname::text in (select vista from _cadena)
          and l ~* '(order by|partition by|^\s*(and|or|where|having)\s)'
          and l ~* 'zona_realidad|prob_real_del_tramo|probabilidad_ajustada_pct' and l !~* '^\s*--') q;

  -- 5 NONCANONICAL_OR_TRIVIAL_LINES
  select count(*), coalesce(jsonb_agg(jsonb_build_object('deporte',deporte,'pick',pick_desc)),'[]') into t5, d5
  from (select deporte, mercado, pick_desc from public.v_mejor_pick_por_partido
        where not public.linea_es_canonica(deporte, mercado, pick_desc)
        union all
        select deporte, mercado, pick_desc from public.v_reto13m_lo_mejor
        where not public.linea_es_canonica(deporte, mercado, pick_desc)) q;

  -- 6 UNTRACEABLE_APPROVED_PICK: ningun pick APROBADO sin model_version
  select count(*), coalesce(jsonb_agg(jsonb_build_object('vista',v,'pick',pick_desc)),'[]') into t6, d6
  from (select 'v_reto13m_lo_mejor' v, pick_desc from public.v_reto13m_lo_mejor where model_version is null
        union all
        select 'v_reto13m_mejores', pick_desc from public.v_reto13m_mejores where model_version is null) q;

  -- 7 SUPERFICIE_SIN_CLASIFICAR: FALLA CERRADO
  select count(*), coalesce(jsonb_agg(nm),'[]') into t7, d7
  from (select c.relname::text nm from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind in ('v','m')
          and exists (select 1 from information_schema.columns col
                      where col.table_schema='public' and col.table_name=c.relname
                        and col.column_name ~* 'probabilidad|prob_|pick')
          and not exists (select 1 from superficie_usuario s where s.vista=c.relname::text)
          and not exists (select 1 from superficie_retirada r where r.vista=c.relname::text)) q;

  -- 8 EV_EN_RUNTIME_ACTIVO: logica economica invocada desde una vista USUARIO
  select count(*), coalesce(jsonb_agg(jsonb_build_object('vista',nm)),'[]') into t8, d8
  from (select distinct c.relname::text nm from pg_class c join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='public' and c.relkind in ('v','m')
          and c.relname::text in (select vista from _sup)
          and pg_get_viewdef(c.oid,true) ~* 'economic_eligibility_v1|decision_economica_v1|\mkelly_|ev_decision_v1|tamano_apuesta|simular_bankroll|kelly_fraccion_pct') q;

  -- 9 IDENTIDAD EXACTA (ISS098): ni substrings, ni alias huerfanos, ni colisiones.
  --   Conductual: muta nombres reales de la agenda y exige rechazo. La version
  --   vieja con %substring% marca 190 de 240 mutaciones aceptadas.
  g9 := gate_identidad_exacta();
  t9 := (g9->>'IDENTIDAD_PARCIAL_ACEPTADA')::int
      + (g9->>'ALIAS_SIN_EQUIPO_EN_AGENDA')::int
      + (g9->>'ALIAS_COLISIONA_CON_OTRO_EQUIPO')::int;

  -- 10 P_RETO solo se mueve lo que explica una transformacion REGISTRADA (ISS098).
  --   NO exige P_RETO == P_RAW: eso rompia una calibracion futura legitima.
  g10 := gate_p_reto_sin_desplazar();
  t10 := (g10->>'P_RETO_DESPLAZADA')::int + (g10->>'ajustes_habilitados_sin_cota')::int;

  -- 11 nada autorizado a mover P_RETO puede ser irreproducible o inverificable.
  g11 := gate_calibrador_reproducible();
  t11 := (g11->>'CALIBRADOR_APTO_NO_REPRODUCIBLE')::int
       + (g11->>'CALIBRADOR_APTO_NO_VERIFICABLE_ESCALAR')::int;

  -- 12 superficie: ni destruida en silencio ni resucitada en silencio.
  g12a := gate_superficie_destruida();
  g12b := gate_superficie_resucitada();
  t12 := (g12a->>'SUPERFICIE_REGISTRADA_INEXISTENTE')::int
       + (g12b->>'SUPERFICIE_RETIRADA_RESUCITADA')::int;

  return jsonb_build_object(
    'EV_FIELDS_USER_VISIBLE', t1, 'EV_FIELDS_detalle', d1,
    'UNIFORM_BASELINE_PICK_GATE', t2, 'BASELINE_detalle', d2,
    'SPORT_QUOTA', t3, 'SPORT_QUOTA_detalle', d3,
    'IN_SAMPLE_PROB_MUTATION', t4, 'IN_SAMPLE_detalle', d4,
    'NONCANONICAL_OR_TRIVIAL_LINES', t5, 'LINEAS_detalle', d5,
    'UNTRACEABLE_APPROVED_PICK', t6, 'TRAZABILIDAD_detalle', d6,
    'SUPERFICIE_SIN_CLASIFICAR', t7, 'SIN_CLASIFICAR_detalle', d7,
    'EV_EN_RUNTIME_ACTIVO', t8, 'EV_RUNTIME_detalle', d8,
    'IDENTIDAD_NO_EXACTA', t9, 'IDENTIDAD_detalle', g9,
    'P_RETO_DESPLAZADA_NO_REGISTRADA', t10, 'DESPLAZAMIENTO_detalle', g10,
    'CALIBRADOR_AUTORIZADO_NO_VERIFICABLE', t11, 'CALIBRADOR_detalle', g11,
    'SUPERFICIE_ALTERADA_EN_SILENCIO', t12,
    'SUPERFICIE_detalle', jsonb_build_object('destruida',g12a,'resucitada',g12b),
    'superficies_USUARIO', (select count(*) from _sup),
    'cadena_revisada', (select count(*) from _cadena),
    'todas_en_cero', (t1=0 and t2=0 and t3=0 and t4=0 and t5=0 and t6=0 and t7=0 and t8=0
                      and t9=0 and t10=0 and t11=0 and t12=0));
end $function$;

grant execute on function public.pruebas_selector_limpio() to anon, authenticated, service_role;

-- Los gates que YA deben estar en cero se asertan duro. Los que siguen abiertos
-- se reportan con WARNING para que el hueco sea VISIBLE en cada corrida sin
-- bloquear el replay del resto.
do $$
declare r jsonb;
begin
  r := public.pruebas_selector_limpio();

  if (r->>'IN_SAMPLE_PROB_MUTATION')::int <> 0 then
    raise exception 'IN_SAMPLE_PROB_MUTATION = % : %', r->>'IN_SAMPLE_PROB_MUTATION', r->'IN_SAMPLE_detalle'; end if;
  if (r->>'NONCANONICAL_OR_TRIVIAL_LINES')::int <> 0 then
    raise exception 'NONCANONICAL_OR_TRIVIAL_LINES = % : %', r->>'NONCANONICAL_OR_TRIVIAL_LINES', r->'LINEAS_detalle'; end if;
  if (r->>'UNTRACEABLE_APPROVED_PICK')::int <> 0 then
    raise exception 'UNTRACEABLE_APPROVED_PICK = % : %', r->>'UNTRACEABLE_APPROVED_PICK', r->'TRAZABILIDAD_detalle'; end if;
  if (r->>'SUPERFICIE_SIN_CLASIFICAR')::int <> 0 then
    raise exception 'SUPERFICIE_SIN_CLASIFICAR = % : %', r->>'SUPERFICIE_SIN_CLASIFICAR', r->'SIN_CLASIFICAR_detalle'; end if;

  if (r->>'EV_FIELDS_USER_VISIBLE')::int <> 0 then
    raise warning 'ABIERTO EV_FIELDS_USER_VISIBLE = %', r->>'EV_FIELDS_USER_VISIBLE'; end if;
  if (r->>'UNIFORM_BASELINE_PICK_GATE')::int <> 0 then
    raise warning 'ABIERTO UNIFORM_BASELINE_PICK_GATE = %', r->>'UNIFORM_BASELINE_PICK_GATE'; end if;
  if (r->>'SPORT_QUOTA')::int <> 0 then
    raise warning 'ABIERTO SPORT_QUOTA = %', r->>'SPORT_QUOTA'; end if;
  if (r->>'EV_EN_RUNTIME_ACTIVO')::int <> 0 then
    raise warning 'ABIERTO EV_EN_RUNTIME_ACTIVO = %', r->>'EV_EN_RUNTIME_ACTIVO'; end if;

  raise notice 'gates: 4 cerrados duros OK; los abiertos quedan como WARNING visible';
end $$;
