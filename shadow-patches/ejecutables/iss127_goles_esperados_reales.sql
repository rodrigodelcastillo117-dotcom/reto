-- =====================================================================
-- ISS127 -- "NO SALEN LOS GOLES ESPERADOS"
--
-- SINTOMA REPORTADO POR EL DUENO:
--   "no quiero ningun bug, error, que no salgan goles esperados,
--    todos con goles esperados reales de los partidos"
--
-- QUE ENCONTRE (medido, no supuesto):
--   De 233 partidos publicados en v_futpro_publication_v3:
--     152 tenian lambdas oficiales del modelo  -> SI mostraban goles esperados
--      81 no tenian modelo aprobado            -> el contrato devolvia
--                                                 'UNAVAILABLE_NO_OFFICIAL_DISTRIBUTION'
--                                                 y en pantalla no salia NADA.
--
--   La causa de fondo NO era falta de datos. Era una VENTANA:
--     public.v_soccer_event_form_context_v2 filtra
--       fecha >= now() - 2 dias  AND  fecha < now() + 4 dias
--     Esa ventana de 6 dias deja fuera 107 de los 233 partidos publicados,
--     asi que mv_futpro_analysis_v4 solo tiene 128 filas. Cualquier cosa que
--     lea el MV hereda la ventana.
--
-- QUE NO HICE Y POR QUE:
--   NO ensanche la ventana de v_soccer_event_form_context_v2.
--   Esa vista alimenta v_soccer_publication_form_guard_v2, y el guard decide
--   form_conflict_level='HIGH' -> "NO entra a TOP". Ensanchar la ventana
--   cambiaria QUE PARTIDOS SON ELEGIBLES. Eso es cutover de seleccion.
--   PROD_MODEL_CUTOVER=FROZEN. Queda como decision del dueno.
--
-- QUE SI HICE:
--   goles_esperados_contexto() lee v2.fn_soccer_team_form_context_v2
--   DIRECTO, con corte temporal = la hora del partido. Esa funcion no tiene
--   la ventana de 6 dias y trae su propio temporal_safe. Es estrictamente
--   aditivo: no toca el MV, ni el guard, ni la elegibilidad, ni P_RETO.
--
-- UN SOLO CEREBRO:
--   Esto NO es un segundo analisis. El contrato tiene un IF excluyente:
--     si hay distribucion oficial  -> se muestra el modelo, y esta funcion
--                                     NI SIQUIERA SE LLAMA.
--     si no hay                    -> se muestra contexto factual, etiquetado
--                                     'FACTUAL_CONTEXT_NOT_P_RETO'.
--   Nunca se muestran los dos. Nunca autoriza un pick.
--
-- SIN EV, SIN KELLY, SIN PRECIO. Solo goles reales metidos y recibidos.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Elegir la muestra de un equipo.
--    Prioridad explicita: lo reciente pesa mas que la historia larga
--    (instruccion del dueno: "ESTA TEMPORADA VALE MAS QUE LA PASADA").
--    Minimo 3 partidos. Con 1 partido, "mete 4 goles por partido" es ruido,
--    y ese ruido es justo el que produce picks que no hacen sentido.
-- ---------------------------------------------------------------------
create or replace function public.goles_pick_muestra(p_ctx jsonb)
returns jsonb language sql immutable as $fn$
  select x.muestra
  from (
    values
      (1,'ULTIMOS_5_TODAS_LAS_COMPETICIONES', p_ctx->>'last5_n',   p_ctx->>'last5_gf_pg',   p_ctx->>'last5_ga_pg'),
      (2,'TEMPORADA_ACTUAL',                  p_ctx->>'current_n', p_ctx->>'current_gf_pg', p_ctx->>'current_ga_pg'),
      (3,'ULTIMOS_10',                        p_ctx->>'last10_n',  p_ctx->>'last10_gf_pg',  p_ctx->>'last10_ga_pg'),
      (4,'ULTIMOS_540_DIAS',                  p_ctx->>'long540_n', p_ctx->>'long540_gf_pg', p_ctx->>'long540_ga_pg')
  ) as v(prio, fuente, n, gf, ga)
  cross join lateral (
    select jsonb_build_object('fuente',v.fuente,'n',v.n::int,
                              'gf_pg',v.gf::numeric,'ga_pg',v.ga::numeric) as muestra
  ) x
  where p_ctx is not null
    and nullif(v.n,'')::int >= 3
    and nullif(v.gf,'') is not null
    and nullif(v.ga,'') is not null
  order by v.prio
  limit 1;
