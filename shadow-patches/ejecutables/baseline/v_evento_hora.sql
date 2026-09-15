-- baseline/v_evento_hora.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
--
-- POR QUE EXISTE: el dueno bloqueo el clean bootstrap con esta razon textual:
--   "No aceptare un clean bootstrap mientras para reconstruir el sistema haga
--    falta leer una definicion preexistente de produccion."
-- Esta vista esta en el cierre transitivo de la ruta de decision
-- (v_pick_canonico depende de ella) y NO tenia definicion en Git.
--
-- NOTA DE LECTURA: esta vista es la que resuelve la HORA del evento con
-- precedencia historico > agenda > live. Es la pieza que sostiene la regla
-- temporal source_data_asof <= decision_time < kickoff, asi que sin ella
-- versionada no se puede reconstruir la defensa contra lookahead.

create or replace view public.v_evento_hora as
 SELECT DISTINCT ON (espn_event_id) espn_event_id,
    fecha,
    fuente
   FROM ( SELECT h.espn_event_id,
            h.fecha,
            1 AS pr,
            'historico'::text AS fuente
           FROM historico_partidos_espn h
          WHERE h.espn_event_id IS NOT NULL
        UNION ALL
         SELECT a.espn_event_id,
            a.fecha,
            2,
            'agenda'::text
           FROM agenda_espn a
          WHERE a.espn_event_id IS NOT NULL
        UNION ALL
         SELECT l.espn_event_id,
            l.game_date,
            3,
            'live'::text
           FROM live_scores l
          WHERE l.espn_event_id IS NOT NULL) z
  ORDER BY espn_event_id, pr;
