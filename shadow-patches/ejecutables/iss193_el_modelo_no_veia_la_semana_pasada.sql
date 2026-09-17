-- ISS193 · El modelo no veia la semana pasada
--
-- EL CASO QUE LO DESTAPO
-- El dueno pregunto, literal: "por que me dice que siente a David Montgomery si
-- es el titular de Houston. revisa cuantos puntos dio la semana pasada, y cuanto
-- le dieron de uso". Revisado, en la base:
--   semana 1 de 2026, David Montgomery con HOU: 23 toques, 3 TD, 28.9 puntos PPR.
-- El modelo B2 que yo construi en ISS192 NO veia ese juego. Su unica fuente de
-- historial era public.lab_ff_playerweek, que cubre solo la temporada 2025
-- (2025-09-05 a 2026-01-05). Proyectaba a Montgomery con su reparto de Detroit.
--
-- DE QUIEN FUE EL ERROR
-- Mio. No es un hueco heredado del sistema: B1
-- (v2.fn_fantasy_project_b1_rq80_v2) incorpora la temporada en curso DESDE
-- SIEMPRE, con la union a public.v_lab_ff_official_snapshot y la guarda
-- graded_at <= momento de decision. Al escribir B2 corte esa fuente sin darme
-- cuenta. En el commit de ISS192 llegue a escribir que el sistema entero
-- contradecia la regla del dueno; eso era falso y queda corregido en aquel
-- archivo.
--
-- POR QUE ESTO NO LLEVA PREREGISTRO
-- No se elige entre variantes ni se prueba una hipotesis nueva. Se repara la
-- cobertura de datos de un estimador ya validado, usando exactamente la misma
-- regla temporal que B1 ya aplicaba. La formula no se toca: siguen siendo L1
-- (oportunidad sin suerte de TD) y L2 (factor del rival), promedio sin ponderar.
-- No se reponderaron los juegos recientes, porque esa hipotesis SI se preregistro
-- y FALLO: ISS182/ISS183, H=4 cruza el cero e H=2 es conclusivamente peor.
--
-- LA CONFIGURACION DE PUNTOS, VERIFICADA CONTRA 5280 JUEGOS REALES
--   0.04 por yarda de pase · 4 por TD de pase · -1 por intercepcion (NO -2)
--   0.1 por yarda terrestre o de recepcion · 6 por TD · 1 por recepcion
-- Reproduce el puntaje guardado al decimal en 5260 de 5280 juegos. QB y WR: 100%
-- exacto. Los 20 que fallan son dos jugadores, Hunter Luepke y Connor Heyward,
-- cuyo actual_points esta guardado en 0 en TODOS sus juegos pese a tener
-- produccion real: es un bug de datos de la tabla de laboratorio, no de la
-- formula, y queda anotado aparte.
--
-- LO QUE ESTO NO ARREGLA, DICHO CLARO
-- Con promedio sin ponderar, un juego entre 18 mueve la proyeccion ~4%.
-- Montgomery sube de 10.02 a 10.44 y sigue por debajo de Dowdle (12.56). Si la
-- intuicion del dueno es correcta y Montgomery ya es otro jugador en Houston,
-- el modelo TODAVIA no lo puede expresar, porque las dos vias que lo expresarian
-- estan medidas y bloqueadas: L3 cambio de equipo fallo por falta de muestra
-- (80 casos de 3269) y la ponderacion por recencia fallo su preregistro. La via
-- que queda viva es la participacion (snaps), y esa esta bloqueada hasta tener
-- al menos 4 semanas de 2026. No se fuerza ninguna.

-- ---------------------------------------------------------------------------
-- 1. El constructor de B2 pasa a ver la temporada en curso, con la misma regla
--    temporal de B1: solo semanas anteriores y solo filas ya calificadas antes
--    del momento de decision. Version nueva: fantasy-b2-rival-2026.09.2
-- ---------------------------------------------------------------------------