$fn$;

revoke all on function public.goles_pick_muestra(jsonb) from public;
grant execute on function public.goles_pick_muestra(jsonb) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2) Goles esperados de contexto.
--    Tres estados honestos, ninguno inventa:
--      AVAILABLE_FROM_GOALS_FOR_AGAINST  los dos equipos tienen muestra
--      PARCIAL_SIN_RIVAL_VERIFICABLE     solo uno; se publica lo que existe
--                                        y NO se calcula marcador ni total
--      SIN_MUESTRA_VERIFICABLE           ninguno; se dice y se nombra a quien
-- ---------------------------------------------------------------------
create or replace function public.goles_esperados_contexto(p_espn_event_id text)
returns jsonb language plpgsql stable as $fn$
declare
  e record;
  h jsonb; a jsonb;
  hf jsonb; af jsonb;
  v_lh numeric; v_la numeric;
  faltan text[] := '{}';
  v_parcial jsonb;
begin
  select distinct on (x.espn_event_id)
         x.espn_event_id, x.liga_id, x.fecha, x.home_espn_id, x.away_espn_id,
         x.home_nombre, x.away_nombre
    into e
  from public.agenda_espn x
  where x.espn_event_id = p_espn_event_id
    and x.deporte = 'soccer'
    and x.home_espn_id is not null and x.away_espn_id is not null and x.liga_id is not null
  order by x.espn_event_id, x.actualizado_at desc nulls last;

  if not found then
    return jsonb_build_object(
      'status','SIN_MUESTRA_VERIFICABLE',
      'motivo','EVENTO_SIN_EQUIPOS_RESUELTOS',
      'note','No se pudo resolver los equipos de este partido en la agenda. No se inventan goles esperados.');
  end if;

  -- corte temporal = hora del partido. Sin lookahead por construccion.
  h := v2.fn_soccer_team_form_context_v2(e.home_espn_id, e.liga_id, e.fecha);
  a := v2.fn_soccer_team_form_context_v2(e.away_espn_id, e.liga_id, e.fecha);

  hf := public.goles_pick_muestra(h);
  af := public.goles_pick_muestra(a);

  if hf is null then faltan := faltan || e.home_nombre; end if;
  if af is null then faltan := faltan || e.away_nombre; end if;

  if (hf is null) <> (af is null) then
    v_parcial := coalesce(hf, af);
    return jsonb_build_object(
      'status','PARCIAL_SIN_RIVAL_VERIFICABLE',
      'authority','FACTUAL_CONTEXT_NOT_P_RETO',
      'home_team', e.home_nombre, 'away_team', e.away_nombre,
      'equipo_con_muestra', case when hf is not null then e.home_nombre else e.away_nombre end,
      'lado_con_muestra',   case when hf is not null then 'home' else 'away' end,
      'gf_pg',(v_parcial->>'gf_pg')::numeric,
      'ga_pg',(v_parcial->>'ga_pg')::numeric,
      'muestra_n',(v_parcial->>'n')::int,
      'fuente', v_parcial->>'fuente',
      'equipos_sin_muestra', to_jsonb(faltan),
      'minimo_exigido_partidos', 3,
      'corte_temporal', e.fecha,
      'note', format('Solo %s tiene historial suficiente (minimo 3 partidos). Sin datos del rival no se calcula marcador ni total esperado: no se inventa.',
                     case when hf is not null then e.home_nombre else e.away_nombre end));
  end if;

  if hf is null and af is null then
    return jsonb_build_object(
      'status','SIN_MUESTRA_VERIFICABLE',
      'motivo','EQUIPO_SIN_HISTORIAL_SUFICIENTE',
      'home_team', e.home_nombre, 'away_team', e.away_nombre,
      'equipos_sin_muestra', to_jsonb(faltan),
      'minimo_exigido_partidos', 3,
      'note', format('Sin historial suficiente (minimo 3 partidos) de: %s. No se inventan goles esperados.',
                     array_to_string(faltan,' ni ')));
  end if;

  v_lh := round((((hf->>'gf_pg')::numeric + (af->>'ga_pg')::numeric) / 2.0), 2);
  v_la := round((((af->>'gf_pg')::numeric + (hf->>'ga_pg')::numeric) / 2.0), 2);

  return jsonb_build_object(
    'status','AVAILABLE_FROM_GOALS_FOR_AGAINST',
    'authority','FACTUAL_CONTEXT_NOT_P_RETO',
    'home_team', e.home_nombre, 'away_team', e.away_nombre,
    'home_expected_goals', v_lh, 'away_expected_goals', v_la,
    'total_expected_goals', round(v_lh + v_la, 2),
    'expected_score_rounded', round(v_lh)::int || '-' || round(v_la)::int,
    'fuente_home', hf->>'fuente', 'fuente_away', af->>'fuente',
    'muestra', jsonb_build_object('home_n',(hf->>'n')::int,'away_n',(af->>'n')::int),
    'insumos', jsonb_build_object(
      'home_gf_pg',(hf->>'gf_pg')::numeric,'home_ga_pg',(hf->>'ga_pg')::numeric,
      'away_gf_pg',(af->>'gf_pg')::numeric,'away_ga_pg',(af->>'ga_pg')::numeric),
    'corte_temporal', e.fecha,
    'temporal_safe', coalesce((h->>'temporal_safe')::boolean,false)
                 and coalesce((a->>'temporal_safe')::boolean,false),
    'formula','ataque de cada equipo promediado con la defensa del rival: (GF_local + GC_visita)/2 y (GF_visita + GC_local)/2',
    'note','Contexto factual a partir de goles reales metidos y recibidos, con corte en la hora del partido. NO es P_RETO ni autoriza ningun pick.');
