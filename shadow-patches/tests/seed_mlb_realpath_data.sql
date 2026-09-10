-- ============================================================================
-- seed_mlb_realpath_data.sql — REAL MLB data slices for the iss052 branch gate
-- ============================================================================
-- Every row below was extracted READ-ONLY from production (project wpiztubmmmzclhlprgpd)
-- on 2026-09-10. Nothing here is invented. Provenance per section is stated inline so an
-- auditor can re-derive each slice with the generator in gen_mlb_realpath_seed.sql.
--
-- WHY THESE SLICES AND NOT THE WHOLE SEASON: the contract proofs (post-first-pitch
-- rejection, immutability, one-distribution coherence, replay idempotence, clock-stable
-- canonical read) are properties of the CONTRACT, not of sample size. The skill question is
-- a separate question and it was answered on the FULL prod corpus (1053 games) rather than
-- on a branch subset — see SOCCER/MLB evidence doc. Seeding 2078 cumulative observations to
-- re-derive a number already measured at full scale would add cost, not proof.
-- ============================================================================

-- ── A) agenda_espn: 30 REAL upcoming MLB fixtures (2026-09-10 23:05Z .. 2026-09-12 23:15Z)
-- source: public.agenda_espn where deporte='baseball' and fecha > now() and fecha < '2026-09-13'
-- fixture identity md5 (espn_event_id|fecha|home_espn_id|away_espn_id, ordered by event):
--   d556db66d72d41f66322a67b61a88d1e   <- asserted by the runner after load
insert into public.agenda_espn
  (espn_event_id, espn_endpoint, liga_id, liga_nombre, fecha,
   home_espn_id, away_espn_id, home_nombre, away_nombre, estado, deporte)
select v.espn_event_id, 'baseball/mlb', null, 'MLB', v.fecha::timestamptz,
       v.home_espn_id, v.away_espn_id, v.home_nombre, v.away_nombre, 'pre', 'baseball'
from (values
  ('401816883','2026-09-10 23:05:00+00','10','27','New York Yankees','Colorado Rockies'),
  ('401816886','2026-09-10 23:40:00+00','4','23','Chicago White Sox','Pittsburgh Pirates'),
  ('401816888','2026-09-11 22:45:00+00','20','3','Washington Nationals','Los Angeles Angels'),
  ('401816889','2026-09-11 23:07:00+00','14','1','Toronto Blue Jays','Baltimore Orioles'),
  ('401816890','2026-09-11 22:40:00+00','6','27','Detroit Tigers','Colorado Rockies'),
  ('401816891','2026-09-11 23:10:00+00','30','18','Tampa Bay Rays','Houston Astros'),
  ('401816892','2026-09-11 23:10:00+00','2','7','Boston Red Sox','Kansas City Royals'),
  ('401816893','2026-09-11 23:10:00+00','28','19','Miami Marlins','Los Angeles Dodgers'),
  ('401816894','2026-09-11 23:05:00+00','10','21','New York Yankees','New York Mets'),
  ('401816895','2026-09-11 23:15:00+00','15','22','Atlanta Braves','Philadelphia Phillies'),
  ('401816896','2026-09-12 00:15:00+00','24','4','St. Louis Cardinals','Chicago White Sox'),
  ('401816897','2026-09-11 23:40:00+00','8','17','Milwaukee Brewers','Cincinnati Reds'),
  ('401816898','2026-09-12 00:10:00+00','9','5','Minnesota Twins','Cleveland Guardians'),
  ('401816899','2026-09-11 18:20:00+00','16','23','Chicago Cubs','Pittsburgh Pirates'),
  ('401816900','2026-09-12 02:15:00+00','26','25','San Francisco Giants','San Diego Padres'),
  ('401816901','2026-09-12 01:40:00+00','11','12','Athletics','Seattle Mariners'),
  ('401816902','2026-09-12 01:40:00+00','29','13','Arizona Diamondbacks','Texas Rangers'),
  ('401816903','2026-09-12 20:05:00+00','20','3','Washington Nationals','Los Angeles Angels'),
  ('401816904','2026-09-12 19:07:00+00','14','1','Toronto Blue Jays','Baltimore Orioles'),
  ('401816905','2026-09-12 17:10:00+00','6','27','Detroit Tigers','Colorado Rockies'),
  ('401816906','2026-09-12 22:10:00+00','30','18','Tampa Bay Rays','Houston Astros'),
  ('401816907','2026-09-12 20:10:00+00','2','7','Boston Red Sox','Kansas City Royals'),
  ('401816908','2026-09-12 20:10:00+00','28','19','Miami Marlins','Los Angeles Dodgers'),
  ('401816909','2026-09-12 17:35:00+00','10','21','New York Yankees','New York Mets'),
  ('401816910','2026-09-12 23:15:00+00','15','22','Atlanta Braves','Philadelphia Phillies'),
  ('401816911','2026-09-12 23:15:00+00','24','4','St. Louis Cardinals','Chicago White Sox'),
  ('401816912','2026-09-12 23:10:00+00','8','17','Milwaukee Brewers','Cincinnati Reds'),
  ('401816913','2026-09-12 20:10:00+00','9','5','Minnesota Twins','Cleveland Guardians'),
  ('401816914','2026-09-12 18:20:00+00','16','23','Chicago Cubs','Pittsburgh Pirates'),
  ('401816915','2026-09-12 20:05:00+00','26','25','San Francisco Giants','San Diego Padres')
) as v(espn_event_id, fecha, home_espn_id, away_espn_id, home_nombre, away_nombre)
on conflict (espn_event_id) do nothing;

