-- ============================================================================
-- ROLLBACK ARTIFACT — ISS-003/009/009B — NO EJECUTAR salvo fallo critico POST-COMMIT
-- Restaura las definiciones vivas PRE-DEPLOY. Orden inverso de dependencias.
-- CREATE OR REPLACE VIEW no puede quitar columnas => DROP + recreate para las vistas.
-- Requiere reponer OWNER/reloptions/GRANTS (DROP los elimina) — incluidos abajo.
-- ============================================================================
BEGIN;
SET LOCAL lock_timeout = '3s';
SET LOCAL statement_timeout = '60s';

-- 1) analisis_completo(text) [funcion late-bound: restaurar primero]
CREATE OR REPLACE FUNCTION public.analisis_completo(p_event text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ev record; sede record; pred record; haf int; aaf int;
  jh jsonb; ja jsonb; jh2h jsonb; jmkt jsonb; jodds jsonb; th jsonb; ta jsonb;
  v_en_casa boolean; v_alt int; v_pref text; v_linea numeric;
  s1 jsonb; s2 jsonb; s3 jsonb; s6 jsonb; s7 jsonb;
  mlb record; nfl record; v_mlb_motor jsonb; v_liga_comun integer;
  v_espn jsonb; v_probs jsonb;
begin
  select a.espn_event_id, a.espn_endpoint, a.liga_nombre, a.fecha, a.home_nombre, a.away_nombre,
         a.home_espn_id, a.away_espn_id, coalesce(a.deporte,'soccer') deporte
    into ev from agenda_espn a where a.espn_event_id = p_event;
  if not found then return jsonb_build_object('error','partido no encontrado'); end if;

  v_pref := split_part(ev.espn_endpoint,'/',1) || '/%';
  select s.estadio, s.ciudad, s.pais, s.sitio_neutral, s.ronda, s.asistencia into sede
    from partido_sede s where s.espn_event_id = p_event;

  select jsonb_agg(jsonb_build_object('pick', pick_nombre, 'mercado', mercado,
           'probabilidad_pct', probabilidad_pct, 'muestra', muestra_calibracion,
           -- Lo que ese decil de probabilidad ENTREGO de verdad, medido en
           -- zonas_confiables. Es el contrapeso del EV en verde: el motor puede
           -- marcar +24% de EV en un no-favorito y estar inflando ese tramo.
           'zona', public.zona_realidad(mercado, probabilidad_pct/100.0),
           'momio_justo', round(100.0/nullif(probabilidad_pct,0),2),
           'momio_casa', coalesce(vv.m, c.momio_mercado),
           'casa', coalesce(vv.prov, c.casa),
           'ev_pct', case when coalesce(vv.m, c.momio_mercado) is not null
                          then round((c.probabilidad_pct/100.0*coalesce(vv.m, c.momio_mercado) - 1)*100, 1)
                     end,
           'como_se_calculo', c.razon) order by c.probabilidad_pct desc)
    into jmkt
    -- 2-sep-2026: el MISMO pick salia con DOS precios y DOS EV en el mismo analisis.
    -- Este bloque traia el momio guardado cuando se genero el pick (1.671 en el
    -- Reds-Padres) y el bloque de "probabilidades" el momio VIVO de odds_espn (1.6024).
    -- En dinero eso es +4.4% de EV contra +0.2% para la misma apuesta. Ahora los dos
    -- leen el precio VIVO; si no hay precio vivo para ese mercado, se cae al guardado.
    -- v_pick_canonico NO se toca, para no mover la generacion de picks.
    from v_pick_canonico c
    left join lateral (
      select o.proveedor as prov,
             case
               when c.mercado = 'Moneyline'
                    and sin_acentos(c.pick_nombre) like '%'||sin_acentos(ev.home_nombre)||'%'
                 then o.ml_home
               when c.mercado = 'Moneyline'
                    and sin_acentos(c.pick_nombre) like '%'||sin_acentos(ev.away_nombre)||'%'
                 then o.ml_away
               when sin_acentos(c.pick_nombre) ~* '^(over|mas de)'
                    and o.total_linea = nullif(regexp_replace(c.pick_nombre,'[^0-9.]','','g'),'')::numeric
                 then o.over_odds
               when sin_acentos(c.pick_nombre) ~* '^(under|menos de)'
                    and o.total_linea = nullif(regexp_replace(c.pick_nombre,'[^0-9.]','','g'),'')::numeric
                 then o.under_odds
             end as m
      from odds_espn o where o.espn_event_id = c.espn_event_id
    ) vv on true
   where c.espn_event_id = p_event;

  ---------------------------------------------------------------- FUTBOL
  if ev.deporte = 'soccer' then
    v_linea := 2.5;
    select e.api_football_id into haf from ligamx_equipos e where e.espn_id::text = ev.home_espn_id::text limit 1;
    select e.api_football_id into aaf from ligamx_equipos e where e.espn_id::text = ev.away_espn_id::text limit 1;
    -- La competencia contra la que se mide la fuerza tiene que ser LA MISMA para
    -- los dos. Se elige la que ambos comparten con mas partidos jugados: casi
    -- siempre su liga de casa. Antes cada equipo elegia por su cuenta la de mas
    -- partidos y salian comparados contra torneos distintos (Toluca contra uno,
    -- Leon contra otro), con medias de liga que no cuadraban entre si.
    select f1.liga_id into v_liga_comun
      from mv_fuerza_equipo f1
      join mv_fuerza_equipo f2 on f2.liga_id = f1.liga_id and f2.team_id = aaf
     where f1.team_id = haf
     order by least(f1.pj, f2.pj) desc, (f1.pj + f2.pj) desc
     limit 1;

    jh := bloque_equipo_futbol(ev.home_espn_id::text, haf, v_liga_comun);
    ja := bloque_equipo_futbol(ev.away_espn_id::text, aaf, v_liga_comun);
    select case when sede.pais is null or pe.pais is null then null
                when sede.sitio_neutral is true                then false
                when sede.pais = pe.pais                       then true
                else false end
      into v_en_casa
      from mv_pais_del_equipo pe where pe.espn_team_id = ev.home_espn_id::text;
    select pr.lam_h, pr.lam_a, pr.marcador_probable, pr.muestra into pred
      from public.pred_futbol_del_evento(p_event) pr;
    v_espn := public.pred_futbol_espn(p_event);
    -- EL RESUMEN sale del historico ESPN propio de cada equipo. Antes salia de
    -- fut_predicciones (API-Football), que solo cubria 10 de 176 partidos
    -- proximos: los otros 166 abrian el analisis con la seccion 1 en blanco.
    -- El modelo ESPN quedo medido contra 10,588 partidos ya jugados:
    -- 2.918 goles predichos vs 2.912 reales, Mas de 2.5 55.0% vs 56.0%,
    -- ambos anotan 55.4% vs 54.2%, gana local 44.2% vs 44.2%. El encogimiento
    -- hacia la media de la liga usa k=11, medido fuera de muestra partiendo
    -- 866 temporadas-equipo por la mitad.
    s1 := case when v_espn is not null then jsonb_build_object(
              'marcador_mas_probable', v_espn->>'marcador_probable',
              'goles_esperados_total', (v_espn->>'goles_esperados_total')::numeric,
              'esperados_local',       (v_espn->>'lam_h')::numeric,
              'esperados_visitante',   (v_espn->>'lam_a')::numeric,
              'muestra_del_modelo',    (v_espn->>'muestra')::int,
              'de_donde_sale', 'Historial ESPN de los ultimos 540 dias: '||(v_espn->>'pj_local')||
                               ' partidos del local y '||(v_espn->>'pj_visitante')||' del visitante.',
              -- Sin esto el resumen se leia como una contradiccion: "marcador
              -- mas probable 1-1" junto a "espera 2.69 goles". No la hay: 1-1
              -- es la MODA de ESTE partido y vale 12.3%; 2.69 es el PROMEDIO de
              -- todos los marcadores posibles. Ahora se dice cuanto vale.
              'prob_del_marcador_pct', (v_espn->>'prob_del_marcador_pct')::numeric,
              'marcadores_probables',  v_espn->'marcadores_probables',
              'nota_marcador',         v_espn->>'nota_marcador')
            else jsonb_build_object('marcador_mas_probable', pred.marcador_probable,
              'goles_esperados_total', round(coalesce(pred.lam_h,0)+coalesce(pred.lam_a,0),2),
              'esperados_local', pred.lam_h, 'esperados_visitante', pred.lam_a,
              'muestra_del_modelo', pred.muestra,
              -- Sin historial no se inventa un numero. Los unicos partidos que
              -- caen aqui son primeras rondas de copa con equipos amateurs
              -- (KNVB Beker, Taca de Portugal): 22 de 176 partidos proximos.
              'por_que_no_hay_numeros', case when pred.lam_h is null then
                 'No tenemos historial de estos dos equipos en ESPN. Pasa en las primeras '
                 ||'rondas de copa, donde entran equipos amateurs y regionales. Antes que '
                 ||'inventarte un numero, esta seccion se queda sin numeros.' end) end;
    s2 := jsonb_build_object('local', jh->'ultimos_5', 'visitante', ja->'ultimos_5');
    s3 := jsonb_build_object(
            'local', jsonb_build_object('torneo_actual', jh->'torneo_actual', 'forma', jh->'forma_240_dias', 'rating_espn', jh->'rating_espn_historico', 'fuerza_liga', jh->'fuerza_en_su_liga'),
            'visitante', jsonb_build_object('torneo_actual', ja->'torneo_actual', 'forma', ja->'forma_240_dias', 'rating_espn', ja->'rating_espn_historico', 'fuerza_liga', ja->'fuerza_en_su_liga'));
    s6 := jsonb_build_object('lesionados_local', jh->'lesionados', 'lesionados_visitante', ja->'lesionados',
            'local_de_local', jh->'de_local', 'visitante_de_visitante', ja->'de_visitante');
    select jsonb_build_object('proveedor', o.proveedor, 'local', o.ml_home, 'empate', o.ml_draw,
             'visitante', o.ml_away, 'linea_total', o.total_linea, 'over', o.over_odds,
             'under', o.under_odds, 'capturado', o.capturado_at)
      into s7 from odds_espn o where o.espn_event_id = p_event;

    -- Lo mas importante del resumen: la probabilidad del modelo contra el precio
    -- real de la casa, mercado por mercado. Antes esta seccion solo traia algo
    -- cuando el motor habia dejado un pick guardado (11 de 176 partidos).
    if v_espn is not null then
      with base(mercado, prob, momio) as (
        values
          ('Gana '||ev.home_nombre, (v_espn->>'prob_local_pct')::numeric,   (s7->>'local')::numeric),
          ('Empate',                (v_espn->>'prob_empate_pct')::numeric,  (s7->>'empate')::numeric),
          ('Gana '||ev.away_nombre, (v_espn->>'prob_visita_pct')::numeric,  (s7->>'visitante')::numeric),
          ('Más de 2.5',            (v_espn->>'prob_mas_25_pct')::numeric,
              case when (s7->>'linea_total')::numeric = 2.5 then (s7->>'over')::numeric end),
          ('Menos de 2.5',          (v_espn->>'prob_menos_25_pct')::numeric,
              case when (s7->>'linea_total')::numeric = 2.5 then (s7->>'under')::numeric end),
          ('Ambos anotan',          (v_espn->>'prob_btts_pct')::numeric,    null::numeric)
      )
      select jsonb_agg(jsonb_build_object(
               'mercado', b.mercado, 'probabilidad_pct', b.prob,
               'momio_justo', round(100.0/nullif(b.prob,0),2),
               'momio_casa', b.momio, 'casa', s7->>'proveedor',
               'ev_pct', case when b.momio is not null
                              then round((b.prob/100.0*b.momio - 1)*100, 1) end,
               'zona', public.zona_realidad(
                   case when b.mercado like 'Gana %' or b.mercado = 'Empate' then 'Moneyline'
                        when b.mercado like '%de 2.5' then 'Over/Under'
                        else 'BTTS' end, b.prob/100.0))
               order by b.prob desc)
        into v_probs from base b;
      s1 := s1 || jsonb_build_object('probabilidades', v_probs);
    end if;

  ---------------------------------------------------------------- MLB
  elsif ev.deporte in ('baseball','baseball/mlb') then
    select c.*, b.proj_home, b.proj_away, b.forma_home, b.forma_away,
           b.carreras_home_l5, b.carreras_away_l5, b.permitidas_home_l5, b.permitidas_away_l5,
           b.lesionados_home, b.lesionados_away, b.ml_home, b.ml_away, b.total_linea,
           b.over_odds, b.under_odds, b.casa_odds,
           e.home_era_prepartido, e.away_era_prepartido, e.home_ip_previas, e.away_ip_previas
      into mlb
    from (select p_event as ev) x
    left join mlb_stats_cache c        on c.espn_event_id = x.ev
    left join badrino_partidos b       on b.espn_event_id = x.ev
    left join badrino_era_prepartido e on e.espn_event_id = x.ev
    limit 1;
    v_linea := coalesce(mlb.total_linea, 8.5);
    -- 1-sep-2026: habia TRES numeros para el mismo juego en la misma pantalla.
    -- El bloque 1 sacaba la probabilidad de badrino_partidos (proj_home), el
    -- marcador y las carreras de motor_mlb, y el recuadro de QUE HARIA de
    -- predecir_mlb. En Angels vs Yankees motor_mlb daba 33.0% al local y
    -- predecir_mlb 42.3%: nueve puntos, y uno decia apostar y el otro no.
    -- Manda predecir_mlb, que es el unico que mira abridores (FIP), bullpen,
    -- park factor, splits contra zurdo/derecho y ventaja de local, y que viene
    -- amortiguado 70% hacia la base tras backtest de 1,897 juegos.
    v_mlb_motor := public.predecir_mlb(p_event);
    -- OJO: proj_home y proj_away de badrino_partidos son PROBABILIDAD DE GANAR
    -- en porcentaje (suman 100), no carreras proyectadas. Estaban etiquetados como
    -- carreras y el total salia 100.00 en todos los juegos.
    s1 := jsonb_build_object('suficiente', coalesce((v_mlb_motor->>'ok')::boolean, false),
            'prob_gana_local_pct', (v_mlb_motor #>> '{prediccion,gana_local_pct}')::numeric,
            'prob_gana_visitante_pct', (v_mlb_motor #>> '{prediccion,gana_visita_pct}')::numeric,
            'ganador_probable', v_mlb_motor #>> '{prediccion,ganador_probable}',
            'confiable', (v_mlb_motor #>> '{edge_vs_mercado,confiable}')::boolean,
            'aviso_modelo', v_mlb_motor->'aviso_modelo',
            'marcador_probable', v_mlb_motor #>> '{prediccion,marcador_mas_probable}',
            'carreras_esperadas', (v_mlb_motor #>> '{prediccion,total_esperado}')::numeric,
            'contexto_del_juego', jsonb_build_object(
               'clima', v_mlb_motor->'desglose'->'clima',
               'movimiento_linea', public.movimiento_linea(p_event),
               'alineacion', public.alineacion_partido(p_event),
               'factor_clima', (v_mlb_motor->'desglose'->>'factor_clima')::numeric,
               'umpire_home', (select u.umpire_home from mlb_umpire_juego u
                                  where u.mlb_game_pk = mlb.mlb_game_pk),
               'umpire_precision_pct', (select um.precision_pct from mlb_umpire_juego u
                                  join umpires_mlb um on um.umpire = u.umpire_home and um.temporada = 2026
                                  where u.mlb_game_pk = mlb.mlb_game_pk),
               'umpire_nota', 'Medido en 1,056 juegos: el umpire NO mueve las carreras. '
                            || 'Su tendencia en la primera mitad de sus juegos no predice la segunda '
                            || '(correlacion -0.04). Se muestra como dato, no cambia el pronostico.',
               'sabermetria_local', (select jsonb_build_object('wRC_plus', v.wrc_plus, 'wOBA', v.woba,
                                          'FIP_equipo', v.fip, 'xFIP_equipo', v.xfip, 'OPS', v.ops)
                                        from v_mlb_saber v where v.equipo = mlb.home_team),
               'sabermetria_visita', (select jsonb_build_object('wRC_plus', v.wrc_plus, 'wOBA', v.woba,
                                          'FIP_equipo', v.fip, 'xFIP_equipo', v.xfip, 'OPS', v.ops)
                                        from v_mlb_saber v where v.equipo = mlb.away_team),
               'sabermetria_nota', 'wRC+ 100 = promedio de la liga, ajustado por parque. xFIP normaliza '
                            || 'los jonrones permitidos. Calculados de ESPN. Todavia NO entran al pronostico: '
                            || 'se estan acumulando fotos diarias para poder medirlos sin fuga de futuro.'),
            'linea_de_la_casa', mlb.total_linea,
            'carreras_ult_5_local', mlb.carreras_home_l5,
            'carreras_ult_5_visitante', mlb.carreras_away_l5,
            'permitidas_ult_5_local', mlb.permitidas_home_l5,
            'permitidas_ult_5_visitante', mlb.permitidas_away_l5,
            -- Sin abridor el motor de MLB no corre y la seccion salia en blanco
            -- sin decir por que. El abridor es la pieza que mas mueve el numero,
            -- asi que no se rellena con un promedio: se dice que falta.
            'por_que_no_hay_numeros', case
              when not coalesce((v_mlb_motor->>'ok')::boolean, false) then
                'Todavia no esta anunciado el abridor probable de este juego. Sin '
                ||'abridor el motor no corre: el pitcher es lo que mas mueve el '
                ||'numero en beisbol, y rellenarlo con un promedio seria '
                ||'inventartelo. Los abridores se cargan hasta 72 horas antes del '
                ||'primer lanzamiento. Lo demas del analisis si esta completo.'
              end);

    -- EL MODELO CONTRA EL PRECIO, igual que en futbol: la probabilidad del
    -- motor de MLB frente al momio real de la casa, mercado por mercado. Antes
    -- el resumen de MLB decia "gana X 43.9%" sin decir si a ese precio conviene.
    -- No se le pega 'zona': zonas_confiables esta medido sobre futbol y
    -- aplicarlo a beisbol seria inventar una medicion que no existe.
    if coalesce((v_mlb_motor->>'ok')::boolean, false) then
      with tot as (
        select v_mlb_motor #> array['prediccion','totales',
                 trim(to_char(mlb.total_linea,'FM990.0'))] as t
      ),
      base(mercado, prob, momio_amer) as (
        values
          ('Gana '||ev.home_nombre, (v_mlb_motor #>> '{prediccion,gana_local_pct}')::numeric, mlb.ml_home::numeric),
          ('Gana '||ev.away_nombre, (v_mlb_motor #>> '{prediccion,gana_visita_pct}')::numeric, mlb.ml_away::numeric),
          ('Más de '||trim(to_char(mlb.total_linea,'FM990.0')),
             ((select t from tot)->>'over_pct')::numeric,  mlb.over_odds::numeric),
          ('Menos de '||trim(to_char(mlb.total_linea,'FM990.0')),
             ((select t from tot)->>'under_pct')::numeric, mlb.under_odds::numeric)
      ),
      dec as (
        -- 2-sep-2026: este bloque tomaba el precio de mlb_stats_cache (cache, se
        -- queda viejo) mientras el bloque de "mercados" tomaba el de odds_espn
        -- (vivo, se refresca cada 20 min). El mismo pick salia con dos precios y
        -- dos EV distintos en el mismo analisis. Ahora manda el VIVO y el cache
        -- solo cubre cuando no hay precio vivo.
        select b.mercado, b.prob,
               coalesce(
                 (select case
                    when b.mercado = 'Gana '||ev.home_nombre then o.ml_home
                    when b.mercado = 'Gana '||ev.away_nombre then o.ml_away
                    when b.mercado like 'Más de %'  and o.total_linea = mlb.total_linea then o.over_odds
                    when b.mercado like 'Menos de %' and o.total_linea = mlb.total_linea then o.under_odds
                  end
                  from odds_espn o where o.espn_event_id = p_event),
                 case when b.momio_amer is null then null
                      when b.momio_amer > 0 then round(1 + b.momio_amer/100.0, 4)
                      else round(1 + 100.0/abs(b.momio_amer), 4) end) as momio
        from base b
      )
      select jsonb_agg(jsonb_build_object(
               'mercado', dc.mercado, 'probabilidad_pct', dc.prob,
               'momio_justo', round(100.0/nullif(dc.prob,0),2),
               'momio_casa', dc.momio, 'casa', mlb.casa_odds,
               'ev_pct', case when dc.momio is not null
                              then round((dc.prob/100.0*dc.momio - 1)*100, 1) end)
               order by dc.prob desc)
        into v_probs from dec dc where dc.prob is not null;
      s1 := s1 || jsonb_build_object('probabilidades', v_probs);
    end if;
    s2 := jsonb_build_object(
            'local', jsonb_build_object('ultimos_10', mlb.home_team_last10, 'forma', mlb.forma_home,
               'carreras_ult_5', mlb.carreras_home_l5, 'permitidas_ult_5', mlb.permitidas_home_l5),
            'visitante', jsonb_build_object('ultimos_10', mlb.away_team_last10, 'forma', mlb.forma_away,
               'carreras_ult_5', mlb.carreras_away_l5, 'permitidas_ult_5', mlb.permitidas_away_l5));
    s3 := jsonb_build_object(
            'abridor_local', jsonb_build_object('nombre', mlb.home_pitcher_name, 'mano', mlb.home_pitcher_hand,
               'era', mlb.home_pitcher_era, 'era_prepartido', mlb.home_era_prepartido, 'ip_previas', mlb.home_ip_previas,
               'whip', mlb.home_pitcher_whip, 'fip', mlb.home_pitcher_fip, 'k9', mlb.home_pitcher_k9,
               'bb9', mlb.home_pitcher_bb9, 'forma_reciente', mlb.home_pitcher_recent_form),
            'abridor_visitante', jsonb_build_object('nombre', mlb.away_pitcher_name, 'mano', mlb.away_pitcher_hand,
               'era', mlb.away_pitcher_era, 'era_prepartido', mlb.away_era_prepartido, 'ip_previas', mlb.away_ip_previas,
               'whip', mlb.away_pitcher_whip, 'fip', mlb.away_pitcher_fip, 'k9', mlb.away_pitcher_k9,
               'bb9', mlb.away_pitcher_bb9, 'forma_reciente', mlb.away_pitcher_recent_form),
            'bateo_local_vs_zurdo', mlb.home_team_vs_lhp, 'bateo_local_vs_derecho', mlb.home_team_vs_rhp,
            'bateo_visitante_vs_zurdo', mlb.away_team_vs_lhp, 'bateo_visitante_vs_derecho', mlb.away_team_vs_rhp);
    s6 := jsonb_build_object('bullpen_cansado_local', mlb.home_bullpen_fatigue,
            'bullpen_cansado_visitante', mlb.away_bullpen_fatigue,
            'bullpen_detalle_local', mlb.home_bullpen_detail, 'bullpen_detalle_visitante', mlb.away_bullpen_detail,
            'parque', mlb.park_name, 'factor_carreras_del_parque', mlb.park_factor_runs,
            'factor_hr_del_parque', mlb.park_factor_hr,
            'lesionados_local', mlb.lesionados_home, 'lesionados_visitante', mlb.lesionados_away);
    s7 := jsonb_build_object('casa', mlb.casa_odds, 'local', mlb.ml_home, 'visitante', mlb.ml_away,
            'linea_total', mlb.total_linea, 'over', mlb.over_odds, 'under', mlb.under_odds);

  ---------------------------------------------------------------- NFL
  elsif ev.deporte in ('football','football/nfl') then
    select n.* into nfl from nfl_partidos n where n.espn_event_id = p_event limit 1;
    v_linea := coalesce(nfl.total_linea, 44.5);
    s1 := jsonb_build_object('semana', nfl.semana, 'tipo_temporada', nfl.tipo_temporada,
            'spread', nfl.spread, 'spread_detalle', nfl.spread_detalle,
            'linea_total', nfl.total_linea, 'prob_local_casa', nfl.p_home, 'prob_visitante_casa', nfl.p_away);
    -- Puntos esperados desde nuestro historial ESPN, para que NFL traiga lo
    -- mismo que futbol y MLB. Va SIN valor esperado a proposito: el modelo se
    -- probo fuera de muestra en 263 partidos de 2025 y da Brier 0.246 contra
    -- 0.213 del mercado. Le pierde a la casa, asi que aqui la probabilidad que
    -- manda es la de la casa y esto es contexto.
    v_espn := public.pred_nfl_espn(p_event);
    if v_espn is not null then s1 := s1 || v_espn; end if;
    -- El record venia de nfl_partidos.home_record, lleno en 16 de 300 partidos
    -- jugados. Se calcula de nuestro propio historial.
    s2 := jsonb_build_object(
            'record_local',     coalesce(nullif(nfl.home_record,''), public.record_nfl(ev.home_espn_id::text)->>'texto'),
            'record_visitante', coalesce(nullif(nfl.away_record,''), public.record_nfl(ev.away_espn_id::text)->>'texto'),
            'de_que_temporada', public.record_nfl(ev.home_espn_id::text)->>'de');
    s3 := (select jsonb_build_object('fpi_vs_mercado', jsonb_build_object(
              'spread_mercado', f.spread_mercado, 'spread_fpi', f.spread_fpi,
              'diferencia', f.diferencia, 'desviaciones', f.desviaciones))
      from v_nfl_fpi_vs_mercado f where f.espn_event_id = p_event);
    s6 := jsonb_build_object('estadio', nfl.estadio, 'techado', nfl.techado,
            'temperatura', nfl.temperatura, 'viento_rafaga', nfl.viento_rafaga,
            'precipitacion', nfl.precipitacion, 'clima', nfl.clima_cond,
            'lesionados_local', nfl.lesionados_home, 'lesionados_visitante', nfl.lesionados_away,
            'out_local', nfl.out_home, 'out_visitante', nfl.out_away,
            'qb_comprometido_local', nfl.qb_comprometido_home, 'qb_comprometido_visitante', nfl.qb_comprometido_away,
            'lesiones_detalle', nfl.lesiones_detalle);
    s7 := jsonb_build_object('casa', nfl.casa, 'local', nfl.ml_home, 'visitante', nfl.ml_away,
            'linea_total', nfl.total_linea, 'over', nfl.over_odds, 'under', nfl.under_odds,
            'spread', nfl.spread, 'vig', nfl.vig);
  end if;

  jh2h := h2h_espn(ev.home_espn_id::text, ev.away_espn_id::text, ev.fecha, v_pref, 8, v_linea);
  th := tendencias_espn(ev.home_espn_id::text, v_pref, ev.fecha, v_linea, 25);
  ta := tendencias_espn(ev.away_espn_id::text, v_pref, ev.fecha, v_linea, 25);
  select altitud_m into v_alt from estadios_altitud
   where sin_acentos(ciudad) = sin_acentos(split_part(coalesce(sede.ciudad,''),',',1)) limit 1;

  -- 2-sep-2026: el bloque CONTEXTO DEL JUEGO existia solo para MLB. Ahora los tres
  -- deportes lo llevan, cada uno con lo que de verdad tiene cargado y verificado.
  -- Lo que un deporte no tiene, se dice que no lo tiene en vez de callarlo.
  if ev.deporte = 'soccer' then
    s1 := s1 || jsonb_build_object('contexto_del_juego', public.contexto_partido_futbol(p_event));
  elsif ev.deporte in ('football','football/nfl') then
    s1 := s1 || jsonb_build_object('contexto_del_juego', public.contexto_partido_nfl(p_event));
  end if;

  return jsonb_build_object(
    'partido', jsonb_build_object('espn_event_id', ev.espn_event_id, 'deporte', ev.deporte,
        'liga', ev.liga_nombre, 'local', ev.home_nombre, 'visitante', ev.away_nombre,
        'arranca_en', ev.fecha, 'linea_principal', v_linea,
        'ronda', ronda_es(sede.ronda), 'sitio_neutral', sede.sitio_neutral),
    '1_el_resumen', coalesce(s1,'{}'::jsonb) || jsonb_build_object('mercados', jmkt),
    '2_como_llegan', coalesce(s2,'{}'::jsonb) || jsonb_build_object(
        'ultimos_partidos_local', ultimos_espn(ev.home_espn_id::text, v_pref, ev.fecha, 6),
        'ultimos_partidos_visitante', ultimos_espn(ev.away_espn_id::text, v_pref, ev.fecha, 6)),
    '3_los_numeros_finos', coalesce(s3,'{}'::jsonb) || jsonb_build_object(
        'historico_profundo_espn', jsonb_build_object('local', th, 'visitante', ta),
        'aviso_muestra', case
          when ev.deporte = 'soccer'
           and (coalesce((jh->'forma_240_dias'->>'pj')::int, 0) < 6
             or coalesce((ja->'forma_240_dias'->>'pj')::int, 0) < 6)
          then 'OJO: la ficha fina (xG, corners, tiros, posesion) va con muestra corta: '
               ||coalesce(jh->'forma_240_dias'->>'pj','0')||' partido(s) del local y '
               ||coalesce(ja->'forma_240_dias'->>'pj','0')||' del visitante. '
               ||'Para goles usa el HISTORICO PROFUNDO de aqui abajo, que trae '
               ||coalesce(th->>'partidos','0')||' y '||coalesce(ta->>'partidos','0')||' partidos.'
          end),
    '4_frente_a_frente', jh2h,
    '5_los_ultimos_partidos', jsonb_build_object(
        'local', ultimos_espn(ev.home_espn_id::text, v_pref, ev.fecha, 10),
        'visitante', ultimos_espn(ev.away_espn_id::text, v_pref, ev.fecha, 10)),
    '6_lo_que_nadie_ve', coalesce(s6,'{}'::jsonb) || jsonb_build_object(
        'estadio', sede.estadio, 'ciudad', sede.ciudad, 'pais', sede.pais, 'altitud_m', v_alt,
        'el_local_juega_en_su_casa', v_en_casa,
        'ronda', ronda_es(sede.ronda), 'sitio_neutral', sede.sitio_neutral,
        'asistencia', sede.asistencia,
        'aviso', case when v_en_casa is false then 'OJO: '||ev.home_nombre||
                   ' aparece como local pero se juega en '||coalesce(sede.ciudad,'otra sede')||
                   coalesce(', '||sede.pais,'')||'. Cancha neutral: medido en 274 partidos de '
                   ||'Leagues Cup, el local de casa gana 52.6% y anota 1.75 veces mas que su rival, '
                   ||'pero el local que juega fuera de su pais gana 34.7% y la ventaja cae a 1.01. '
                   ||'Aqui NO hay ventaja de local.' end),
    '7_el_precio', coalesce(s7,'{}'::jsonb),
    '8_tendencias', jsonb_build_object('local', th, 'visitante', ta,
        'confiabilidad_del_modelo', (select jsonb_agg(to_jsonb(mc)) from modelo_confiabilidad mc
            where mc.deporte = case when ev.deporte='soccer' then 'FUTBOL'
                                    when ev.deporte like 'baseball%' then 'MLB' else 'NFL' end))
  );
end $function$
;

-- 2) v_mejores_picks_mlb [24->22 cols: DROP (0 vistas dependientes) + recreate]
DROP VIEW public.v_mejores_picks_mlb;
CREATE OR REPLACE VIEW public.v_mejores_picks_mlb AS  WITH picks AS (
         SELECT m.espn_event_id,
            m.arranca_en,
            m.liga_nombre,
            m.home_nombre,
            m.away_nombre,
            m.mercado,
            m.pick,
            m.prob,
            m.detalle,
            m.favorito,
            m.favorito_pct,
            m.confiable,
            o.ml_home,
            o.ml_away,
            o.total_linea,
            o.over_odds,
            o.under_odds
           FROM v_picks_mlb_modelo m
             LEFT JOIN odds_espn o ON o.espn_event_id = m.espn_event_id
        ), con_momio AS (
         SELECT p.espn_event_id,
            p.arranca_en,
            p.liga_nombre,
            p.home_nombre,
            p.away_nombre,
            p.mercado,
            p.pick,
            p.prob,
            p.detalle,
            p.favorito,
            p.favorito_pct,
            p.confiable,
            p.ml_home,
            p.ml_away,
            p.total_linea,
            p.over_odds,
            p.under_odds,
                CASE
                    WHEN p.mercado = 'Moneyline'::text AND p.pick = ('ML '::text || p.home_nombre) THEN p.ml_home
                    WHEN p.mercado = 'Moneyline'::text AND p.pick = ('ML '::text || p.away_nombre) THEN p.ml_away
                    WHEN p.mercado = 'Over/Under'::text AND p.pick ~~ 'Over %'::text AND p.total_linea::text = split_part(p.pick, ' '::text, 2) THEN p.over_odds
                    WHEN p.mercado = 'Over/Under'::text AND p.pick ~~ 'Under %'::text AND p.total_linea::text = split_part(p.pick, ' '::text, 2) THEN p.under_odds
                    ELSE NULL::numeric
                END AS cuota,
                CASE
                    WHEN p.mercado = 'Moneyline'::text AND p.ml_home > 1::numeric AND p.ml_away > 1::numeric THEN 1::numeric / p.ml_home + 1::numeric / p.ml_away
                    WHEN p.mercado = 'Over/Under'::text AND p.over_odds > 1::numeric AND p.under_odds > 1::numeric THEN 1::numeric / p.over_odds + 1::numeric / p.under_odds
                    ELSE NULL::numeric
                END AS suma_implicita
           FROM picks p
        ), juzgado AS (
         SELECT c.espn_event_id,
            c.arranca_en,
            c.liga_nombre,
            c.home_nombre,
            c.away_nombre,
            c.mercado,
            c.pick,
            c.prob,
            c.detalle,
            c.favorito,
            c.favorito_pct,
            c.confiable,
            c.ml_home,
            c.ml_away,
            c.total_linea,
            c.over_odds,
            c.under_odds,
            c.cuota,
            c.suma_implicita,
            filtro_pick_live(c.prob / 100::numeric, c.cuota, c.mercado, 'baseball'::text) AS f,
                CASE
                    WHEN c.suma_implicita > 0::numeric THEN round(1::numeric / c.cuota / c.suma_implicita * 100::numeric, 1)
                    ELSE NULL::numeric
                END AS mercado_sin_comision
           FROM con_momio c
          WHERE c.cuota > 1::numeric
        ), final AS (
         SELECT j.espn_event_id,
            j.arranca_en,
            j.liga_nombre,
            j.home_nombre,
            j.away_nombre,
            j.mercado,
            j.pick,
            j.prob,
            j.detalle,
            j.favorito,
            j.favorito_pct,
            j.confiable,
            j.ml_home,
            j.ml_away,
            j.total_linea,
            j.over_odds,
            j.under_odds,
            j.cuota,
            j.suma_implicita,
            j.f,
            j.mercado_sin_comision,
            ((j.f ->> 'prob_calibrada'::text)::numeric) - j.mercado_sin_comision AS brecha_pp
           FROM juzgado j
          WHERE ((j.f ->> 'pasa'::text)::boolean) AND (j.mercado <> 'Moneyline'::text OR COALESCE(j.confiable, true))
        )
 SELECT DISTINCT ON (espn_event_id) espn_event_id,
    arranca_en,
    home_nombre,
    away_nombre,
    mercado,
    pick,
    cuota,
    prob AS prob_modelo,
    (f ->> 'prob_calibrada'::text)::numeric AS prob_calibrada,
    mercado_sin_comision,
    round(brecha_pp, 1) AS ventaja_pp,
    (f ->> 'wr_necesario'::text)::numeric AS necesitas_pct,
    (f ->> 'ev_pct'::text)::numeric AS ev_pct,
    COALESCE((f ->> 'calibrado'::text)::boolean, true) AS calibrado,
        CASE
            WHEN brecha_pp >= 12::numeric THEN 'ojo'::text
            WHEN brecha_pp >= 3::numeric THEN 'fuerte'::text
            ELSE 'flojo'::text
        END AS nivel,
    detalle,
    equipo_corto(home_nombre, 'baseball'::text) AS home_corto,
    equipo_corto(away_nombre, 'baseball'::text) AS away_corto,
        CASE
            WHEN mercado = 'Moneyline'::text AND pick = ('ML '::text || home_nombre) THEN equipo_corto(home_nombre, 'baseball'::text) || ' ML'::text
            WHEN mercado = 'Moneyline'::text AND pick = ('ML '::text || away_nombre) THEN equipo_corto(away_nombre, 'baseball'::text) || ' ML'::text
            ELSE upper(pick)
        END AS etiqueta,
    equipo_corto(favorito, 'baseball'::text) AS favorito_corto,
    favorito_pct,
        CASE
            WHEN mercado = 'Moneyline'::text THEN pick = ('ML '::text || favorito)
            ELSE NULL::boolean
        END AS pick_es_favorito
   FROM final
  ORDER BY espn_event_id, ((f ->> 'ev_pct'::text)::numeric) DESC;

-- 3) v_pick_canonico [44->43 cols: DROP CASCADE + recreate vista + 3 dependientes]
DROP VIEW public.v_pick_canonico CASCADE;
CREATE OR REPLACE VIEW public.v_pick_canonico AS  SELECT espn_event_id,
    deporte,
    liga,
    home,
    away,
    arranca_en,
    mercado,
    pick_nombre,
    pick_desc,
    momio_declarado,
    probabilidad_pct,
    momio_justo,
    muestra_calibracion,
    calibracion_confiable,
    odds_source,
    odds_apertura,
    odds_cierre,
    clv_pct,
    clasificacion,
    confianza,
    razon,
    resumen,
    fuente,
    momio_mercado,
    casa,
    momio_capturado_at,
    home_ml,
    draw_ml,
    away_ml,
    prob_local_casa_pct,
    prob_visitante_casa_pct,
    ev_pct,
    edge_pct,
    prob_que_implica_el_precio_pct,
    favorito,
    favorito_pct,
    etiqueta_cuando,
    es_pick,
    es_senal,
    rank_en_partido,
    explicacion_precio,
    nivel_ventaja,
    zona_realidad(mercado, probabilidad_pct / 100.0) AS zona
   FROM ( WITH unidos AS (
                 SELECT p.espn_event_id,
                    COALESCE(ae.deporte, ls.deporte, 'soccer'::text) AS deporte,
                    p.liga,
                    p.home,
                    p.away,
                    p.arranca_en,
                    p.mercado,
                    p.pick_nombre,
                    p.pick_desc,
                    p.momio_mercado AS momio_declarado,
                        CASE
                            WHEN COALESCE(ae.deporte, ls.deporte, 'soccer'::text) ~~ 'baseball%'::text THEN prob_recalibrada_lado('MLB'::text, p.mercado, round(p.probabilidad_real * 100::numeric, 1), sin_acentos(p.pick_nombre) ~~ (('%'::text || sin_acentos(p.home)) || '%'::text) OR p.pick_nombre ~* '^(over|mas de)'::text)
                            ELSE round(p.probabilidad_real * 100::numeric, 1)
                        END AS probabilidad_pct,
                    NULL::numeric AS momio_justo,
                    NULL::integer AS muestra_calibracion,
                    NULL::boolean AS calibracion_confiable,
                    p.odds_source,
                    p.odds_apertura,
                    p.odds_cierre,
                    p.clv_pct,
                    p.clasificacion,
                    p.confianza,
                    p.razon,
                    p.resumen,
                    'motor_picks'::text AS fuente
                   FROM picks_recomendados_hoy p
                     LEFT JOIN agenda_espn ae ON ae.espn_event_id = p.espn_event_id
                     LEFT JOIN live_scores ls ON ls.espn_event_id = p.espn_event_id
                  WHERE COALESCE(ae.deporte, ls.deporte, 'soccer'::text) !~~ 'baseball%'::text
                UNION ALL
                 SELECT c.espn_event_id,
                    'soccer'::text AS text,
                    c.liga_nombre,
                    c.home_nombre,
                    c.away_nombre,
                    c.arranca_en,
                    c.mercado,
                    c.pick,
                    c.pick,
                    c.momio_casa,
                        CASE
                            WHEN c.mercado = 'Over/Under'::text AND c.pick ~* '^(over|mas de) *2\.5'::text THEN ajuste_h2h_over25(c.espn_event_id, c.probabilidad_pct)
                            ELSE c.probabilidad_pct
                        END AS probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    'motor_futbol_calibrado'::text AS text,
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::text AS text,
                    NULL::numeric AS "numeric",
                    c.como_se_calculo,
                    NULL::text AS text,
                    'motor_futbol_calibrado'::text AS text
                   FROM v_picks_futbol_calibrado c
                  WHERE (c.calibracion_confiable OR c.mercado = 'Moneyline'::text) AND c.mercado !~* '(corner|tarjeta)'::text
                UNION ALL
                 SELECT mm.espn_event_id,
                    'baseball'::text AS text,
                    mm.liga_nombre,
                    mm.home_nombre,
                    mm.away_nombre,
                    mm.arranca_en,
                    mm.mercado,
                    mm.pick,
                    mm.pick,
                    NULL::numeric AS "numeric",
                    mm.prob,
                    round(100.0 / NULLIF(mm.prob, 0::numeric), 2) AS round,
                    NULL::integer AS int4,
                    true AS bool,
                    'motor_mlb_cuantitativo'::text AS text,
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::text AS text,
                    NULL::numeric AS "numeric",
                    mm.detalle,
                    NULL::text AS text,
                    'motor_mlb_cuantitativo'::text AS text
                   FROM v_picks_mlb_modelo mm
                ), precio AS (
                 SELECT u.espn_event_id,
                    u.deporte,
                    u.liga,
                    u.home,
                    u.away,
                    u.arranca_en,
                    u.mercado,
                    u.pick_nombre,
                    u.pick_desc,
                    u.momio_declarado,
                    u.probabilidad_pct,
                    u.momio_justo,
                    u.muestra_calibracion,
                    u.calibracion_confiable,
                    u.odds_source,
                    u.odds_apertura,
                    u.odds_cierre,
                    u.clv_pct,
                    u.clasificacion,
                    u.confianza,
                    u.razon,
                    u.resumen,
                    u.fuente,
                    r.momio AS momio_mercado,
                    r.casa,
                    r.capturado AS momio_capturado_at
                   FROM unidos u
                     LEFT JOIN LATERAL momio_real_de_mercado(u.espn_event_id, u.mercado, u.pick_nombre, u.home, u.away) r(momio, casa, capturado) ON true
                ), mercado AS (
                 SELECT p.espn_event_id,
                    p.deporte,
                    p.liga,
                    p.home,
                    p.away,
                    p.arranca_en,
                    p.mercado,
                    p.pick_nombre,
                    p.pick_desc,
                    p.momio_declarado,
                    p.probabilidad_pct,
                    p.momio_justo,
                    p.muestra_calibracion,
                    p.calibracion_confiable,
                    p.odds_source,
                    p.odds_apertura,
                    p.odds_cierre,
                    p.clv_pct,
                    p.clasificacion,
                    p.confianza,
                    p.razon,
                    p.resumen,
                    p.fuente,
                    p.momio_mercado,
                    p.casa,
                    p.momio_capturado_at,
                    m_1.home_ml,
                    m_1.draw_ml,
                    m_1.away_ml,
                        CASE
                            WHEN m_1.home_ml IS NOT NULL AND m_1.away_ml IS NOT NULL THEN round(100::numeric * (1::numeric / m_1.home_ml) / (1::numeric / m_1.home_ml + 1::numeric / m_1.away_ml + COALESCE(1::numeric / NULLIF(m_1.draw_ml, 0::numeric), 0::numeric)), 1)
                            ELSE NULL::numeric
                        END AS prob_local_casa_pct,
                        CASE
                            WHEN m_1.home_ml IS NOT NULL AND m_1.away_ml IS NOT NULL THEN round(100::numeric * (1::numeric / m_1.away_ml) / (1::numeric / m_1.home_ml + 1::numeric / m_1.away_ml + COALESCE(1::numeric / NULLIF(m_1.draw_ml, 0::numeric), 0::numeric)), 1)
                            ELSE NULL::numeric
                        END AS prob_visitante_casa_pct
                   FROM precio p
                     LEFT JOIN LATERAL ( SELECT s.home_ml,
                            s.draw_ml,
                            s.away_ml
                           FROM v_radar_odds_fase s
                          WHERE s.espn_event_id = p.espn_event_id AND s.home_ml IS NOT NULL AND s.fase <> 'en_vivo'::text
                          ORDER BY s.snapshot_at DESC
                         LIMIT 1) m_1 ON true
                ), calc AS (
                 SELECT m_1.espn_event_id,
                    m_1.deporte,
                    m_1.liga,
                    m_1.home,
                    m_1.away,
                    m_1.arranca_en,
                    m_1.mercado,
                    m_1.pick_nombre,
                    m_1.pick_desc,
                    m_1.momio_declarado,
                    m_1.probabilidad_pct,
                    m_1.momio_justo,
                    m_1.muestra_calibracion,
                    m_1.calibracion_confiable,
                    m_1.odds_source,
                    m_1.odds_apertura,
                    m_1.odds_cierre,
                    m_1.clv_pct,
                    m_1.clasificacion,
                    m_1.confianza,
                    m_1.razon,
                    m_1.resumen,
                    m_1.fuente,
                    m_1.momio_mercado,
                    m_1.casa,
                    m_1.momio_capturado_at,
                    m_1.home_ml,
                    m_1.draw_ml,
                    m_1.away_ml,
                    m_1.prob_local_casa_pct,
                    m_1.prob_visitante_casa_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN (decision_economica_v1(m_1.probabilidad_pct, m_1.momio_mercado, m_1.mercado) ->> 'ev_pct'::text)::numeric
                            ELSE NULL::numeric
                        END AS ev_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round((m_1.probabilidad_pct / 100.0 - 1.0 / m_1.momio_mercado) * 100::numeric, 1)
                            ELSE NULL::numeric
                        END AS edge_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round(100.0 / m_1.momio_mercado, 1)
                            ELSE NULL::numeric
                        END AS prob_que_implica_el_precio_pct,
                        CASE
                            WHEN m_1.prob_local_casa_pct >= m_1.prob_visitante_casa_pct THEN m_1.home
                            ELSE m_1.away
                        END AS favorito,
                    GREATEST(m_1.prob_local_casa_pct, m_1.prob_visitante_casa_pct) AS favorito_pct,
                        CASE
                            WHEN (m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text)::date = (now() AT TIME ZONE 'America/Mexico_City'::text)::date THEN 'HOY '::text || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                            WHEN (m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text)::date = ((now() AT TIME ZONE 'America/Mexico_City'::text)::date + 1) THEN 'MAÑANA '::text || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                            ELSE (upper(to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'DD/MM'::text)) || ' · '::text) || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                        END AS etiqueta_cuando
                   FROM mercado m_1
                ), marcado AS (
                 SELECT c.espn_event_id,
                    c.deporte,
                    c.liga,
                    c.home,
                    c.away,
                    c.arranca_en,
                    c.mercado,
                    c.pick_nombre,
                    c.pick_desc,
                    c.momio_declarado,
                    c.probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    c.odds_source,
                    c.odds_apertura,
                    c.odds_cierre,
                    c.clv_pct,
                    c.clasificacion,
                    c.confianza,
                    c.razon,
                    c.resumen,
                    c.fuente,
                    c.momio_mercado,
                    c.casa,
                    c.momio_capturado_at,
                    c.home_ml,
                    c.draw_ml,
                    c.away_ml,
                    c.prob_local_casa_pct,
                    c.prob_visitante_casa_pct,
                    c.ev_pct,
                    c.edge_pct,
                    c.prob_que_implica_el_precio_pct,
                    c.favorito,
                    c.favorito_pct,
                    c.etiqueta_cuando,
                    (economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(c.deporte), 'mercado', c.mercado, 'fuente', c.fuente, 'model_version', NULL::text, 'model_skill', NULL::text, 'empirical_sufficiency',
                        CASE
                            WHEN COALESCE(c.muestra_calibracion, 0) >= 20 THEN 'OK'::text
                            ELSE 'PENDING'::text
                        END, 'semantic_validity',
                        CASE
                            WHEN pick_sin_discrepancia_motores(c.espn_event_id, c.mercado, c.pick_desc) THEN 'PASS'::text
                            ELSE 'FAIL'::text
                        END, 'data_readiness', 'READY', 'exact_decision_price',
                        CASE
                            WHEN exact_decision_price(c.espn_event_id, c.mercado, c.pick_desc, c.home, c.away) THEN 'true'::text
                            ELSE 'false'::text
                        END, 'market_abstention', mercado_en_abstencion(c.mercado, c.pick_desc), 'ev_pct', c.ev_pct, 'ev_threshold', 2.5)) ->> 'eligible'::text)::boolean AS es_pick,
                    c.momio_mercado IS NULL AND c.probabilidad_pct >= 70::numeric AND c.calibracion_confiable AS es_senal
                   FROM calc c
                )
         SELECT m.espn_event_id,
            m.deporte,
            m.liga,
            m.home,
            m.away,
            m.arranca_en,
            m.mercado,
                CASE
                    WHEN m.deporte = 'soccer'::text AND m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text THEN 'Gana '::text || m.home
                    WHEN m.deporte = 'soccer'::text AND m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text THEN 'Gana '::text || m.away
                    ELSE m.pick_nombre
                END AS pick_nombre,
            m.pick_desc,
            m.momio_declarado,
            m.probabilidad_pct,
            m.momio_justo,
            m.muestra_calibracion,
            m.calibracion_confiable,
            m.odds_source,
            m.odds_apertura,
            m.odds_cierre,
            m.clv_pct,
            m.clasificacion,
            m.confianza,
            m.razon,
            m.resumen,
            m.fuente,
            m.momio_mercado,
            m.casa,
            m.momio_capturado_at,
            m.home_ml,
            m.draw_ml,
            m.away_ml,
            m.prob_local_casa_pct,
            m.prob_visitante_casa_pct,
            m.ev_pct,
            m.edge_pct,
            m.prob_que_implica_el_precio_pct,
                CASE
                    WHEN COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id), '-1'::numeric) >= COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id), '-1'::numeric) AND GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) IS NOT NULL THEN m.home
                    WHEN GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) IS NOT NULL THEN m.away
                    ELSE NULL::text
                END AS favorito,
            GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) AS favorito_pct,
            m.etiqueta_cuando,
            m.es_pick,
            m.es_senal,
            row_number() OVER (PARTITION BY m.espn_event_id ORDER BY m.es_pick DESC, m.es_senal DESC, m.ev_pct DESC NULLS LAST, m.probabilidad_pct DESC) AS rank_en_partido,
                CASE
                    WHEN m.momio_mercado IS NULL THEN ('Todavia no tenemos precio de casa. Nuestro modelo le da '::text || m.probabilidad_pct) || '%.'::text
                    WHEN m.ev_pct > 0::numeric THEN ((((('La casa paga '::text || m.momio_mercado) || ', que implica '::text) || m.prob_que_implica_el_precio_pct) || '%. Nosotros le damos '::text) || m.probabilidad_pct) || '%: paga MAS de lo que vale.'::text
                    ELSE ((((('La casa paga '::text || m.momio_mercado) || ', que implica '::text) || m.prob_que_implica_el_precio_pct) || '%. Nosotros le damos '::text) || m.probabilidad_pct) || '%: paga MENOS de lo que vale. Aqui no hay apuesta.'::text
                END AS explicacion_precio,
                CASE
                    WHEN m.es_pick AND m.edge_pct >= 5::numeric THEN 'ok'::text
                    WHEN m.es_pick THEN 'ventaja_corta'::text
                    WHEN m.es_senal THEN 'alta_probabilidad'::text
                    WHEN m.momio_mercado IS NULL THEN 'sin_precio'::text
                    ELSE 'no_apostar'::text
                END AS nivel_ventaja
           FROM ( SELECT m0.espn_event_id,
                    m0.deporte,
                    m0.liga,
                    m0.home,
                    m0.away,
                    m0.arranca_en,
                    m0.mercado,
                    m0.pick_nombre,
                    m0.pick_desc,
                    m0.momio_declarado,
                    m0.probabilidad_pct,
                    m0.momio_justo,
                    m0.muestra_calibracion,
                    m0.calibracion_confiable,
                    m0.odds_source,
                    m0.odds_apertura,
                    m0.odds_cierre,
                    m0.clv_pct,
                    m0.clasificacion,
                    m0.confianza,
                    m0.razon,
                    m0.resumen,
                    m0.fuente,
                    m0.momio_mercado,
                    m0.casa,
                    m0.momio_capturado_at,
                    m0.home_ml,
                    m0.draw_ml,
                    m0.away_ml,
                    m0.prob_local_casa_pct,
                    m0.prob_visitante_casa_pct,
                    m0.ev_pct,
                    m0.edge_pct,
                    m0.prob_que_implica_el_precio_pct,
                    m0.favorito,
                    m0.favorito_pct,
                    m0.etiqueta_cuando,
                    m0.es_pick,
                    m0.es_senal,
                    row_number() OVER (PARTITION BY m0.espn_event_id, (
                        CASE
                            WHEN m0.deporte = 'soccer'::text AND m0.mercado = 'Moneyline'::text THEN
                            CASE
                                WHEN m0.pick_nombre ~* '^gana +local'::text OR sin_acentos(m0.pick_nombre) ~~ (('%'::text || sin_acentos(m0.home)) || '%'::text) THEN 'ML|local'::text
                                WHEN m0.pick_nombre ~* '^gana +visitante'::text OR sin_acentos(m0.pick_nombre) ~~ (('%'::text || sin_acentos(m0.away)) || '%'::text) THEN 'ML|visita'::text
                                WHEN m0.pick_nombre ~~* '%empate%'::text THEN 'ML|empate'::text
                                ELSE 'ML|'::text || m0.pick_nombre
                            END
                            ELSE (m0.mercado || '|'::text) || m0.pick_nombre
                        END) ORDER BY (m0.fuente = 'motor_futbol_calibrado'::text) DESC, m0.muestra_calibracion DESC NULLS LAST) AS rn_dup
                   FROM marcado m0) m
          WHERE m.rn_dup = 1 AND (m.mercado = 'Moneyline'::text OR m.mercado = 'BTTS'::text OR m.mercado = 'Over/Under'::text AND (m.deporte ~~ 'baseball%'::text OR m.deporte ~~ 'football%'::text OR m.pick_nombre ~* '^(over|mas de) *2\.5'::text OR m.pick_nombre ~* '^(over|under|mas de|menos de) *3\.5'::text))) v
  WHERE espn_event_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM agenda_espn a
          WHERE a.espn_event_id = v.espn_event_id AND NOT (EXISTS ( SELECT 1
                   FROM ligas_bloqueadas b
                  WHERE b.tipo = 'endpoint'::text AND a.espn_endpoint ~~ b.patron))));
