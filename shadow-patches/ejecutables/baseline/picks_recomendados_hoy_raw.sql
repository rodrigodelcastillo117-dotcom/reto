-- baseline/picks_recomendados_hoy_raw.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. NO tenia definicion en Git.
--
-- =====================================================================
-- ADVERTENCIA: ESTA ES LA MAYOR CONCENTRACION DE VIOLACIONES DEL CANDADO
-- DEL DUENO EN TODO EL SISTEMA, Y ESTUVO SIN VERSIONAR.
-- Se vuelca TAL COMO ESTA, sin corregir nada: corregirla cambia que picks
-- existen y con que probabilidad, o sea es cutover de modelo, congelado.
-- Lo que sigue es el inventario de lo que hace, linea por linea.
-- =====================================================================
--
-- 1) INVENTA UNA PROBABILIDAD. Lo mas grave del archivo.
--      CASE ... ELSE 0.52 END AS prob
--    Si la probabilidad del pick no viene en ninguno de los cuatro formatos
--    que reconoce, la vista NO falla cerrado: asigna 52 %. Un numero
--    inventado que de ahi en adelante viaja como "probabilidad_real" y llega
--    a la superficie. El dueno prohibio explicitamente inventar
--    probabilidades. Este default es exactamente eso.
--
-- 2) EL EV FILTRA QUE PICKS EXISTEN.
--      WHERE ... ev_estimado parseado >= 4
--    Un pick del modelo con EV menor a 4 % no aparece. El precio suprime.
--
-- 3) EL EV ASIGNA LA CATEGORIA.
--      ev_num >= 8  y no es nicho  -> 'ELITE'
--      ev_num >= 12 y es nicho     -> 'SOLIDO'
--      ev_num >= 4                 -> 'SOLIDO'
--    La etiqueta que el usuario lee como calidad del pick es un umbral de EV.
--
-- 4) LA CONFIANZA TRAE PRECIO ADENTRO.
--      confianza = 50 + min(ev_num/25*22, 22) + ... +
--                  (momio entre 1.60 y 2.20 -> +5 ; entre 1.40 y 2.60 -> +3)
--    O sea: el mismo pick con el mismo modelo recibe MAS confianza si la casa
--    lo paga en cierto rango. Eso no es confianza del modelo.
--
-- 5) EL ORDEN ES 60 % EV.
--      score_combinado = ev_num * 0.6 + confianza * 0.4
--      ORDER BY score_combinado DESC
--    Y como confianza tambien lleva EV y momio dentro, el peso real del
--    precio en el orden es mayor que 0.6.
--
-- 6) FABRICA NOMBRES DE EQUIPO A PARTIR DEL ID.
--      initcap(replace(split_part(split_part(espn_event_id,':',4),'_vs_',1),'_',' '))
--    Ultimo recurso de la cadena COALESCE de home/away: si ninguna fuente
--    tiene el nombre, lo construye parseando el texto del id del evento. Eso
--    es inventar identidad, no resolverla.
--
-- 7) CLASIFICA "NICHO" POR NOMBRE.
--      pick_desc like '%corner%' or '%tarjeta%' or '%card%'  -> es_nicho
--    Clasificacion por regex sobre texto libre, esquivable escribiendo
--    distinto. Es el patron que ya dio tres verdes falsos en esta auditoria.
--
-- 8) LO QUE SI HACE BIEN, y hay que decirlo:
--    - exige odds_verificadas = true
--    - excluye picks que ya tienen resultado en oraculo_picks_tracking
--    - acota la ventana a created_at > now() - 20h
--    - LEAST(ev_num, 25) pone techo al EV declarado, asi que un EV absurdo
--      del LLM no se propaga sin limite
-- =====================================================================