create or replace function v2.build_fantasy_projection_snapshot_b2(p_apodo text, p_season integer, p_week integer, p_decision timestamp with time zone)
returns integer language plpgsql as $function$
declare n int;
begin
  perform v2.build_fantasy_projection_snapshot_v2(p_apodo, p_season, p_week, p_decision);
  perform v2.refrescar_factor_rival_v1(p_season, p_week);

  with hist as (
    select f.espn_player_id pid, upper(f.position) pos, f.actual_points::numeric pts,
           coalesce(g.rush_tds,0)+coalesce(g.rec_tds,0) tds,
           coalesce(g.rush_attempts,0)+coalesce(g.targets,0) opp
    from public.lab_ff_playerweek f
    join public.nfl_player_game_logs g on g.espn_player_id=f.espn_player_id and g.espn_event_id=f.espn_event_id
    where f.status in ('PLAYED','ACTIVE_ZERO_USAGE') and f.actual_points is not null
    union all
    select s.espn_player_id, upper(s.position), s.actual_points::numeric,
           coalesce(g.rush_tds,0)+coalesce(g.rec_tds,0),
           coalesce(g.rush_attempts,0)+coalesce(g.targets,0)
    from public.v_lab_ff_official_snapshot s
    join public.nfl_player_game_logs g on g.espn_player_id=s.espn_player_id
    join public.nfl_partidos pa on pa.espn_event_id=g.espn_event_id
         and pa.temporada=s.temporada and pa.semana=s.semana and pa.tipo_temporada=2
    where s.temporada=p_season and s.semana<p_week and s.actual_points is not null
      and s.graded_at is not null and s.graded_at<=p_decision
  ), agg as (
    select pid, avg(pts - 6*tds) prod, avg(opp) opp, count(*) n from hist group by 1
  ), tasa as (
    select pos, sum(tds)::numeric / nullif(sum(opp),0) r from hist group by 1
  ), b1 as (
    select distinct on (s.espn_player_id) s.*
    from v2.fantasy_projection_snapshot_v2 s
    where s.season=p_season and s.week=p_week and s.decision_time=p_decision
      and s.model_version='fantasy-b1-rq80-2026.09.1'
    order by s.espn_player_id, s.built_at desc
  ), nuevo as (
    select b1.*,
      case when b1.projected_mean is null or h.prod is null then b1.projected_mean
           else round(((h.prod + h.opp*coalesce(t.r,0)*6) * coalesce(fr.factor,1))::numeric, 2)
      end nueva_media,
      coalesce(fr.factor,1) factor, h.n n_hist_b2
    from b1
    left join agg h on h.pid = b1.espn_player_id
    left join tasa t on t.pos = upper(b1.position)
    left join v2.fantasy_factor_rival_v1 fr
      on fr.temporada=p_season and fr.semana=p_week
     and fr.equipo_defensa=b1.opponent and fr.posicion=upper(b1.position)
  )
  insert into v2.fantasy_projection_snapshot_v2
    (espn_player_id, player_name, position, team, opponent, espn_event_id, season, week,
     roster_slot, decision_time, kickoff, model_version, scoring_config_version,
     projected_mean, floor_points, ceiling_points, uncertainty, n_history, cold_start,
     feature_data_asof, availability_status, model_status, quality_flag, identity_status,
     provenance, built_at)
  select espn_player_id, player_name, position, team, opponent, espn_event_id, season, week,
    roster_slot, decision_time, kickoff, 'fantasy-b2-rival-2026.09.2', scoring_config_version,
    nueva_media,
    case when projected_mean > 0 then round((floor_points   * nueva_media/projected_mean)::numeric,2) else floor_points end,
    case when projected_mean > 0 then round((ceiling_points * nueva_media/projected_mean)::numeric,2) else ceiling_points end,
    uncertainty, coalesce(n_hist_b2, n_history), cold_start, feature_data_asof, availability_status,
    model_status, quality_flag, identity_status,
    coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
      'brain','B2_OPORTUNIDAD_Y_RIVAL',
      'base_b1', projected_mean,
      'factor_rival', factor,
      'n_juegos_historial', n_hist_b2,
      'historial','2025 completa mas las semanas ya calificadas de la temporada en curso (misma regla as-of que B1)',
      'ajustes', jsonb_build_array(
        'L1 oportunidad: se le quita la suerte de touchdown y se repone con la tasa de la posicion',
        'L2 rival: se multiplica por que tan blanda es esa defensa contra esa posicion'),
      'no_aplicado','L3 cambio de equipo: fallo la prueba por falta de muestra (80 casos de 3269)',
      'market_used', false),
    now()
  from nuevo
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $function$;

-- ---------------------------------------------------------------------------
-- 2. La version nueva queda registrada con toda la evidencia y la confesion
-- ---------------------------------------------------------------------------
-- (ejecutado: insert en v2.fantasy_model_config_v2 de fantasy-b2-rival-2026.09.2
--  copiando la fila .1 y agregando la clave iss193_correccion_de_cobertura con
--  que estaba mal, de quien fue el error, el caso que lo destapo, que se cambio,
--  que NO se cambio, por que no lleva preregistro, la verificacion de puntaje y
--  lo que sigue sin medirse.)

