-- ISS100 — issue #4, comentario 5645732488.
-- Contexto factual (ultimos partidos / tendencias con numeradores / H2H) + cuarentena
-- de Under 3.5 en el origen.
--
-- HALLAZGO P0 QUE NO ESTABA EN LA AUDITORIA — LEER ESTO PRIMERO
-- ============================================================
-- v_analisis_v2 keyea TODO el analisis por equipo (forma, tendencias, xG, H2H) con
-- `escudos_partido.home_id/away_id`. Esa tabla usa ids de API-FOOTBALL.
-- Pero v_equipo_partido_espn_xg e historico_partidos_espn usan ids de ESPN.
-- Son dos espacios de enteros pequenos que COLISIONAN, asi que el join no falla:
-- devuelve el historial de otro equipo en silencio.
--
-- Medido en produccion el 2026-09-12:
--   186 de 186 eventos de futbol tienen escudos_partido desalineado vs agenda_espn
--   37 de esos ids existen en el espacio ESPN y pertenecen a OTRO equipo
--
-- Caso del propio dossier que auditaste, evento 401884799:
--   agenda_espn:      home 124 = Borussia Dortmund, away 3307 = SC Paderborn 07
--   escudos_partido:  home 165,                     away 185
--   en espacio ESPN:  165 = NANTES,                 185 = FC DALLAS
--   -> el bloque "tendencias.home" del dossier de Dortmund son los ultimos 8 de NANTES
--   -> el bloque "tendencias.away" son los ultimos 8 de FC DALLAS
--
-- Eso explica la discrepancia que encontre al reproducir: el dossier reportaba
-- home gana_pct = 25 cuando Dortmund gano 5 de sus ultimos 8 (63%) y 6 de 8 en el
-- otro origen (75%). No era un contrato incompleto de tendencias: eran los numeros
-- de otro equipo.
--
-- El H2H "sin enfrentamientos directos" tambien se calculo sobre Nantes vs FC Dallas.
-- Da 0, y el H2H real de Dortmund vs Paderborn tambien da 0, asi que la conclusion
-- era correcta POR CASUALIDAD, no por metodo.
--
-- v_fuerza_equipo SI usa ids de API-Football, asi que home_forma/away_forma estaban
-- bien. Por eso el defecto es invisible: la mitad del dossier es correcta.
--
-- NO reescribo v_analisis_v2 en este parche: el dueno acoto este bloque a
-- "stage in Git, do not cut over". Dejo el gate que lo prueba y la vista correcta
-- para que el frontend pueda cambiar de fuente. Mientras no cambie, 37 dossieres
-- siguen mostrando tendencias de otro equipo.

begin;

-- =====================================================================
-- 1) ULTIMOS PARTIDOS REALES POR EQUIPO  (requisito 1)
-- =====================================================================
-- Identidad por espn_team_id. Corte temporal duro fecha < p_hasta.
-- Si solo hay 2, devuelve 2. Nunca rellena a 5.
create or replace function public.partidos_recientes_equipo(
  p_team_espn_id text, p_hasta timestamptz, p_n integer default 5)
