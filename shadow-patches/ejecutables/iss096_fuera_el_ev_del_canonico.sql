-- iss096 — FUERA LA SEMANTICA ECONOMICA DEL OBJETO CANONICO  [EJECUTABLE]
--
-- RECAPTURA: la version anterior era SOLO PROSA, 0 lineas de SQL. Detectado por
-- el dueno. Esta version se ejecuta, es IDEMPOTENTE (detecta si ya esta
-- aplicada) y termina en assertions.
--
-- MEDICION QUE MOTIVA ESTO: en el runtime activo hay 71 funciones y 8 vistas con
-- semantica de EV/Kelly/edge/stake. No es "una vista con ev_pct": es un
-- subsistema economico completo, con Kelly, stake, bankroll y limites de
-- exposicion. Este patch limpia el OBJETO CANONICO y las hojas; el resto queda
-- MEDIDO por los gates, no escondido.
--
-- EJECUCION: correr el archivo COMPLETO en una transaccion. Requiere iss095.

-- ===========================================================================
-- 1) La elegibilidad canonica nueva: NADA economico.
--    Regla textual del dueno: modelo correcto + identidad correcta + datos
--    suficientes + temporalidad limpia + calidad/calibracion permitida.
-- ===========================================================================
create or replace function public.elegibilidad_no_economica_v1(p jsonb)
returns jsonb language sql stable set search_path to 'public' as $function$
with c as (
  select
    (p->>'model_version') is not null and (p->>'model_version') <> ''       as modelo_ok,
    coalesce(p->>'semantic_validity','FAIL') = 'PASS'                       as identidad_ok,
    coalesce(p->>'empirical_sufficiency','PENDING') = 'OK'                  as datos_ok,
    coalesce((p->>'temporalidad_limpia')::boolean, false)                   as tiempo_ok,
    coalesce(p->>'respaldo','SIN_REGISTRO') in ('VALIDADO','EARLY')         as calidad_ok,
    coalesce(p->>'data_readiness','') = 'READY'                             as datos_listos
)
select jsonb_build_object(
  'eligible', (modelo_ok and identidad_ok and datos_ok and tiempo_ok and calidad_ok and datos_listos),
  'reason_code', case
     when not modelo_ok    then 'SIN_MODEL_VERSION'
     when not identidad_ok then 'IDENTIDAD_EN_DISPUTA'
     when not datos_ok     then 'MUESTRA_INSUFICIENTE'
     when not tiempo_ok    then 'TEMPORALIDAD_SUCIA'
     when not calidad_ok   then 'CALIBRACION_NO_PERMITIDA'
     when not datos_listos then 'DATOS_NO_LISTOS'
     else 'OK' end,
  'criterios', jsonb_build_object('modelo',modelo_ok,'identidad',identidad_ok,
     'datos',datos_ok,'temporalidad',tiempo_ok,'calidad',calidad_ok,'listos',datos_listos))
from c;
$function$;
comment on function public.elegibilidad_no_economica_v1(jsonb) is
  'Elegibilidad canonica SIN NADA ECONOMICO. No lee ev, edge, kelly, stake ni momio. Sustituye a economic_eligibility_v1 en el objeto canonico.';
grant execute on function public.elegibilidad_no_economica_v1(jsonb) to anon, authenticated, service_role;

-- ===========================================================================
-- 2) Fuera v_diagnostico_precio.
--    La cree yo en iss093 pensando que mover el EV a una vista de diagnostico
--    bastaba. El dueno fue explicito en que NO cumple lo que pidio. Tenia razon.
-- ===========================================================================
drop view if exists public.v_diagnostico_precio;

