-- baseline/picks_recomendados_hoy.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. NO tenia definicion en Git.
--
-- ESTA VISTA ES LA CAPA DE HIGIENE SOBRE picks_recomendados_hoy_raw, Y LO QUE
-- HACE BIEN HAY QUE DECIRLO, porque es lo mejor escrito del sistema:
--
--   arranca_en > now()
--       solo prospectivo. Nada de picks sobre partidos ya jugados.
--
--   created_at <= arranca_en
--       GUARDA ANTI-LOOKAHEAD REAL. El analisis tuvo que existir ANTES del
--       saque. Es la regla temporal del dueno escrita en SQL, y aqui si esta.
--
--   NOT momio_fabricado,  donde
--       momio_fabricado = abs(momio_mercado - 1.0/probabilidad_real) < 0.05
--       Detecta el caso en que el supuesto "precio de la casa" es solo el
--       inverso de NUESTRA propia probabilidad, o sea un momio inventado a
--       partir del modelo y presentado como dato de mercado. Es una prueba de
--       integridad genuinamente buena y no la escribi yo.
--
--   NOT momio_fantasma            precio que ya no corresponde al partido
--   NOT vetado_por_leccion        veto por lecciones_aprendidas con bloqueo_total
--   mercado !~* '(corner|tarjeta|card)'   fuera los nichos
--   NOT pick_en_cuarentena(...)   el envoltorio de Under/Over 3.5 (ISS100/101)
--
--   row_number() con precedencia de PROVEEDOR en el desempate:
--       id numerico (ESPN) = 1, 'af:%' (API-Football) = 2, otro = 3
--       Deduplica el mismo pick llegado por dos proveedores y se queda con el
--       de ESPN. Es manejo correcto de espacios de id, no una mezcla silenciosa.
--
--   precio_de_casa_real: marca si odds_source empieza con libro:, the_odds_api,
--       radar_odds_real, TheOddsAPI, DraftKings o Pinnacle. Se calcula pero NO
--       se usa en el WHERE ni se expone en la salida. Queda como senal muerta.
--
-- LO QUE HEREDA Y NO ARREGLA:
--   ORDER BY score_combinado DESC
--   score_combinado viene de picks_recomendados_hoy_raw y es
--     ev_num * 0.6 + confianza * 0.4, con confianza llevando EV y momio dentro.
--   O sea: toda la higiene de arriba es correcta, y el ORDEN final sigue
--   siendo del precio. Tambien hereda el ELSE 0.52 que inventa probabilidad.
--   Limpiar el filtro no sirve si el ranking sigue siendo economico.

