-- baseline/v_picks_futbol_calibrado.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. No tenia definicion en Git.
--
-- NOTAS DE LECTURA
--  1) Ya trae el envoltorio de cuarentena de Under/Over 3.5 que puso ISS100/101:
--       WHERE NOT pick_en_cuarentena('soccer','Over/Under', pick)
--     Eso queda AQUI versionado, que era justo la deuda: antes el filtro solo
--     existia envolviendo una definicion de produccion.
--  2) ev_pct y edge_pct salen en la LISTA DE SELECT, no en un WHERE ni en un
--     ORDER BY. Bajo el criterio de ISS107 eso es informar, no decidir, y por
--     eso el detector no lo marca como violacion del candado.
--  3) La fuente es fut_predicciones, la tabla que NO tiene columna de version
--     de modelo ni de calibracion. Por eso todo pick que sale de aqui llega a
--     v_pick_canonico con es_pick_reason = 'SIN_MODEL_VERSION'. Este archivo
--     deja esa cadena reproducible; arreglar el origen es del generador.

create or replace view public.v_picks_futbol_calibrado as
 SELECT espn_event_id,
    fixture_id,
    arranca_en,
    liga_nombre,
    home_nombre,
    away_nombre,
    mercado,
    pick,
    probabilidad_pct,
    momio_justo,
    momio_casa,
    bookmaker,
    partidos_del_modelo,
    muestra_calibracion,
    calibracion_confiable,
    como_se_calculo,
    ev_pct,
    edge_pct
   FROM ( WITH expandido AS (
                 SELECT f.fixture_id,
                    f.fecha,
                    f.liga_nombre,
                    f.home_nombre,
                    f.away_nombre,
                    f.lam_h,
                    f.lam_a,
                    f.muestra,
                    m.value ->> 'mercado'::text AS mercado,
                    m.value ->> 'pick'::text AS pick,
                    (m.value ->> 'probabilidad'::text)::numeric AS probabilidad_pct,
                    (m.value ->> 'momio_justo'::text)::numeric AS momio_justo,
                    ((m.value -> 'respaldo'::text) ->> 'muestra'::text)::integer AS muestra_calibracion,
                    ((m.value -> 'respaldo'::text) ->> 'confiable'::text)::boolean AS calibracion_confiable,
                    m.value ->> 'base'::text AS como_se_calculo
                   FROM fut_predicciones f,
                    LATERAL jsonb_array_elements(f.mercados) m(value)
                  WHERE f.fecha > now()
                ), con_evento AS (
                 SELECT e.fixture_id,
                    e.fecha,
                    e.liga_nombre,
                    e.home_nombre,
                    e.away_nombre,
                    e.lam_h,
                    e.lam_a,
                    e.muestra,
                    e.mercado,
                    e.pick,
                    e.probabilidad_pct,
                    e.momio_justo,
                    e.muestra_calibracion,
                    e.calibracion_confiable,
                    e.como_se_calculo,
                    lp.espn_event_id
                   FROM expandido e
                     LEFT JOIN ligamx_partidos lp ON lp.id = e.fixture_id
                ), con_precio AS (
                 SELECT c.fixture_id,
                    c.fecha,
                    c.liga_nombre,
                    c.home_nombre,
                    c.away_nombre,
                    c.lam_h,
                    c.lam_a,
                    c.muestra,
                    c.mercado,
                    c.pick,
                    c.probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    c.como_se_calculo,
                    c.espn_event_id,
                        CASE
                            WHEN c.pick ~* '^over 2\.5'::text THEN r.over_odds
                            WHEN c.pick ~* '^under 2\.5'::text THEN r.under_odds
                            ELSE NULL::numeric
                        END AS momio_casa,
                    r.bookmaker
                   FROM con_evento c
                     LEFT JOIN LATERAL ( SELECT s.over_odds,
                            s.under_odds,
                            s.bookmaker
                           FROM radar_odds_snapshots s
                          WHERE s.espn_event_id = c.espn_event_id AND s.over_line = 2.5 AND s.over_odds IS NOT NULL
                          ORDER BY s.snapshot_at DESC
                         LIMIT 1) r ON c.pick ~* '^(over|under) 2\.5'::text
                )
         SELECT con_precio.espn_event_id,
            con_precio.fixture_id,
            con_precio.fecha AS arranca_en,
            con_precio.liga_nombre,
            con_precio.home_nombre,
            con_precio.away_nombre,
            con_precio.mercado,
            con_precio.pick,
            con_precio.probabilidad_pct,
            con_precio.momio_justo,
            con_precio.momio_casa,
            con_precio.bookmaker,
            con_precio.muestra AS partidos_del_modelo,
            con_precio.muestra_calibracion,
            con_precio.calibracion_confiable,
            con_precio.como_se_calculo,
                CASE
                    WHEN con_precio.momio_casa IS NOT NULL THEN round((con_precio.probabilidad_pct / 100.0 * con_precio.momio_casa - 1::numeric) * 100::numeric, 1)
                    ELSE NULL::numeric
                END AS ev_pct,
                CASE
                    WHEN con_precio.momio_casa IS NOT NULL THEN round((con_precio.probabilidad_pct / 100.0 - 1.0 / con_precio.momio_casa) * 100::numeric, 1)
                    ELSE NULL::numeric
                END AS edge_pct
           FROM con_precio
          WHERE con_precio.probabilidad_pct IS NOT NULL AND con_precio.muestra >= 20) _pool
  WHERE NOT pick_en_cuarentena('soccer'::text, 'Over/Under'::text, pick);
