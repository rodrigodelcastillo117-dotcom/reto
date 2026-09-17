-- ISS192 · El rival entra al modelo y a la tarjeta
--
-- CONTEXTO
-- La escalera preregistrada (ISS188) midio cuatro peldanos y se paro en L2.
-- L1 (TD sin suerte) +0.0325 y L2 (factor del rival) +0.0249 pasan con IC95
-- inferior positivo; L3 (cambio de equipo) da -0.0067 y ahi se para la escalera.
-- Lo medido se llama fantasy-b2-rival-2026.09.1 y ya esta autorizado en
-- v2.fantasy_model_config_v2 con toda la evidencia. Lo que faltaba era enchufarlo
-- a lo que la app sirve, y contarle al dueno POR QUE, no solo CUANTO.
--
-- QUE ROMPIA
-- 1. El reporte decia "B1" en siete lugares mientras corria B2. Texto que miente.
-- 2. La tarjeta daba un numero (10.88) sin una sola razon verificable: ni toques,
--    ni % de jugadas, ni dureza del rival, ni el aviso de cambio de equipo. Por eso
--    el dueno no pudo creerle la recomendacion sobre Montgomery, y tenia razon.
--
-- QUE HACE ESTE PARCHE
-- a) Sustituye todo texto "B1" por el model_version real que se esta sirviendo.
-- b) Cuelga public.fantasy_contexto_jugador de cada tarjeta (campo 'contexto') y
--    agrega a 'por_que' las lineas de uso, rival y cambio de equipo cuando existen.
-- c) No inventa nada: si no hay muestra, el campo viene nulo y no se escribe linea.
--
-- DISCIPLINA: cada ancla debe aparecer exactamente una vez o el parche truena.

