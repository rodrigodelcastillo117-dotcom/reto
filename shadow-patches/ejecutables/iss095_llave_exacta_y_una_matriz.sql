-- iss095 — LLAVE EXACTA POR model_version + UNA SOLA MATRIZ  [EJECUTABLE]
--
-- RECAPTURA: la version anterior era SOLO PROSA, 0 lineas de SQL. Detectado por
-- el dueno. Esta version se ejecuta, es idempotente y termina en assertions.
--
-- POR QUE: autorizar por (deporte, mercado) permitia que el calibrador de un
-- modelo autorizara a OTRO modelo del mismo mercado. NO era hipotetico: el
-- porcentaje de MLB visible lo produce `motor_mlb_cuantitativo` y el modelo con
-- calibrador es `mlb_totales_normal_v1`. SON DISTINTOS. En cuanto ese pasara el
-- holdout, la llave vieja habria autorizado a un motor que nunca fue medido.
--
-- Hallazgos colaterales, ambos reales:
--   modelo_version_activa('soccer') devuelve 'crossleague_v1', que NO EXISTE en
--     modelo_registry: referencia colgante.
--   modelo_version_activa('baseball') devuelve NULL.
--
-- EJECUCION: correr el archivo COMPLETO en una transaccion.

-- ===========================================================================
-- 1) De que modelo sale cada porcentaje visible
-- ===========================================================================
create table if not exists public.motor_modelo_mapa (
  fuente text not null, deporte text not null, mercado text not null,
  model_version text, nota text,
  primary key (fuente, deporte, mercado));
comment on table public.motor_modelo_mapa is
  'Mapea el motor que produce cada porcentaje visible a su model_version. NULL = motor SIN REGISTRAR: falla cerrado. Regla del dueno: ningun porcentaje visible sin rastrearlo al modelo exacto que lo produjo.';

insert into public.motor_modelo_mapa (fuente, deporte, mercado, model_version, nota) values
 ('motor_mlb_cuantitativo','baseball','Moneyline',  null,'SIN REGISTRAR en modelo_registry. NO es mlb_ml_poisson_v1 (MODEL_REJECTED).'),
 ('motor_mlb_cuantitativo','baseball','Over/Under', null,'SIN REGISTRAR. OJO: NO es mlb_totales_normal_v1; ese es el del backtest, no el que sirve esta vista.'),
 ('motor_futbol_calibrado','soccer','Moneyline',    null,'SIN REGISTRAR. modelo_version_activa(soccer) devuelve crossleague_v1, inexistente en modelo_registry.'),
 ('motor_futbol_calibrado','soccer','Over/Under',   null,'SIN REGISTRAR.'),
 ('motor_futbol_calibrado','soccer','BTTS',         null,'SIN REGISTRAR.'),
 ('motor_picks','soccer','Moneyline',               null,'SIN REGISTRAR.'),
 ('motor_picks','soccer','Over/Under',              null,'SIN REGISTRAR.')
on conflict (fuente, deporte, mercado) do update set nota = excluded.nota;

create or replace function public.modelo_de_pick(p_fuente text, p_deporte text, p_mercado text)
returns text language sql stable set search_path to 'public' as $function$
  select model_version from motor_modelo_mapa
   where fuente = p_fuente and deporte = p_deporte and mercado = p_mercado;
$function$;

-- ===========================================================================
-- 2) La autorizacion: deporte + mercado + model_version (+ calibration_version)
--    FALLA CERRADO. La version laxa de 2 argumentos se ELIMINA: si existe,
--    alguien la va a llamar.
-- ===========================================================================
create or replace function public.mercado_apto_para_lock(
  p_deporte text, p_mercado text, p_model_version text, p_calibration_version text default null)
returns boolean language sql stable set search_path to 'public' as $function$
  select p_model_version is not null and exists (
    select 1 from calibradores c
    where c.apto_para_lock and not c.invalidado
      and c.model_version = p_model_version
      and (p_calibration_version is null or c.calibration_version = p_calibration_version)
      and c.deporte = case
            when p_deporte ~* 'baseball|beisbol' then 'baseball'
            when p_deporte ~* 'football|nfl'     then 'football'
            when p_deporte ~* 'soccer|futbol'    then 'soccer'
            else p_deporte end
      and c.mercado = case
            when p_deporte ~* 'soccer|futbol' and p_mercado = 'Moneyline' then '1X2'
            else p_mercado end);