create or replace view public.picks_recomendados_hoy_raw as
 WITH base AS (
         SELECT ap.espn_event_id,
            ap.liga,
            ap.created_at,
            COALESCE(NULLIF(ap.analisis_json ->> '_home'::text, ''::text), ( SELECT ot2.home
                   FROM oraculo_picks_tracking ot2
                  WHERE ot2.espn_event_id = ap.espn_event_id
                 LIMIT 1), ( SELECT ls.home_team
                   FROM live_scores ls
                  WHERE ls.espn_event_id = ap.espn_event_id
                 LIMIT 1), ( SELECT eh.nombre
                   FROM ligamx_partidos mp
                     JOIN ligamx_equipos eh ON eh.id = mp.home_id
                  WHERE ap.espn_event_id ~ '^af:[0-9]+$'::text AND mp.id = SUBSTRING(ap.espn_event_id FROM 4)::bigint
                 LIMIT 1), NULLIF(initcap(replace(split_part(split_part(ap.espn_event_id, ':'::text, 4), '_vs_'::text, 1), '_'::text, ' '::text)), ''::text), ''::text) AS home,
            COALESCE(NULLIF(ap.analisis_json ->> '_away'::text, ''::text), ( SELECT ot2.away
                   FROM oraculo_picks_tracking ot2
                  WHERE ot2.espn_event_id = ap.espn_event_id
                 LIMIT 1), ( SELECT ls.away_team
                   FROM live_scores ls
                  WHERE ls.espn_event_id = ap.espn_event_id
                 LIMIT 1), ( SELECT ea.nombre
                   FROM ligamx_partidos mp
                     JOIN ligamx_equipos ea ON ea.id = mp.away_id
                  WHERE ap.espn_event_id ~ '^af:[0-9]+$'::text AND mp.id = SUBSTRING(ap.espn_event_id FROM 4)::bigint
                 LIMIT 1), NULLIF(initcap(replace(split_part(split_part(ap.espn_event_id, ':'::text, 4), '_vs_'::text, 2), '_'::text, ' '::text)), ''::text), ''::text) AS away,
            ap.analisis_json ->> '_odds_source'::text AS odds_source,
            TRIM(BOTH FROM COALESCE(NULLIF(regexp_replace(p.value ->> 'pick'::text, '^\[.*?\]\s*'::text, ''::text), ''::text), p.value ->> 'pick'::text)) AS pick_nombre,
            TRIM(BOTH FROM COALESCE(NULLIF(regexp_replace(COALESCE(NULLIF(p.value ->> 'pick_desc'::text, ''::text), p.value ->> 'pick'::text), '^\[.*?\]\s*'::text, ''::text), ''::text), p.value ->> 'pick'::text)) AS pick_desc,
            p.value ->> 'mercado'::text AS mercado,
            p.value ->> 'ev_estimado'::text AS ev_estimado,
                CASE
                    WHEN (p.value ->> 'momio_mercado'::text) ~ '^[0-9]+\.?[0-9]*$'::text THEN (p.value ->> 'momio_mercado'::text)::numeric
                    ELSE NULL::numeric
                END AS momio_mercado,
                CASE
                    WHEN (p.value ->> 'probabilidad_real'::text) ~ '^[0-9]+\.?[0-9]*%$'::text THEN (regexp_match(p.value ->> 'probabilidad_real'::text, '([0-9]+\.?[0-9]*)'::text))[1]::numeric / 100::numeric
                    WHEN (p.value ->> 'probabilidad_real'::text) ~ '^0?\.[0-9]+$'::text THEN (p.value ->> 'probabilidad_real'::text)::numeric
                    WHEN (p.value ->> 'prob'::text) ~ '^[0-9]+\.?[0-9]*$'::text AND ((p.value ->> 'prob'::text)::numeric) <= 1::numeric THEN (p.value ->> 'prob'::text)::numeric
                    WHEN (p.value ->> 'prob'::text) ~ '^[0-9]+\.?[0-9]*$'::text AND ((p.value ->> 'prob'::text)::numeric) > 1::numeric THEN ((p.value ->> 'prob'::text)::numeric) / 100::numeric
                    ELSE 0.52
                END AS prob,
                CASE
                    WHEN (p.value ->> 'kelly_pct'::text) ~ '^[-+]?[0-9]+\.?[0-9]*$'::text THEN (p.value ->> 'kelly_pct'::text)::numeric
                    ELSE NULL::numeric
                END AS kelly_pct,
            COALESCE((p.value ->> 'odds_verificadas'::text)::boolean, false) AS odds_verificadas,
            p.value ->> 'razon'::text AS razon,
            ap.analisis_json ->> 'resumen_ejecutivo'::text AS resumen,
            LEAST(
                CASE
                    WHEN (p.value ->> 'ev_estimado'::text) ~ '^[-+]?[0-9]+\.?[0-9]*\s*%$'::text THEN (regexp_match(p.value ->> 'ev_estimado'::text, '([0-9]+\.?[0-9]*)'::text))[1]::numeric
                    ELSE 0::numeric
                END, 25::numeric) AS ev_num,
                CASE
                    WHEN lower(COALESCE(NULLIF(p.value ->> 'pick_desc'::text, ''::text), p.value ->> 'pick'::text, ''::text)) ~~* '%corner%'::text OR lower(COALESCE(NULLIF(p.value ->> 'pick_desc'::text, ''::text), p.value ->> 'pick'::text, ''::text)) ~~* '%tarjeta%'::text OR lower(COALESCE(NULLIF(p.value ->> 'pick_desc'::text, ''::text), p.value ->> 'pick'::text, ''::text)) ~~* '%card%'::text THEN true
                    ELSE false
                END AS es_nicho,
                CASE
                    WHEN (p.value ->> 'prob'::text) ~ '^[0-9]+\.?[0-9]*$'::text THEN (p.value ->> 'prob'::text)::numeric
                    ELSE NULL::numeric
                END AS prob_raw
           FROM analisis_partidos ap,
            LATERAL jsonb_array_elements(ap.analisis_json -> 'picks_recomendados'::text) p(value)
          WHERE ap.created_at > (now() - '20:00:00'::interval) AND jsonb_typeof(ap.analisis_json -> 'picks_recomendados'::text) = 'array'::text AND COALESCE(NULLIF(p.value ->> 'pick_desc'::text, ''::text), p.value ->> 'pick'::text, ''::text) <> ''::text AND COALESCE((p.value ->> 'odds_verificadas'::text)::boolean, false) = true AND
                CASE
                    WHEN (p.value ->> 'ev_estimado'::text) ~ '^[-+]?[0-9]+\.?[0-9]*\s*%$'::text THEN (regexp_match(p.value ->> 'ev_estimado'::text, '([0-9]+\.?[0-9]*)'::text))[1]::numeric
                    ELSE 0::numeric
                END >= 4::numeric AND
                CASE
                    WHEN (p.value ->> 'prob'::text) ~ '^[0-9]+\.?[0-9]*$'::text AND ((p.value ->> 'prob'::text)::numeric) > 1::numeric THEN ((p.value ->> 'prob'::text)::numeric) >= 15::numeric
                    WHEN (p.value ->> 'prob'::text) ~ '^[0-9]+\.?[0-9]*$'::text AND ((p.value ->> 'prob'::text)::numeric) <= 1::numeric THEN ((p.value ->> 'prob'::text)::numeric) >= 0.15
                    ELSE true
                END AND NOT (EXISTS ( SELECT 1
                   FROM oraculo_picks_tracking ot
                  WHERE ot.espn_event_id = ap.espn_event_id AND (ot.resultado = ANY (ARRAY['ganado'::text, 'perdido'::text, 'nulo'::text])) AND (lower(ot.pick_nombre) = lower(TRIM(BOTH FROM COALESCE(NULLIF(regexp_replace(p.value ->> 'pick'::text, '^\[.*?\]\s*'::text, ''::text), ''::text), p.value ->> 'pick'::text))) OR lower(ot.pick_desc) = lower(TRIM(BOTH FROM COALESCE(NULLIF(p.value ->> 'pick_desc'::text, ''::text), p.value ->> 'pick'::text))))))
        ), scored AS (
         SELECT base.espn_event_id,
            base.liga,
            base.created_at,
            base.home,
            base.away,
            base.odds_source,
            base.pick_nombre,
            base.pick_desc,
            base.mercado,
            base.ev_estimado,
            base.momio_mercado,
            base.prob,
            base.kelly_pct,
            base.odds_verificadas,
            base.razon,
            base.resumen,
            base.ev_num,
            base.es_nicho,
            base.prob_raw,
                CASE
                    WHEN base.ev_num >= 8::numeric AND NOT base.es_nicho THEN 'ELITE'::text
                    WHEN base.ev_num >= 12::numeric AND base.es_nicho THEN 'SOLIDO'::text
                    WHEN base.ev_num >= 4::numeric THEN 'SOLIDO'::text
                    ELSE NULL::text
                END AS clasificacion,
            LEAST(83::numeric, GREATEST(42::numeric, round(50::numeric + LEAST(base.ev_num / 25.0 * 22::numeric, 22::numeric) + GREATEST(0::numeric, LEAST((base.prob - 0.50) * 100::numeric, 20::numeric)) +
                CASE
                    WHEN base.momio_mercado >= 1.60 AND base.momio_mercado <= 2.20 THEN 5
                    WHEN base.momio_mercado >= 1.40 AND base.momio_mercado <= 2.60 THEN 3
                    ELSE 1
                END::numeric -
                CASE
                    WHEN base.es_nicho THEN 8
                    ELSE 0
                END::numeric + 5::numeric))) AS confianza
           FROM base
        )
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
    ev_num AS ev_numerico,
    confianza,
    momio_mercado,
    prob AS probabilidad_real,
    kelly_pct,
    odds_verificadas,
    razon,
    resumen,
    clasificacion,
    round(ev_num * 0.6 + confianza * 0.4, 1) AS score_combinado
   FROM scored
  WHERE COALESCE(home, ''::text) <> ''::text AND COALESCE(away, ''::text) <> ''::text
  ORDER BY (round(ev_num * 0.6 + confianza * 0.4, 1)) DESC;