do $do$
declare
  v_def text := pg_get_functiondef('v2.fantasy_start_sit_auto_v2(text,integer,integer,text,timestamp with time zone,text)'::regprocedure);
  v_pairs text[] := array[

    -- 1. engine: deja de anunciar b1
    $o$'ok',true,'engine','fantasy_b1_exact_optimizer_v1'$o$,
    $n$'ok',true,'engine','fantasy_exact_optimizer_v2'$n$,

    -- 2. reglas.brain decia B1 mientras corria B2. Ahora dice el que corre,
    --    y declara si el rival ya esta incorporado a la proyeccion.
    $o$'reglas',jsonb_build_object('brain','fantasy-b1-rq80-2026.09.1','optimizer','GLOBAL_EXACT_MEDIAN','market_used',false,'cold_start_authorized',false,'k_dst_modelled',false,'past_recomputed',false)$o$,
    $n$'reglas',jsonb_build_object('brain',p_model_version,'optimizer','GLOBAL_EXACT_MEDIAN','market_used',false,'cold_start_authorized',false,'k_dst_modelled',false,'past_recomputed',false,'rival_incorporado',(p_model_version='fantasy-b2-rival-2026.09.1'))$n$,

    -- 3..7. los textos que decian B1
    $o$'Identidad confirmada. K/DST todavía no están cubiertos por el modelo B1 validado; no se inventa una proyección.'$o$,
    $n$'Identidad confirmada. K/DST todavía no están cubiertos por el modelo publicado ('||p_model_version||'); no se inventa una proyección.'$n$,

    $o$'El modelo B1 validado no cubre esta posicion todavia. No se inventa una proyeccion.'$o$,
    $n$'El modelo publicado ('||p_model_version||') no cubre esta posicion todavia. No se inventa una proyeccion.'$n$,

    $o$'Identidad confirmada, pero B1 no tiene una proyección publicable para este jugador/semana (estado: '$o$,
    $n$'Identidad confirmada, pero el modelo publicado no tiene una proyección publicable para este jugador/semana (estado: '$n$,

    $o$'El optimizador global B1 lo incluye en la mejor alineación modelada de tu roster.'$o$,
    $n$'El optimizador global lo incluye en la mejor alineación modelada de tu roster.'$n$,

    $o$'El optimizador global B1 deja mejores opciones en los slots disponibles.'$o$,
    $n$'El optimizador global deja mejores opciones en los slots disponibles.'$n$,

    $o$jsonb_build_array('Proyección B1 no publicable para este jugador/semana')$o$,
    $n$jsonb_build_array('Proyección no publicable para este jugador/semana con el modelo '||p_model_version)$n$,

    -- 8. el contexto verificable entra a la tarjeta
    $o$'model_version',p_model_version,'por_que',jsonb_build_array(a.reason),$o$,
    $n$'model_version',p_model_version,
      'contexto', case when a.player_position in ('QB','RB','WR','TE') then cx.ctx end,
      'por_que', jsonb_build_array(a.reason)
        || case when a.player_position in ('QB','RB','WR','TE') and (cx.ctx->>'juegos_en_historial')::int > 0
             then jsonb_build_array(
                    'Uso medido: '||coalesce(cx.ctx->>'toques_por_juego','?')||' toques por juego y '
                    ||coalesce(cx.ctx->>'td_por_juego','?')||' TD por juego en '
                    ||(cx.ctx->>'juegos_en_historial')||' juegos'
                    ||case when (cx.ctx->>'pct_jugadas_temporada_actual') is not null
                        then '. Juega el '||(cx.ctx->>'pct_jugadas_temporada_actual')||'% de las jugadas de su ofensiva esta temporada'
                             ||case when (cx.ctx->>'pct_jugadas_temporada_anterior') is not null
                                 then ' (el año pasado '||(cx.ctx->>'pct_jugadas_temporada_anterior')||'%)' else '' end
                        else '' end||'.')
             else '[]'::jsonb end
        || case when (cx.ctx->>'aviso_cambio_equipo') is not null
             then jsonb_build_array(cx.ctx->>'aviso_cambio_equipo') else '[]'::jsonb end
        || case when (cx.ctx->>'rival_permisividad') is not null
             then jsonb_build_array(
                    'Rival '||coalesce(cx.ctx->>'rival','')||': permite '||(cx.ctx->>'rival_permite_ppr')
                    ||' PPR por juego a un '||a.player_position||', '||(cx.ctx->>'rival_permisividad')
                    ||' en permisividad. '||coalesce(cx.ctx->>'lectura_del_rival',''))
             else '[]'::jsonb end,$n$,

    -- 9. el lateral que calcula ese contexto una sola vez por jugador
    $o$) order by a.idx) j from advice a$o$,
    $n$) order by a.idx) j from advice a
      left join lateral (select public.fantasy_contexto_jugador(a.player_name,a.player_position,a.opp,p_season,p_week) as ctx) cx on true$n$
  ];
  v_o text; v_n text; c int;
begin
  for i in 1..(array_length(v_pairs,1)/2) loop
    v_o := v_pairs[2*i-1]; v_n := v_pairs[2*i];
    c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
    if c <> 1 then
      raise exception 'ISS192: el ancla % aparece % veces, no 1. No se toca la funcion.', i, c;
    end if;
    v_def := replace(v_def,v_o,v_n);
  end loop;
  execute v_def;
end $do$;

comment on function v2.fantasy_start_sit_auto_v2(text,integer,integer,text,timestamptz,text) is
'ISS192. Sirve el modelo autorizado (por defecto fantasy-b2-rival-2026.09.1, que gano la escalera preregistrada ISS188/ISS189) y cuelga de cada tarjeta el contexto verificable: toques por juego, TD por juego, % de jugadas de esta temporada contra la anterior, aviso de cambio de equipo y permisividad del rival contra esa posicion. Si no hay muestra, el campo viene nulo y no se escribe la linea: no se rellena para que se vea bonito.';

notify pgrst, 'reload schema';