-- ── B) v2.mlb_run_rate_observation: REAL point-in-time season-to-date run rates
-- Derived in prod from public.mlb_linescore (per-inning runs, summed per competitor per game)
-- joined to public.lab_mlb_wf for the game timestamp, accumulated per team ordered by
-- (fecha, espn_event_id). THREE checkpoints per team (as of 2026-07-15, 2026-08-01, 2026-08-31)
-- so fn_mlb_features_asof's "latest observation at or before decision_time" is actually exercised
-- rather than assumed: a decision on 2026-09-10 must select the 08-30 row, and a replay at an
-- earlier decision_time must select an earlier row and produce DIFFERENT lambdas.
--
-- observed_at = game timestamp + 4h. That 4h is an explicit AVAILABILITY LAG (a game is not a
-- completed observation until it ends). It is not cosmetic: it is the reason a decision taken
-- during a game cannot consume that game's own result.
--
-- games per team here: 27..76. The 20-game readiness floor in mlb_model_config is therefore
-- satisfied by real data, not by lowering the bar.
insert into v2.mlb_run_rate_observation
  (team_espn_id, observed_at, runs_scored_pg, runs_allowed_pg, games, source)
values
  ('1','2026-07-12 21:35:00+00',4.5455,4.0606,33,'mlb_linescore_cum_asof'),
  ('1','2026-08-01 03:05:00+00',4.5652,4.2826,46,'mlb_linescore_cum_asof'),
  ('1','2026-08-30 06:05:00+00',4.5000,4.2571,70,'mlb_linescore_cum_asof'),
  ('2','2026-07-12 21:40:00+00',4.2222,3.5833,36,'mlb_linescore_cum_asof'),
  ('2','2026-07-30 05:40:00+00',4.4082,3.4898,49,'mlb_linescore_cum_asof'),
  ('2','2026-08-30 03:15:00+00',4.7895,3.5789,76,'mlb_linescore_cum_asof'),
  ('3','2026-07-12 22:10:00+00',4.9259,4.7778,27,'mlb_linescore_cum_asof'),
  ('3','2026-07-29 05:38:00+00',4.2432,4.4595,37,'mlb_linescore_cum_asof'),
  ('3','2026-08-30 06:07:00+00',3.6667,4.2333,60,'mlb_linescore_cum_asof'),
  ('4','2026-07-12 22:10:00+00',5.1250,4.0000,32,'mlb_linescore_cum_asof'),
  ('4','2026-08-01 03:10:00+00',5.0667,4.0222,45,'mlb_linescore_cum_asof'),
  ('4','2026-08-29 22:10:00+00',5.0870,4.4058,69,'mlb_linescore_cum_asof'),
  ('5','2026-07-12 21:40:00+00',3.5152,4.0000,33,'mlb_linescore_cum_asof'),
  ('5','2026-08-01 03:10:00+00',3.4894,4.1489,47,'mlb_linescore_cum_asof'),
  ('5','2026-08-30 00:10:00+00',3.7571,4.2857,70,'mlb_linescore_cum_asof'),
  ('6','2026-07-12 21:40:00+00',4.9310,3.0345,29,'mlb_linescore_cum_asof'),
  ('6','2026-07-29 21:10:00+00',4.9756,3.3902,41,'mlb_linescore_cum_asof'),
  ('6','2026-08-29 21:10:00+00',4.9091,3.3939,66,'mlb_linescore_cum_asof'),
  ('7','2026-07-12 21:35:00+00',4.8000,6.3429,35,'mlb_linescore_cum_asof'),
  ('7','2026-07-30 21:40:00+00',4.5000,5.7500,48,'mlb_linescore_cum_asof'),
  ('7','2026-08-30 00:10:00+00',4.6479,5.3099,71,'mlb_linescore_cum_asof'),
  ('8','2026-07-12 20:15:00+00',5.3529,4.3235,34,'mlb_linescore_cum_asof'),
  ('8','2026-07-29 23:45:00+00',5.1957,4.3043,46,'mlb_linescore_cum_asof'),
  ('8','2026-08-30 03:15:00+00',5.0417,3.8611,72,'mlb_linescore_cum_asof'),
  ('9','2026-07-12 22:10:00+00',5.0323,5.6452,31,'mlb_linescore_cum_asof'),
  ('9','2026-07-30 21:40:00+00',4.6136,5.3864,44,'mlb_linescore_cum_asof'),
  ('9','2026-08-29 22:10:00+00',4.4179,5.3284,67,'mlb_linescore_cum_asof'),
  ('10','2026-07-12 21:35:00+00',4.6571,4.2286,35,'mlb_linescore_cum_asof'),
  ('10','2026-07-31 22:20:00+00',4.2653,4.0000,49,'mlb_linescore_cum_asof'),
  ('10','2026-08-30 03:15:00+00',4.0822,3.8219,73,'mlb_linescore_cum_asof'),
  ('11','2026-07-12 22:10:00+00',4.6000,6.9333,30,'mlb_linescore_cum_asof'),
  ('11','2026-07-30 05:40:00+00',4.5714,6.7619,42,'mlb_linescore_cum_asof'),
  ('11','2026-08-30 06:05:00+00',4.4462,6.7385,65,'mlb_linescore_cum_asof'),
  ('12','2026-07-12 21:40:00+00',3.7813,4.0313,32,'mlb_linescore_cum_asof'),
  ('12','2026-07-30 06:10:00+00',3.7955,4.1818,44,'mlb_linescore_cum_asof'),
  ('12','2026-08-29 23:07:00+00',3.6324,4.8529,68,'mlb_linescore_cum_asof'),
  ('13','2026-07-12 22:35:00+00',4.2667,5.1000,30,'mlb_linescore_cum_asof'),
  ('13','2026-07-30 20:10:00+00',4.3571,5.0714,42,'mlb_linescore_cum_asof'),
  ('13','2026-08-30 03:15:00+00',4.1231,4.9692,65,'mlb_linescore_cum_asof'),
  ('14','2026-07-13 00:10:00+00',4.1935,4.7097,31,'mlb_linescore_cum_asof'),
  ('14','2026-08-01 03:07:00+00',3.8000,4.6667,45,'mlb_linescore_cum_asof'),
  ('14','2026-08-29 23:07:00+00',3.9000,4.4714,70,'mlb_linescore_cum_asof'),
  ('15','2026-07-12 22:15:00+00',4.2647,4.7941,34,'mlb_linescore_cum_asof'),
  ('15','2026-08-01 03:15:00+00',4.5306,4.7143,49,'mlb_linescore_cum_asof'),
  ('15','2026-08-30 00:10:00+00',4.3611,4.2500,72,'mlb_linescore_cum_asof'),
  ('16','2026-07-12 21:40:00+00',5.9333,4.2000,30,'mlb_linescore_cum_asof'),
  ('16','2026-07-31 22:20:00+00',5.9767,3.8605,43,'mlb_linescore_cum_asof'),
  ('16','2026-08-29 22:20:00+00',6.0299,3.9254,67,'mlb_linescore_cum_asof'),
  ('17','2026-07-12 21:40:00+00',3.8571,4.2857,35,'mlb_linescore_cum_asof'),
  ('17','2026-08-01 02:10:00+00',3.8980,4.3673,49,'mlb_linescore_cum_asof'),
  ('17','2026-08-29 22:20:00+00',4.0137,4.6849,73,'mlb_linescore_cum_asof'),
  ('18','2026-07-12 22:35:00+00',4.8966,5.0690,29,'mlb_linescore_cum_asof'),
  ('18','2026-07-29 05:38:00+00',4.7692,4.8974,39,'mlb_linescore_cum_asof'),
  ('18','2026-08-30 00:10:00+00',4.6774,4.5806,62,'mlb_linescore_cum_asof'),
  ('19','2026-07-13 00:10:00+00',5.3548,4.8710,31,'mlb_linescore_cum_asof'),
  ('19','2026-07-30 06:10:00+00',5.1429,4.6190,42,'mlb_linescore_cum_asof'),
  ('19','2026-08-29 21:10:00+00',4.5909,4.5152,66,'mlb_linescore_cum_asof'),
  ('20','2026-07-12 21:35:00+00',5.2647,5.0882,34,'mlb_linescore_cum_asof'),
  ('20','2026-08-01 03:15:00+00',5.5208,5.0625,48,'mlb_linescore_cum_asof'),
  ('20','2026-08-30 00:05:00+00',5.1918,4.8904,73,'mlb_linescore_cum_asof'),
  ('21','2026-07-12 21:40:00+00',4.0541,5.7568,37,'mlb_linescore_cum_asof'),
  ('21','2026-08-01 03:10:00+00',4.0588,5.0392,51,'mlb_linescore_cum_asof'),
  ('21','2026-08-30 00:10:00+00',4.0933,4.7067,75,'mlb_linescore_cum_asof'),
  ('22','2026-07-12 21:40:00+00',5.1143,4.8286,35,'mlb_linescore_cum_asof'),
  ('22','2026-08-01 03:05:00+00',4.8333,4.7708,48,'mlb_linescore_cum_asof'),
  ('22','2026-08-30 06:07:00+00',5.0000,4.3699,73,'mlb_linescore_cum_asof'),
  ('23','2026-07-12 20:15:00+00',5.4516,5.4839,31,'mlb_linescore_cum_asof'),
  ('23','2026-08-01 02:10:00+00',5.0000,5.2222,45,'mlb_linescore_cum_asof'),
  ('23','2026-08-29 22:15:00+00',4.4714,4.7429,70,'mlb_linescore_cum_asof'),
  ('24','2026-07-12 22:15:00+00',4.6857,4.2286,35,'mlb_linescore_cum_asof'),
  ('24','2026-08-01 03:07:00+00',4.2400,4.3600,50,'mlb_linescore_cum_asof'),
  ('24','2026-08-29 22:15:00+00',4.2432,4.3919,74,'mlb_linescore_cum_asof'),
  ('25','2026-07-13 00:10:00+00',4.3438,5.3438,32,'mlb_linescore_cum_asof'),
  ('25','2026-07-31 05:40:00+00',4.7556,4.9778,45,'mlb_linescore_cum_asof'),
  ('25','2026-08-30 00:10:00+00',4.6522,4.5217,69,'mlb_linescore_cum_asof'),
  ('26','2026-07-13 00:05:00+00',4.3000,4.8000,30,'mlb_linescore_cum_asof'),
  ('26','2026-07-31 05:40:00+00',4.4762,4.3810,42,'mlb_linescore_cum_asof'),
  ('26','2026-08-30 00:05:00+00',4.0455,4.3485,66,'mlb_linescore_cum_asof'),
  ('27','2026-07-13 00:05:00+00',5.5806,5.6129,31,'mlb_linescore_cum_asof'),
  ('27','2026-07-30 00:10:00+00',5.2857,5.8810,42,'mlb_linescore_cum_asof'),
  ('27','2026-08-30 00:10:00+00',5.0152,5.7576,66,'mlb_linescore_cum_asof'),
  ('28','2026-07-12 21:40:00+00',5.1176,3.7941,34,'mlb_linescore_cum_asof'),
  ('28','2026-08-01 03:10:00+00',4.7021,4.0426,47,'mlb_linescore_cum_asof'),
  ('28','2026-08-30 00:05:00+00',4.4429,4.0429,70,'mlb_linescore_cum_asof'),
  ('29','2026-07-13 00:10:00+00',4.5172,4.2414,29,'mlb_linescore_cum_asof'),
  ('29','2026-08-01 03:10:00+00',4.9070,4.3488,43,'mlb_linescore_cum_asof'),
  ('29','2026-08-30 00:05:00+00',4.8235,4.4412,68,'mlb_linescore_cum_asof'),
  ('30','2026-07-12 21:40:00+00',4.3333,3.6667,33,'mlb_linescore_cum_asof'),
  ('30','2026-08-01 03:10:00+00',4.1667,3.5833,48,'mlb_linescore_cum_asof'),
  ('30','2026-08-30 00:10:00+00',4.5139,3.8333,72,'mlb_linescore_cum_asof')