CREATE OR REPLACE VIEW public.lab_dq_medicion_v1 AS  WITH od AS (
         SELECT DISTINCT ON (radar_odds_snapshots.espn_event_id) radar_odds_snapshots.espn_event_id,
            radar_odds_snapshots.snapshot_at,
            radar_odds_snapshots.confiable,
            radar_odds_snapshots.bookmaker
           FROM radar_odds_snapshots
          ORDER BY radar_odds_snapshots.espn_event_id, radar_odds_snapshots.snapshot_at DESC
        )
 SELECT p.espn_event_id,
    p.mercado,
    p.home,
    p.away,
    p.arranca_en,
    p.momio_mercado,
    od.espn_event_id IS NOT NULL AS odds_snapshot_presente,
    p.momio_mercado IS NOT NULL AS odds_en_pick,
    round(EXTRACT(epoch FROM now() - od.snapshot_at) / 3600.0, 1) AS odds_edad_h,
    od.snapshot_at IS NOT NULL AND (now() - od.snapshot_at) <= '06:00:00'::interval AS odds_dentro_ventana_6h,
    od.confiable AS odds_confiable,
    round(EXTRACT(epoch FROM now() - ae.actualizado_at) / 3600.0, 1) AS agenda_edad_h,
    ae.actualizado_at IS NOT NULL AND (now() - ae.actualizado_at) <= '24:00:00'::interval AS agenda_dentro_ventana_24h,
    ae.estado AS agenda_estado,
    'NO_MEDIDO_FIABLE'::text AS hist_goles_coverage,
    'REQUIERE_RESOLVER_ALIAS'::text AS hist_goles_freshness,
    'NO_MEDIDO'::text AS data_readiness
   FROM v_pick_canonico p
     LEFT JOIN od ON od.espn_event_id = p.espn_event_id
     LEFT JOIN agenda_espn ae ON ae.espn_event_id = p.espn_event_id
  WHERE p.deporte = 'soccer'::text;