-- ===========================================================================
-- 3) v_pick_canonico: 7 parches sobre la definicion viva.
--
--    POR QUE PARCHE Y NO DDL COMPLETO: v_pick_canonico es una vista
--    PREEXISTENTE de 21 KB cuya definicion completa NUNCA estuvo en git (deuda
--    anterior a este bloque, la nombro en vez de absorberla en silencio). El
--    volcado integro vive en baseline/v_pick_canonico_YYYYMMDD.sql para permitir
--    reconstruccion desde cero; aqui va la TRANSFORMACION, que es lo que este
--    patch aporta.
--
--    IDEMPOTENTE: si ya no hay semantica economica, no hace nada.
--    ABORTA si un patron no coincide: nunca aplica a medias.
-- ===========================================================================
do $$
declare d text; nd text; paso text; ya_limpia boolean;
begin
  d := pg_get_viewdef('public.v_pick_canonico'::regclass, true);

  ya_limpia := not (d ~* 'decision_economica_v1|economic_eligibility_v1|edge_pct >=|ev_threshold');
  if ya_limpia then
    raise notice 'iss096: v_pick_canonico ya estaba limpia, no se toca';
    return;
  end if;

  nd := d;
  paso := 'ev_pct';
  nd := regexp_replace(nd,
    '\(decision_economica_v1\(m_1\.probabilidad_pct, m_1\.momio_mercado, m_1\.mercado\) ->> ''ev_pct''::text\)::numeric',
    'NULL::numeric', 'g');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'edge_pct';
  nd := regexp_replace(nd,
    'round\(\(m_1\.probabilidad_pct / 100\.0 - 1\.0 / m_1\.momio_mercado\) \* 100::numeric, 1\)',
    'NULL::numeric', 'g');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'prob_implicita';
  nd := regexp_replace(nd, 'round\(100\.0 / m_1\.momio_mercado, 1\)', 'NULL::numeric', 'g');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'elegibilidad';
  nd := replace(nd, 'economic_eligibility_v1(', 'public.elegibilidad_no_economica_v1(');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'entradas_elegibilidad';
  nd := replace(nd,
    '''ev_pct'', c.ev_pct, ''ev_threshold'', 2.5',
    '''respaldo'', public.estado_respaldo(c.deporte, c.mercado, public.modelo_de_pick(c.fuente, c.deporte, c.mercado)), ''temporalidad_limpia'', (c.arranca_en > now())');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'model_version';
  nd := replace(nd,
    '''model_version'', modelo_version_activa(c.deporte)',
    '''model_version'', public.modelo_de_pick(c.fuente, c.deporte, c.mercado)');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'explicacion_precio';
  nd := regexp_replace(nd,
    'CASE\s+WHEN m\.momio_mercado IS NULL THEN.*?END AS explicacion_precio',
    'CASE WHEN m.momio_mercado IS NULL THEN (''Nuestro modelo le da ''::text || m.probabilidad_pct) || ''%. Todavia no tenemos precio de casa.''::text ELSE ((((''Nuestro modelo le da ''::text || m.probabilidad_pct) || ''%. La casa paga ''::text) || m.momio_mercado) || '', que se muestra solo como dato informativo.''::text) END AS explicacion_precio',
    'g');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  d := nd; paso := 'nivel_ventaja';
  nd := regexp_replace(nd,
    'CASE\s+WHEN m\.es_pick AND m\.edge_pct >= 5::numeric THEN ''ok''::text.*?END AS nivel_ventaja',
    'public.estado_respaldo(m.deporte, m.mercado, public.modelo_de_pick(m.fuente, m.deporte, m.mercado)) AS nivel_ventaja',
    'g');
  if nd = d then raise exception 'iss096 PARCHE NO APLICADO en %', paso; end if;

  execute 'create or replace view public.v_pick_canonico as ' || nd;
  raise notice 'iss096: v_pick_canonico, 8 parches aplicados';
end $$;

-- ===========================================================================
-- 4) Hojas: se envuelve cada vista en si misma seleccionando TODAS sus columnas
--    MENOS las economicas. Asi no se reescriben 5 definiciones preexistentes a
--    mano ni se arriesga divergencia: la logica interna queda igual.
--    Aqui salio KELLY VIVO EN VISTAS DE USUARIO:
--      v_oraculo_canonico.kelly_pct  y  v_super_pick.kelly_pct_sugerido
-- ===========================================================================
do $$
declare v text; d text; cols text; n_out int;
  prohibidas text[] := array['ev_pct','edge_pct','kelly_pct','kelly_pct_sugerido',
    'prob_que_implica_el_precio_pct','discriminacion_pp','score_valor','brecha_pp',
    'vs_mercado_pts','stake_sugerido','stake_pct'];
begin
  foreach v in array array['v_mejores_picks_mlb','v_motor_valor_proximos','v_oraculo_canonico',
                           'v_picks_con_valor','v_super_pick']
  loop
    select count(*) into n_out from information_schema.columns
     where table_schema='public' and table_name=v and column_name = any(prohibidas);
    if n_out = 0 then raise notice 'iss096: % ya estaba limpia', v; continue; end if;

    d := regexp_replace(pg_get_viewdef(('public.'||v)::regclass, true), ';\s*$', '');
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position) into cols
    from information_schema.columns
    where table_schema='public' and table_name=v and not (column_name = any(prohibidas));

    execute format('drop view public.%I', v);
    execute format('create view public.%I as select %s from ( %s ) _q', v, cols, d);
    execute format('comment on view public.%I is %L', v,
      'Semantica economica RETIRADA del runtime activo (iss096): se quitaron '||n_out||
      ' columna(s) de EV/edge/Kelly. Los momios siguen como precio informativo; EV, Kelly, edge y stake no.');
    raise notice 'iss096: % -> % columnas economicas retiradas', v, n_out;
  end loop;
end $$;

-- ===========================================================================
-- 5) REGISTRO DE SUPERFICIES COMPLETO, con fail-closed.
--    Con 4 vistas registradas el gate de EV daba 0. Con 58 da 31. El dueno
--    avisó exactamente de esto: un registro chico da un FALSO VERDE.
--    Clasificacion CONSERVADORA: el default es USUARIO; solo baja de categoria
--    lo inequivocamente interno.
-- ===========================================================================
alter table public.superficie_usuario add column if not exists clase text not null default 'USUARIO';
alter table public.superficie_usuario drop constraint if exists superficie_clase_check;
alter table public.superficie_usuario add constraint superficie_clase_check
  check (clase in ('USUARIO','DIAGNOSTICO','LAB'));