-- ---------------------------------------------------------------------------
-- 3. El reporte sirve .2 por defecto y acepta cualquier B2 autorizada
-- ---------------------------------------------------------------------------
do $do$
declare
  v_def text := pg_get_functiondef('v2.fantasy_start_sit_auto_v2(text,integer,integer,text,timestamp with time zone,text)'::regprocedure);
  v_pairs text[] := array[
    $o$p_model_version text DEFAULT 'fantasy-b2-rival-2026.09.1'::text$o$,
    $n$p_model_version text DEFAULT 'fantasy-b2-rival-2026.09.2'::text$n$,
    $o$if p_model_version not in ('fantasy-b1-rq80-2026.09.1','fantasy-b2-rival-2026.09.1')$o$,
    $n$if p_model_version not in ('fantasy-b1-rq80-2026.09.1','fantasy-b2-rival-2026.09.1','fantasy-b2-rival-2026.09.2')$n$,
    $o$if p_model_version='fantasy-b2-rival-2026.09.1'
  then perform v2.build_fantasy_projection_snapshot_b2$o$,
    $n$if p_model_version like 'fantasy-b2-rival-%'
  then perform v2.build_fantasy_projection_snapshot_b2$n$,
    $o$case when p_model_version='fantasy-b2-rival-2026.09.1' and a.model_status='READY'$o$,
    $n$case when p_model_version like 'fantasy-b2-rival-%' and a.model_status='READY'$n$,
    $o$'rival_incorporado',(p_model_version='fantasy-b2-rival-2026.09.1')$o$,
    $n$'rival_incorporado',(p_model_version like 'fantasy-b2-rival-%')$n$
  ];
  v_o text; v_n text; c int;
begin
  for i in 1..(array_length(v_pairs,1)/2) loop
    v_o := v_pairs[2*i-1]; v_n := v_pairs[2*i];
    c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
    if c <> 1 then raise exception 'ISS193: el ancla % aparece % veces, no 1.', i, c; end if;
    v_def := replace(v_def,v_o,v_n);
  end loop;
  execute v_def;
end $do$;

-- La linea de uso declara cuantos de esos juegos son de esta temporada.
do $do$
declare
  v_def text := pg_get_functiondef('v2.fantasy_start_sit_auto_v2(text,integer,integer,text,timestamp with time zone,text)'::regprocedure);
  v_o text := $o$'Uso medido: '||(cx.ctx->>'uso_texto')||', en '
                    ||(cx.ctx->>'juegos_en_historial')||' juegos'$o$;
  v_n text := $n$'Uso medido: '||(cx.ctx->>'uso_texto')||', en '
                    ||(cx.ctx->>'juegos_en_historial')||' juegos'
                    ||case when coalesce((cx.ctx->>'juegos_de_esta_temporada')::int,0) > 0
                        then ' ('||(cx.ctx->>'juegos_de_esta_temporada')||' de esta temporada, ya calificados)'
                        else ' (ninguno de esta temporada todavia)' end$n$;
  c int;
begin
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  if c <> 1 then raise exception 'ISS193b: el ancla aparece % veces, no 1.', c; end if;
  execute replace(v_def,v_o,v_n);
end $do$;

-- ---------------------------------------------------------------------------
-- 4. El contexto de la tarjeta tambien cuenta la temporada en curso
--    (definicion completa aplicada en public.fantasy_contexto_jugador: se agrega
--     la rama union a v_lab_ff_official_snapshot y los campos
--     juegos_de_esta_temporada y toques_esta_temporada)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 5. G44 · que nadie vuelva a cortarle la temporada en curso al modelo
-- ---------------------------------------------------------------------------

create or replace function public.gate_fantasy_ve_la_temporada_en_curso()
returns table(gate text, estado text, detalle text)
language plpgsql security definer set search_path to 'public','v2','pg_catalog'
as $function$
declare
  v_apodo text; v_season int; v_week int; v_rep jsonb; v_mv text;
  v_disp int; v_mal int; v_total int; v_ejemplo text;