$function$;

-- ===========================================================================
-- 3) El respaldo SOLO lo dice el registro versionado.
--    Antes salia de calibracion_confiable / muestra_calibracion, que permitian
--    mostrar "ALTO" y advertir "no validado" a la vez.
-- ===========================================================================
create or replace function public.estado_respaldo(p_deporte text, p_mercado text, p_model_version text)
returns text language sql stable set search_path to 'public' as $function$
  select case
    when p_model_version is null then 'SIN_REGISTRO'
    when public.mercado_apto_para_lock(p_deporte, p_mercado, p_model_version) then 'VALIDADO'
    when exists (select 1 from calibradores c
                  where c.model_version = p_model_version and c.elegido and not c.invalidado)
         then 'EARLY'
    else 'INSUFFICIENT'
  end;
$function$;

-- ===========================================================================
-- 4) Universo de lineas. NO es un baseline de probabilidad: no toca P_RETO ni
--    el orden. Restringe QUE CANDIDATOS EXISTEN, que es la forma correcta de
--    evitar que gane un Over 0.5 por facil.
--    INTERINO: son lineas PLAUSIBLES del deporte, no la linea real del
--    proveedor para cada partido. Con lineas reales esto debe endurecerse.
-- ===========================================================================
create table if not exists public.lineas_canonicas (
  deporte text not null, mercado text not null, linea numeric not null,
  es_principal boolean not null default false, nota text,
  primary key (deporte, mercado, linea));

insert into public.lineas_canonicas (deporte, mercado, linea, es_principal, nota) values
 ('baseball','Over/Under',7.0,false,'secundaria habitual'),
 ('baseball','Over/Under',7.5,true ,'principal frecuente'),
 ('baseball','Over/Under',8.0,true ,'principal frecuente'),
 ('baseball','Over/Under',8.5,true ,'la mas comun en MLB'),
 ('baseball','Over/Under',9.0,true ,'principal frecuente'),
 ('baseball','Over/Under',9.5,true ,'principal frecuente'),
 ('baseball','Over/Under',10.0,false,'secundaria'),
 ('baseball','Over/Under',10.5,false,'secundaria'),
 ('soccer','Over/Under',2.5,true ,'LA linea principal de totales en futbol'),
 ('football','Over/Under',37.0,false,''),('football','Over/Under',37.5,false,''),
 ('football','Over/Under',40.0,false,''),('football','Over/Under',40.5,false,''),
 ('football','Over/Under',43.0,true ,''),('football','Over/Under',43.5,true ,''),
 ('football','Over/Under',46.0,true ,''),('football','Over/Under',46.5,true ,''),
 ('football','Over/Under',49.0,false,''),('football','Over/Under',49.5,false,'')
on conflict (deporte, mercado, linea) do update
  set es_principal=excluded.es_principal, nota=excluded.nota;
-- soccer 3.5 NO se registra: es el "viejo problema del Under 3.5". Acierta ~75%
-- por construccion y gana cualquier argmax puro sin aportar nada.

create or replace function public.linea_es_canonica(p_deporte text, p_mercado text, p_pick_desc text)
returns boolean language sql stable set search_path to 'public' as $function$
  select case
    when p_mercado not in ('Over/Under') then true          -- Moneyline/BTTS: no aplica
    when nullif((regexp_match(p_pick_desc,'(\d+(?:\.\d+)?)'))[1],'') is null then false
    else exists (select 1 from lineas_canonicas l
                  where l.mercado = p_mercado
                    and l.deporte = case
                          when p_deporte ~* 'baseball|beisbol' then 'baseball'
                          when p_deporte ~* 'football|nfl'     then 'football'
                          when p_deporte ~* 'soccer|futbol'    then 'soccer'
                          else p_deporte end
                    and l.linea = nullif((regexp_match(p_pick_desc,'(\d+(?:\.\d+)?)'))[1],'')::numeric)
  end;
$function$;

grant execute on function public.modelo_de_pick(text,text,text) to anon, authenticated, service_role;
grant execute on function public.mercado_apto_para_lock(text,text,text,text) to anon, authenticated, service_role;
grant execute on function public.estado_respaldo(text,text,text) to anon, authenticated, service_role;
grant execute on function public.linea_es_canonica(text,text,text) to anon, authenticated, service_role;

