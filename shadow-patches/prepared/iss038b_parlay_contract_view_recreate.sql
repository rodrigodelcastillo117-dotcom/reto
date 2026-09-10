-- ============================================================================
-- iss038b — PRE-CUTOVER VIEW RECREATE GUARD · STAGED ONLY
-- ============================================================================
-- PostgreSQL cannot CREATE OR REPLACE a view when the new SELECT changes an
-- existing column's name/position (observed on isolated soccer-validation branch:
-- old column n_legs occupied the slot where the new contract adds decision_time).
-- Apply immediately BEFORE iss038_parlay_joint_prob_failclosed.sql.
-- Branch validation only; DO NOT APPLY TO PROD while RELEASE_GATE=HOLD.
-- ============================================================================

drop view if exists v2.v_parlay_canonical_contract;
drop view if exists v2.v_parlay_non_authority_audit;

-- iss038 recreates both views with the canonical per-leg schema after this guard.
