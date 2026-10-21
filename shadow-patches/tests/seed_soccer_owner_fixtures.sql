-- ============================================================================
-- seed_soccer_owner_fixtures.sql — the 6 REAL owner UCL cards (P0 gate fixtures)
-- ============================================================================
-- VERSIONED SEED (was the missing `iss041_fixtures`). Populates
-- v2.gate_fixture_soccer_cards (created empty by iss045) with the SIX owner
-- Champions-League cards from the coherence/discrepancy audit. Every value here is
-- REAL, pulled READ-ONLY from prod wpiztubmmmzclhlprgpd.v2.soccer_prediction_v2
-- (model_version crossleague_v1, latest computed_at per event, 2026-09-10):
--   lambda_home / lambda_away  = crossleague Dixon-Coles lambdas (prod model output)
--   over_line, odds_*          = real DraftKings line + prices used at prediction time
--   disp_p_*                   = prod displayed probabilities (the audited values)
-- rho = 0.0705 (v2.crossleague_params.rho, crossleague_v1). maxg = 10.
-- NO value is invented. NO PROD MUTATION. Branch-only. Idempotent (truncate+insert).
--
-- Cards (espn_event_id): 401915422 PSV–Shakhtar, 401915440 Slavia–Lens,
--   401915441 Como–RB Leipzig, 401915442 Man United–Sabah, 401915443 Bayern–Bodo/Glimt,
--   401915444 Fenerbahce–AS Roma. Bayern + Man United are the two the discrepancy gate
--   suppresses (QUALITY_DOWNGRADE vs no-vig); the other four are OK.
-- ============================================================================

truncate table v2.gate_fixture_soccer_cards;
insert into v2.gate_fixture_soccer_cards
 (espn_event_id, home_team, away_team, competition, over_line, lambda_home, lambda_away, rho, maxg,
  odds_home, odds_draw, odds_away, odds_over, odds_under,
  disp_p_home, disp_p_draw, disp_p_away, disp_p_over, bookmaker) values
 ('401915422','PSV Eindhoven','Shakhtar Donetsk','UEFA Champions League',3.5, 2.289,1.308, 0.0705,10,
   1.488,4.700,6.000,2.100,1.714, 60.0,18.4,21.6,48.4,'DraftKings'),
 ('401915440','Slavia Prague','Lens','UEFA Champions League',2.5, 1.350,1.606, 0.0705,10,
   2.700,3.550,2.550,1.625,2.300, 33.0,22.7,44.3,56.7,'DraftKings'),
 ('401915441','Como','RB Leipzig','UEFA Champions League',3.5, 1.879,1.034, 0.0705,10,
   1.714,4.200,4.400,2.050,1.769, 57.9,20.9,21.3,33.3,'DraftKings'),
 ('401915442','Manchester United','Sabah FK','UEFA Champions League',4.5, 2.499,0.963, 0.0705,10,
   1.071,12.000,29.000,2.150,1.714, 71.4,15.6,13.1,26.7,'DraftKings'),
 ('401915443','Bayern Munich','Bodo/Glimt','UEFA Champions League',4.5, 2.697,1.266, 0.0705,10,
   1.071,14.000,26.000,1.714,2.150, 68.1,15.6,16.2,36.4,'DraftKings'),
 ('401915444','Fenerbahce','AS Roma','UEFA Champions League',2.5, 1.370,1.444, 0.0705,10,
   3.650,3.650,2.000,1.571,2.400, 36.6,23.5,39.9,53.4,'DraftKings');