returns jsonb language sql stable set search_path to 'public' as $function$
with base as (
  select h.espn_event_id, h.fecha, h.liga_id, h.espn_endpoint, h.cargado_at,
         (h.home_espn_id = p_team_espn_id)                      as es_local,
         case when h.home_espn_id = p_team_espn_id then h.away_espn_id else h.home_espn_id end as rival_espn_id,
         case when h.home_espn_id = p_team_espn_id then h.away_nombre  else h.home_nombre  end as rival,
         case when h.home_espn_id = p_team_espn_id then h.home_score   else h.away_score   end as gf,
         case when h.home_espn_id = p_team_espn_id then h.away_score   else h.home_score   end as gc
  from historico_partidos_espn h
  where (h.home_espn_id = p_team_espn_id or h.away_espn_id = p_team_espn_id)
    and h.fecha < p_hasta                 -- corte temporal duro
    and h.home_score is not null and h.away_score is not null
  order by h.fecha desc
  limit greatest(coalesce(p_n,5), 1)
)
select jsonb_build_object(
  'solicitados', greatest(coalesce(p_n,5),1),
  -- muestra es lo que EXISTE DE VERDAD. Si hay 2, son 2. Nunca se rellena a 5.
  'muestra', (select count(*) from base),
  'disponible', (select count(*) from base) > 0,
  'source', 'historico_partidos_espn (identidad exacta por espn_team_id)',
  'identidad', 'espn_team_id',
  'corte_temporal', p_hasta,
  'temporal_safe', (select coalesce(bool_and(b.fecha < p_hasta), true) from base b),
  'data_asof', (select max(b.fecha) from base b),
  'capturado_max', (select max(b.cargado_at) from base b),
  'competencias', coalesce((select jsonb_agg(distinct b.espn_endpoint) from base b), '[]'),
  'missing_reason', case when (select count(*) from base) = 0
                         then 'Sin partidos con marcador anteriores al corte temporal para este espn_team_id'
                         when (select count(*) from base) < greatest(coalesce(p_n,5),1)
                         then 'Solo existen '||(select count(*) from base)||' partidos reales antes del corte'
                         else null end,
  'partidos', coalesce((select jsonb_agg(jsonb_build_object(
      'espn_event_id', b.espn_event_id, 'fecha', b.fecha,
      'competencia', b.espn_endpoint, 'liga_id', b.liga_id,
      'rival', b.rival, 'rival_espn_id', b.rival_espn_id,
      'es_local', b.es_local, 'gf', b.gf, 'gc', b.gc,
      'marcador', b.gf||'-'||b.gc,
      'resultado', case when b.gf > b.gc then 'W' when b.gf = b.gc then 'E' else 'L' end)
      order by b.fecha desc) from base b), '[]'));
$function$;

-- =====================================================================
-- 2) TENDENCIAS CON NUMERADORES EXACTOS  (requisito 2)
-- =====================================================================
-- El contrato viejo solo daba pct redondeado, asi que el frontend no podia escribir
-- "5/8" sin inventarlo. Aqui cada metrica lleva aciertos Y muestra, y el pct se
-- deriva de esos dos numeros. La ventana pedida y la obtenida se reportan por
-- separado: "ultimos 8" con muestra 3 es una afirmacion distinta a "ultimos 8" con 8.
create or replace function public.tendencias_equipo_exactas(
  p_team_espn_id text, p_hasta timestamptz, p_n integer default 8)
returns jsonb language sql stable set search_path to 'public' as $function$
with base as (
  select h.espn_event_id, h.fecha, h.cargado_at,
         case when h.home_espn_id = p_team_espn_id then h.home_score else h.away_score end as gf,
         case when h.home_espn_id = p_team_espn_id then h.away_score else h.home_score end as gc
  from historico_partidos_espn h
  where (h.home_espn_id = p_team_espn_id or h.away_espn_id = p_team_espn_id)
    and h.fecha < p_hasta
    and h.home_score is not null and h.away_score is not null
  order by h.fecha desc
  limit greatest(coalesce(p_n,8), 1)
),
m as (
  select count(*)::int n,
         count(*) filter (where gf > gc)::int            gana,
         count(*) filter (where gf = gc)::int            empata,
         count(*) filter (where gf < gc)::int            pierde,
         count(*) filter (where gf+gc >= 3)::int         over25,
         count(*) filter (where gf+gc <= 3)::int         under35,
         count(*) filter (where gf > 0 and gc > 0)::int  btts,
         count(*) filter (where gc = 0)::int             porteria_cero,
         sum(gf)::int gf_total, sum(gc)::int gc_total
  from base
)
select case when (select n from m) = 0 then
  jsonb_build_object('disponible', false, 'muestra', 0,
    'ventana_solicitada', greatest(coalesce(p_n,8),1),
    'source','historico_partidos_espn (identidad exacta por espn_team_id)',
    'identidad','espn_team_id','corte_temporal',p_hasta,'temporal_safe',true,
    'missing_reason','Sin partidos con marcador anteriores al corte temporal',
    'metricas','{}'::jsonb)