end $fn$;

revoke all on function public.goles_esperados_contexto(text) from public;
grant execute on function public.goles_esperados_contexto(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 3) Conexion al contrato, UNA sola expresion, con guarda de "exactamente 1".
--    Se reemplaza SOLO la rama ELSE (sin distribucion oficial).
--    La rama oficial (AVAILABLE_FROM_CANONICAL_DISTRIBUTION) no se toca.
--    md5(prosrc) de futpro_terminal_v2:
--      antes  (no capturado en el mismo statement; ver RAISE NOTICE)
--      despues 6c35b50e909d43712b08a85913522c88
-- ---------------------------------------------------------------------
DO $outer$
DECLARE
  v_def text; v_old text; v_new text; v_n int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='futpro_terminal_v2';

  v_old := $repl$      'goal_expectation', jsonb_build_object(
        'status','UNAVAILABLE_NO_OFFICIAL_DISTRIBUTION',
        'note','Sin distribución oficial no se inventan goles esperados ni marcador.'
      )$repl$;

  v_new := $repl$      'goal_expectation', coalesce(public.goles_esperados_contexto(p_espn_event_id),'{}'::jsonb)
        || jsonb_build_object(
             'official_distribution_status','UNAVAILABLE_NO_OFFICIAL_DISTRIBUTION',
             'official_distribution_note','Sin distribución oficial no se inventan goles esperados ni marcador; lo de arriba es contexto factual de goles reales, no P_RETO.'
           )$repl$;

  v_n := (length(v_def) - length(replace(v_def, v_old, ''))) / length(v_old);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'ISS127 ABORTA: el bloque a reemplazar aparece % veces, se exigia exactamente 1', v_n;
  END IF;

  EXECUTE replace(v_def, v_old, v_new);
END
$outer$;

-- ---------------------------------------------------------------------
-- 4) Evidencia. Lo que mida esto queda escrito, incluso lo que me contradice.
-- ---------------------------------------------------------------------
create table if not exists public.iss127_evidencia (
  id bigserial primary key,
  medido_at timestamptz not null default now(),
  medicion text not null,
  n int, valor numeric, sd numeric, t_stat numeric, nota text
);

-- ---------------------------------------------------------------------
-- 5) Compuerta. La definicion vive aqui; el runner esta en gates_selector.sql
--    como GATE 27.
-- ---------------------------------------------------------------------
-- (ver public.gate_goles_esperados() -- instalada en produccion,
--  7 comprobaciones: 6 duras + 1 informativa de cobertura)

