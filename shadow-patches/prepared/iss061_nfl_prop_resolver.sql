-- iss061 — El parlay no se autocalificaba porque el calificador NO PUEDE calificar props.
--
-- SÍNTOMA: "no autocalifica el parlay".
--
-- LO QUE NO ERA: el cron sí corre. `autocalificar-parlays` (job 120) se ejecuta cada 2 minutos
-- y lleva 180 corridas exitosas en 6 horas. No está apagado ni fallando.
--
-- CAUSA RAÍZ: el parlay del owner tiene 4 patas y TRES son props de jugador —
--   "Christian McCaffrey (SF) 1+ Touchdowns de jugador totales"
--   "Davante Adams (LAR) 1+ Touchdowns de jugador totales"
--   "Matthew Stafford (LAR) 1+ Pases de Touchdown por jugador"
-- y la firma del evaluador es:
--   evaluar_leg_parlay_v1(p_pick_desc, p_partido, p_home_team, p_away_team,
--                         p_home_score, p_away_score, p_home_sets, p_away_sets, ...)
-- NO tiene un solo parámetro de estadística de jugador. No es que falle: no puede decidir una
-- prop ni en teoría. Esas patas iban a quedarse pendientes para siempre.
--
-- Esto también explica las patas huérfanas de parlays viejos ya cerrados: 1, 4, 1, 1, 1 y 9
-- patas atoradas en seis parlays distintos.
--
-- LO QUE SÍ TENEMOS: `nfl_player_game_logs` guarda pass_tds, rush_tds, rec_tds, yardas y
-- recepciones por jugador y por partido. Con eso una prop se liquida sin ambigüedad.

create or replace function public.nfl_prop_resolver(p_espn_event_id text, p_pick_desc text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare
  v_txt text := lower(unaccent(coalesce(p_pick_desc,''))); v_nombre text; v_umbral numeric;
  v_metrica text; v_valor numeric; v_n int; v_final boolean;
begin
  v_nombre := (regexp_match(p_pick_desc, '^\s*(.+?)\s*\([A-Za-z]{2,4}\)'))[1];
  v_umbral := nullif((regexp_match(v_txt, '(\d+(?:\.\d+)?)\s*\+'))[1], '')::numeric;
  if v_nombre is null or v_umbral is null then
    return jsonb_build_object('estado','SIN_MAPEO','motivo','La descripcion no tiene forma de prop de jugador');
  end if;

  -- El ORDEN importa: "pases de touchdown" tiene que ganarle a "touchdown" a secas. Si se
  -- evalúa al revés, un QB que lanzó un TD pero no anotó ninguno sale GANADA cuando es PERDIDA.
  v_metrica := case
    when v_txt like '%pases de touchdown%' or v_txt like '%pase de touchdown%' then 'pass_tds'
    when v_txt like '%yardas de pase%' then 'pass_yards'
    when v_txt like '%yardas recibidas%' or v_txt like '%yardas por aire%' then 'rec_yards'
    when v_txt like '%yardas terrestres%' or v_txt like '%yardas por tierra%' or v_txt like '%yardas corriendo%' then 'rush_yards'
    when v_txt like '%recepcion%' then 'receptions'
    when v_txt like '%intercepcion%' then 'interceptions'
    when v_txt like '%touchdown%' then 'tds_totales'
  end;
  if v_metrica is null then
    return jsonb_build_object('estado','SIN_MAPEO','motivo','Mercado de prop no reconocido','jugador',v_nombre);
  end if;

  select (ls.status = 'final') into v_final from public.live_scores ls where ls.espn_event_id = p_espn_event_id;

  select count(*), max(case v_metrica
      when 'pass_tds' then l.pass_tds when 'pass_yards' then l.pass_yards
      when 'rec_yards' then l.rec_yards when 'rush_yards' then l.rush_yards
      when 'receptions' then l.receptions when 'interceptions' then l.interceptions
      when 'tds_totales' then coalesce(l.rush_tds,0) + coalesce(l.rec_tds,0) end)
    into v_n, v_valor
    from public.nfl_player_game_logs l
   where l.espn_event_id = p_espn_event_id
     and lower(unaccent(l.player_name)) = lower(unaccent(v_nombre));

  -- Sin fila del jugador NO se puede afirmar "no anotó": puede ser que la fuente aún no publique.
  if v_n = 0 then
    return jsonb_build_object('estado', case when coalesce(v_final,false) then 'SIN_DATO_JUGADOR' else 'PENDIENTE' end,
                              'jugador', v_nombre, 'metrica', v_metrica, 'umbral', v_umbral);
  end if;
  -- Dos jugadores con el mismo nombre en un partido: se reporta, NO se adivina.
  if v_n > 1 then
    return jsonb_build_object('estado','AMBIGUO','jugador',v_nombre,'coincidencias',v_n);
  end if;
  -- Sólo se liquida con el partido FINAL.
  if not coalesce(v_final,false) then
    return jsonb_build_object('estado','PENDIENTE','jugador',v_nombre,'metrica',v_metrica,
                              'umbral',v_umbral,'valor_parcial',v_valor,'motivo','El partido no ha terminado');
  end if;

  return jsonb_build_object('estado', case when v_valor >= v_umbral then 'GANADA' else 'PERDIDA' end,
    'jugador', v_nombre, 'metrica', v_metrica, 'umbral', v_umbral, 'valor', v_valor);
end;
$$;

grant execute on function public.nfl_prop_resolver(text,text) to anon, authenticated, service_role;

-- GATE EJECUTADO contra el partido NE @ SEA, que ya terminó y tiene logs reales (8/8 correctos):
--   Smith-Njigba 1+ TD            -> GANADA  (anotó 1 recepción de TD)
--   Drake Maye 1+ Pases de TD     -> GANADA  (lanzó 1)
--   Drake Maye 2+ Pases de TD     -> PERDIDA (sólo 1)
--   Drake Maye 1+ Touchdowns      -> PERDIDA (no anotó; este es el caso que discrimina el orden)
--   Smith-Njigba 100+ Yds recib.  -> GANADA  (122)
--   Smith-Njigba 9+ Recepciones   -> PERDIDA (8)
--   Jugador inexistente           -> SIN_DATO_JUGADOR, NO "perdida"
--   "Menos de 50.5 puntos"        -> SIN_MAPEO (no es prop, la califica el evaluador de siempre)
--
-- LO QUE FALTA Y NO DEPENDE DE ESTA FUNCIÓN: `nfl_player_game_logs` todavía no tiene NINGUNA
-- fila del partido SF @ LAR (terminó 27-7). Hasta que la ingesta de estadísticas de jugador
-- corra para ese evento, las tres patas devuelven SIN_DATO_JUGADOR. La función está lista y
-- probada; el dato no ha llegado.
--
-- NO SE CABLEÓ SOLA al autocalificador a propósito: escribir en `parlays.picks_data` cambia el
-- registro de dinero del owner. Eso se enciende con su visto bueno explícito, no de oficio.
