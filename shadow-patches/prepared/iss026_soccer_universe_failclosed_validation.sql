-- ISS-026 — SOCCER UNIVERSE / FAIL-CLOSED ACCEPTANCE
-- *** READ-ONLY VALIDATION — run after ISS-018..025 in preview/cutover txn. ***
-- Supersedes the old interpretation that a missing matrix row is an acceptable NO_MODEL state.
-- Contract: every soccer event in the active matrix window has exactly one canonical row;
-- lack of Motor B is represented by MODEL_STATUS=NO_MODEL + all P_RETO fields NULL.

-- A) Matrix coverage: ZERO missing canonical rows for the active matrix universe [-6h,+48h].
WITH ev AS (
  SELECT a.espn_event_id,a.fecha,a.home_nombre,a.away_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer'
    AND a.espn_event_id IS NOT NULL
    AND a.fecha>=now()-interval '6 hours'
    AND a.fecha< now()+interval '48 hours'
)
SELECT e.*
FROM ev e
LEFT JOIN public.v_prediccion_reto_futbol p
  ON p.canonical_event_id=e.espn_event_id
WHERE p.canonical_event_id IS NULL;
-- PASS: 0 rows.

-- B) Exactly one row per event. ZERO rows.
SELECT canonical_event_id,count(*) AS n
FROM public.v_prediccion_reto_futbol
GROUP BY canonical_event_id
HAVING count(*)<>1;

-- C) Allowed state machine only. ZERO rows.
SELECT canonical_event_id,model_status,unavailable_reason
FROM public.v_prediccion_reto_futbol
WHERE model_status NOT IN ('UNVALIDATED','INSUFFICIENT_SAMPLE','TEMPORAL_UNSAFE','NO_MODEL');

-- D) Fail-closed states may NEVER publish event P_RETO. ZERO rows.
SELECT canonical_event_id,model_status,p_local_gana,p_empate,p_visita_gana,
       p_btts_yes,p_btts_no,linea_ou,p_over,p_under
FROM public.v_prediccion_reto_futbol
WHERE model_status IN ('INSUFFICIENT_SAMPLE','TEMPORAL_UNSAFE','NO_MODEL')
  AND (
    p_local_gana IS NOT NULL OR p_empate IS NOT NULL OR p_visita_gana IS NOT NULL
    OR p_btts_yes IS NOT NULL OR p_btts_no IS NOT NULL
    OR linea_ou IS NOT NULL OR p_over IS NOT NULL OR p_under IS NOT NULL
  );

-- E) Every fail-closed state has an explicit reason. ZERO rows.
SELECT canonical_event_id,model_status,model_sample,min_sample_required,unavailable_reason
FROM public.v_prediccion_reto_futbol
WHERE model_status<>'UNVALIDATED'
  AND nullif(unavailable_reason,'') IS NULL;

-- F) Sample floor semantics. ZERO rows.
SELECT canonical_event_id,model_sample,min_sample_required,model_status
FROM public.v_prediccion_reto_futbol
WHERE model_sample IS NOT NULL
  AND model_sample<min_sample_required
  AND model_status<>'INSUFFICIENT_SAMPLE';

-- G) Ready state requires complete 1X2 and temporal safety. ZERO rows.
SELECT canonical_event_id,model_status,temporal_safe,p_local_gana,p_empate,p_visita_gana
FROM public.v_prediccion_reto_futbol
WHERE model_status='UNVALIDATED'
  AND (
    temporal_safe IS DISTINCT FROM true
    OR p_local_gana IS NULL OR p_empate IS NULL OR p_visita_gana IS NULL
  );

-- H) Flagship/Pick del Día universe is STRICTLY upcoming [now,+48h).
-- This query is the backend oracle for the frontend regression test.
SELECT canonical_event_id,home_nombre,away_nombre,scheduled_at,reto_score
FROM public.v_prediccion_reto_futbol
WHERE scheduled_at>=now()
  AND scheduled_at<now()+interval '48 hours'
  AND reto_score IS NOT NULL
ORDER BY reto_score DESC,scheduled_at ASC,canonical_event_id ASC;

-- PASS requires A..G = zero violations. H is compared directly against the visible
-- Reto13M flagship #1 and Pick del Día alias during authenticated browser smoke.
