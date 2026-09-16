-- =====================================================================
-- ISS131 -- NFL NO MOSTRABA NADA: NI PICK, NI PUNTOS, NI FPI
--
-- El dueno pidio: "TOCHDOWNS METIDOS, RECIBIDOS, YARDAS TOTALES,
-- ESPN POWER INDEX". Medido antes de tocar nada:
--
--   nfl_terminal_v2 en los 8 proximos partidos:
--     status = NO_OFFICIAL_PICK, official_prediction = UNAVAILABLE
--     razon: "NFL form ML requires >=4 current-season regular games per
--             team; early season"
--   Eso es CORRECTO: es semana 2, cada equipo lleva 1 juego. Falla cerrado.
--   Pero deja la seccion de NFL completamente vacia.
--
--   En un evento sin snapshot canonico devolvia SEIS llaves y nada mas:
--     ok, status, contract_version, event, official_prediction, principles
--
--   El contrato SI traia factores utiles (lesiones reales 10 vs 5, H2H con
--   marcadores, mercado, ventaja de local) pero CERO puntos anotados,
--   CERO puntos recibidos y CERO FPI.
--
-- LO QUE VERIFIQUE ANTES DE ASUMIR:
--   pg_stat_user_tables decia que public.nfl_fpi tenia 0 filas.
--   ERA UNA ESTIMACION STALE. El conteo real: 32 filas (los 32 equipos),
--   actualizadas 2026-09-15, con fpi, fpi_rank, epa_ofensiva, epa_defensiva,
--   proyeccion de victorias y probabilidad de playoffs. Mas 160 filas de
--   nfl_fpi_historico. El dato estaba ahi; nadie lo publicaba.
--
-- MATERIA PRIMA REAL (public.nfl_partidos, 572 filas):
--   2026 regular: 272 programados, 16 con marcador (semana 1)
--   2025 regular: 272 completos
--   2026 pretemporada: 28 con marcador  <- SE EXCLUYE, no es representativa
--
-- POR QUE VENTANA MOVIL DE 17 Y NO "TEMPORADA ACTUAL":
--   En semana 2 cada equipo tiene 1 juego. Un promedio de 1 partido es
--   ruido, y el ruido es lo que produce picks que no hacen sentido.
--   La ventana de los ultimos 17 juegos de TEMPORADA REGULAR cruza el
--   corte de temporada, siempre tiene muestra, y pesa lo reciente por
--   construccion. Se declara en 'ventana' y en 'temporadas' que juegos
--   entraron, para que nadie tenga que adivinar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Forma de un equipo: puntos a favor y en contra, con corte temporal.
-- ---------------------------------------------------------------------
create or replace function public.nfl_forma_equipo(p_team text, p_corte timestamptz, p_n int default 17)
returns jsonb language sql stable as $fn$
  with g as (
    select p.fecha, p.temporada,
           case when p.home_id::text = p_team then p.pts_home else p.pts_away end as pf,
           case when p.home_id::text = p_team then p.pts_away else p.pts_home end as pa
    from public.nfl_partidos p
    where (p.home_id::text = p_team or p.away_id::text = p_team)
      and p.tipo_temporada = 2            -- solo temporada regular
      and p.pts_home is not null and p.pts_away is not null
      and p.fecha < p_corte               -- sin lookahead
    order by p.fecha desc
    limit p_n
  )
  select case when count(*) >= 3 then jsonb_build_object(
    'n', count(*),
    'puntos_a_favor_pj', round(avg(pf)::numeric, 1),
    'puntos_en_contra_pj', round(avg(pa)::numeric, 1),
    'diferencial_pj', round((avg(pf)-avg(pa))::numeric, 1),
    'ventana', 'ULTIMOS_' || count(*) || '_DE_TEMPORADA_REGULAR',
    'desde', min(fecha)::date, 'hasta', max(fecha)::date,
    'temporadas', (select jsonb_agg(distinct temporada order by temporada desc) from g)
  ) end
  from g;
$fn$;

-- ---------------------------------------------------------------------
-- 2) Puntos esperados + ESPN FPI. Tres estados honestos, ninguno inventa.
-- ---------------------------------------------------------------------
create or replace function public.puntos_esperados_contexto(p_espn_event_id text)
returns jsonb language plpgsql stable as $fn$
declare
  e record; h jsonb; a jsonb; fh record; fa record;
  ph numeric; pa numeric; faltan text[] := '{}';