-- ===========================================================================
-- ISS192-b · CORRECCION DE UN ERROR MIO, EN EL ACTO
--
-- La primera version de public.fantasy_contexto_jugador marcaba CAMBIO DE EQUIPO
-- a casi todo el roster, Mahomes incluido. El error: comparaba "juegos desde
-- agosto de 2026" (1 o 2) contra "juegos en todo el historial" (17), asi que la
-- desigualdad se cumplia siempre. Habria impreso una mentira verificable en la
-- tarjeta. Ademas, para un QB reportaba "toques" (4.6), que no significa nada en
-- un pasador porque la tabla de logs no tiene intentos de pase.
--
-- Correccion: el equipo actual sale del ultimo juego registrado, y se cuenta
-- cuantos juegos de su historial fueron con ESE equipo. Y el texto de uso se
-- arma por posicion: QB en yardas de pase y TD totales, RB en toques, WR/TE en
-- objetivos.
-- ===========================================================================

create or replace function public.fantasy_contexto_jugador(p_nombre text, p_pos text, p_rival text, p_season integer default 2026, p_week integer default 2)
returns jsonb
language sql stable security definer
set search_path to 'public','v2','pg_catalog'
as $function$
  with h as (
    select g.team equipo, g.game_date,
           coalesce(g.rush_attempts,0)+coalesce(g.targets,0) toques,
           coalesce(g.rush_attempts,0) acarreos,
           coalesce(g.targets,0) objetivos,
           coalesce(g.pass_yards,0) yds_pase,
           coalesce(g.pass_tds,0) tds_pase,
           coalesce(g.rush_tds,0)+coalesce(g.rec_tds,0) tds_campo
    from public.lab_ff_playerweek f
    join public.nfl_player_game_logs g on g.espn_player_id=f.espn_player_id and g.espn_event_id=f.espn_event_id
    where g.player_name = p_nombre and f.actual_points is not null
      and f.status in ('PLAYED','ACTIVE_ZERO_USAGE')
  ), eq_actual as (
    select team from public.nfl_player_game_logs
    where player_name = p_nombre order by game_date desc, id desc limit 1
  ), n_act as (
    select count(*) n from h where h.equipo = (select team from eq_actual)
  ), sn as (
    select avg(pct_ofensiva) filter (where temporada = p_season) act,
           avg(pct_ofensiva) filter (where temporada = p_season-1) prev,
           count(*) filter (where temporada = p_season) n_act
    from public.nfl_snaps where jugador = p_nombre
  ), fr as (
    select factor, rank_permisividad, ppr_permitido
    from v2.fantasy_factor_rival_v1
    where temporada=p_season and semana=p_week and equipo_defensa=p_rival and posicion=upper(p_pos)
  )
  select jsonb_build_object(
    'juegos_en_historial', count(*),
    'toques_por_juego',   case when count(*)>0 then round(avg(h.toques)::numeric,1) end,
    'objetivos_por_juego',case when count(*)>0 then round(avg(h.objetivos)::numeric,1) end,
    'acarreos_por_juego', case when count(*)>0 then round(avg(h.acarreos)::numeric,1) end,
    'yardas_pase_por_juego', case when count(*)>0 then round(avg(h.yds_pase)::numeric,0) end,
    'td_por_juego', case when count(*)>0 then round(avg(
        case when upper(p_pos)='QB' then h.tds_pase + h.tds_campo else h.tds_campo end)::numeric,2) end,
    'uso_texto', case when count(*)=0 then null
      when upper(p_pos)='QB' then
        round(avg(h.yds_pase)::numeric,0)||' yardas de pase, '||round(avg(h.tds_pase+h.tds_campo)::numeric,2)
        ||' TD totales y '||round(avg(h.acarreos)::numeric,1)||' acarreos por juego'
      when upper(p_pos)='RB' then
        round(avg(h.toques)::numeric,1)||' toques por juego (acarreos mas objetivos) y '
        ||round(avg(h.tds_campo)::numeric,2)||' TD por juego'
      else
        round(avg(h.objetivos)::numeric,1)||' objetivos por juego y '
        ||round(avg(h.tds_campo)::numeric,2)||' TD por juego' end,
    'equipo_actual', (select team from eq_actual),
    'juegos_con_equipo_actual', (select n from n_act),
    'cambio_de_equipo', count(*)>0 and (select n from n_act) < count(*),
    'aviso_cambio_equipo', case when count(*)>0 and (select n from n_act) < count(*)
      then 'CAMBIO DE EQUIPO: solo '||(select n from n_act)||' de sus '||count(*)
           ||' juegos son con '||coalesce((select team from eq_actual),'su equipo actual')
           ||'. El resto de su promedio viene de otra ofensiva y otro reparto, asi que el numero reacciona lento.' end,
    'pct_jugadas_temporada_actual', round((select act*100 from sn)::numeric,0),
    'pct_jugadas_temporada_anterior', round((select prev*100 from sn)::numeric,0),
    'rival', p_rival,
    'rival_permite_ppr', (select round(ppr_permitido,1) from fr),
    'rival_permisividad', (select rank_permisividad||' de 32' from fr),
    'rival_factor', (select factor from fr),
    'lectura_del_rival', case
      when (select rank_permisividad from fr) <= 8 then 'EMPAREJAMIENTO A FAVOR: de las defensas mas blandas de la liga contra su posicion.'
      when (select rank_permisividad from fr) >= 25 then 'EMPAREJAMIENTO EN CONTRA: de las defensas mas duras de la liga contra su posicion.'
      else 'Emparejamiento neutro.' end
  ) from h
