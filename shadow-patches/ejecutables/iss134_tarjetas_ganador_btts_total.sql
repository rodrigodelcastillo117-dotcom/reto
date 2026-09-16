-- =====================================================================
-- ISS134 -- LOS TRES DE LA TARJETA: GANADOR, BTTS Y TOTAL DE GOLES
--
-- El dueno pidio "% de quien gana, % si BTTS, y % O2.5 en las tarjetas
-- principales de reto13M y favoritos". Lo construi mal la primera vez y el
-- dueno lo corrigio: "Usar la Linea Real de los partidos. Si es O2.5 o 3.5
-- o 4.5. Igual que en MLB, usar la linea de carreras."
--
-- Tiene razon, y aqui queda por que.
--
-- ============ MI PRIMER DISENO Y POR QUE ESTABA PEOR ============
--
-- Yo detecte un problema real: over_line NO siempre es 2.5.
--     2.5 -> 91 eventos | 3.5 -> 54 | 4.5 -> 4 | 1.5 -> 1 | null -> 6
-- Pintar p_over como "Over 2.5" mentiria en 65 de 156 partidos.
--
-- Mi solucion fue forzar TODO a 2.5 calculandolo de score_dist. Eso arregla
-- la etiqueta pero rompe algo mas importante: le muestra al usuario un
-- mercado que NO EXISTE para ese partido. Si la casa solo ofrece 3.5, un
-- "Over 2.5: 71%" es un numero correcto sobre una pregunta que nadie hizo.
--
-- ============ LA DISTINCION QUE ME FALTABA ============
--
--   La LINEA es una PREGUNTA.  El MOMIO es un PRECIO.
--
-- La regla del dueno prohibe que el PRECIO decida: nada de EV, Kelly, ni
-- probabilidad implicada del momio. No prohibe responder la pregunta que el
-- mercado plantea. MLB ya funciona asi: muestra la linea de carreras (8.5) y
-- la probabilidad del modelo para ESA linea. Futbol ahora hace lo mismo.
--
--   La casa define QUE se pregunta. El modelo define la RESPUESTA.
--   El precio no entra en el numero, ni ordena, ni filtra, ni autoriza.
--
-- ============ POR QUE USO p_over DEL MODELO Y NO MI CALCULO ============
--
-- Verifique mi calculo desde score_dist contra el p_over del modelo, por linea:
--     linea 2.5 (91 ev): dif media 0.047 pp, maxima 0.200
--     linea 3.5 (54 ev): dif media 0.161 pp, maxima 1.100
--     linea 4.5 ( 4 ev): dif media 0.725 pp, maxima 1.500
--     linea 1.5 ( 1 ev): dif 0.000
--
-- La diferencia CRECE con la linea. La razon: score_dist esta truncada (masa
-- medida entre 90.7% y 96.8%) y lo que falta en la cola son marcadores de
-- muchos goles, que pesan mas justo en las lineas altas. El p_over del
-- modelo sale de la distribucion completa.
--
-- O sea: para la linea real, EL NUMERO DEL MODELO ES MAS EXACTO QUE EL MIO.
-- Uso el suyo. Un solo cerebro, y ademas el mejor de los dos.
--
-- ============ QUE SE MUESTRA ============
--
--   linea_total / over_pct / under_pct / push_pct / linea_fuente
--       La linea real y la probabilidad del modelo para ella. Es lo primario.
--       push_pct sale 0 hoy porque todas las lineas son .5, pero se calcula
--       de verdad por si alguna vez llega una entera; asi no se rompe callado.
--
--   over25_norm_pct / under25_norm_pct
--       Over 2.5 normalizado, de score_dist. Existe SOLO para poder comparar
--       partidos entre si cuando sus lineas difieren. No es el mercado real
--       y va etiquetado como normalizado.
--
--   linea_estado = 'SIN_LINEA_DE_CASA' en los 6 eventos sin linea.
--       Ahi over_pct va en NULL. No se inventa una linea.
-- =====================================================================

drop view if exists public.v_tarjeta_soccer_v1;