begin
  select distinct on (x.espn_event_id)
         x.espn_event_id, x.fecha, x.home_espn_id, x.away_espn_id, x.home_nombre, x.away_nombre
    into e
  from public.agenda_espn x
  where x.espn_event_id = p_espn_event_id and x.deporte = 'football'
    and x.home_espn_id is not null and x.away_espn_id is not null
  order by x.espn_event_id, x.actualizado_at desc nulls last;

  if not found then
    return jsonb_build_object('status','SIN_MUESTRA_VERIFICABLE','motivo','EVENTO_SIN_EQUIPOS_RESUELTOS',
      'note','No se pudo resolver los equipos de este partido. No se inventan puntos esperados.');
  end if;

  h := public.nfl_forma_equipo(e.home_espn_id, e.fecha);
  a := public.nfl_forma_equipo(e.away_espn_id, e.fecha);
  select * into fh from public.nfl_fpi where espn_team_id = e.home_espn_id;
  select * into fa from public.nfl_fpi where espn_team_id = e.away_espn_id;

  if h is null then faltan := faltan || e.home_nombre; end if;
  if a is null then faltan := faltan || e.away_nombre; end if;

  if h is null or a is null then
    return jsonb_build_object(
      'status', case when h is null and a is null then 'SIN_MUESTRA_VERIFICABLE' else 'PARCIAL_SIN_RIVAL_VERIFICABLE' end,
      'authority','FACTUAL_CONTEXT_NOT_P_RETO',
      'home_team', e.home_nombre, 'away_team', e.away_nombre,
      'equipos_sin_muestra', to_jsonb(faltan),
      'minimo_exigido_juegos', 3,
      'forma_home', h, 'forma_away', a,
      'note', format('Sin al menos 3 juegos de temporada regular de: %s. No se inventan puntos esperados.',
                     array_to_string(faltan,' ni ')));
  end if;

  ph := round((((h->>'puntos_a_favor_pj')::numeric + (a->>'puntos_en_contra_pj')::numeric)/2.0), 1);
  pa := round((((a->>'puntos_a_favor_pj')::numeric + (h->>'puntos_en_contra_pj')::numeric)/2.0), 1);

  return jsonb_build_object(
    'status','AVAILABLE_FROM_POINTS_FOR_AGAINST',
    'authority','FACTUAL_CONTEXT_NOT_P_RETO',
    'home_team', e.home_nombre, 'away_team', e.away_nombre,
    'home_expected_points', ph, 'away_expected_points', pa,
    'total_expected_points', round(ph + pa, 1),
    'expected_score_rounded', round(ph)::int || '-' || round(pa)::int,
    'forma_home', h, 'forma_away', a,
    'espn_fpi', jsonb_build_object(
      'home', case when fh.espn_team_id is not null then jsonb_build_object(
        'fpi', fh.fpi, 'rank', fh.fpi_rank, 'epa_ofensiva', fh.epa_ofensiva,
        'epa_defensiva', fh.epa_defensiva, 'proyeccion_victorias', fh.proyectadas_g,
        'prob_playoffs_pct', fh.prob_playoffs, 'actualizado', fh.actualizado_espn) end,
      'away', case when fa.espn_team_id is not null then jsonb_build_object(
        'fpi', fa.fpi, 'rank', fa.fpi_rank, 'epa_ofensiva', fa.epa_ofensiva,
        'epa_defensiva', fa.epa_defensiva, 'proyeccion_victorias', fa.proyectadas_g,
        'prob_playoffs_pct', fa.prob_playoffs, 'actualizado', fa.actualizado_espn) end,
      'fuente','ESPN Football Power Index', 'role','FACTUAL_CONTEXT'),
    'corte_temporal', e.fecha,
    'formula','ataque de cada equipo promediado con la defensa del rival: (PF_local + PC_visita)/2 y (PF_visita + PC_local)/2',
    'ventaja_de_local_aplicada', false,
    'note','Contexto factual a partir de puntos reales anotados y recibidos en temporada regular, con corte en la hora del partido. La pretemporada se excluye. NO es P_RETO ni autoriza ningun pick.');
end $fn$;