-- ===========================================================================
-- 5) LA CADENA LIMPIA. Se recrean las 4 vistas y se elimina la funcion laxa.
--    Orden obligatorio: primero las vistas que dependen de ella.
-- ===========================================================================
drop view if exists public.v_reto13m_mejores;
drop view if exists public.v_reto13m_analisis_experimental;
drop view if exists public.v_reto13m_lo_mejor;
drop view if exists public.v_mejor_pick_por_partido;
drop function if exists public.mercado_apto_para_lock(text, text);

create view public.v_mejor_pick_por_partido as
select espn_event_id, deporte, liga, home, away, arranca_en, etiqueta_cuando,
       mercado, pick_nombre, pick_desc, probabilidad_pct,
       muestra_calibracion, calibracion_confiable, fuente, razon, resumen,
       momio_mercado, casa, momio_capturado_at,
       model_version, apto_para_lock, rn as rank_en_partido
from (
  select p.espn_event_id, p.deporte, p.liga, p.home, p.away, p.arranca_en,
         p.etiqueta_cuando, p.mercado, p.pick_nombre, p.pick_desc,
         p.probabilidad_pct, p.muestra_calibracion, p.calibracion_confiable,
         p.fuente, p.razon, p.resumen,
         p.momio_mercado, p.casa, p.momio_capturado_at,
         public.modelo_de_pick(p.fuente, p.deporte, p.mercado) model_version,
         public.mercado_apto_para_lock(p.deporte, p.mercado,
           public.modelo_de_pick(p.fuente, p.deporte, p.mercado)) apto_para_lock,
         row_number() over (partition by p.espn_event_id
                            order by p.probabilidad_pct desc nulls last,
                                     p.mercado, p.pick_desc) rn
  from public.v_pick_canonico p
  where p.arranca_en > now() and p.probabilidad_pct is not null
    -- el universo se restringe ANTES del argmax: un Over 0.5 nunca compite
    and public.linea_es_canonica(p.deporte, p.mercado, p.pick_desc)
) x
where rn = 1;
comment on view public.v_mejor_pick_por_partido is
  'SUPERFICIE DE USUARIO. Por partido, el resultado con mayor P_RETO, dentro de un universo de lineas canonicas. Lleva model_version. apto_para_lock exige deporte+mercado+model_version y falla cerrado.';

create view public.v_reto13m_mejores as
select espn_event_id, deporte, liga, home, away, arranca_en, etiqueta_cuando,
       mercado, pick_nombre, pick_desc, probabilidad_pct as probabilidad_cruda_pct,
       model_version, momio_mercado, casa,
       true as es_lock, true as validado_fuera_de_muestra, rank_global
from (select m.*, row_number() over (order by m.probabilidad_pct desc nulls last,
                                              m.arranca_en, m.espn_event_id) rank_global
      from public.v_mejor_pick_por_partido m where m.apto_para_lock) r;
comment on view public.v_reto13m_mejores is
  'SUPERFICIE DE USUARIO. TOP_ONLY_GLOBAL: orden unicamente por P_RETO, SIN cuota por deporte. Solo entra lo autorizado por deporte+mercado+model_version.';

create view public.v_reto13m_lo_mejor as
select m.espn_event_id, m.deporte, m.liga, m.home, m.away, m.arranca_en,
       m.etiqueta_cuando, m.mercado, m.pick_nombre, m.pick_desc, m.probabilidad_pct,
       m.model_version,
       public.estado_respaldo(m.deporte, m.mercado, m.model_version) as respaldo,
       m.momio_mercado, m.casa,
       true as es_lock, true as validado_fuera_de_muestra,
       row_number() over (order by m.probabilidad_pct desc nulls last,
                                   m.arranca_en, m.espn_event_id) as rank_global
from public.v_mejor_pick_por_partido m where m.apto_para_lock;
comment on view public.v_reto13m_lo_mejor is
  'SUPERFICIE DE USUARIO. SOLO picks aprobados. Vacia = no hay ninguno aprobado; el material experimental vive en v_reto13m_analisis_experimental, no aqui. Sin UNION paralelo de NFL: todo entra por la cadena canonica.';