$function$;

-- La linea de uso en la tarjeta pasa a usar uso_texto, que ya viene por posicion.
do $do$
declare
  v_def text := pg_get_functiondef('v2.fantasy_start_sit_auto_v2(text,integer,integer,text,timestamp with time zone,text)'::regprocedure);
  v_o text := $o$'Uso medido: '||coalesce(cx.ctx->>'toques_por_juego','?')||' toques por juego y '
                    ||coalesce(cx.ctx->>'td_por_juego','?')||' TD por juego en '
                    ||(cx.ctx->>'juegos_en_historial')||' juegos'$o$;
  v_n text := $n$'Uso medido: '||(cx.ctx->>'uso_texto')||', en '
                    ||(cx.ctx->>'juegos_en_historial')||' juegos'$n$;
  c int;
begin
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  if c <> 1 then raise exception 'ISS192b: el ancla aparece % veces, no 1.', c; end if;
  execute replace(v_def,v_o,v_n);
end $do$;


-- ===========================================================================
-- ISS192-c · QUE LA TARJETA NO SE LEA COMO SI SE CONTRADIJERA
--
-- Montgomery sale SIT con un emparejamiento a favor (3 de 32) y Dowdle entra
-- START con uno en contra (27 de 32). No es una contradiccion: bajo B2 el factor
-- del rival YA esta multiplicado dentro de la proyeccion, y aun asi el uso base
-- de Dowdle (16.8 toques) manda sobre el de Montgomery (11.0). Pero si la tarjeta
-- no lo dice, parece un error. Lo dice.
-- ===========================================================================

do $do$
declare
  v_def text := pg_get_functiondef('v2.fantasy_start_sit_auto_v2(text,integer,integer,text,timestamp with time zone,text)'::regprocedure);
  v_o text := $o$                    ||' en permisividad. '||coalesce(cx.ctx->>'lectura_del_rival',''))
             else '[]'::jsonb end,$o$;
  v_n text := $n$                    ||' en permisividad. '||coalesce(cx.ctx->>'lectura_del_rival',''))
             else '[]'::jsonb end
        || case when p_model_version='fantasy-b2-rival-2026.09.1' and a.model_status='READY'
                     and (cx.ctx->>'rival_permisividad') is not null
             then case
               when split_part(cx.ctx->>'rival_permisividad',' ',1)::int <= 8 and a.action in ('SIT','BANCA')
                 then jsonb_build_array('Ese emparejamiento a favor YA esta multiplicado dentro de la proyeccion. Aun asi queda abajo: su uso base es menor que el de quien ocupa el lugar.')
               when split_part(cx.ctx->>'rival_permisividad',' ',1)::int >= 25 and a.action in ('START','MANTENER')
                 then jsonb_build_array('Ese emparejamiento en contra YA esta descontado dentro de la proyeccion. Aun asi manda: su uso base es mayor que el de las alternativas.')
               else '[]'::jsonb end
             else '[]'::jsonb end,$n$;
  c int;
