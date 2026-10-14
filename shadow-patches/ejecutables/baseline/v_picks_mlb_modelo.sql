-- baseline/v_picks_mlb_modelo.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. No tenia definicion en Git.
--
-- NOTAS DE LECTURA
--  1) Esta es la unica rama del sistema que NACE de agenda_espn con
--     deporte='baseball' y llama a predecir_mlb(espn_event_id). O sea, MLB si
--     tiene identidad verificada contra el calendario autoritativo desde el
--     origen, a diferencia de la rama de futbol que nace de fut_predicciones.
--  2) La columna detalle arma en texto el DESGLOSE REAL del modelo: FIP de
--     cada abridor con su valor crudo, multiplicadores de bullpen, park factor,
--     platoon y carreras esperadas. Son drivers deportivos, no salidas del
--     modelo disfrazadas de causas. Es el unico deporte donde ese desglose
--     existe y esta versionado.
--  3) La linea de totales sale de badrino_partidos, luego odds_espn, y si no
--     hay ninguna cae en 8.5 POR DEFECTO. Ese 8.5 es un default inventado que
--     el dueno deberia revisar: un total asumido no es un total observado.
--     Queda reportado, no cambiado.
--  4) brecha_pp y confiable vienen de p->'edge_vs_mercado'. Salen en la lista
--     de SELECT, no en un WHERE ni en un ORDER BY, asi que bajo el criterio de
--     ISS107 informan y no deciden.

create or replace view public.v_picks_mlb_modelo as
 WITH j AS MATERIALIZED (
         SELECT a.espn_event_id,
            a.fecha,
            a.liga_nombre,
            a.home_nombre,
            a.away_nombre,
            predecir_mlb(a.espn_event_id) AS p
           FROM agenda_espn a
          WHERE a.deporte = 'baseball'::text AND a.fecha >= (now() - '03:00:00'::interval) AND a.fecha <= (now() + '4 days'::interval)
        ), ok AS (
         SELECT j.espn_event_id,
            j.fecha,
            j.liga_nombre,
            j.home_nombre,
            j.away_nombre,
            j.p
           FROM j
          WHERE (j.p ->> 'ok'::text)::boolean
        ), linea AS (
         SELECT ok.espn_event_id,
            ok.fecha,
            ok.liga_nombre,
            ok.home_nombre,
            ok.away_nombre,
            ok.p,
            COALESCE(( SELECT b.total_linea
                   FROM badrino_partidos b
                  WHERE b.espn_event_id = ok.espn_event_id), ( SELECT o.total_linea
                   FROM odds_espn o
                  WHERE o.espn_event_id = ok.espn_event_id), 8.5) AS ln
           FROM ok
        )
 SELECT linea.espn_event_id,
    linea.fecha AS arranca_en,
    linea.liga_nombre,
    linea.home_nombre,
    linea.away_nombre,
    m.mercado,
    m.pick,
    m.prob,
    m.detalle,
        CASE
            WHEN (((linea.p -> 'prediccion'::text) ->> 'gana_local_pct'::text)::numeric) >= (((linea.p -> 'prediccion'::text) ->> 'gana_visita_pct'::text)::numeric) THEN linea.home_nombre
            ELSE linea.away_nombre
        END AS favorito,
    GREATEST(((linea.p -> 'prediccion'::text) ->> 'gana_local_pct'::text)::numeric, ((linea.p -> 'prediccion'::text) ->> 'gana_visita_pct'::text)::numeric) AS favorito_pct,
    ((linea.p -> 'edge_vs_mercado'::text) ->> 'confiable'::text)::boolean AS confiable,
    ((linea.p -> 'edge_vs_mercado'::text) ->> 'brecha_pp'::text)::numeric AS brecha_pp
   FROM linea,
    LATERAL ( VALUES ('Moneyline'::text,'ML '::text || linea.home_nombre,((linea.p -> 'prediccion'::text) ->> 'gana_local_pct'::text)::numeric,(((((((((((((((((((('FIP '::text || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_local'::text) ->> 'nombre'::text, '?'::text)) || ' '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_local'::text) ->> 'valor_crudo'::text, '?'::text)) || ' vs '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_visita'::text) ->> 'nombre'::text, '?'::text)) || ' '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_visita'::text) ->> 'valor_crudo'::text, '?'::text)) || ' | bullpen '::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'mult_bullpen_local'::text, '?'::text)) || '/'::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'mult_bullpen_visita'::text, '?'::text)) || ' | parque '::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'park_factor'::text, '?'::text)) || ' | platoon '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'platoon'::text) ->> 'mult_local'::text, '?'::text)) || '/'::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'platoon'::text) ->> 'mult_visita'::text, '?'::text)) || ' | carreras esperadas '::text) || COALESCE((linea.p -> 'prediccion'::text) ->> 'carreras_local'::text, '?'::text)) || '-'::text) || COALESCE((linea.p -> 'prediccion'::text) ->> 'carreras_visita'::text, '?'::text)), ('Moneyline'::text,'ML '::text || linea.away_nombre,((linea.p -> 'prediccion'::text) ->> 'gana_visita_pct'::text)::numeric,(((((((((((((((('FIP '::text || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_visita'::text) ->> 'nombre'::text, '?'::text)) || ' '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_visita'::text) ->> 'valor_crudo'::text, '?'::text)) || ' vs '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_local'::text) ->> 'nombre'::text, '?'::text)) || ' '::text) || COALESCE(((linea.p -> 'desglose'::text) -> 'abridor_local'::text) ->> 'valor_crudo'::text, '?'::text)) || ' | bullpen '::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'mult_bullpen_visita'::text, '?'::text)) || '/'::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'mult_bullpen_local'::text, '?'::text)) || ' | parque '::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'park_factor'::text, '?'::text)) || ' | carreras esperadas '::text) || COALESCE((linea.p -> 'prediccion'::text) ->> 'carreras_visita'::text, '?'::text)) || '-'::text) || COALESCE((linea.p -> 'prediccion'::text) ->> 'carreras_local'::text, '?'::text)), ('Over/Under'::text,'Over '::text || linea.ln::text,((((linea.p -> 'prediccion'::text) -> 'totales'::text) -> linea.ln::text) ->> 'over_pct_ajustado'::text)::numeric,(((('total esperado '::text || COALESCE((linea.p -> 'prediccion'::text) ->> 'total_esperado'::text, '?'::text)) || ' | linea de la casa '::text) || linea.ln::text) || ' | parque '::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'park_factor'::text, '?'::text)), ('Over/Under'::text,'Under '::text || linea.ln::text,((((linea.p -> 'prediccion'::text) -> 'totales'::text) -> linea.ln::text) ->> 'under_pct_ajustado'::text)::numeric,(((('total esperado '::text || COALESCE((linea.p -> 'prediccion'::text) ->> 'total_esperado'::text, '?'::text)) || ' | linea de la casa '::text) || linea.ln::text) || ' | parque '::text) || COALESCE((linea.p -> 'desglose'::text) ->> 'park_factor'::text, '?'::text))) m(mercado, pick, prob, detalle)
  WHERE m.prob IS NOT NULL;