on conflict (team_espn_id, observed_at) do nothing;

-- ── C) v2.mlb_league_baseline: REAL league runs-per-game at the same checkpoints
-- source: avg(runs per team-game) over public.mlb_linescore x lab_mlb_wf, cutoff-respecting.
insert into v2.mlb_league_baseline (observed_at, runs_per_game, source)
values
  ('2026-07-14 23:59:59+00',4.6814,'mlb_linescore_league_cum_asof'),
  ('2026-07-31 23:59:59+00',4.5872,'mlb_linescore_league_cum_asof'),
  ('2026-08-30 23:59:59+00',4.5024,'mlb_linescore_league_cum_asof')
on conflict (observed_at) do nothing;

-- ── D) momios: REAL DraftKings snapshots for 10 of the 30 fixtures
-- source: public.v_momios_confiables restricted to the section-A events; per event the 3 most
-- recent distinct snapshot_at values were kept.
-- Two properties this slice buys us deliberately:
--   * 20 of the 30 fixtures have NO market at all -> the gate's NO_MARKET_DIAGNOSTIC path is
--     exercised on real absence, not on a contrived NULL.
--   * over_line mixes 7.5 / 8 / 8.5 / 9.5 -> fn_total_weights sees HALF *and* WHOLE (push)
--     lines, so the shared settlement primitive is tested on both shapes.
-- All snapshots fall in 2026-09-10 22:30..22:49Z; the runner's decision epoch 22:50Z is after
-- them (market available) and before every fixture's first pitch (snapshot legal).
insert into public.v_momios_confiables
  (espn_event_id, odds_event_id, home_team, away_team, sport_key,
   home_ml, away_ml, draw_ml, over_odds, under_odds, over_line,
   snapshot_at, overround, confiable, bookmaker)
