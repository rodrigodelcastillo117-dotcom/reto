-- ============================================================================
-- iss047 FANTASY "EQUIPO" START/SIT TEST — SUPERSEDED (v1)
-- ============================================================================
-- This v1 test targeted the WITHDRAWN v1 contract (which wrongly modelled the
-- owner's league as "PPR + Superflex + TE Premium"). The STOP-SHIP audit
-- (GitHub issue #4, comment 5620923816) rejected that model. The authoritative
-- tests for the corrected v2 contract (exact Yahoo league: PPR 1.0, starters
-- QB/WR/WR/RB/RB/TE/FLEX/K/DEF, BN×6, IR×2 — NO Superflex, NO TE-premium) live in:
--
--     shadow-patches/tests/iss047_fantasy_equipo_v2_test.sql
--
-- Run THAT file. This stub is intentionally a no-op so the suite stays green.
-- ============================================================================
do $$
begin
  raise notice 'iss047 v1 test superseded — run iss047_fantasy_equipo_v2_test.sql';
end;
$$;
