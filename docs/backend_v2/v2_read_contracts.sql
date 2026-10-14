-- =====================================================================
-- RETO 13M V2 — Public read contracts (soccer), reproducible snapshot
-- Project: wpiztubmmmzclhlprgpd (prod). Captured 2026-09-09 (slice 29A closure).
-- Anon/authenticated get SELECT only (write grants revoked). Fail-closed.
--   v_futpro_v2      — FUT PRO board (full slate). P_RETO only when READY.
--   v_analisis_v2    — factual analysis (1 row/event). forma/xG/H2H/tendencias/clima/alineaciones.
--   v_reto13m_daily  — RETO 13M best pick/day. ONLY markets ML / BTTS / Over 2.5.
-- =====================================================================

-- ---------------------------------------------------------------------
-- public.v_futpro_v2  (mejor_pick excludes Doble oportunidad; presentation filter only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_futpro_v2 AS
 WITH upcoming AS (
         SELECT DISTINCT ON (a.espn_event_id) a.espn_event_id, a.liga_id, a.liga_nombre, a.home_nombre, a.away_nombre, a.fecha, a.estado
           FROM agenda_espn a
          WHERE a.deporte = 'soccer'::text AND a.fecha >= (now() - '03:00:00'::interval) AND a.home_nombre IS NOT NULL AND a.away_nombre IS NOT NULL
          ORDER BY a.espn_event_id, a.fecha
        ), pred AS (
         SELECT DISTINCT ON (soccer_prediction_v2.espn_event_id) soccer_prediction_v2.*
           FROM v2.soccer_prediction_v2
          ORDER BY soccer_prediction_v2.espn_event_id, soccer_prediction_v2.computed_at DESC
        ), gf AS (
         SELECT DISTINCT ON (v_goles_equipo_futbol.equipo, v_goles_equipo_futbol.liga_id) v_goles_equipo_futbol.equipo,
            v_goles_equipo_futbol.liga_id, v_goles_equipo_futbol.anotados_local_prom, v_goles_equipo_futbol.recibidos_local_prom,
            v_goles_equipo_futbol.anotados_visita_prom, v_goles_equipo_futbol.recibidos_visita_prom, v_goles_equipo_futbol.btts_pct,
            v_goles_equipo_futbol.partidos
           FROM v_goles_equipo_futbol
          ORDER BY v_goles_equipo_futbol.equipo, v_goles_equipo_futbol.liga_id, v_goles_equipo_futbol.partidos DESC NULLS LAST
        )
 SELECT u.espn_event_id AS snapshot_id, u.espn_event_id AS canonical_event_id,
    la.competition_id, c.canonical_name AS competition_name, c.group_name, c.display_order, c.show_in_futpro, c.show_in_favorites,
    u.home_nombre AS home_team, u.away_nombre AS away_team, u.fecha AS kickoff, u.estado AS event_status,
    COALESCE(ev.escudo_local, lh.logo_url) AS escudo_home, COALESCE(ev.escudo_visitante, la2.logo_url) AS escudo_away,
    CASE WHEN g.rdy THEN p.p_home ELSE NULL::numeric END AS p_reto_home,
    CASE WHEN g.rdy THEN p.p_draw ELSE NULL::numeric END AS p_reto_draw,
    CASE WHEN g.rdy THEN p.p_away ELSE NULL::numeric END AS p_reto_away,
    CASE WHEN g.rdy THEN p.predicted_score ELSE NULL::text END AS predicted_score,
    CASE WHEN g.rdy THEN p.predicted_score_prob ELSE NULL::numeric END AS predicted_score_prob,
    CASE WHEN g.rdy THEN p.score_dist ELSE NULL::jsonb END AS score_dist,
    g.rdy AS score_available,
    CASE WHEN g.rdy THEN p.btts_yes ELSE NULL::numeric END AS btts_yes,
    p.over_line,
    CASE WHEN g.rdy THEN p.p_over ELSE NULL::numeric END AS p_over,
    CASE WHEN g.rdy THEN p.p_under ELSE NULL::numeric END AS p_under,
    p.line_source,
    CASE WHEN g.rdy THEN mp.label ELSE NULL::text END AS mejor_pick,
    CASE WHEN g.rdy THEN mp.prob ELSE NULL::numeric END AS mejor_pick_prob,
    CASE WHEN g.rdy THEN mk.dd -> 'markets'::text ELSE NULL::jsonb END AS markets,
    CASE WHEN g.rdy THEN p.exp_goals_total ELSE NULL::numeric END AS exp_goals_total,
    p.lambda_home, p.lambda_away,
    gh.anotados_local_prom AS home_gf_pg, gh.recibidos_local_prom AS home_gc_pg,
    ga.anotados_visita_prom AS away_gf_pg, ga.recibidos_visita_prom AS away_gc_pg,
    gh.btts_pct AS home_btts_pct, ga.btts_pct AS away_btts_pct,
    p.sample_home, p.sample_away,
    p.odds_home, p.odds_draw, p.odds_away, p.odds_over, p.odds_under, p.odds_bookmaker, p.odds_captured_at,
    COALESCE(p.model_status, 'PENDING_ANALYSIS'::text) AS model_status,
    COALESCE(p.model_status_reason, 'En la agenda de RETO. El modelo aún no corre para este partido.'::text) AS model_status_reason,
    p.model_name, p.model_version, p.feature_version, p.calibration_status, p.temporal_safe, p.data_asof,
    p.prediction_time, p.computed_at, p.prediction_time AS source_created_at,
    p.provenance ->> 'engine'::text AS engine, NULL::text AS narrative
   FROM upcoming u
     JOIN v2.liga_alias la ON la.liga_source = u.liga_nombre
     JOIN v2.competition_catalog c ON c.competition_id = la.competition_id AND c.enabled = true
     LEFT JOIN pred p ON p.espn_event_id = u.espn_event_id
     LEFT JOIN LATERAL ( SELECT p.model_status = 'READY_UNVALIDATED'::text AS rdy) g ON true
     LEFT JOIN escudos_evento ev ON ev.espn_event_id = u.espn_event_id
     LEFT JOIN v2.team_logo lh ON lh.team_name = u.home_nombre
     LEFT JOIN v2.team_logo la2 ON la2.team_name = u.away_nombre
     LEFT JOIN gf gh ON gh.equipo = u.home_nombre AND gh.liga_id = u.liga_id
     LEFT JOIN gf ga ON ga.equipo = u.away_nombre AND ga.liga_id = u.liga_id
     LEFT JOIN LATERAL ( SELECT v2.fn_dist_from_lambda(p.lambda_home, p.lambda_away, p.over_line) AS dd) mk ON true
     LEFT JOIN LATERAL ( SELECT m.label, m.prob
           FROM ( VALUES
             ('Gana '::text || u.home_nombre, p.p_home), ('Empate'::text, p.p_draw), ('Gana '::text || u.away_nombre, p.p_away),
             ('Ambos anotan'::text, p.btts_yes), ('No ambos anotan'::text, p.btts_no),
             (('Más de '::text || p.over_line) || ' goles'::text, p.p_over), (('Menos de '::text || p.over_line) || ' goles'::text, p.p_under),
             (u.home_nombre || ' -1.5'::text, ((mk.dd -> 'markets'::text) ->> 'home_minus15'::text)::numeric),
             (u.away_nombre || ' -1.5'::text, ((mk.dd -> 'markets'::text) ->> 'away_minus15'::text)::numeric)
           ) m(label, prob)
          WHERE m.prob IS NOT NULL AND m.prob >= 45::numeric AND m.prob <= 83.3
          ORDER BY m.prob DESC LIMIT 1) mp ON true;

-- ---------------------------------------------------------------------
-- public.v_reto13m_daily  — best pick/day; ONLY ML / BTTS / Over 2.5
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW public.v_reto13m_daily AS
 WITH base AS (
         SELECT 'FUT'::text AS deporte, f.snapshot_id AS canonical_event_id,
            f.home_team, f.away_team, f.competition_name, f.escudo_home, f.escudo_away,
            (f.kickoff AT TIME ZONE 'America/Mexico_City'::text)::date AS dia_mx, f.kickoff,
            f.predicted_score, f.predicted_score_prob,
            GREATEST(COALESCE(f.p_reto_home,0::numeric), COALESCE(f.p_reto_draw,0::numeric), COALESCE(f.p_reto_away,0::numeric)) AS p_reto_lider,
            f.model_version, LEAST(COALESCE(f.sample_home,0), COALESCE(f.sample_away,0)) AS muestra_min,
            f.p_reto_home, f.p_reto_away, f.btts_yes,
            CASE WHEN f.btts_yes IS NOT NULL THEN 100::numeric - f.btts_yes ELSE NULL::numeric END AS btts_no,
            ((f.markets ->> 'over25'::text))::numeric AS p_over25
           FROM v_futpro_v2 f WHERE f.model_status = 'READY_UNVALIDATED'::text
        ), cand AS (
         SELECT b.*, mp.label AS mejor_pick, mp.prob AS mejor_pick_prob
           FROM base b
           JOIN LATERAL ( SELECT m.label, m.prob
                 FROM ( VALUES
                     ('Gana '::text || b.home_team, b.p_reto_home), ('Gana '::text || b.away_team, b.p_reto_away),
                     ('Ambos anotan'::text, b.btts_yes), ('No ambos anotan'::text, b.btts_no),
                     ('Over 2.5 goles'::text, b.p_over25)
                   ) m(label, prob)
                WHERE m.prob IS NOT NULL AND m.prob >= 45::numeric AND m.prob <= 83.3
                ORDER BY m.prob DESC LIMIT 1) mp ON true
        ), ranked AS (
         SELECT cand.*, row_number() OVER (PARTITION BY cand.deporte, cand.dia_mx ORDER BY cand.mejor_pick_prob DESC, cand.p_reto_lider DESC, cand.muestra_min DESC, cand.kickoff, cand.canonical_event_id) AS rank_dia
           FROM cand
        )
 SELECT deporte, canonical_event_id, home_team, away_team, competition_name, escudo_home, escudo_away,
    dia_mx, kickoff, mejor_pick, mejor_pick_prob, predicted_score, predicted_score_prob,
    p_reto_lider, model_version, muestra_min, rank_dia, rank_dia = 1 AS es_mejor_del_dia
   FROM ranked;

-- v_analisis_v2 is large (forma/xG/H2H/tendencias/clima/alineaciones, 1 row/event,
-- fail-closed per block). Its live definition is captured via the re-dump query in README.md.