create view public.v_reto13m_analisis_experimental as
select m.espn_event_id, m.deporte, m.liga, m.home, m.away, m.arranca_en,
       m.etiqueta_cuando, m.mercado, m.pick_nombre, m.pick_desc, m.probabilidad_pct,
       m.model_version,
       public.estado_respaldo(m.deporte, m.mercado, m.model_version) as respaldo,
       m.fuente, m.momio_mercado, m.casa,
       false as es_lock, false as validado_fuera_de_muestra,
       case when m.model_version is null
            then 'Este porcentaje viene de un motor SIN REGISTRAR: no se puede rastrear al modelo exacto que lo produjo. No es una recomendacion.'
            else 'El calibrador de este modelo no ha pasado el holdout limpio. No es una recomendacion.' end as advertencia,
       row_number() over (order by m.probabilidad_pct desc nulls last,
                                   m.arranca_en, m.espn_event_id) as rank_global
from public.v_mejor_pick_por_partido m where not m.apto_para_lock;

-- ===========================================================================
-- 6) ASSERTIONS
-- ===========================================================================
do $$
declare v_n int;
begin
  -- 6a) la funcion laxa de 2 argumentos NO puede existir
  select count(*) into v_n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='mercado_apto_para_lock'
     and pg_get_function_identity_arguments(p.oid) = 'text, text';
  if v_n > 0 then raise exception 'LA LLAVE LAXA DE 2 ARGUMENTOS SIGUE VIVA'; end if;

  -- 6b) falla cerrado sin model_version
  if public.mercado_apto_para_lock('baseball','Over/Under', null) then
    raise exception 'NO FALLA CERRADO: autorizo sin model_version'; end if;

  -- 6c) no cruza modelos: el motor que sirve no hereda el aval del que se midio
  if public.mercado_apto_para_lock('baseball','Over/Under','motor_mlb_cuantitativo')
     <> public.mercado_apto_para_lock('baseball','Over/Under','mlb_totales_normal_v1')
     and public.mercado_apto_para_lock('baseball','Over/Under','motor_mlb_cuantitativo') then
    raise exception 'CRUCE DE MODELOS: se autorizo un motor distinto al medido'; end if;

  -- 6d) el universo de lineas hace su trabajo
  if public.linea_es_canonica('soccer','Over/Under','Under 3.5') then
    raise exception 'Under 3.5 de futbol NO debe ser canonica'; end if;
  if public.linea_es_canonica('soccer','Over/Under','Over 0.5') then
    raise exception 'Over 0.5 NO debe ser canonica'; end if;
  if not public.linea_es_canonica('soccer','Over/Under','Over 2.5') then
    raise exception 'Over 2.5 SI debe ser canonica'; end if;
  if not public.linea_es_canonica('soccer','Moneyline','Gana visitante') then
    raise exception 'Moneyline no lleva linea: debe pasar'; end if;

  -- 6e) ninguna linea no canonica en la superficie
  select count(*) into v_n from public.v_mejor_pick_por_partido
   where not public.linea_es_canonica(deporte, mercado, pick_desc);
  if v_n > 0 then raise exception 'LINEAS NO CANONICAS EN SUPERFICIE: %', v_n; end if;

  -- 6f) ningun pick aprobado sin model_version
  select count(*) into v_n from public.v_reto13m_mejores where model_version is null;
  if v_n > 0 then raise exception 'PICK APROBADO SIN MODEL_VERSION: %', v_n; end if;

  -- 6g) TOP_ONLY_GLOBAL: ninguna de las 4 vistas particiona por deporte
  select count(*) into v_n from pg_class c join pg_namespace n on n.oid=c.relnamespace
   where n.nspname='public' and c.relkind='v'
     and c.relname in ('v_mejor_pick_por_partido','v_reto13m_mejores',
                       'v_reto13m_lo_mejor','v_reto13m_analisis_experimental')
     and pg_get_viewdef(c.oid,true) ~* 'partition by[^(]*\mdeporte\M';
  if v_n > 0 then raise exception 'CUOTA POR DEPORTE EN LA CADENA LIMPIA: % vistas', v_n; end if;

  raise notice 'iss095 OK: llave exacta por model_version, falla cerrado, sin cuota, lineas canonicas';
end $$;

-- FIN iss095.
