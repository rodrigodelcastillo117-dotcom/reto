-- baseline/v_radar_odds_fase.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. No tenia definicion en Git.
--
-- NOTA DE LECTURA: esta vista clasifica cada captura de momio en pregame,
-- cierre o en_vivo comparando snapshot_at contra la hora del evento que da
-- v_evento_hora. Es la pieza que distingue un precio capturado ANTES del
-- saque de uno capturado EN VIVO, asi que es parte de la defensa temporal.

create or replace view public.v_radar_odds_fase as
 SELECT r.id,
    r.odds_event_id,
    r.home_team,
    r.away_team,
    r.sport_key,
    r.home_ml,
    r.away_ml,
    r.draw_ml,
    r.over_odds,
    r.under_odds,
    r.over_line,
    r.snapshot_at,
    r.espn_event_id,
    r.bookmaker,
    r.overround,
    r.confiable,
    r.btts_si,
    r.btts_no,
    r.casa_norm,
    h.fecha AS hora_partido,
    h.fuente AS fuente_hora,
        CASE
            WHEN h.fecha IS NULL THEN 'sin_hora'::text
            WHEN r.snapshot_at > h.fecha THEN 'en_vivo'::text
            WHEN r.snapshot_at > (h.fecha - '00:15:00'::interval) THEN 'cierre'::text
            ELSE 'pregame'::text
        END AS fase,
        CASE
            WHEN h.fecha IS NOT NULL THEN round(EXTRACT(epoch FROM h.fecha - r.snapshot_at) / 3600.0, 2)
            ELSE NULL::numeric
        END AS horas_antes_del_saque,
    r.bookmaker IS NOT NULL AS generacion_con_casa
   FROM radar_odds_snapshots r
     LEFT JOIN v_evento_hora h ON h.espn_event_id = r.espn_event_id;