begin
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  if c <> 1 then raise exception 'ISS192c: el ancla aparece % veces, no 1.', c; end if;
  execute replace(v_def,v_o,v_n);
end $do$;


-- ===========================================================================
-- G43 · LA CLASE DE ERROR QUE COSTO UNA RECOMENDACION FALSA
--
-- Con B1 y B2 escritos en la misma tabla, v2.fn_fantasy_optimal_lineup_v2 leia el
-- snapshot sin filtrar por model_version y SUMABA los dos modelos: devolvia
-- 221.87 cuando la verdad era 110.77. El filtro ya se arreglo; este gate impide
-- que vuelva a pasar, y lo vigila por dos caminos independientes.
-- ===========================================================================

create or replace function public.gate_fantasy_un_solo_modelo()
returns table(gate text, estado text, detalle text)
language plpgsql security definer set search_path to 'public','v2','pg_catalog'
as $function$
declare
  v_rep jsonb; v_actual numeric; v_suma numeric; v_max_card numeric; v_max_snap numeric;
  v_mv text; v_def text; v_n_tabla int; v_n_filtro int; v_apodo text;
begin
  select c.model_version into v_mv from v2.fantasy_model_config_v2 c
   where c.publish_authorized order by c.model_version desc limit 1;

  v_def := pg_get_functiondef('v2.fn_fantasy_optimal_lineup_v2(text,integer,integer,timestamptz)'::regprocedure);
  v_n_tabla  := (length(v_def)-length(replace(v_def,'fantasy_projection_snapshot_v2','')))/length('fantasy_projection_snapshot_v2');
  v_n_filtro := (length(v_def)-length(replace(v_def,'model_version','')))/length('model_version');
  gate := 'G43.1 optimizador filtra por model_version';
  if v_n_filtro >= v_n_tabla and v_n_tabla > 0 then
    estado := 'PASS'; detalle := v_n_tabla||' lecturas del snapshot, '||v_n_filtro||' menciones de model_version';
  else
    estado := 'FAIL'; detalle := 'el optimizador lee el snapshot '||v_n_tabla||' veces y solo menciona model_version '||v_n_filtro||' veces: puede estar sumando dos modelos';
  end if;
  return next;

  select r.apodo into v_apodo from public.fantasy_roster_semanal r order by r.guardado_at desc limit 1;
  gate := 'G43.2 el resumen es la suma de las tarjetas';
  if v_apodo is null then
    estado := 'UNAVAILABLE'; detalle := 'no hay ningun roster guardado que probar'; return next; return;
  end if;
  select r.temporada, r.semana into strict v_n_tabla, v_n_filtro
    from public.fantasy_roster_semanal r where r.apodo=v_apodo order by r.guardado_at desc limit 1;
  v_rep := public.fantasy_reporte_semana(v_apodo, v_n_tabla, v_n_filtro, 'BALANCEADO');
  if coalesce((v_rep->>'ok')::boolean,false) is not true then
    estado := 'FAIL'; detalle := 'el reporte no responde ok: '||coalesce(v_rep->>'reason','sin razon'); return next; return;
  end if;
  v_actual := (v_rep->'resumen'->>'proyeccion_actual')::numeric;
  select sum((p->>'proyeccion')::numeric), max((p->>'proyeccion')::numeric)
    into v_suma, v_max_card
    from jsonb_array_elements(v_rep->'jugadores') p
   where p->>'slot' <> 'BANCA' and p->>'proyeccion' is not null;
  if v_actual is null or v_suma is null then
    estado := 'UNAVAILABLE'; detalle := 'no hay titulares con proyeccion publicable';
  elsif abs(v_actual - v_suma) <= 0.05 then
    estado := 'PASS'; detalle := 'resumen '||v_actual||' = suma de titulares '||v_suma;
  else
    estado := 'FAIL'; detalle := 'resumen '||v_actual||' contra suma de titulares '||v_suma||': el resumen no sale de las tarjetas';
  end if;
  return next;

  select max(s.projected_mean) into v_max_snap from v2.fantasy_projection_snapshot_v2 s
   where s.season=(v_rep->>'season')::int and s.week=(v_rep->>'week')::int and s.model_version=v_mv;
  gate := 'G43.3 ninguna tarjeta excede el snapshot del modelo autorizado';
  if v_max_card is null or v_max_snap is null then
    estado := 'UNAVAILABLE'; detalle := 'sin snapshot o sin tarjetas con proyeccion para '||coalesce(v_mv,'(ningun modelo autorizado)');
  elsif v_max_card <= v_max_snap + 0.01 then
    estado := 'PASS'; detalle := 'maximo en tarjeta '||v_max_card||' <= maximo en snapshot '||v_max_snap||' ('||v_mv||')';
  else
    estado := 'FAIL'; detalle := 'maximo en tarjeta '||v_max_card||' supera el maximo del snapshot '||v_max_snap||': hay mas de un modelo sumado';
  end if;
  return next;