else
  jsonb_build_object(
    'disponible', true,
    'muestra', (select n from m),
    'ventana_solicitada', greatest(coalesce(p_n,8),1),
    'ventana_completa', (select n from m) >= greatest(coalesce(p_n,8),1),
    'source','historico_partidos_espn (identidad exacta por espn_team_id)',
    'identidad','espn_team_id',
    'corte_temporal', p_hasta,
    'temporal_safe', (select coalesce(bool_and(b.fecha < p_hasta), true) from base b),
    'data_asof', (select max(b.fecha) from base b),
    'capturado_max', (select max(b.cargado_at) from base b),
    'missing_reason', case when (select n from m) < greatest(coalesce(p_n,8),1)
                           then 'Ventana incompleta: solo '||(select n from m)||' partidos reales'
                           else null end,
    'eventos_usados', (select jsonb_agg(b.espn_event_id order by b.fecha desc) from base b),
    'goles_favor_total', (select gf_total from m),
    'goles_contra_total', (select gc_total from m),
    'metricas', (select jsonb_build_object(
       'gana',          jsonb_build_object('aciertos',gana,         'muestra',n,'pct',round(100.0*gana/n)),
       'empata',        jsonb_build_object('aciertos',empata,       'muestra',n,'pct',round(100.0*empata/n)),
       'pierde',        jsonb_build_object('aciertos',pierde,       'muestra',n,'pct',round(100.0*pierde/n)),
       'over25',        jsonb_build_object('aciertos',over25,       'muestra',n,'pct',round(100.0*over25/n)),
       'under35',       jsonb_build_object('aciertos',under35,      'muestra',n,'pct',round(100.0*under35/n)),
       'btts',          jsonb_build_object('aciertos',btts,         'muestra',n,'pct',round(100.0*btts/n)),
       'porteria_cero', jsonb_build_object('aciertos',porteria_cero,'muestra',n,'pct',round(100.0*porteria_cero/n)))
     from m))
end;
$function$;

-- =====================================================================
-- 3) H2H FACTUAL  (requisito 3)
-- =====================================================================
-- Identidad exacta por espn_team_id en AMBOS sentidos del enfrentamiento.
-- Nada de nombres, nada de substring. Falla cerrado: si no hay enfrentamientos
-- reales con marcador antes del corte, devuelve disponible=false con motivo.
create or replace function public.h2h_factual(
  p_home_espn_id text, p_away_espn_id text, p_hasta timestamptz, p_n integer default 10)
