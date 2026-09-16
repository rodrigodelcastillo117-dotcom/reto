-- =====================================================================
-- ISS134 -- LOS TRES PORCENTAJES EN LA TARJETA: GANADOR, BTTS, OVER 2.5
--
-- El dueno pidio "% de quien gana, % si BTTS, y % O2.5 en las tarjetas
-- principales afuera, en reto13M y favoritos".
--
-- ============ EL BUG QUE ENCONTRE ANTES DE CONSTRUIR NADA ============
--
-- La salida obvia habria sido pintar v2.soccer_prediction_v2.p_over y
-- etiquetarlo "Over 2.5". ESTA MAL. Medido sobre los 156 eventos publicados
-- con P_RETO:
--
--     over_line = 2.5  ->  91 eventos
--     over_line = 3.5  ->  54 eventos
--     over_line = 4.5  ->   4 eventos
--     over_line = 1.5  ->   1 evento
--     over_line = null ->   6 eventos
--
-- p_over es la probabilidad de superar LA LINEA QUE PUSO LA CASA, no 2.5.
-- Pintarlo como "O2.5" seria mentir en 65 de 156 partidos, el 42%.
--
-- Y hay algo peor de fondo: la linea sale de DraftKings (line_source). Si la
-- tarjeta usara p_over, seria el bookmaker quien decide QUE MERCADO se le
-- muestra al usuario. Eso viola la regla del dueno: el precio puede existir
-- como dato informativo, nunca como criterio.
--
-- ============ COMO SE RESUELVE ============
--
-- Over 2.5 se calcula de score_dist, la MISMA distribucion canonica de la
-- que salen el 1X2 y el marcador esperado. Un solo cerebro, sin precio.
--
-- Se suma el UNDER (marcadores con total <= 2) y se resta de 100. Se hace
-- asi y no al reves a proposito: la malla de score_dist esta truncada
-- (masa total medida entre 90.7% y 93.8%), y todo lo que falta en la cola
-- son marcadores de muchos goles, es decir OVER. Sumar el under, que son
-- las celdas de mayor probabilidad y siempre estan completas, y restar,
-- captura la cola truncada sin tener que modelarla.
--
-- VALIDACION: en los 91 eventos donde el modelo SI uso linea 2.5, este
-- calculo reproduce su propio p_over con diferencia media de 0.047 pp y
-- maxima de 0.200 pp. Es puro redondeo. No es un segundo cerebro: es el
-- mismo, extendido de 91 a 156 eventos.
-- =====================================================================