create or replace view public.picks_recomendados_hoy as
 SELECT espn_event_id,
    liga,
    created_at,
    home,
    away,
    odds_source,
    pick_nombre,
    pick_desc,
    mercado,
    ev_estimado,
    ev_numerico,
    confianza,
    momio_mercado,
    probabilidad_real,
    kelly_pct,
    odds_verificadas,
    razon,
    resumen,
    clasificacion,
    score_combinado,
    arranca_en,
    edge_real,
    momio_fabricado,
    odds_apertura,
    odds_cierre,
    clv_pct
   FROM ( WITH fecha_partido AS (
                 SELECT f.espn_event_id,
                    f.liga,
                    f.created_at,
                    f.home,
                    f.away,
                    f.odds_source,
                    f.pick_nombre,
                    f.pick_desc,
                    f.mercado,
                    f.ev_estimado,
                    f.ev_numerico,
                    f.confianza,
                    f.momio_mercado,
                    f.probabilidad_real,
                    f.kelly_pct,
                    f.odds_verificadas,
                    f.razon,
                    f.resumen,
                    f.clasificacion,
                    f.score_combinado,
                    COALESCE(( SELECT ae.fecha
                           FROM agenda_espn ae
                          WHERE ae.espn_event_id = f.espn_event_id), ( SELECT ls.game_date
                           FROM live_scores ls
                          WHERE ls.espn_event_id = f.espn_event_id), ( SELECT lp.fecha_utc
                           FROM ligamx_partidos lp
                          WHERE f.espn_event_id ~~ 'af:%'::text AND lp.id = NULLIF(SUBSTRING(f.espn_event_id FROM 4), ''::text)::bigint)) AS arranca_en
                   FROM picks_recomendados_hoy_raw f
                ), marcado AS (
                 SELECT p.espn_event_id,
                    p.liga,
                    p.created_at,
                    p.home,
                    p.away,
                    p.odds_source,
                    p.pick_nombre,
                    p.pick_desc,
                    p.mercado,
                    p.ev_estimado,
                    p.ev_numerico,
                    p.confianza,
                    p.momio_mercado,
                    p.probabilidad_real,
                    p.kelly_pct,
                    p.odds_verificadas,
                    p.razon,
                    p.resumen,
                    p.clasificacion,
                    p.score_combinado,
                    p.arranca_en,
                    round(p.probabilidad_real - 1.0 / NULLIF(p.momio_mercado, 0::numeric), 4) AS edge_real,
                    abs(p.momio_mercado - 1.0 / NULLIF(p.probabilidad_real, 0::numeric)) < 0.05 AS momio_fabricado,
                    (EXISTS ( SELECT 1
                           FROM lecciones_aprendidas l
                          WHERE l.bloqueo_total AND COALESCE(l.activa, true) AND sin_acentos(COALESCE(p.mercado, ''::text)) ~~* (('%'::text || sin_acentos(
                                CASE upper(btrim(split_part(l.mercado_norm, ':'::text, 1)))
                                    WHEN 'ML'::text THEN 'Moneyline'::text
                                    WHEN 'OU'::text THEN 'Over/Under'::text
                                    WHEN 'CORNERS'::text THEN 'Corners'::text
                                    WHEN 'BTTS'::text THEN 'BTTS'::text
                                    WHEN 'DC'::text THEN 'Double Chance'::text
                                    ELSE split_part(l.mercado_norm, ':'::text, 1)
                                END)) || '%'::text) AND (split_part(l.mercado_norm, ':'::text, 2) = ''::text OR sin_acentos(COALESCE(p.pick_nombre, p.pick_desc, ''::text)) ~~* (('%'::text || sin_acentos(split_part(l.mercado_norm, ':'::text, 2))) || '%'::text)) AND (l.liga IS NULL OR l.liga = ''::text OR sin_acentos(l.liga) ~~* sin_acentos(COALESCE(p.liga, ''::text))) AND (l.rango_momio IS NULL OR l.rango_momio = ''::text OR p.momio_mercado IS NOT NULL AND p.momio_mercado >= NULLIF(split_part(replace(l.rango_momio, '+'::text, ''::text), '-'::text, 1), ''::text)::numeric AND (split_part(l.rango_momio, '-'::text, 2) = ''::text OR p.momio_mercado <= NULLIF(split_part(l.rango_momio, '-'::text, 2), ''::text)::numeric)))) AS vetado_por_leccion,
                    t.odds_apertura,
                    t.odds_cierre,
                    t.clv_pct,
                    COALESCE(t.momio_fantasma, false) AS momio_fantasma,
                    COALESCE(p.odds_source, ''::text) ~ '^(libro:|the_odds_api|radar_odds_real|TheOddsAPI|DraftKings|Pinnacle)'::text AS precio_de_casa_real
                   FROM fecha_partido p
                     LEFT JOIN LATERAL ( SELECT o.odds_apertura,
                            o.odds_cierre,
                            o.clv_pct,
                            o.momio_fantasma
                           FROM oraculo_picks_tracking o
                          WHERE o.espn_event_id = p.espn_event_id AND COALESCE(o.mercado, ''::text) = COALESCE(p.mercado, ''::text)
                          ORDER BY o.created_at DESC
                         LIMIT 1) t ON true
                ), rankeado AS (
                 SELECT m.espn_event_id,
                    m.liga,
                    m.created_at,
                    m.home,
                    m.away,
                    m.odds_source,
                    m.pick_nombre,
                    m.pick_desc,
                    m.mercado,
                    m.ev_estimado,
                    m.ev_numerico,
                    m.confianza,
                    m.momio_mercado,
                    m.probabilidad_real,
                    m.kelly_pct,
                    m.odds_verificadas,
                    m.razon,
                    m.resumen,
                    m.clasificacion,
                    m.score_combinado,
                    m.arranca_en,
                    m.edge_real,
                    m.momio_fabricado,
                    m.vetado_por_leccion,
                    m.odds_apertura,
                    m.odds_cierre,
                    m.clv_pct,
                    m.momio_fantasma,
                    m.precio_de_casa_real,
                    row_number() OVER (PARTITION BY m.espn_event_id, (regexp_replace(lower(COALESCE(m.pick_nombre, m.pick_desc)), '[^a-z0-9]'::text, ''::text, 'g'::text)), (regexp_replace(lower(COALESCE(m.mercado, ''::text)), '[^a-z0-9]'::text, ''::text, 'g'::text)) ORDER BY (
                        CASE
                            WHEN m.espn_event_id ~ '^[0-9]+$'::text THEN 1
                            WHEN m.espn_event_id ~~ 'af:%'::text THEN 2
                            ELSE 3
                        END), m.created_at DESC) AS rn
                   FROM marcado m
                )
         SELECT rankeado.espn_event_id,
            rankeado.liga,
            rankeado.created_at,
            rankeado.home,
            rankeado.away,
            rankeado.odds_source,
            rankeado.pick_nombre,
            rankeado.pick_desc,
            rankeado.mercado,
            rankeado.ev_estimado,
            rankeado.ev_numerico,
            rankeado.confianza,
            rankeado.momio_mercado,
            rankeado.probabilidad_real,
            rankeado.kelly_pct,
            rankeado.odds_verificadas,
            rankeado.razon,
            rankeado.resumen,
            rankeado.clasificacion,
            rankeado.score_combinado,
            rankeado.arranca_en,
            rankeado.edge_real,
            rankeado.momio_fabricado,
            rankeado.odds_apertura,
            rankeado.odds_cierre,
            rankeado.clv_pct
           FROM rankeado
          WHERE rankeado.rn = 1 AND rankeado.arranca_en IS NOT NULL AND rankeado.arranca_en > now() AND rankeado.created_at <= rankeado.arranca_en AND NOT rankeado.momio_fabricado AND NOT rankeado.momio_fantasma AND NOT rankeado.vetado_por_leccion AND COALESCE(rankeado.mercado, ''::text) !~* '(corner|tarjeta|card)'::text
          ORDER BY rankeado.score_combinado DESC, rankeado.home, rankeado.pick_nombre) _pool
  WHERE NOT pick_en_cuarentena('soccer'::text, 'Over/Under'::text, pick_desc);