returns jsonb language sql stable set search_path to 'public' as $function$
with base as (
  select h.espn_event_id, h.fecha, h.espn_endpoint, h.cargado_at,
         (h.home_espn_id = p_home_espn_id) as jugo_en_casa_el_local_de_hoy,
         h.home_nombre, h.away_nombre,
         case when h.home_espn_id = p_home_espn_id then h.home_score else h.away_score end as gf_local_de_hoy,
         case when h.home_espn_id = p_home_espn_id then h.away_score else h.home_score end as gf_visita_de_hoy
  from historico_partidos_espn h
  where ((h.home_espn_id = p_home_espn_id and h.away_espn_id = p_away_espn_id)
      or (h.home_espn_id = p_away_espn_id and h.away_espn_id = p_home_espn_id))
    and h.fecha < p_hasta
    and h.home_score is not null and h.away_score is not null
  order by h.fecha desc
  limit greatest(coalesce(p_n,10),1)
),
m as (
  select count(*)::int n,
         count(*) filter (where gf_local_de_hoy > gf_visita_de_hoy)::int gana_local_de_hoy,
         count(*) filter (where gf_local_de_hoy = gf_visita_de_hoy)::int empates,
         count(*) filter (where gf_local_de_hoy < gf_visita_de_hoy)::int gana_visita_de_hoy,
         count(*) filter (where gf_local_de_hoy + gf_visita_de_hoy >= 3)::int over25,
         count(*) filter (where gf_local_de_hoy > 0 and gf_visita_de_hoy > 0)::int btts,
         sum(gf_local_de_hoy + gf_visita_de_hoy)::int goles_total
  from base
)
select case when (select n from m) = 0 then
  jsonb_build_object(
    'disponible', false, 'muestra', 0,
    'source','historico_partidos_espn (identidad exacta por espn_team_id, ambos sentidos)',
    'identidad','espn_team_id',
    'home_espn_id', p_home_espn_id, 'away_espn_id', p_away_espn_id,
    'corte_temporal', p_hasta, 'temporal_safe', true,
    -- FALLA CERRADO. No se inventa H2H ni se rellena desde nombres parecidos.
    'missing_reason','Sin enfrentamientos directos con marcador entre estos dos espn_team_id antes del corte temporal',
    'metricas','{}'::jsonb, 'partidos','[]'::jsonb)
else
  jsonb_build_object(
    'disponible', true,
    'muestra', (select n from m),
    'ventana_solicitada', greatest(coalesce(p_n,10),1),
    'source','historico_partidos_espn (identidad exacta por espn_team_id, ambos sentidos)',
    'identidad','espn_team_id',
    'home_espn_id', p_home_espn_id, 'away_espn_id', p_away_espn_id,
    'corte_temporal', p_hasta,
    'temporal_safe', (select coalesce(bool_and(b.fecha < p_hasta), true) from base b),
    'data_asof', (select max(b.fecha) from base b),
    'capturado_max', (select max(b.cargado_at) from base b),
    'missing_reason', null,
    'goles_total', (select goles_total from m),
    'metricas', (select jsonb_build_object(
       'gana_local_de_hoy',  jsonb_build_object('aciertos',gana_local_de_hoy, 'muestra',n,'pct',round(100.0*gana_local_de_hoy/n)),
       'empate',             jsonb_build_object('aciertos',empates,          'muestra',n,'pct',round(100.0*empates/n)),
       'gana_visita_de_hoy', jsonb_build_object('aciertos',gana_visita_de_hoy,'muestra',n,'pct',round(100.0*gana_visita_de_hoy/n)),
       'over25',             jsonb_build_object('aciertos',over25,           'muestra',n,'pct',round(100.0*over25/n)),
       'btts',               jsonb_build_object('aciertos',btts,             'muestra',n,'pct',round(100.0*btts/n))) from m),
    'partidos', (select jsonb_agg(jsonb_build_object(
       'espn_event_id', b.espn_event_id, 'fecha', b.fecha, 'competencia', b.espn_endpoint,
       'home', b.home_nombre, 'away', b.away_nombre,
       'marcador', b.gf_local_de_hoy||'-'||b.gf_visita_de_hoy,
       'local_de_hoy_jugo_en_casa', b.jugo_en_casa_el_local_de_hoy)
       order by b.fecha desc) from base b))
end;
$function$;

