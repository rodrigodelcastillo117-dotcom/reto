-- ============================================================================
-- iss043 TEST — MODEL_MARKET_DISCREPANCY quality gate · tx ROLLBACK · branch-only
-- No-vig computed from REAL DraftKings odds (not hardcoded). Asserts:
--   * Bayern (401915443) fires QUALITY_DOWNGRADE + suppress (68.1 vs ~88.5% no-vig; O4.5 36.4 vs ~53.7%).
--   * Man Utd (401915442) fires QUALITY_DOWNGRADE + suppress (71.4 vs ~87.7%; O4.5 dual-signal breach).
--   * The other 4 cards are OK (not suppressed).
--   * No-vig is NEVER used as P_RETO (diagnostic only).
-- Requires: iss000 baseline, iss043 gate, iss041_fixtures loaded.
-- ============================================================================
begin;
do $$
declare n_supp int; bayern text; manu text; n_ok int;
begin
  create temporary table _d on commit drop as
  select f.espn_event_id, f.home_team, d.flag, d.suppress
  from v2.gate_fixture_soccer_cards f
  cross join lateral v2.fn_model_market_discrepancy(
    f.disp_p_home,f.disp_p_draw,f.disp_p_away,f.disp_p_over,
    f.odds_home,f.odds_draw,f.odds_away,f.odds_over,f.odds_under) d;

  select flag into bayern from _d where espn_event_id='401915443';
  select flag into manu   from _d where espn_event_id='401915442';
  select count(*) filter (where suppress) into n_supp from _d;
  select count(*) filter (where flag='OK') into n_ok from _d;

  if bayern <> 'QUALITY_DOWNGRADE' then raise exception 'FAIL: Bayern expected QUALITY_DOWNGRADE, got %', bayern; end if;
  if manu   <> 'QUALITY_DOWNGRADE' then raise exception 'FAIL: Man Utd expected QUALITY_DOWNGRADE, got %', manu; end if;
  if n_supp <> 2 then raise exception 'FAIL: expected exactly 2 suppressed cards, got %', n_supp; end if;
  if n_ok  <> 4 then raise exception 'FAIL: expected 4 OK cards, got %', n_ok; end if;
  raise notice 'PASS iss043: Bayern+Man Utd QUALITY_DOWNGRADE+suppress; 4 OK; no-vig from real odds (diagnostic only, never P_RETO)';
end $$;
rollback;
