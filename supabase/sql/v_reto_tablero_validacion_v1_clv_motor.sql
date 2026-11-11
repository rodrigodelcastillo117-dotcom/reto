-- v_reto_tablero_validacion_v1 — repunte del bloque CLV al "motor" ESPN (cierre real, gratis).
-- Motivo: el bloque CLV anterior leía v_reto_clv_multicasa_v1 / reto_clv_snapshots_v1, cuya
-- "línea de cierre" se mide ~12h antes del kickoff con ~1 foto por evento => nunca converge
-- (quedaba en 'recolectando' permanente). El motor v_reto_clv_motor_v1 compara la prob de
-- entrada contra el CIERRE ESPN capturado en la ventana T-90min->kickoff (cron cierre-momios-espn,
-- gratis, cada 5 min) y ya muestra señal real y positiva en nba/nhl/nfl.
-- DINERO/EV/KELLY siguen FUERA. Fútbol (P0) aún no tiene cierre pegado => se reporta 'pendiente'.
-- Solo cambia el bloque CLV; todo lo demás de la vista queda idéntico.
CREATE OR REPLACE VIEW public.v_reto_tablero_validacion_v1 AS
 WITH g AS (
         SELECT v_reto_pick_grade_v1.deporte,
            v_reto_pick_grade_v1.prob_pct,
            v_reto_pick_grade_v1.acierto,
            v_reto_pick_grade_v1.kickoff,
            lower(COALESCE(v_reto_pick_grade_v1.mercado, '(nulo)'::text)) AS mkt
           FROM v_reto_pick_grade_v1
          WHERE v_reto_pick_grade_v1.acierto IS NOT NULL
        ), por AS (
         SELECT jsonb_agg(jsonb_build_object('d', s.deporte, 'n', s.n, 'hit', s.hit, 'dice', s.dice, 'brier', s.brier, 'n_alta', s.n_alta, 'hit_alta', s.hit_alta) ORDER BY s.n DESC) AS j
           FROM ( SELECT g.deporte,
                    count(*) AS n,
                    round(avg(g.acierto::numeric) * 100::numeric, 1) AS hit,
                    round(avg(g.prob_pct), 1) AS dice,
                    round(avg((g.prob_pct / 100.0 - g.acierto::numeric) ^ 2::numeric), 4) AS brier,
                    count(*) FILTER (WHERE g.prob_pct >= 70::numeric) AS n_alta,
                    round(avg(g.acierto::numeric) FILTER (WHERE g.prob_pct >= 70::numeric) * 100::numeric, 1) AS hit_alta
                   FROM g
                  GROUP BY g.deporte) s
        ), buck AS (
         SELECT jsonb_agg(jsonb_build_object('b', b.bucket, 'n', b.n, 'dice', b.dice, 'real', b.rl) ORDER BY b.ord) AS j
           FROM ( SELECT
                        CASE
                            WHEN g.prob_pct < 55::numeric THEN '50-55'::text
                            WHEN g.prob_pct < 60::numeric THEN '55-60'::text
                            WHEN g.prob_pct < 65::numeric THEN '60-65'::text
                            WHEN g.prob_pct < 70::numeric THEN '65-70'::text
                            WHEN g.prob_pct < 80::numeric THEN '70-80'::text
                            ELSE '80+'::text
                        END AS bucket,
                    min(
                        CASE
                            WHEN g.prob_pct < 55::numeric THEN 1
                            WHEN g.prob_pct < 60::numeric THEN 2
                            WHEN g.prob_pct < 65::numeric THEN 3
                            WHEN g.prob_pct < 70::numeric THEN 4
                            WHEN g.prob_pct < 80::numeric THEN 5
                            ELSE 6
                        END) AS ord,
                    count(*) AS n,
                    round(avg(g.prob_pct), 1) AS dice,
                    round(avg(g.acierto::numeric) * 100::numeric, 1) AS rl
                   FROM g
                  GROUP BY (
                        CASE
                            WHEN g.prob_pct < 55::numeric THEN '50-55'::text
                            WHEN g.prob_pct < 60::numeric THEN '55-60'::text
                            WHEN g.prob_pct < 65::numeric THEN '60-65'::text
                            WHEN g.prob_pct < 70::numeric THEN '65-70'::text
                            WHEN g.prob_pct < 80::numeric THEN '70-80'::text
                            ELSE '80+'::text
                        END)) b
        ), wk AS (
         SELECT jsonb_agg(jsonb_build_object('w', to_char(w.wk, 'DD Mon'::text), 'n', w.n, 'hit', w.hit) ORDER BY w.wk) AS j
           FROM ( SELECT date_trunc('week'::text, g.kickoff) AS wk,
                    count(*) AS n,
                    round(avg(g.acierto::numeric) * 100::numeric, 1) AS hit
                   FROM g
                  GROUP BY (date_trunc('week'::text, g.kickoff))) w
        ), merc AS (
         SELECT jsonb_agg(jsonb_build_object('m', m.mkt, 'n', m.n, 'dice', m.dice, 'real', m.rl, 'sesgo', m.sesgo) ORDER BY m.n DESC) AS j
           FROM ( SELECT g.mkt,
                    count(*) AS n,
                    round(avg(g.prob_pct), 1) AS dice,
                    round(avg(g.acierto::numeric) * 100::numeric, 1) AS rl,
                    round(avg(g.prob_pct) - avg(g.acierto::numeric) * 100::numeric, 1) AS sesgo
                   FROM g
                  GROUP BY g.mkt
                 HAVING count(*) >= 25) m
        ), tot AS (
         SELECT jsonb_build_object('n', count(*), 'hit', round(avg(g.acierto::numeric) * 100::numeric, 1), 'dice', round(avg(g.prob_pct), 1), 'n_alta', count(*) FILTER (WHERE g.prob_pct >= 70::numeric), 'hit_alta', round(avg(g.acierto::numeric) FILTER (WHERE g.prob_pct >= 70::numeric) * 100::numeric, 1), 'desde', to_char(min(g.kickoff), 'DD Mon'::text), 'hasta', to_char(max(g.kickoff), 'DD Mon YYYY'::text)) AS j
           FROM g
        ), forma AS (
         SELECT jsonb_build_object('d7', ( SELECT jsonb_build_object('n', count(*), 'hit', round(avg(g.acierto::numeric) * 100::numeric, 1)) AS jsonb_build_object
                   FROM g
                  WHERE g.kickoff > (now() - '7 days'::interval)), 'd30', ( SELECT jsonb_build_object('n', count(*), 'hit', round(avg(g.acierto::numeric) * 100::numeric, 1)) AS jsonb_build_object
                   FROM g
                  WHERE g.kickoff > (now() - '30 days'::interval))) AS j
        ), clv_m AS (
         SELECT DISTINCT ON (u.espn_event_id) u.espn_event_id,
            u.deporte,
            u.clv_pp,
            u.le_gano_al_cierre,
            u.kickoff
           FROM ( SELECT reto_clv_motor_hist_v1.espn_event_id,
                    reto_clv_motor_hist_v1.deporte,
                    reto_clv_motor_hist_v1.clv_pp,
                    reto_clv_motor_hist_v1.le_gano_al_cierre,
                    reto_clv_motor_hist_v1.kickoff
                   FROM public.reto_clv_motor_hist_v1
                UNION ALL
                 SELECT v_reto_clv_motor_v1.espn_event_id,
                    v_reto_clv_motor_v1.deporte,
                    v_reto_clv_motor_v1.clv_pp,
                    v_reto_clv_motor_v1.le_gano_al_cierre,
                    v_reto_clv_motor_v1.kickoff
                   FROM v_reto_clv_motor_v1
                  WHERE v_reto_clv_motor_v1.clv_pp IS NOT NULL AND v_reto_clv_motor_v1.kickoff < now()) u
          ORDER BY u.espn_event_id
        ), clv_pd AS (
         SELECT jsonb_agg(jsonb_build_object('d', x.deporte, 'n', x.n, 'gano_pct', x.gano, 'clv_pp', x.clv) ORDER BY x.n DESC) AS j
           FROM ( SELECT clv_m.deporte,
                    count(*) AS n,
                    round(100.0 * avg(clv_m.le_gano_al_cierre::integer::numeric), 1) AS gano,
                    round(avg(clv_m.clv_pp), 2) AS clv
                   FROM clv_m
                  GROUP BY clv_m.deporte) x
        ), clv AS (
         SELECT jsonb_build_object(
                'fuente', 'motor_cierre_espn',
                'alcance', 'nba/nhl/nfl — cierre ESPN (ventana T-90min, gratis)',
                'eventos', ( SELECT count(*) FROM clv_m),
                'dias_datos', ( SELECT count(DISTINCT clv_m.kickoff::date) FROM clv_m),
                'clv_pp', ( SELECT round(avg(clv_m.clv_pp), 2) FROM clv_m),
                'gano_cierre_pct', ( SELECT round(100.0 * avg(clv_m.le_gano_al_cierre::integer::numeric), 1) FROM clv_m),
                'por_deporte', ( SELECT clv_pd.j FROM clv_pd),
                'soccer', ( SELECT jsonb_build_object(
                        'fuente', 'evidencia_mercado_samebook_dk',
                        'alcance', '1X2/ML — cierre DraftKings T-0..30min (mediana ~7min), mismo libro',
                        'eventos', s.picks_con_cierre,
                        'clv_pp', s.drift_promedio_pp,
                        'gano_cierre_pct', s.pct_clv_positivo,
                        'desde', s.desde,
                        'hasta', s.hasta,
                        'estado',
                        CASE
                            WHEN s.picks_con_cierre < 100 THEN 'preliminar'::text
                            WHEN s.pct_clv_positivo >= 55::numeric THEN 'positivo'::text
                            WHEN s.pct_clv_positivo <= 45::numeric THEN 'negativo'::text
                            ELSE 'neutral'::text
                        END)
                   FROM public.reto_clv_cache_v1 s WHERE s.deporte = 'soccer'::text ),
                'estado',
                CASE
                    WHEN ( SELECT count(*) FROM clv_m) < 30 THEN 'recolectando'::text
                    WHEN ( SELECT count(*) FROM clv_m) < 100 THEN
                        CASE WHEN ( SELECT round(100.0 * avg(clv_m.le_gano_al_cierre::integer::numeric), 1) FROM clv_m) >= 55::numeric
                             THEN 'preliminar_positivo'::text ELSE 'preliminar'::text END
                    ELSE
                        CASE WHEN ( SELECT round(100.0 * avg(clv_m.le_gano_al_cierre::integer::numeric), 1) FROM clv_m) >= 55::numeric
                             THEN 'positivo'::text ELSE 'neutral'::text END
                END) AS j
        )
 SELECT jsonb_build_object('generado_at', now(), 'totales', ( SELECT tot.j
           FROM tot), 'forma', ( SELECT forma.j
           FROM forma), 'por_deporte', ( SELECT por.j
           FROM por), 'por_mercado', ( SELECT merc.j
           FROM merc), 'buckets', ( SELECT buck.j
           FROM buck), 'semanas', ( SELECT wk.j
           FROM wk), 'clv', ( SELECT clv.j
           FROM clv)) AS data;