-- =====================================================================
-- 4) CONTEXT_ONLY  (requisito 4)
-- =====================================================================
-- Identidad ESPN tomada de agenda_espn, NO de escudos_partido. Ninguna superficie
-- predictiva la consume y no entra a P_RETO; el gate de ISS100 lo comprueba.
create or replace view public.v_contexto_factual_v1 as
select a.espn_event_id,
       a.deporte, a.liga_nombre, a.home_nombre, a.away_nombre,
       a.home_espn_id, a.away_espn_id, a.fecha as kickoff,
       'CONTEXT_ONLY'::text as uso,
       'agenda_espn.home_espn_id/away_espn_id (espacio ESPN)'::text as identidad_fuente,
       partidos_recientes_equipo(a.home_espn_id, a.fecha, 5) as home_ultimos_partidos,
       partidos_recientes_equipo(a.away_espn_id, a.fecha, 5) as away_ultimos_partidos,
       tendencias_equipo_exactas(a.home_espn_id, a.fecha, 8) as home_tendencias,
       tendencias_equipo_exactas(a.away_espn_id, a.fecha, 8) as away_tendencias,
       h2h_factual(a.home_espn_id, a.away_espn_id, a.fecha, 10) as h2h
from agenda_espn a
where a.deporte = 'soccer'
  and a.home_espn_id is not null and a.away_espn_id is not null and a.fecha is not null;

insert into public.superficie_usuario(vista, proposito, declarada_at, clase)
values ('v_contexto_factual_v1',
        'Contexto factual del partido: ultimos partidos, tendencias con aciertos/muestra y H2H. CONTEXT_ONLY, no mueve P_RETO.',
        now(), 'USUARIO')
on conflict (vista) do nothing;

-- =====================================================================
-- 5) CUARENTENA DE UNDER 3.5 EN EL ORIGEN  (requisito 5)
-- =====================================================================
create table if not exists public.mercado_cuarentena (
  deporte     text not null,
  mercado     text not null,
  patron_pick text not null,
  motivo      text not null,
  registrado_at timestamptz not null default now(),
  primary key (deporte, mercado, patron_pick)
);

insert into public.mercado_cuarentena (deporte, mercado, patron_pick, motivo) values
 ('soccer','Over/Under','(under|menos de) *3\.5',
  $m$CUARENTENA. Under 3.5 en futbol es un mercado degenerado: acierta ~80% por construccion, asi que infla la tasa de acierto sin aportar informacion, igual que Over 0.5. Ademas 3.5 NO es linea canonica de futbol (lineas_canonicas solo tiene 2.5), asi que estas filas ya fallaban identidad con LINEA_NO_CANONICA pero seguian siendo VISIBLES. El dueno las vio en produccion diciendo "Reto predice Menos de 3.5 goles".$m$)
on conflict do nothing;

create or replace function public.pick_en_cuarentena(p_deporte text, p_mercado text, p_pick_desc text)
returns boolean language sql stable set search_path to 'public' as $function$
  select exists (
    select 1 from mercado_cuarentena q
    where q.deporte = deporte_canonico(p_deporte)
      and q.mercado = p_mercado
      and sin_acentos(lower(coalesce(p_pick_desc,''))) ~* q.patron_pick);
$function$;

commit;

-- El filtro se aplica como envoltura EXTERNA sobre la definicion vigente, a proposito:
-- rank_en_partido se calcula DENTRO, asi que las filas en cuarentena desaparecen SIN
-- renumerar. Ningun pick asciende a rank 1 como efecto secundario, que es lo que el
-- dueno prohibio explicitamente. Medido: 18 filas Under 3.5 en v_pick_canonico, 11 de
-- ellas eran rank 1; tras el filtro la huella md5 de las 284 filas restantes
-- (evento|mercado|pick|probabilidad|rank) es IDENTICA a la de antes: ac7e12585a1ae9c8f7d1d6ebe8f2e287
--
-- NOTA DE REPRODUCIBILIDAD: esta envoltura LEE la definicion vigente de produccion,
-- igual que iss099. Eso es exactamente la deuda que el dueno marco como bloqueante
-- para el clean bootstrap. No queda cerrada aqui; se cierra con el volcado de la capa
-- origen transitiva, que es el siguiente bloque.
do $$
declare v record; v_def text; v_col text;
begin
  for v in select unnest(array[
      'v_pick_canonico','v_picks_con_valor','v_picks_futbol_calc','v_picks_futbol_calibrado',
      'picks_premium','v_picks_futbol_limpio','picks_recomendados_hoy','v_analisis_fut_completo']) vista
  loop
    v_def := pg_get_viewdef(('public.'||v.vista)::regclass);
    if v_def ~ 'pick_en_cuarentena' then continue; end if;
    select a.attname into v_col from pg_attribute a
     where a.attrelid=('public.'||v.vista)::regclass and a.attnum>0 and not a.attisdropped
       and a.attname in ('pick_desc','pick')
     order by case a.attname when 'pick_desc' then 1 else 2 end limit 1;
    if v_col is null then raise exception 'ABORTADO: % no tiene columna pick/pick_desc', v.vista; end if;
    execute format('create or replace view public.%I as select * from (%s) _pool where not public.pick_en_cuarentena(%L,%L,_pool.%I)',
                   v.vista, rtrim(rtrim(v_def),';'), 'soccer','Over/Under', v_col);
  end loop;