CREATE OR REPLACE VIEW public.v_lab_dq_capturas_faltantes AS  SELECT espn_event_id,
    mercado,
    pick_nombre,
    (((espn_event_id || '|'::text) || mercado) || '|'::text) || pick_nombre AS pick_id,
    arranca_en,
    'DQ_CAPTURE_MISSED'::text AS estado,
    'reconciliar: capturar en el flujo; NO reconstruir estado historico'::text AS accion
   FROM v_pick_canonico p
  WHERE deporte = 'soccer'::text AND arranca_en > (now() - '03:00:00'::interval) AND NOT (EXISTS ( SELECT 1
           FROM lab_dq_decision d
          WHERE d.pick_id = ((((p.espn_event_id || '|'::text) || p.mercado) || '|'::text) || p.pick_nombre)));
CREATE OR REPLACE VIEW public.v_oraculo_canonico AS  WITH sugerido AS (
         SELECT o.espn_event_id,
            o.liga,
            o.created_at,
            o.home,
            o.away,
            o.odds_source,
            o.pick_nombre,
            o.pick_desc,
            o.mercado,
            o.ev_estimado,
            o.ev_numerico,
            o.confianza,
            o.momio_mercado,
            o.probabilidad_real,
            o.kelly_pct,
            o.odds_verificadas,
            o.razon,
            o.resumen,
            o.clasificacion,
            o.score_combinado,
            o.arranca_en,
            o.edge_real,
            o.momio_fabricado,
            o.odds_apertura,
            o.odds_cierre,
            o.clv_pct,
            regexp_replace(lower(COALESCE(o.pick_nombre, o.pick_desc, ''::text)), '[^a-z0-9]'::text, ''::text, 'g'::text) AS k
           FROM picks_recomendados_hoy o
        ), canon AS (
         SELECT c_1.espn_event_id,
            c_1.deporte,
            c_1.liga,
            c_1.home,
            c_1.away,
            c_1.arranca_en,
            c_1.mercado,
            c_1.pick_nombre,
            c_1.pick_desc,
            c_1.momio_declarado,
            c_1.probabilidad_pct,
            c_1.momio_justo,
            c_1.muestra_calibracion,
            c_1.calibracion_confiable,
            c_1.odds_source,
            c_1.odds_apertura,
            c_1.odds_cierre,
            c_1.clv_pct,
            c_1.clasificacion,
            c_1.confianza,
            c_1.razon,
            c_1.resumen,
            c_1.fuente,
            c_1.momio_mercado,
            c_1.casa,
            c_1.momio_capturado_at,
            c_1.home_ml,
            c_1.draw_ml,
            c_1.away_ml,
            c_1.prob_local_casa_pct,
            c_1.prob_visitante_casa_pct,
            c_1.ev_pct,
            c_1.edge_pct,
            c_1.prob_que_implica_el_precio_pct,
            c_1.favorito,
            c_1.favorito_pct,
            c_1.etiqueta_cuando,
            c_1.es_pick,
            c_1.es_senal,
            c_1.rank_en_partido,
            c_1.explicacion_precio,
            c_1.nivel_ventaja,
            c_1.zona,
            regexp_replace(lower(COALESCE(c_1.pick_nombre, c_1.pick_desc, ''::text)), '[^a-z0-9]'::text, ''::text, 'g'::text) AS k
           FROM v_pick_canonico c_1
          WHERE c_1.es_pick
        )
 SELECT s.espn_event_id,
    s.liga,
    s.created_at,
    c.arranca_en,
    c.mercado,
    c.pick_nombre,
    c.pick_desc,
    c.home,
    c.away,
    c.deporte,
    s.score_combinado,
    c.probabilidad_pct,
    c.ev_pct,
    c.edge_pct,
    c.momio_mercado,
    c.momio_justo,
    c.casa,
    c.nivel_ventaja,
    c.zona,
    c.explicacion_precio,
    c.muestra_calibracion,
    c.calibracion_confiable,
    c.odds_apertura,
    c.odds_cierre,
    c.clv_pct,
    c.clasificacion,
    c.confianza,
    c.fuente,
    c.favorito,
    c.favorito_pct,
    c.rank_en_partido,
    c.etiqueta_cuando,
    NULL::text AS razon,
    NULL::text AS resumen,
    NULL::numeric AS kelly_pct
   FROM sugerido s
     JOIN canon c ON c.espn_event_id = s.espn_event_id AND c.k = s.k;