select v.espn_event_id, v.odds_event_id, v.home_team, v.away_team, 'baseball_mlb',
       v.home_ml, v.away_ml, null, v.over_odds, v.under_odds, v.over_line,
       v.snapshot_at::timestamptz, v.overround, v.confiable, v.bookmaker
from (values
  ('401816883','401816883','New York Yankees','Colorado Rockies',1.328,3.420,1.971,1.855,8.5,'2026-09-10 22:30:03.612842+00',1.0454,true,'DraftKings'),
  ('401816883','401816883','New York Yankees','Colorado Rockies',1.328,3.420,1.971,1.855,8.5,'2026-09-10 22:45:03.587514+00',1.0454,true,'DraftKings'),
  ('401816883','401816883','New York Yankees','Colorado Rockies',1.328,3.420,1.971,1.855,8.5,'2026-09-10 22:49:02.316092+00',1.0454,true,'DraftKings'),
  ('401816886','401816886','Chicago White Sox','Pittsburgh Pirates',1.870,1.962,1.840,1.980,7.5,'2026-09-10 22:30:03.612842+00',1.0444,true,'DraftKings'),
  ('401816886','401816886','Chicago White Sox','Pittsburgh Pirates',1.870,1.952,1.840,1.980,7.5,'2026-09-10 22:45:03.587514+00',1.0471,true,'DraftKings'),
  ('401816886','401816886','Chicago White Sox','Pittsburgh Pirates',1.870,1.952,1.840,1.980,7.5,'2026-09-10 22:49:02.316092+00',1.0471,true,'DraftKings'),
  ('401816888','401816888','Washington Nationals','Los Angeles Angels',1.641,2.290,1.870,1.952,8,'2026-09-10 22:30:03.612842+00',1.0461,true,'DraftKings'),
  ('401816888','401816888','Washington Nationals','Los Angeles Angels',1.641,2.290,1.870,1.952,8,'2026-09-10 22:45:03.587514+00',1.0461,true,'DraftKings'),
  ('401816888','401816888','Washington Nationals','Los Angeles Angels',1.641,2.290,1.870,1.952,8,'2026-09-10 22:49:02.316092+00',1.0461,true,'DraftKings'),
  ('401816889','401816889','Toronto Blue Jays','Baltimore Orioles',1.781,2.060,1.917,1.901,8.5,'2026-09-10 22:30:03.612842+00',1.0469,true,'DraftKings'),
  ('401816889','401816889','Toronto Blue Jays','Baltimore Orioles',1.781,2.060,1.917,1.901,8.5,'2026-09-10 22:45:03.587514+00',1.0469,true,'DraftKings'),
  ('401816889','401816889','Toronto Blue Jays','Baltimore Orioles',1.781,2.060,1.917,1.901,8.5,'2026-09-10 22:49:02.316092+00',1.0469,true,'DraftKings'),
  ('401816892','401816892','Boston Red Sox','Kansas City Royals',1.488,2.680,1.909,1.909,8.5,'2026-09-10 22:30:03.612842+00',1.0452,true,'DraftKings'),
  ('401816892','401816892','Boston Red Sox','Kansas City Royals',1.488,2.680,1.909,1.909,8.5,'2026-09-10 22:45:03.587514+00',1.0452,true,'DraftKings'),
  ('401816892','401816892','Boston Red Sox','Kansas City Royals',1.488,2.680,1.909,1.909,8.5,'2026-09-10 22:49:02.316092+00',1.0452,true,'DraftKings'),
  ('401816894','401816894','New York Yankees','New York Mets',1.725,2.150,2.000,1.833,8,'2026-09-10 22:30:03.612842+00',1.0448,true,'DraftKings'),
  ('401816894','401816894','New York Yankees','New York Mets',1.735,2.130,2.000,1.833,8,'2026-09-10 22:45:03.587514+00',1.0459,true,'DraftKings'),
  ('401816894','401816894','New York Yankees','New York Mets',1.735,2.130,2.000,1.833,8,'2026-09-10 22:49:02.316092+00',1.0459,true,'DraftKings'),
  ('401816895','401816895','Atlanta Braves','Philadelphia Phillies',1.552,2.490,1.877,1.943,7.5,'2026-09-10 22:30:03.612842+00',1.0459,true,'DraftKings'),
  ('401816895','401816895','Atlanta Braves','Philadelphia Phillies',1.552,2.490,1.877,1.943,7.5,'2026-09-10 22:45:03.587514+00',1.0459,true,'DraftKings'),
  ('401816895','401816895','Atlanta Braves','Philadelphia Phillies',1.552,2.490,1.877,1.943,7.5,'2026-09-10 22:49:02.316092+00',1.0459,true,'DraftKings'),
  ('401816897','401816897','Milwaukee Brewers','Cincinnati Reds',1.518,2.580,1.893,1.926,8,'2026-09-10 22:30:03.612842+00',1.0464,true,'DraftKings'),
  ('401816897','401816897','Milwaukee Brewers','Cincinnati Reds',1.518,2.580,1.893,1.926,8,'2026-09-10 22:45:03.587514+00',1.0464,true,'DraftKings'),
  ('401816897','401816897','Milwaukee Brewers','Cincinnati Reds',1.518,2.580,1.893,1.926,8,'2026-09-10 22:49:02.316092+00',1.0464,true,'DraftKings'),
  ('401816898','401816898','Minnesota Twins','Cleveland Guardians',2.000,1.833,1.893,1.926,7.5,'2026-09-10 22:30:03.612842+00',1.0456,true,'DraftKings'),
  ('401816898','401816898','Minnesota Twins','Cleveland Guardians',1.990,1.833,1.893,1.926,7.5,'2026-09-10 22:45:03.587514+00',1.0481,true,'DraftKings'),
  ('401816898','401816898','Minnesota Twins','Cleveland Guardians',1.990,1.833,1.893,1.926,7.5,'2026-09-10 22:49:02.316092+00',1.0481,true,'DraftKings'),
  ('401816901','401816901','Athletics','Seattle Mariners',2.330,1.625,1.952,1.870,9.5,'2026-09-10 22:30:03.612842+00',1.0446,true,'DraftKings'),
  ('401816901','401816901','Athletics','Seattle Mariners',2.350,1.613,1.952,1.917,9.5,'2026-09-10 22:45:03.587514+00',1.0455,true,'DraftKings'),
  ('401816901','401816901','Athletics','Seattle Mariners',2.350,1.613,1.952,1.917,9.5,'2026-09-10 22:49:02.316092+00',1.0455,true,'DraftKings')
) as v(espn_event_id, odds_event_id, home_team, away_team,
       home_ml, away_ml, over_odds, under_odds, over_line,
       snapshot_at, overround, confiable, bookmaker);

-- ── E) public.mlb_linescore surface (prod = real table, 129019 rows / 7323 events)
-- iss052's walk-forward harness reads finals from here because it is the ONLY outcome source
-- with full coverage of the walk-forward corpus (1053/1053 events join, vs 307/1053 for
-- public.marcadores_archivo). Created empty on the branch: the real historical corpus is NOT
-- shuttled here — the skill measurement was taken at full scale in prod (see the evidence doc),
-- and what the branch must prove is that the FUNCTION computes the metric correctly, which the
-- runner does against a hand-computable fixture it inserts itself.
create table if not exists public.mlb_linescore (
  espn_event_id text, competitor_id text, lado text, period integer,
  carreras numeric, hits integer, errores integer, cargado_at timestamptz default now()
);