end $$;

-- =====================================================================
-- 6) GATES
-- =====================================================================
begin;

-- Gate de cuarentena con TRES estados, no dos. "Sin columna de fecha" NO prueba que
-- una vista sea historica, asi que no se le concede el beneficio de la duda: cuenta
-- aparte y falla cerrado. Borrar Under 3.5 del track record historico falsificaria
-- el registro, asi que eso no se toca; pero tampoco se declara historico lo que no
-- se puede probar que lo sea.
create or replace function public.gate_mercado_en_cuarentena()
returns jsonb language plpgsql stable set search_path to 'public' as $function$
declare r record; v_col text; v_ts text; n_fut bigint; n_pas bigint;
        tot_fut bigint := 0; tot_pas bigint := 0; tot_sf bigint := 0;
        det_fut jsonb := '[]'::jsonb; det_pas jsonb := '[]'::jsonb;
        det_sf jsonb := '[]'::jsonb; det_err jsonb := '[]'::jsonb;
begin
  for r in
    select s.vista from superficie_usuario s
    join pg_class c on c.relname = s.vista and c.relnamespace='public'::regnamespace
    where s.clase='USUARIO' and c.relkind in ('v','m') order by s.vista
  loop
    select a.attname into v_col from pg_attribute a
     where a.attrelid=('public.'||r.vista)::regclass and a.attnum>0 and not a.attisdropped
       and a.attname in ('pick_desc','pick')
     order by case a.attname when 'pick_desc' then 1 else 2 end limit 1;
    if v_col is null then continue; end if;
    select a.attname into v_ts from pg_attribute a
     where a.attrelid=('public.'||r.vista)::regclass and a.attnum>0 and not a.attisdropped
       and a.attname in ('arranca_en','kickoff','fecha_evento','comienza_en','fecha_partido','fecha')
       and format_type(a.atttypid,null) ~ 'timestamp'
     order by array_position(array['arranca_en','kickoff','fecha_evento','comienza_en','fecha_partido','fecha'], a.attname)
     limit 1;
    begin
      if v_ts is null then
        execute format('select 0::bigint, count(*) from public.%I x where exists (select 1 from mercado_cuarentena q where sin_acentos(lower(coalesce(x.%I,''''))) ~* q.patron_pick)', r.vista, v_col) into n_fut, n_pas;
        if coalesce(n_pas,0) > 0 then
          -- SIN COLUMNA DE FECHA NO PRUEBA QUE SEA HISTORICO. Falla cerrado.
          tot_sf := tot_sf + n_pas;
          det_sf := det_sf || jsonb_build_object('vista', r.vista, 'filas', n_pas);
        end if;
      else
        execute format('select count(*) filter (where x.%I > now()), count(*) filter (where x.%I <= now()) from public.%I x where exists (select 1 from mercado_cuarentena q where sin_acentos(lower(coalesce(x.%I,''''))) ~* q.patron_pick)',
                       v_ts, v_ts, r.vista, v_col) into n_fut, n_pas;
        if coalesce(n_fut,0) > 0 then
          tot_fut := tot_fut + n_fut;
          det_fut := det_fut || jsonb_build_object('vista', r.vista, 'filas', n_fut, 'fecha', v_ts);
        end if;
        if coalesce(n_pas,0) > 0 then
          tot_pas := tot_pas + n_pas;
          det_pas := det_pas || jsonb_build_object('vista', r.vista, 'filas', n_pas, 'fecha', v_ts);
        end if;
      end if;
    exception when others then
      det_err := det_err || jsonb_build_object('vista', r.vista, 'error', left(sqlerrm,60));
    end;
  end loop;
  return jsonb_build_object(
    'MERCADO_EN_CUARENTENA_CANDIDATO', tot_fut,
    'MERCADO_EN_CUARENTENA_TEMPORALIDAD_NO_PROBADA', tot_sf,
    'en_cuarentena_historico_probado', tot_pas,
    'reglas_registradas', (select count(*) from mercado_cuarentena),
    'detalle_candidatos', det_fut,
    'detalle_temporalidad_no_probada', det_sf,
    'detalle_historico_probado', det_pas,
    'no_evaluables', det_err);
