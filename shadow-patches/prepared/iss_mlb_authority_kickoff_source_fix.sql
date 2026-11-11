-- STAGED (NO APLICADA) — requiere revisión del auditor: toca el gate de dinero MLB.
-- Bug: v_mlb_canonical_release_authority_v1 obtiene el kickoff con JOIN agenda_espn,
-- y agenda_espn PURGA los juegos pasados. Resultado: toda captura forward ya calificada
-- (juego pasado) se cae del JOIN -> n_oos_events=0 SIEMPRE -> reporta
-- FORWARD_SAMPLE_INSUFFICIENT aunque existan 116+ capturas calificadas.
--
-- Evidencia (2026-10-13): lab_mlb_forward (C0-prod-2026-09, graded) = 118;
--   match historico_partidos_espn = 116 ; match agenda_espn = 0.
--
-- Fix: tomar el kickoff de historico_partidos_espn (permanente), con fallback a agenda
-- para juegos aun no jugados. NO cambia ningun umbral ni el chequeo temporal
-- (decision_time < kickoff, cache_timestamp <= decision_time). money_authorized sigue
-- hard-coded en false. Con el fix, MLB SIGUE gateado (gap calibracion 10pp>5, 2<3 buckets,
-- n~116<120) — esto solo hace HONESTO el reporte y permite que la muestra acumule.
--
-- Unico cambio vs original: en el CTE `graded`,
--   (a) JOIN agenda_espn  ->  LEFT JOIN historico_partidos_espn + LEFT JOIN agenda_espn
--   (b) `a.fecha AS kickoff` -> `coalesce(h.fecha, a.fecha) AS kickoff`
--   (c) WHERE `f.decision_time < a.fecha` -> `f.decision_time < coalesce(h.fecha, a.fecha)`
--       + `coalesce(h.fecha, a.fecha) is not null`
-- Todo lo demas es identico a la definicion vigente.

