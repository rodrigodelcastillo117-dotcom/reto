-- baseline/v_pick_momio_libro.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. No tenia definicion en Git.
--
-- NOTA DE LECTURA, IMPORTANTE PARA LA AUDITORIA DE IDENTIDAD:
--   El lado de esta vista que asigna el momio al pick NO usa ids: usa
--   coincidencia de TEXTO entre el nombre del pick y el nombre del equipo del
--   libro, con LIKE de comodines sobre norm_equipo() y slug_equipo():
--     norm_equipo(pick_desc) like '%'||slug_equipo(home_team)||'%'
--   Es decir, es exactamente el tipo de emparejamiento difuso por substring
--   que el dueno prohibio para decidir identidad. Aqui decide QUE MOMIO se le
--   pega a un pick. Si dos equipos de un partido comparten una subcadena, es_home
--   y es_away pueden ser ambos true y el CASE devuelve NULL (falla cerrado),
--   pero si solo uno coincide por accidente, pega el momio equivocado.
--   Queda registrado aqui; corregirlo toca la asignacion de precio y se reporta
--   para decision del dueno, no se parcha de pasada.

create or replace view public.v_pick_momio_libro as
 WITH libro AS (
         SELECT DISTINCT ON (v_momios_confiables.espn_event_id) v_momios_confiables.espn_event_id,
            v_momios_confiables.home_team,
            v_momios_confiables.away_team,
            v_momios_confiables.home_ml,
            v_momios_confiables.away_ml,
            v_momios_confiables.draw_ml,
            v_momios_confiables.over_odds,
            v_momios_confiables.under_odds,
            v_momios_confiables.over_line,
            v_momios_confiables.bookmaker,
            v_momios_confiables.snapshot_at
           FROM v_momios_confiables
          WHERE v_momios_confiables.confiable AND v_momios_confiables.espn_event_id IS NOT NULL AND v_momios_confiables.snapshot_at > (now() - '48:00:00'::interval)
          ORDER BY v_momios_confiables.espn_event_id, v_momios_confiables.snapshot_at DESC
        ), pk AS (
         SELECT v.espn_event_id,
            COALESCE(v.pick_nombre, v.pick_desc) AS pick_desc,
            v.mercado,
            v.momio_mercado AS momio_ai,
            mercado_normalizado((COALESCE(v.mercado, ''::text) || ' '::text) || COALESCE(v.pick_nombre, ''::text)) AS mercado_norm
           FROM picks_recomendados_hoy v
          WHERE v.momio_mercado IS NOT NULL
        ), m AS (
         SELECT pk.espn_event_id,
            pk.pick_desc,
            pk.mercado,
            pk.mercado_norm,
            pk.momio_ai,
            l.bookmaker,
            l.snapshot_at,
            l.over_line,
            l.home_ml,
            l.away_ml,
            l.draw_ml,
            l.over_odds,
            l.under_odds,
            norm_equipo(pk.pick_desc) ~~ (('%'::text || slug_equipo(l.home_team)) || '%'::text) OR norm_equipo(pk.pick_desc) ~~ (('%'::text || norm_equipo(l.home_team)) || '%'::text) AS es_home,
            norm_equipo(pk.pick_desc) ~~ (('%'::text || slug_equipo(l.away_team)) || '%'::text) OR norm_equipo(pk.pick_desc) ~~ (('%'::text || norm_equipo(l.away_team)) || '%'::text) AS es_away,
            pk.pick_desc ~* '(empate|draw)'::text AS es_empate,
            (regexp_match(pk.pick_desc, '([0-9]+\.?[0-9]*)'::text))[1]::numeric AS linea_pick
           FROM pk
             JOIN libro l ON l.espn_event_id = pk.espn_event_id
        )
 SELECT espn_event_id,
    pick_desc,
    mercado_norm,
    momio_ai,
    bookmaker,
    snapshot_at AS momio_leido_en,
        CASE
            WHEN mercado_norm = 'ML'::text AND es_empate THEN draw_ml
            WHEN mercado_norm = 'ML'::text AND es_home AND NOT es_away THEN home_ml
            WHEN mercado_norm = 'ML'::text AND es_away AND NOT es_home THEN away_ml
            WHEN mercado_norm = 'OU'::text AND pick_desc ~* 'over'::text AND linea_pick = over_line THEN over_odds
            WHEN mercado_norm = 'OU'::text AND pick_desc ~* 'under'::text AND linea_pick = over_line THEN under_odds
            ELSE NULL::numeric
        END AS momio_libro
   FROM m;