end $function$;

-- Gate de COLISION DE ESPACIOS DE ID entre proveedores. Esto es lo que hace que el
-- dossier de Dortmund muestre las tendencias de Nantes.
create or replace function public.gate_identidad_cruzada_proveedores()
returns jsonb language sql stable set search_path to 'public' as $function$
with cmp as (
  select a.espn_event_id, a.home_espn_id, a.away_espn_id,
         e.home_id::text eh, e.away_id::text ea,
         (a.home_espn_id <> e.home_id::text or a.away_espn_id <> e.away_id::text) as desalineado
  from agenda_espn a join escudos_partido e using (espn_event_id)
  where a.deporte='soccer'
),
-- el caso peligroso: el id del otro proveedor EXISTE en el espacio ESPN y pertenece
-- a otro equipo, asi que el join no falla, devuelve historia ajena en silencio
colision as (
  select c.*, (select count(*) from v_equipo_partido_espn_xg x where x.equipo = c.eh) filas_ajenas
  from cmp c where c.desalineado
)
select jsonb_build_object(
  'IDENTIDAD_CRUZADA_PROVEEDORES', (select count(*) from cmp where desalineado),
  'COLISION_SILENCIOSA', (select count(*) from colision where filas_ajenas > 0),
  'eventos_comparados', (select count(*) from cmp),
  'nota','escudos_partido usa ids de API-Football; v_equipo_partido_espn_xg e historico_partidos_espn usan ids de ESPN. Keyear uno con el otro devuelve el historial de otro equipo sin error.',
  'ejemplo', coalesce((select jsonb_build_object(
      'evento', espn_event_id, 'agenda_home_espn_id', home_espn_id,
      'escudos_home_id', eh, 'filas_de_historia_ajena', filas_ajenas)
      from colision order by filas_ajenas desc limit 1), '{}'));
$function$;

commit;