end $function$;

comment on function public.gate_fantasy_un_solo_modelo() is
'ISS192. Cierra la clase de error que costo una recomendacion falsa: con B1 y B2 escritos en la misma tabla, el optimizador leia el snapshot sin filtrar por model_version y sumaba los dos, devolviendo 221.87 donde la verdad era 110.77. Vigila lo estructural (el filtro existe) y lo funcional (el resumen es la suma de las tarjetas y nada excede el snapshot).';

notify pgrst, 'reload schema';


-- ===========================================================================
-- VERIFICACION EJECUTADA (2026-09-17)
--
-- select * from public.gate_fantasy_un_solo_modelo();
--   G43.1 PASS  4 lecturas del snapshot, 5 menciones de model_version
--   G43.2 PASS  resumen 110.77 = suma de titulares 110.77
--   G43.3 PASS  maximo en tarjeta 21.19 <= maximo en snapshot 21.19
--
-- Tarjeta de David Montgomery (SIT), tal como la sirve el backend:
--   1. El optimizador global deja mejores opciones en los slots disponibles.
--   2. Uso medido: 11.0 toques por juego (acarreos mas objetivos) y 0.47 TD por
--      juego, en 17 juegos. Juega el 49% de las jugadas de su ofensiva esta
--      temporada (el ano pasado 37%).
--   3. CAMBIO DE EQUIPO: solo 0 de sus 17 juegos son con HOU. El resto de su
--      promedio viene de otra ofensiva y otro reparto, asi que el numero
--      reacciona lento.
--   4. Rival CIN: permite 10.5 PPR por juego a un RB, 3 de 32 en permisividad.
--      EMPAREJAMIENTO A FAVOR.
--   5. Ese emparejamiento a favor YA esta multiplicado dentro de la proyeccion.
--      Aun asi queda abajo: su uso base es menor que el de quien ocupa el lugar.
--
-- Patrick Mahomes: cambio_de_equipo = false, equipo_actual = KC. Correcto.
--
-- CORRECCION A ESTA MISMA NOTA (ver ISS193):
-- La nota original que quedo aqui decia que lab_ff_playerweek era "la unica
-- fuente de historial del modelo" y que por eso todo el sistema contradecia la
-- regla del dueno. ESO ERA FALSO y lo escribi yo sin verificarlo.
-- B1 (v2.fn_fantasy_project_b1_rq80_v2) SI incorpora la temporada en curso
-- desde siempre, via public.v_lab_ff_official_snapshot con guarda
-- graded_at <= momento de decision. El que no la veia era B2, o sea la funcion
-- que yo escribi en este mismo parche. El error era mio y solo mio, no del
-- sistema. Se repara en ISS193.
-- ===========================================================================