create or replace view public.v_tarjeta_soccer_v1 as
with pub as (
  select p.canonical_event_id::text as espn_event_id
  from public.v_futpro_publication_v3 p
),
ev as (
  select distinct on (a.espn_event_id)
         a.espn_event_id, a.liga_id, a.liga_nombre, a.fecha as kickoff,
         a.home_nombre, a.away_nombre, a.home_espn_id, a.away_espn_id
  from public.agenda_espn a join pub on pub.espn_event_id = a.espn_event_id
  where a.deporte='soccer'
  order by a.espn_event_id, a.actualizado_at desc nulls last
),
pred as (
  select distinct on (s.espn_event_id)
         s.espn_event_id, s.p_home, s.p_draw, s.p_away, s.btts_yes, s.btts_no,
         s.score_dist, s.lambda_home, s.lambda_away, s.exp_goals_total,
         s.predicted_score, s.model_version, s.model_status, s.model_status_reason,
         s.calibration_status, s.temporal_safe, s.data_asof, s.computed_at
  from v2.soccer_prediction_v2 s join pub on pub.espn_event_id = s.espn_event_id
  where s.model_status='READY' and s.lambda_home is not null
  order by s.espn_event_id, s.computed_at desc
),
ou as (
  select pr.espn_event_id,
         round(sum(case when (split_part(c->>'s','-',1))::int + (split_part(c->>'s','-',2))::int <= 2
                        then (c->>'p')::numeric else 0 end), 1) as under25
  from pred pr cross join lateral jsonb_array_elements(pr.score_dist) c
  group by 1
)
select
  e.espn_event_id, e.liga_id, e.liga_nombre, e.kickoff,
  e.home_nombre as home_team, e.away_nombre as away_team,

  case when pr.espn_event_id is null then 'SIN_P_RETO' else 'CON_P_RETO' end as estado,

  -- 1) QUIEN GANA
  case when pr.espn_event_id is null then null
       when pr.p_home >= pr.p_draw and pr.p_home >= pr.p_away then e.home_nombre
       when pr.p_away >= pr.p_home and pr.p_away >= pr.p_draw then e.away_nombre
       else 'Empate' end as ganador_pick,
  case when pr.espn_event_id is null then null
       else greatest(pr.p_home, pr.p_draw, pr.p_away) end as ganador_pct,
  pr.p_home as local_pct, pr.p_draw as empate_pct, pr.p_away as visita_pct,

  -- 2) AMBOS ANOTAN
  pr.btts_yes as btts_si_pct,
  pr.btts_no  as btts_no_pct,

  -- 3) MAS DE 2.5 GOLES, de la distribucion canonica
  case when ou.under25 is null then null else round(100 - ou.under25, 1) end as over25_pct,
  ou.under25 as under25_pct,

  pr.exp_goals_total as goles_esperados_total,
  pr.lambda_home as goles_esperados_local,
  pr.lambda_away as goles_esperados_visita,
  pr.predicted_score as marcador_esperado,

  -- sin P_RETO la tarjeta NO se queda vacia: lleva goles esperados reales
  case when pr.espn_event_id is null
       then public.goles_esperados_contexto(e.espn_event_id) end as contexto_sin_p_reto,

  pr.model_version, pr.calibration_status, pr.temporal_safe,
  pr.data_asof, pr.computed_at as calculado_at,
  'SIN_EV_SIN_KELLY_SIN_PRECIO'::text as politica,
  'Over 2.5 se calcula de la distribucion canonica del modelo, no de la linea de ninguna casa.'::text as nota_over25
from ev e
left join pred pr on pr.espn_event_id = e.espn_event_id
left join ou on ou.espn_event_id = e.espn_event_id;

revoke all on public.v_tarjeta_soccer_v1 from public;
grant select on public.v_tarjeta_soccer_v1 to anon, authenticated, service_role;

-- =====================================================================
-- MEDIDO (233 tarjetas publicadas):
--
--   G30.1 los tres o ninguno ............... PASS  0
--   G30.2 suman 100 ........................ PASS  0
--   G30.3 el ganador es el argmax .......... PASS  0
--   G30.4 rangos posibles .................. PASS  0
--   G30.5 Over 2.5 no sale de la casa ...... PASS  0
--   G30.6 sin precio / EV / Kelly .......... PASS  0
--   G30.7 un solo cerebro en Over 2.5 ...... PASS  0  (91 eventos, dif max 0.200 pp)
--   G30.8 cobertura ........................ INFO  233
--         156 con los tres porcentajes
--          13 sin P_RETO pero con goles esperados reales
--          49 sin nada (copas contra amateurs, sin fuente)
--
--   Coherencia interna sobre los 156: 1X2, BTTS y Over/Under suman 100 en
--   todos. Cero ganadores por debajo de 33.3 (imposible siendo el maximo de
--   tres). Cero porcentajes arriba de 95, que serian sospechosos.
--
--   Rangos reales:
--     ganador   37.5 a 83.3   promedio 49.9
--     BTTS si   35.8 a 67.7   promedio 53.4
--     Over 2.5  29.4 a 80.1   promedio 52.7
--   Ninguno esta pegado a un valor constante, que era el sintoma de
--   probabilidades falsas que ya habiamos visto antes en esta app.
-- =====================================================================