create view public.v_tarjeta_soccer_v1 as
with pub as (
  select p.canonical_event_id::text as espn_event_id from public.v_futpro_publication_v3 p
),
ev as (
  select distinct on (a.espn_event_id)
         a.espn_event_id, a.liga_id, a.liga_nombre, a.fecha as kickoff,
         a.home_nombre, a.away_nombre
  from public.agenda_espn a join pub on pub.espn_event_id = a.espn_event_id
  where a.deporte='soccer'
  order by a.espn_event_id, a.actualizado_at desc nulls last
),
pred as (
  select distinct on (s.espn_event_id)
         s.espn_event_id, s.p_home, s.p_draw, s.p_away, s.btts_yes, s.btts_no,
         s.score_dist, s.lambda_home, s.lambda_away, s.exp_goals_total, s.predicted_score,
         s.over_line, s.p_over, s.p_under, s.line_source,
         s.model_version, s.calibration_status, s.temporal_safe, s.data_asof, s.computed_at
  from v2.soccer_prediction_v2 s join pub on pub.espn_event_id = s.espn_event_id
  where s.model_status='READY' and s.lambda_home is not null
  order by s.espn_event_id, s.computed_at desc
),
norm as (
  select pr.espn_event_id,
         round(sum(case when (split_part(c->>'s','-',1))::int + (split_part(c->>'s','-',2))::int <= 2
                        then (c->>'p')::numeric else 0 end), 1) as under25
  from pred pr cross join lateral jsonb_array_elements(pr.score_dist) c
  group by 1
),
push as (
  select pr.espn_event_id,
         round(sum(case when pr.over_line is not null
                         and pr.over_line = floor(pr.over_line)
                         and (split_part(c->>'s','-',1))::int + (split_part(c->>'s','-',2))::int = pr.over_line::int
                        then (c->>'p')::numeric else 0 end), 1) as push_pct
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

  -- 3) TOTAL DE GOLES EN LA LINEA REAL, igual que MLB con las carreras
  pr.over_line   as linea_total,
  pr.p_over      as over_pct,
  pr.p_under     as under_pct,
  coalesce(push.push_pct, 0) as push_pct,
  pr.line_source as linea_fuente,
  case when pr.espn_event_id is null then null
       when pr.over_line is null then 'SIN_LINEA_DE_CASA'
       else 'LINEA_REAL_DEL_PARTIDO' end as linea_estado,

  -- 3b) Over 2.5 normalizado, SOLO para comparar partidos entre si
  case when norm.under25 is null then null else round(100 - norm.under25, 1) end as over25_norm_pct,
  norm.under25 as under25_norm_pct,

  pr.exp_goals_total as goles_esperados_total,
  pr.lambda_home as goles_esperados_local,
  pr.lambda_away as goles_esperados_visita,
  pr.predicted_score as marcador_esperado,

  case when pr.espn_event_id is null
       then public.goles_esperados_contexto(e.espn_event_id) end as contexto_sin_p_reto,

  pr.model_version, pr.calibration_status, pr.temporal_safe,
  pr.data_asof, pr.computed_at as calculado_at,
  'SIN_EV_SIN_KELLY_EL_PRECIO_NO_DECIDE'::text as politica,
  'La linea viene de la casa; la probabilidad viene del modelo. over25_norm_pct existe solo para comparar partidos con lineas distintas.'::text as nota_total
from ev e
left join pred pr on pr.espn_event_id = e.espn_event_id
left join norm on norm.espn_event_id = e.espn_event_id
left join push on push.espn_event_id = e.espn_event_id;

revoke all on public.v_tarjeta_soccer_v1 from public;
grant select on public.v_tarjeta_soccer_v1 to anon, authenticated, service_role;

-- =====================================================================
-- MEDIDO, 233 tarjetas:
--
--   G30.1  los tres o ninguno .............. PASS  0
--   G30.2  suman 100 (con push) ............ PASS  0
--   G30.3  el ganador es el argmax ......... PASS  0
--   G30.4  rangos posibles ................. PASS  0
--   G30.5  la linea declara su fuente ...... PASS  0
--   G30.6  sin momios / EV / Kelly ......... PASS  0
--   G30.7  la prob ES la del modelo ........ PASS  0   (150 tarjetas contrastadas)
--   G30.8  monotonia de lineas ............. PASS  0
--   G30.9  sin linea no se inventa ......... PASS  0
--   G30.10 cobertura ....................... INFO  233
--          156 con ganador y BTTS | 150 con linea real | 6 sin linea de casa
--          13 sin P_RETO pero con goles esperados reales
--
-- G30.8 es la que mas me importa: verifica que no exista un imposible
-- fisico, que superar una linea alta salga mas probable que superar una
-- baja. Medido por linea, la monotonia se cumple:
--     linea 1.5 -> over 59.0  vs  Over 2.5 normalizado 32.8
--     linea 2.5 -> over 48.6  vs  48.6   (identicos, como debe ser)
--     linea 3.5 -> over 36.5  vs  58.7
--     linea 4.5 -> over 31.7  vs  71.6
--
-- Y G30.7 verifica que el numero publicado sea BYTE A BYTE el del modelo
-- canonico (tolerancia 0.01 pp), no una recalculo paralelo. Un solo cerebro.
-- =====================================================================