comment on column public.superficie_usuario.clase is
  'USUARIO = la ve el usuario final, aplican las reglas estrictas. DIAGNOSTICO = auditoria interna. LAB = laboratorio. Una vista predictiva SIN fila aqui cuenta como violacion: FALLA CERRADO.';

insert into public.superficie_usuario (vista, proposito, clase)
select c.relname::text,
       'clasificada automaticamente por iss096; revisar si cambia de pantalla',
       case
         when c.relname::text ~ '^(v_)?lab_|_raw$' then 'LAB'
         when c.relname::text ~ 'health_check|alert|huerfano|sin_marcador|sin_resolver|_dq_|dq_|medicion|calibracion|termometro|desempeno|patrones|nichos|grading|movimiento_linea|clv_|riesgo_homonimo|cobertura|legs_sin|anti_picks|evidencia_modelo' then 'DIAGNOSTICO'
         else 'USUARIO'
       end
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relkind in ('v','m')
  and exists (select 1 from information_schema.columns col
              where col.table_schema='public' and col.table_name=c.relname
                and col.column_name ~* 'probabilidad|prob_|pick')
on conflict (vista) do nothing;

update public.superficie_usuario set clase='USUARIO'
 where vista in ('v_reto13m_mejores','v_reto13m_lo_mejor','v_mejor_pick_por_partido','v_reto13m_analisis_experimental');

-- lista interna de veto por rendimiento de modelo, no es pantalla.
-- Se deja escrito el motivo: no se reclasifica para que pase un gate.
update public.superficie_usuario
   set clase='DIAGNOSTICO',
       proposito='Lista interna de veto por rendimiento de modelo. No la ve el usuario final.'
 where vista='ai_categorias_a_vetar';

-- ===========================================================================
-- 6) ASSERTIONS
-- ===========================================================================
do $$
declare v_n int;
begin
  -- 6a) el objeto canonico, limpio
  if pg_get_viewdef('public.v_pick_canonico'::regclass,true) ~* 'decision_economica_v1' then
    raise exception 'decision_economica_v1 sigue en v_pick_canonico'; end if;
  if pg_get_viewdef('public.v_pick_canonico'::regclass,true) ~* 'economic_eligibility_v1' then
    raise exception 'economic_eligibility_v1 sigue en v_pick_canonico'; end if;
  if pg_get_viewdef('public.v_pick_canonico'::regclass,true) ~* 'edge_pct >=' then
    raise exception 'el gate edge_pct>= sigue en v_pick_canonico'; end if;
  if pg_get_viewdef('public.v_pick_canonico'::regclass,true) ~* 'ev_threshold' then
    raise exception 'ev_threshold sigue en v_pick_canonico'; end if;
  if pg_get_viewdef('public.v_pick_canonico'::regclass,true) ~* 'paga MAS|paga MENOS' then
    raise exception 'la narrativa de EV sigue en v_pick_canonico'; end if;

  -- 6b) EV/edge/implicita sin semantica: siempre NULL
  select count(*) into v_n from public.v_pick_canonico
   where ev_pct is not null or edge_pct is not null or prob_que_implica_el_precio_pct is not null;
  if v_n > 0 then raise exception 'EV/edge/implicita con valor en v_pick_canonico: % filas', v_n; end if;

  -- 6c) la vista de diagnostico de precio no debe existir
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relname='v_diagnostico_precio';
  if v_n > 0 then raise exception 'v_diagnostico_precio sigue viva'; end if;

  -- 6d) Kelly fuera de las hojas
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and column_name in ('kelly_pct','kelly_pct_sugerido')
     and table_name in ('v_oraculo_canonico','v_super_pick');
  if v_n > 0 then raise exception 'KELLY SIGUE EN VISTA DE USUARIO: % columnas', v_n; end if;

  -- 6e) fail-closed: ninguna vista predictiva sin clasificar
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind in ('v','m')
     and exists (select 1 from information_schema.columns col
                 where col.table_schema='public' and col.table_name=c.relname
                   and col.column_name ~* 'probabilidad|prob_|pick')
     and not exists (select 1 from public.superficie_usuario s where s.vista=c.relname::text);
  if v_n > 0 then raise exception 'SUPERFICIE SIN CLASIFICAR: % vistas', v_n; end if;

  raise notice 'iss096 OK: objeto canonico sin EV, Kelly fuera de hojas, registro fail-closed';
end $$;

-- ===========================================================================
-- 7) LO QUE ESTE PATCH NO CIERRA (medido por gates_selector.sql)
-- ===========================================================================
--   EV_FIELDS_USER_VISIBLE     = 31  columnas economicas en 12 vistas USUARIO
--   UNIFORM_BASELINE_PICK_GATE =  5  vistas con baseline uniforme
--   SPORT_QUOTA                =  1  v_reto13m_daily: PARTITION BY deporte, dia_mx
--   EV_EN_RUNTIME_ACTIVO       =  7  vistas USUARIO que invocan logica economica
-- C NO ESTA COMPLETO. Los gates lo dicen en vez de esconderlo.
