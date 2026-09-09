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
--   * data_asof must be <= decision_time; SAFE_CURRENT is deliberately not trusted.

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
  SELECT jsonb_strip_nulls(jsonb_build_object(
    'feature',p_feature,
    'source',p_source,
    'provenance',p_source,
    'role',CASE
      WHEN p_feature='canonical_prediction' THEN 'MODEL_ACTIVE'
      WHEN p_feature IN ('xg_shots_possession_corners_cards','weather') THEN 'AVAILABLE_NOT_USED'
      ELSE 'CONTEXT_ONLY'
    END,
    'available',coalesce(p_available,false),
    'used_in_model',coalesce(p_used_in_model,false),
    'used_in_context',coalesce(p_used_in_context,false),
    'as_of',p_as_of,
    'decision_time',p_decision_time,
    'temporal_status',p_temporal_status,
    'temporal_safe',CASE
      WHEN p_temporal_status='STATIC' THEN true
      WHEN p_temporal_status IN ('SAFE_ASOF','SAFE_COMPUTED_ASOF')
           AND p_as_of IS NOT NULL
           AND p_decision_time IS NOT NULL
           AND p_as_of <= p_decision_time THEN true
      WHEN p_temporal_status IS NULL THEN NULL
      ELSE false END,
    'freshness_seconds',CASE
      WHEN p_temporal_status='STATIC' THEN 0
      WHEN p_as_of IS NOT NULL AND p_decision_time IS NOT NULL AND p_as_of<=p_decision_time
      THEN extract(epoch from (p_decision_time-p_as_of))::bigint
      ELSE NULL END,
    'missing_reason',CASE
      WHEN coalesce(p_available,false)=false
      THEN coalesce(nullif(p_missing_reason,''),'SOURCE_NOT_AVAILABLE_BEFORE_DECISION_TIME')
      ELSE p_missing_reason END,
    'details',p_details
  ));
$$;

COMMENT ON FUNCTION public.reto_manifest_item(text,text,boolean,boolean,boolean,timestamptz,timestamptz,text,text,jsonb)
IS 'SOCCER_FULL_DATA_V1 manifest helper: explicit provenance/role/freshness; only MODEL_ACTIVE may alter P_RETO; no SAFE_CURRENT shortcut.';

-- Acceptance is ISS-024 sections 8 / 8b / 8c.
-- Expected zero violations after ISS-018..025 are applied in preview/cutover txn.