revoke all on function public.nfl_forma_equipo(text,timestamptz,int) from public;
revoke all on function public.puntos_esperados_contexto(text) from public;
grant execute on function public.nfl_forma_equipo(text,timestamptz,int) to anon, authenticated, service_role;
grant execute on function public.puntos_esperados_contexto(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3) Conexion al contrato. DOS ramas, cada una con guarda de exactamente 1.
--    Una es la rama sin snapshot canonico (la que devolvia 6 llaves).
--    La otra es la principal: el contexto va SIEMPRE, haya o no P_RETO.
--    UN SOLO CEREBRO: esto no compite con el modelo. Cuando hay P_RETO,
--    official_prediction sigue mandando; points_expectation va etiquetado
--    FACTUAL_CONTEXT_NOT_P_RETO y no autoriza nada.
-- ---------------------------------------------------------------------
DO $outer$
DECLARE v_def text; v_o text; v_n text; c int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='nfl_terminal_v2';

  v_o := $r$      'principles',jsonb_build_object('one_brain',true,'market_can_create_p_reto',false,'ev_used',false,'kelly_used',false)
    );$r$;
  v_n := $r$      'points_expectation',coalesce(public.puntos_esperados_contexto(p_event),'{}'::jsonb),
      'principles',jsonb_build_object('one_brain',true,'market_can_create_p_reto',false,'ev_used',false,'kelly_used',false)
    );$r$;
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  IF c <> 1 THEN RAISE EXCEPTION 'ISS131 R1 aborta: % coincidencias, se exigia 1', c; END IF;
  v_def := replace(v_def, v_o, v_n);

  v_o := $r$    'factors',v_factors,$r$;
  v_n := $r$    'points_expectation',coalesce(public.puntos_esperados_contexto(p_event),'{}'::jsonb),
    'factors',v_factors,$r$;
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  IF c <> 1 THEN RAISE EXCEPTION 'ISS131 R2 aborta: % coincidencias, se exigia 1', c; END IF;
  v_def := replace(v_def, v_o, v_n);

  EXECUTE v_def;
END
$outer$;

-- =====================================================================
-- MEDIDO SOBRE LOS 256 PARTIDOS FUTUROS DE NFL:
--
--   AVAILABLE_FROM_POINTS_FOR_AGAINST .... 256 de 256  (100%)
--   con FPI de AMBOS equipos ............. 256 de 256  (100%)
--   promedio total esperado .............. 46.6 puntos
--   rango ................................ 39.8 a 55.6
--   sin muestra .......................... 0
--
-- VERIFICACION PUNTUAL (Buffalo Bills - Detroit Lions, semana 3):
--   Bills 26.3 - Lions 25.2, total 51.5, marcador redondeado "26-25"
--   Bills:  28.0 PF / 20.9 PC por juego, diferencial +7.1, n=17
--   Lions:  29.4 PF / 24.5 PC por juego, diferencial +4.9, n=17
--   ventana 2025-09-14 a 2026-09-13, temporadas [2026, 2025]
--   FPI: Bills 4.835 rank 2 (EPA of 4.96) | Lions 1.525 rank 11 (EPA of 2.069)
--
--   CONTROL INDEPENDIENTE, no usado en el calculo:
--   la linea de total del mercado para ese partido era 53.5 y yo di 51.5,
--   sin haberla mirado. Que caiga cerca es senal de que los insumos no
--   estan locos. NO es validacion: el mercado no valida nada aqui, y el
--   precio no entra ni puede entrar en este bloque.
--
-- LO QUE NO HICE Y POR QUE:
--   NO apliqué ventaja de local a los puntos esperados, aunque el contrato
--   declara home_advantage = 1.50 puntos en v2.nfl_form_model_config_v1.
--   Ese coeficiente es del MODELO; meterlo aqui seria mezclar el cerebro con
--   el contexto factual. El bloque declara 'ventaja_de_local_aplicada': false
--   para que nadie asuma lo contrario.
--
--   NO invente yardas ni touchdowns. public.nfl_partidos NO tiene esas
--   columnas: tiene pts_home, pts_away, lesionados, clima, momios y estadio.
--   Las tablas nfl_equipo_totales, nfl_defense_logs y nfl_depth_chart estan
--   VACIAS. El dueno pidio yardas y touchdowns; la respuesta honesta es que
--   hoy no hay de donde sacarlos, y queda como ingesta pendiente, no como
--   un numero inventado.
-- =====================================================================