-- =====================================================================
-- RESULTADO MEDIDO (2026-09-16), 233 partidos publicados:
--
--   G27.1 todo publicado tiene bloque ........ PASS  0
--   G27.2 estados conocidos .................. PASS  0
--   G27.3 available con datos reales ......... PASS  0
--   G27.4 un solo cerebro .................... PASS  1
--   G27.5 rama oficial intacta ............... PASS  1
--   G27.6 sin precio / EV / Kelly ............ PASS  limpio
--   G27.7 cobertura .......................... INFO  233
--         modelo_oficial=152 | contexto_completo=17 | parcial=15 | sin_muestra=49
--
--   ANTES: 152 con goles esperados, 81 en blanco.
--   AHORA: 169 con goles esperados completos, 15 con el dato real de un solo
--          equipo, 49 que dicen por su nombre que no hay muestra.
--
--   Los 49 no son un bug que quede por arreglar. Son eliminatorias de copa
--   contra clubes amateur (Taca de Portugal, KNVB Beker). Medido: 33 equipos
--   con CERO partidos en la base, 66 con exactamente 1, 14 con 2. Con 1
--   partido, "mete 3 goles por partido" es ruido. No hay fuente. Se dice.
--
-- VERIFICACION PUNTUAL:
--   Everton - Wolverhampton (401914282), sin P_RETO oficial:
--     home 1.60  away 1.40  total 3.00  marcador 2-1
--     fuente ULTIMOS_5_TODAS_LAS_COMPETICIONES, muestra 5 y 5
--     insumos: Everton 1.80 GF / 0.60 GC ; Wolves 2.20 GF / 1.40 GC
--     temporal_safe = true, corte 2026-09-16T18:45:00Z
--   Levski Sofia - RB Salzburg (401915584), un solo lado:
--     PARCIAL_SIN_RIVAL_VERIFICABLE, Salzburg 2.40 GF / 1.00 GC sobre 5
--     partidos, Levski sin muestra. NO se calcula marcador.
--
-- =====================================================================
-- LO QUE MEDI Y ME CONTRADICE (queda escrito):
--
-- 1) Yo habia dicho que el modelo de futbol SUBESTIMA los goles
--    (+0.288, t=1.81). ESO ESTABA MAL. Medicion pareada correcta sobre el
--    unico modelo con partidos terminados (dc-2026.09.1, n=159):
--         realidad - modelo = +0.059, sd 1.806, t = 0.41
--    No hay sesgo de goles detectable. Retiro la afirmacion.
--
-- 2) El contexto crudo GF/GA da +0.314 mas goles que el modelo publicado
--    (n=152 pareado, sd 0.570, t=6.79). Eso NO prueba que el modelo este mal.
--    Con (1) arriba, lo mas probable es que el sesgado sea MI estimador:
--    no tiene encogimiento, ni fuerza de liga, ni ventaja de local.
--    Por eso el contexto NUNCA se muestra donde hay modelo, y va etiquetado
--    'FACTUAL_CONTEXT_NOT_P_RETO'.
--
-- 3) BLOQUEADOR DE VALIDACION, sin arreglo de mi parte:
--    el modelo publicado hoy, soccer_canonical_v2 (160 eventos READY), tiene
--    CERO partidos terminados. Su calibracion y su sesgo de goles son HOY
--    NO MEDIBLES. No es un fallo que yo pueda cerrar: hay que esperar a que
--    se jueguen partidos. Lo dejo declarado, no lo tapo.
--
-- DECISION DEL DUENO PENDIENTE (no la tomo yo):
--    public.v_soccer_event_form_context_v2 filtra a una ventana de 6 dias
--    (now()-2d .. now()+4d). Eso deja 107 de 233 partidos publicados sin
--    contexto de forma en mv_futpro_analysis_v4. Ensanchar esa ventana
--    daria contexto a mas partidos, PERO alimenta
--    v_soccer_publication_form_guard_v2, que con form_conflict_level='HIGH'
--    saca picks del TOP. Ensancharla cambia QUE SE PUBLICA.
--    Eso es cutover de seleccion. PROD_MODEL_CUTOVER=FROZEN. No lo toco.
-- =====================================================================