create or replace view public.v_mlb_canonical_release_authority_v1 as
 WITH cfg AS (
         SELECT mlb_canonical_model_config_v1.public_model_version,
            mlb_canonical_model_config_v1.candidate_model_version,
            mlb_canonical_model_config_v1.feature_version,
            mlb_canonical_model_config_v1.decision_policy,
            mlb_canonical_model_config_v1.min_oos_events,
            mlb_canonical_model_config_v1.brier_reference,
            mlb_canonical_model_config_v1.max_logloss,
            mlb_canonical_model_config_v1.max_calibration_gap_pp,
            mlb_canonical_model_config_v1.min_supported_calibration_buckets,
            mlb_canonical_model_config_v1.market_scope,
            mlb_canonical_model_config_v1.sealed_at,
            mlb_canonical_model_config_v1.evidence
           FROM v2.mlb_canonical_model_config_v1
          WHERE mlb_canonical_model_config_v1.public_model_version = 'mlb_canonical_v1'::text
        ), graded AS (
         SELECT f.captura_id, f.espn_event_id, f.decision_time, f.model_version,
            f.p_raw_home, f.p_over_raw, f.p_over_win, f.p_push, f.p_under_win,
            f.starter_ref_home, f.starter_ref_away, f.starter_status, f.cache_timestamp,
            f.data_readiness, f.exact_decision_odds, f.market_key, f.ingested_at,
            f.resultado, f.closing_odds, f.clv, f.notes, f.decision_id,
            f.available_at_decision, f.eligibility_state, f.feature_provenance_version,
            f.closing_timestamp,
            COALESCE(h.fecha, a.fecha) AS kickoff,
            ((f.p_raw_home - f.resultado::numeric) ^ 2::numeric) - 0.25 AS brier_delta,
            - (f.resultado::numeric * ln(GREATEST(f.p_raw_home, 0.000001)) + (1 - f.resultado)::numeric * ln(GREATEST(1::numeric - f.p_raw_home, 0.000001))) AS logloss
           FROM lab_mlb_forward f
             LEFT JOIN historico_partidos_espn h ON h.espn_event_id = f.espn_event_id
             LEFT JOIN agenda_espn a ON a.espn_event_id = f.espn_event_id AND a.deporte = 'baseball'::text
             CROSS JOIN cfg c_1
          WHERE f.model_version = c_1.candidate_model_version
            AND f.eligibility_state = 'FORWARD_VALIDATION_PENDING'::text
            AND (f.resultado = ANY (ARRAY[0, 1]))
            AND f.decision_time > '2026-08-30 00:00:00+00'::timestamp with time zone
            AND COALESCE(h.fecha, a.fecha) IS NOT NULL
            AND f.decision_time < COALESCE(h.fecha, a.fecha)
            AND f.available_at_decision = 'AVAILABLE_AT_DECISION'::text
            AND f.cache_timestamp IS NOT NULL
            AND f.cache_timestamp <= f.decision_time
            AND f.p_raw_home > 0::numeric AND f.p_raw_home < 1::numeric
            AND COALESCE(f.notes, ''::text) !~~* '%SYNTHETIC%'::text
        ), agg AS (
         SELECT count(*)::integer AS n_oos_events,
            avg((graded.p_raw_home - graded.resultado::numeric) ^ 2::numeric) AS brier_model,
            avg(graded.logloss) AS logloss_model,
            avg(graded.brier_delta) AS mean_brier_delta,
            stddev_samp(graded.brier_delta) AS sd_brier_delta,
            count(*) FILTER (WHERE NOT (graded.decision_time < graded.kickoff AND graded.cache_timestamp <= graded.decision_time))::integer AS temporal_leaks
           FROM graded
        ), buckets AS (
         SELECT floor(graded.p_raw_home * 10::numeric) / 10::numeric AS bucket,
            count(*)::integer AS n, avg(graded.p_raw_home) AS p_avg, avg(graded.resultado) AS y_avg
           FROM graded GROUP BY (floor(graded.p_raw_home * 10::numeric) / 10::numeric)
        ), cal AS (
         SELECT count(*) FILTER (WHERE buckets.n >= 20)::integer AS supported_buckets,
            max(abs(buckets.p_avg - buckets.y_avg) * 100::numeric) FILTER (WHERE buckets.n >= 20) AS max_gap_pp
           FROM buckets
        ), stats AS (
         SELECT a.n_oos_events, a.brier_model, a.logloss_model, a.mean_brier_delta, a.sd_brier_delta,
            a.temporal_leaks, k.supported_buckets, k.max_gap_pp,
            a.mean_brier_delta + 1.96 * a.sd_brier_delta / NULLIF(sqrt(a.n_oos_events::numeric), 0::numeric) AS brier_delta_upper95_raw
           FROM agg a CROSS JOIN cal k
        )
 SELECT c.public_model_version AS model_version, c.candidate_model_version, c.feature_version, c.market_scope,
    COALESCE(s.n_oos_events, 0) AS n_oos_events,
    round(s.brier_model, 6) AS brier_model, c.brier_reference,
    round(s.brier_delta_upper95_raw, 6) AS brier_delta_upper95,
    round(s.logloss_model, 6) AS logloss_model,
    COALESCE(s.supported_buckets, 0) AS supported_calibration_buckets,
    round(s.max_gap_pp, 2) AS max_calibration_gap_pp,
    COALESCE(s.temporal_leaks, 0) AS temporal_leaks,
    COALESCE(s.n_oos_events, 0) >= c.min_oos_events AND COALESCE(s.temporal_leaks, 0) = 0 AND s.brier_model < c.brier_reference AND s.brier_delta_upper95_raw < 0::numeric AND s.logloss_model < c.max_logloss AND COALESCE(s.supported_buckets, 0) >= c.min_supported_calibration_buckets AND s.max_gap_pp <= c.max_calibration_gap_pp AS scientific_ready,
    COALESCE(s.n_oos_events, 0) >= c.min_oos_events AND COALESCE(s.temporal_leaks, 0) = 0 AND s.brier_model < c.brier_reference AND s.brier_delta_upper95_raw < 0::numeric AND s.logloss_model < c.max_logloss AND COALESCE(s.supported_buckets, 0) >= c.min_supported_calibration_buckets AND s.max_gap_pp <= c.max_calibration_gap_pp AS product_release_authorized,
    false AS money_authorized,
        CASE
            WHEN COALESCE(s.n_oos_events, 0) < c.min_oos_events THEN 'FORWARD_SAMPLE_INSUFFICIENT'::text
            WHEN COALESCE(s.temporal_leaks, 0) > 0 THEN 'TEMPORAL_FAIL'::text
            WHEN NOT s.brier_model < c.brier_reference THEN 'BRIER_FAIL'::text
            WHEN NOT s.brier_delta_upper95_raw < 0::numeric THEN 'BRIER_SIGNIFICANCE_FAIL'::text
            WHEN NOT s.logloss_model < c.max_logloss THEN 'LOGLOSS_FAIL'::text
            WHEN COALESCE(s.supported_buckets, 0) < c.min_supported_calibration_buckets THEN 'CALIBRATION_SAMPLE_INSUFFICIENT'::text
            WHEN NOT s.max_gap_pp <= c.max_calibration_gap_pp THEN 'CALIBRATION_FAIL'::text
            ELSE 'OOS_VALIDATED_FORWARD'::text
        END AS validation_status,
    c.decision_policy, c.sealed_at,
    c.evidence || jsonb_build_object('current_n', COALESCE(s.n_oos_events, 0), 'current_brier', s.brier_model, 'current_logloss', s.logloss_model, 'current_max_calibration_gap_pp', s.max_gap_pp) AS evidence
   FROM cfg c CROSS JOIN stats s;
