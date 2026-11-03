-- baseline/v_momios_confiables.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. No tenia definicion en Git.
--
-- NOTA DE LECTURA: une las capturas marcadas confiables de radar_odds_snapshots
-- con las de odds_espn SOLO para los eventos donde el radar no tiene captura
-- confiable. El overround se recalcula aqui para la rama de odds_espn.

create or replace view public.v_momios_confiables as
 SELECT radar_odds_snapshots.id,
    radar_odds_snapshots.odds_event_id,
    radar_odds_snapshots.home_team,
    radar_odds_snapshots.away_team,
    radar_odds_snapshots.sport_key,
    radar_odds_snapshots.home_ml,
    radar_odds_snapshots.away_ml,
    radar_odds_snapshots.draw_ml,
    radar_odds_snapshots.over_odds,
    radar_odds_snapshots.under_odds,
    radar_odds_snapshots.over_line,
    radar_odds_snapshots.snapshot_at,
    radar_odds_snapshots.espn_event_id,
    radar_odds_snapshots.bookmaker,
    radar_odds_snapshots.overround,
    radar_odds_snapshots.confiable
   FROM radar_odds_snapshots
  WHERE radar_odds_snapshots.confiable IS TRUE
UNION ALL
 SELECT NULL::uuid AS id,
    NULL::text AS odds_event_id,
    NULL::text AS home_team,
    NULL::text AS away_team,
    NULL::text AS sport_key,
    o.ml_home AS home_ml,
    o.ml_away AS away_ml,
    o.ml_draw AS draw_ml,
    o.over_odds,
    o.under_odds,
    o.total_linea AS over_line,
    o.capturado_at AS snapshot_at,
    o.espn_event_id,
    o.proveedor AS bookmaker,
        CASE
            WHEN o.ml_home > 1::numeric AND o.ml_away > 1::numeric THEN round(1::numeric / o.ml_home + 1::numeric / o.ml_away + COALESCE(1::numeric / NULLIF(o.ml_draw, 0::numeric), 0::numeric), 4)
            ELSE NULL::numeric
        END AS overround,
    true AS confiable
   FROM odds_espn o
  WHERE NOT (EXISTS ( SELECT 1
           FROM radar_odds_snapshots r
          WHERE r.espn_event_id = o.espn_event_id AND r.confiable IS TRUE));
