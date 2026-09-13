-- ============================================================================
-- iss053a — NFL CLEAN-INSTALL PREREQUISITE · STAGED
-- ============================================================================
-- NO PROD MUTATION · additive/idempotent · RELEASE_GATE=HOLD.
--
-- Exact-candidate reproducibility repair for iss054_nfl_brain_decision_snapshot.sql.
-- iss054 seeds nfl-2026.09.2 by copying rows from v2.nfl_points_shape BEFORE the
-- file's later CREATE TABLE statement. On a clean disposable where the table does
-- not already exist, that ordering makes iss054 fail even though production happens
-- to have the table from an earlier historical install.
--
-- This prerequisite makes the dependency explicit and clean-install safe. It does
-- not seed any probabilities, authorize publication, or touch production.
-- ============================================================================

create schema if not exists v2;

create table if not exists v2.nfl_points_shape (
  model_version text not null,
  points int not null,
  observaciones int not null,
  fuente text not null,
  primary key (model_version, points)
);
