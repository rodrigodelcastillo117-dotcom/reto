-- ISS-025 — SOCCER FULL-DATA MANIFEST CONTRACT HARDENING
-- *** STAGED — NO APLICADO A PROD ***
-- Apply AFTER ISS-023 in the coordinated preview/cutover transaction.
-- No data mutation. Replaces only the manifest JSON helper with the same signature.
--
-- Contract required by the P0 soccer closure gate:
--   * every source declares provenance + semantic role;
--   * MODEL_ACTIVE is the only role permitted to alter P_RETO;
--   * CONTEXT_ONLY / AVAILABLE_NOT_USED may enrich dossier/manifest but not P_RETO;
--   * every non-static available source has explicit as_of and freshness;
--   * data_asof must be <= decision_time; SAFE_CURRENT is deliberately not trusted;
--   * a canonical matrix ROW is not the same as an AVAILABLE MODEL. NO_MODEL and
--     INSUFFICIENT_SAMPLE rows are intentionally retained fail-closed, but their
--     canonical_prediction item must say available=false / used_in_model=false.

CREATE OR REPLACE FUNCTION public.reto_manifest_item(
  p_feature text,
  p_source text,
  p_available boolean,
  p_used_in_model boolean,
  p_used_in_context boolean,
  p_as_of timestamptz,
  p_decision_time timestamptz,
  p_temporal_status text,
  p_missing_reason text DEFAULT NULL,
  p_details jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  WITH effective AS (
    SELECT
      CASE
        WHEN p_feature='canonical_prediction'
          THEN coalesce(p_available,false)
               AND coalesce(p_details->>'model_status','')='UNVALIDATED'
        ELSE coalesce(p_available,false)
      END AS available_eff,
      CASE
        WHEN p_feature='canonical_prediction'
          THEN coalesce(p_used_in_model,false)
               AND coalesce(p_available,false)
               AND coalesce(p_details->>'model_status','')='UNVALIDATED'
        ELSE coalesce(p_used_in_model,false) AND coalesce(p_available,false)
      END AS used_model_eff,
      CASE
        WHEN p_feature='canonical_prediction'
             AND coalesce(p_details->>'model_status','')='NO_MODEL'
          THEN 'MISSING'
        ELSE p_temporal_status
      END AS temporal_eff
  )
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'feature',p_feature,
    'source',p_source,
    'provenance',p_source,
    'role',CASE
      WHEN p_feature='canonical_prediction' THEN 'MODEL_ACTIVE'
      WHEN p_feature IN ('xg_shots_possession_corners_cards','weather') THEN 'AVAILABLE_NOT_USED'
      ELSE 'CONTEXT_ONLY'
    END,
    'available',e.available_eff,
    'used_in_model',e.used_model_eff,
    'used_in_context',coalesce(p_used_in_context,false) AND e.available_eff,
    'as_of',p_as_of,
    'decision_time',p_decision_time,
    'temporal_status',e.temporal_eff,
    'temporal_safe',CASE
      WHEN e.temporal_eff='STATIC' THEN true
      WHEN e.temporal_eff IN ('SAFE_ASOF','SAFE_COMPUTED_ASOF')
           AND p_as_of IS NOT NULL
           AND p_decision_time IS NOT NULL
           AND p_as_of <= p_decision_time THEN true
      WHEN e.temporal_eff IS NULL THEN NULL
      ELSE false END,
    'freshness_seconds',CASE
      WHEN e.temporal_eff='STATIC' THEN 0
      WHEN p_as_of IS NOT NULL AND p_decision_time IS NOT NULL AND p_as_of<=p_decision_time
      THEN extract(epoch from (p_decision_time-p_as_of))::bigint
      ELSE NULL END,
    'missing_reason',CASE
      WHEN e.available_eff=false
      THEN coalesce(nullif(p_missing_reason,''),'SOURCE_NOT_AVAILABLE_BEFORE_DECISION_TIME')
      ELSE p_missing_reason END,
    'details',p_details
  ))
  FROM effective e;
$$;

COMMENT ON FUNCTION public.reto_manifest_item(text,text,boolean,boolean,boolean,timestamptz,timestamptz,text,text,jsonb)
IS 'SOCCER_FULL_DATA_V1 manifest helper: explicit provenance/role/freshness; only an available temporally governed MODEL_ACTIVE prediction may alter P_RETO; NO_MODEL/INSUFFICIENT rows stay visible fail-closed.';

-- Acceptance is ISS-024 sections 8 / 8b / 8c + ISS-026.
-- Expected zero violations after ISS-018..026 are applied in preview/cutover txn.