begin
  select r.apodo, r.temporada, r.semana into v_apodo, v_season, v_week
    from public.fantasy_roster_semanal r order by r.guardado_at desc limit 1;
  gate := 'G44.1 hay temporada en curso calificada que el modelo pueda ver';
  if v_apodo is null then
    estado := 'UNAVAILABLE'; detalle := 'no hay roster guardado'; return next; return;
  end if;
  select count(*) into v_disp from public.v_lab_ff_official_snapshot s
   where s.temporada=v_season and s.semana < v_week and s.actual_points is not null and s.graded_at is not null;
  if v_disp = 0 then
    estado := 'UNAVAILABLE';
    detalle := 'la temporada '||v_season||' no tiene ninguna semana calificada antes de la '||v_week||': no hay nada que el modelo pudiera estar ignorando';
    return next; return;
  end if;
  estado := 'PASS'; detalle := v_disp||' juegos calificados de la temporada '||v_season||' disponibles antes de la semana '||v_week;
  return next;

  v_rep := public.fantasy_reporte_semana(v_apodo, v_season, v_week, 'BALANCEADO');
  v_mv := v_rep->>'model_version';

  with jug as (
    select distinct s.espn_player_id pid, s.player_name, s.n_history
    from v2.fantasy_projection_snapshot_v2 s
    where s.season=v_season and s.week=v_week and s.model_version=v_mv
      and s.model_status='READY' and s.espn_player_id is not null
  ), esperado as (
    select j.pid, j.player_name, j.n_history,
      (select count(*) from public.lab_ff_playerweek f
        where f.espn_player_id=j.pid and f.actual_points is not null
          and f.status in ('PLAYED','ACTIVE_ZERO_USAGE'))
      + (select count(*) from public.v_lab_ff_official_snapshot s2
          join public.nfl_player_game_logs g on g.espn_player_id=s2.espn_player_id
          join public.nfl_partidos pa on pa.espn_event_id=g.espn_event_id
               and pa.temporada=s2.temporada and pa.semana=s2.semana and pa.tipo_temporada=2
         where s2.espn_player_id=j.pid and s2.temporada=v_season and s2.semana < v_week
           and s2.actual_points is not null and s2.graded_at is not null) n_esperado
    from jug j
  )
  select count(*), count(*) filter (where n_history <> n_esperado),
         max(case when n_history <> n_esperado then player_name||': declara '||n_history||' juegos y deberia declarar '||n_esperado end)
    into v_total, v_mal, v_ejemplo from esperado;

  gate := 'G44.2 el historial servido incluye la temporada en curso';
  if v_total = 0 then
    estado := 'UNAVAILABLE'; detalle := 'ningun jugador con proyeccion publicable en '||coalesce(v_mv,'(sin version)');
  elsif v_mal = 0 then
    estado := 'PASS'; detalle := v_total||' jugadores, todos con historial = 2025 mas las semanas calificadas de '||v_season||' ('||v_mv||')';
  else
    estado := 'FAIL'; detalle := v_mal||' de '||v_total||' jugadores con historial incompleto. Ejemplo: '||coalesce(v_ejemplo,'(sin detalle)');
  end if;
  return next;
end $function$;

comment on function public.gate_fantasy_ve_la_temporada_en_curso() is
'ISS193. B2 se construyo leyendo solo lab_ff_playerweek, que cubre unicamente 2025, y por eso no veia los juegos ya jugados de la temporada en curso: en concreto, los 23 toques, 3 TD y 28.9 puntos de David Montgomery con Houston en la semana 1. Este gate exige que el historial declarado por el snapshot sea exactamente 2025 mas las semanas ya calificadas de la temporada en curso, jugador por jugador.';

notify pgrst, 'reload schema';


-- ===========================================================================
-- VERIFICACION EJECUTADA (2026-09-17)
--
-- select * from public.gate_fantasy_ve_la_temporada_en_curso();
--   G44.1 PASS  257 juegos calificados de 2026 disponibles antes de la semana 2
--   G44.2 PASS  12 jugadores, todos con historial = 2025 mas las semanas
--               calificadas de 2026 (fantasy-b2-rival-2026.09.2)
-- select * from public.gate_fantasy_un_solo_modelo();
--   G43.1 / G43.2 / G43.3 PASS
--
-- Antes y despues, con el mismo roster (semana 2 de 2026):
--   historial por jugador      17 juegos  ->  18 juegos
--   David Montgomery           10.02      ->  10.44   (toques 11.0 -> 11.7)
--   Rico Dowdle                12.89      ->  12.56   (toques 16.8 -> 16.6)
--   MarShawn Lloyd              3.70      ->   7.25   (de 0 juegos a 1: 14 toques)
--   proyeccion_actual         110.77      -> 110.79
--
-- La recomendacion NO se voltea: sigue START Dowdle, SIT Montgomery. Un juego
-- entre 18 en un promedio sin ponderar mueve ~4%. Eso es la aritmetica, no una
-- opinion, y la tarjeta ahora lo dice con todos sus numeros a la vista.
-- ===========================================================================