-- 4) OWNER + reloptions + GRANTS (reponer; el DROP los borro)
ALTER VIEW public.lab_dq_medicion_v1 OWNER TO postgres;
ALTER VIEW public.v_lab_dq_capturas_faltantes OWNER TO postgres;
ALTER VIEW public.v_mejores_picks_mlb OWNER TO postgres;
ALTER VIEW public.v_oraculo_canonico OWNER TO postgres;
ALTER VIEW public.v_pick_canonico OWNER TO postgres;

GRANT DELETE ON public.lab_dq_medicion_v1 TO service_role;
GRANT DELETE ON public.lab_dq_medicion_v1 TO authenticated;
GRANT DELETE ON public.lab_dq_medicion_v1 TO postgres;
GRANT DELETE ON public.lab_dq_medicion_v1 TO anon;
GRANT INSERT ON public.lab_dq_medicion_v1 TO service_role;
GRANT INSERT ON public.lab_dq_medicion_v1 TO anon;
GRANT INSERT ON public.lab_dq_medicion_v1 TO authenticated;
GRANT INSERT ON public.lab_dq_medicion_v1 TO postgres;
GRANT MAINTAIN ON public.lab_dq_medicion_v1 TO anon;
GRANT MAINTAIN ON public.lab_dq_medicion_v1 TO postgres;
GRANT MAINTAIN ON public.lab_dq_medicion_v1 TO service_role;
GRANT MAINTAIN ON public.lab_dq_medicion_v1 TO authenticated;
GRANT REFERENCES ON public.lab_dq_medicion_v1 TO authenticated;
GRANT REFERENCES ON public.lab_dq_medicion_v1 TO postgres;
GRANT REFERENCES ON public.lab_dq_medicion_v1 TO service_role;
GRANT REFERENCES ON public.lab_dq_medicion_v1 TO anon;
GRANT SELECT ON public.lab_dq_medicion_v1 TO service_role;
GRANT SELECT ON public.lab_dq_medicion_v1 TO anon;
GRANT SELECT ON public.lab_dq_medicion_v1 TO postgres;
GRANT SELECT ON public.lab_dq_medicion_v1 TO authenticated;
GRANT TRIGGER ON public.lab_dq_medicion_v1 TO anon;
GRANT TRIGGER ON public.lab_dq_medicion_v1 TO service_role;
GRANT TRIGGER ON public.lab_dq_medicion_v1 TO postgres;
GRANT TRIGGER ON public.lab_dq_medicion_v1 TO authenticated;
GRANT TRUNCATE ON public.lab_dq_medicion_v1 TO authenticated;
GRANT TRUNCATE ON public.lab_dq_medicion_v1 TO service_role;
GRANT TRUNCATE ON public.lab_dq_medicion_v1 TO anon;
GRANT TRUNCATE ON public.lab_dq_medicion_v1 TO postgres;
GRANT UPDATE ON public.lab_dq_medicion_v1 TO anon;
GRANT UPDATE ON public.lab_dq_medicion_v1 TO postgres;
GRANT UPDATE ON public.lab_dq_medicion_v1 TO authenticated;
GRANT UPDATE ON public.lab_dq_medicion_v1 TO service_role;
GRANT DELETE ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT DELETE ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT DELETE ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT DELETE ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT INSERT ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT INSERT ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT INSERT ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT INSERT ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT MAINTAIN ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT MAINTAIN ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT MAINTAIN ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT MAINTAIN ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT REFERENCES ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT REFERENCES ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT REFERENCES ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT REFERENCES ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT SELECT ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT SELECT ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT SELECT ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT SELECT ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT TRIGGER ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT TRIGGER ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT TRIGGER ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT TRIGGER ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT TRUNCATE ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT TRUNCATE ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT TRUNCATE ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT TRUNCATE ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT UPDATE ON public.v_lab_dq_capturas_faltantes TO service_role;
GRANT UPDATE ON public.v_lab_dq_capturas_faltantes TO postgres;
GRANT UPDATE ON public.v_lab_dq_capturas_faltantes TO authenticated;
GRANT UPDATE ON public.v_lab_dq_capturas_faltantes TO anon;
GRANT DELETE ON public.v_mejores_picks_mlb TO postgres;
GRANT DELETE ON public.v_mejores_picks_mlb TO service_role;
GRANT INSERT ON public.v_mejores_picks_mlb TO service_role;
GRANT INSERT ON public.v_mejores_picks_mlb TO postgres;
GRANT MAINTAIN ON public.v_mejores_picks_mlb TO service_role;
GRANT MAINTAIN ON public.v_mejores_picks_mlb TO postgres;
GRANT REFERENCES ON public.v_mejores_picks_mlb TO service_role;
GRANT REFERENCES ON public.v_mejores_picks_mlb TO postgres;
GRANT SELECT ON public.v_mejores_picks_mlb TO service_role;
GRANT SELECT ON public.v_mejores_picks_mlb TO postgres;
GRANT SELECT ON public.v_mejores_picks_mlb TO anon;
GRANT SELECT ON public.v_mejores_picks_mlb TO authenticated;
GRANT TRIGGER ON public.v_mejores_picks_mlb TO service_role;
GRANT TRIGGER ON public.v_mejores_picks_mlb TO postgres;
GRANT TRUNCATE ON public.v_mejores_picks_mlb TO postgres;
GRANT TRUNCATE ON public.v_mejores_picks_mlb TO service_role;
GRANT UPDATE ON public.v_mejores_picks_mlb TO postgres;
GRANT UPDATE ON public.v_mejores_picks_mlb TO service_role;
GRANT DELETE ON public.v_oraculo_canonico TO service_role;
GRANT DELETE ON public.v_oraculo_canonico TO postgres;
GRANT DELETE ON public.v_oraculo_canonico TO anon;
GRANT DELETE ON public.v_oraculo_canonico TO authenticated;
GRANT INSERT ON public.v_oraculo_canonico TO anon;
GRANT INSERT ON public.v_oraculo_canonico TO service_role;
GRANT INSERT ON public.v_oraculo_canonico TO authenticated;
GRANT INSERT ON public.v_oraculo_canonico TO postgres;
GRANT MAINTAIN ON public.v_oraculo_canonico TO anon;
GRANT MAINTAIN ON public.v_oraculo_canonico TO postgres;
GRANT MAINTAIN ON public.v_oraculo_canonico TO service_role;
GRANT MAINTAIN ON public.v_oraculo_canonico TO authenticated;
GRANT REFERENCES ON public.v_oraculo_canonico TO postgres;
GRANT REFERENCES ON public.v_oraculo_canonico TO anon;
GRANT REFERENCES ON public.v_oraculo_canonico TO authenticated;
GRANT REFERENCES ON public.v_oraculo_canonico TO service_role;
GRANT SELECT ON public.v_oraculo_canonico TO service_role;
GRANT SELECT ON public.v_oraculo_canonico TO anon;
GRANT SELECT ON public.v_oraculo_canonico TO authenticated;
GRANT SELECT ON public.v_oraculo_canonico TO postgres;
GRANT TRIGGER ON public.v_oraculo_canonico TO service_role;
GRANT TRIGGER ON public.v_oraculo_canonico TO authenticated;
GRANT TRIGGER ON public.v_oraculo_canonico TO postgres;
GRANT TRIGGER ON public.v_oraculo_canonico TO anon;
GRANT TRUNCATE ON public.v_oraculo_canonico TO service_role;
GRANT TRUNCATE ON public.v_oraculo_canonico TO anon;
GRANT TRUNCATE ON public.v_oraculo_canonico TO postgres;
GRANT TRUNCATE ON public.v_oraculo_canonico TO authenticated;
GRANT UPDATE ON public.v_oraculo_canonico TO anon;
GRANT UPDATE ON public.v_oraculo_canonico TO postgres;
GRANT UPDATE ON public.v_oraculo_canonico TO authenticated;
GRANT UPDATE ON public.v_oraculo_canonico TO service_role;
GRANT DELETE ON public.v_pick_canonico TO anon;
GRANT DELETE ON public.v_pick_canonico TO service_role;
GRANT DELETE ON public.v_pick_canonico TO authenticated;
GRANT DELETE ON public.v_pick_canonico TO postgres;
GRANT INSERT ON public.v_pick_canonico TO postgres;
GRANT INSERT ON public.v_pick_canonico TO anon;
GRANT INSERT ON public.v_pick_canonico TO authenticated;
GRANT INSERT ON public.v_pick_canonico TO service_role;
GRANT MAINTAIN ON public.v_pick_canonico TO anon;
GRANT MAINTAIN ON public.v_pick_canonico TO postgres;
GRANT MAINTAIN ON public.v_pick_canonico TO authenticated;
GRANT MAINTAIN ON public.v_pick_canonico TO service_role;
GRANT REFERENCES ON public.v_pick_canonico TO service_role;
GRANT REFERENCES ON public.v_pick_canonico TO anon;
GRANT REFERENCES ON public.v_pick_canonico TO authenticated;
GRANT REFERENCES ON public.v_pick_canonico TO postgres;
GRANT SELECT ON public.v_pick_canonico TO postgres;
GRANT SELECT ON public.v_pick_canonico TO service_role;
GRANT SELECT ON public.v_pick_canonico TO anon;
GRANT SELECT ON public.v_pick_canonico TO authenticated;
GRANT TRIGGER ON public.v_pick_canonico TO service_role;
GRANT TRIGGER ON public.v_pick_canonico TO postgres;
GRANT TRIGGER ON public.v_pick_canonico TO anon;
GRANT TRIGGER ON public.v_pick_canonico TO authenticated;
GRANT TRUNCATE ON public.v_pick_canonico TO anon;
GRANT TRUNCATE ON public.v_pick_canonico TO authenticated;
GRANT TRUNCATE ON public.v_pick_canonico TO service_role;
GRANT TRUNCATE ON public.v_pick_canonico TO postgres;
GRANT UPDATE ON public.v_pick_canonico TO authenticated;
GRANT UPDATE ON public.v_pick_canonico TO postgres;
GRANT UPDATE ON public.v_pick_canonico TO service_role;
GRANT UPDATE ON public.v_pick_canonico TO anon;

COMMIT;