-- =====================================================================
-- 7) ASSERTIONS + REGRESION DEL FIXTURE 401884799  (requisito 6)
-- =====================================================================
do $$
declare c record; g jsonb;
begin
  select * into c from v_contexto_factual_v1 where espn_event_id = '401884799';
  if not found then raise exception 'ASSERT 1 FALLO: el fixture 401884799 no esta en el contexto'; end if;

  -- ultimos partidos REALES: 5 de cada lado, no los 2 de v_fuerza_equipo
  if (c.home_ultimos_partidos->>'muestra')::int <> 5
     or (c.away_ultimos_partidos->>'muestra')::int <> 5 then
    raise exception 'ASSERT 2 FALLO: ultimos partidos home=% away=%',
      c.home_ultimos_partidos->>'muestra', c.away_ultimos_partidos->>'muestra';
  end if;

  -- ventana de tendencias 8 y con numeradores exactos
  if (c.home_tendencias->>'muestra')::int <> 8 then
    raise exception 'ASSERT 3 FALLO: ventana de tendencias home = %', c.home_tendencias->>'muestra';
  end if;
  if (c.home_tendencias->'metricas'->'gana'->>'aciertos') is null
     or (c.home_tendencias->'metricas'->'gana'->>'muestra') is null then
    raise exception 'ASSERT 4 FALLO: tendencias sin aciertos/muestra exactos';
  end if;

  -- H2H no disponible, con motivo, y SIN inventarlo
  if (c.h2h->>'disponible')::boolean then
    raise exception 'ASSERT 5 FALLO: H2H se declara disponible para un par sin enfrentamientos reales';
  end if;
  if (c.h2h->>'missing_reason') is null then
    raise exception 'ASSERT 6 FALLO: H2H no disponible sin missing_reason';
  end if;

  -- corte temporal estricto en los tres bloques
  if not ((c.home_ultimos_partidos->>'temporal_safe')::boolean
      and (c.home_tendencias->>'temporal_safe')::boolean
      and (c.h2h->>'temporal_safe')::boolean) then
    raise exception 'ASSERT 7 FALLO: algun bloque no es temporal_safe';
  end if;

  -- CONTEXT_ONLY: ninguna vista predictiva consume el contexto
  if exists (select 1 from pg_class k join pg_namespace n on n.oid=k.relnamespace
              where n.nspname='public' and k.relkind in ('v','m')
                and k.relname <> 'v_contexto_factual_v1'
                and pg_get_viewdef(k.oid) ~ 'v_contexto_factual_v1|partidos_recientes_equipo|tendencias_equipo_exactas|h2h_factual') then
    raise exception 'ASSERT 8 FALLO: una vista consume el contexto factual; deja de ser CONTEXT_ONLY';
  end if;

  -- cuarentena: cero candidatos Under 3.5 en superficies prospectivas probadas
  g := gate_mercado_en_cuarentena();
  if (g->>'MERCADO_EN_CUARENTENA_CANDIDATO')::int <> 0 then
    raise exception 'ASSERT 9 FALLO: % filas Under 3.5 candidatas', g->>'MERCADO_EN_CUARENTENA_CANDIDATO';
  end if;

  raise notice 'ISS100 OK: 9 assertions pasadas';
end $$;

-- ESTADO CONOCIDO Y ABIERTO AL CERRAR ISS100 (2026-09-12):
--   MERCADO_EN_CUARENTENA_CANDIDATO               = 0
--   MERCADO_EN_CUARENTENA_TEMPORALIDAD_NO_PROBADA = 328 en 10 vistas sin columna de
--       fecha (ai_picks_historial 116, v_picks_medibles 116, v_oraculo_picks_activos 26,
--       track_record_detalle 24, v_picks_para_parlay 19, v_motor_valor_proximos 8,
--       v_apuestas_equipo 7, picks_reales 4, track_record_historial 4, v_tr_base 4).
--       NO las filtro: unas son registro historico y borrarlas falsificaria el track
--       record, otras suenan prospectivas. Distinguirlas por el NOMBRE seria
--       exactamente el atajo que este proyecto ya rechazo. Necesitan una declaracion
--       explicita de temporalidad.
--   IDENTIDAD_CRUZADA_PROVEEDORES = 186 de 186 · COLISION_SILENCIOSA = 37
--       v_analisis_v2 sigue sirviendo tendencias/xG/H2H de otro equipo en esos 37.
--       La vista correcta (v_contexto_factual_v1) ya existe; falta que el frontend
--       cambie de fuente o que se reescriba v_analisis_v2.
