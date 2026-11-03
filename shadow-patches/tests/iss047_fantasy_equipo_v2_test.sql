-- ============================================================================
-- iss047 FANTASY "EQUIPO" START/SIT — v2 TEST  (branch-only: kmasawoljjyfmxadbvou)
-- ============================================================================
-- Requires iss047_fantasy_equipo_startsit.sql (v2) applied. Every assertion
-- RAISE EXCEPTIONs on failure; a clean run ending in the final NOTICE means all
-- assertions passed. Resolves issue #4 comment 5620923816 (7 STOP-SHIP findings)
-- plus 5620314120 (full roster/bench) and 5620342324 (scoring names).
--
-- Builds the OWNER'S EXACT Yahoo league (invent nothing):
--   Starters: QB, WR, WR, RB, RB, TE, W/R/T(FLEX=WR/RB/TE), K, DEF  (= 9)
--   Bench BN×6, IR×2.  Scoring: PPR (1.0 pt / reception).
--   NO Superflex slot. NO TE-premium.  Modifiers (DST/K/TE bonus) are metadata.
--
-- Coverage:
--   F1  exact config + derived eligible_slots per position
--   F2  first-class snapshot keys + immutability
--   F3  legal slot occupancy (9-QB adversarial => ROSTER_INVALID, not COMPLETE)
--   F4  client eligible_slots / projection_status ignored (server-derived)
--   F5  whole-roster global optimizer: legal FLEX chain, illegal rejected,
--       no double-use, locked-player cannot move
--   F6  partial projection => fail-close (stays NO_FANTASY_BRAIN)
--   F7  PPR-with-modifiers stays PPR; modifiers in separate metadata
-- ============================================================================

-- ############################################################################
-- BLOCK 1 — OWNER FIXTURE + F1/F2/F7/F8(NULL projections)
-- ############################################################################
do $$
declare
  v_prof text := 'iss047v2_owner';
  r record; n int; v text; d numeric; arr text[]; b boolean;
begin
  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_modifier where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  -- ==== OWNER'S EXACT Yahoo league: PPR 1.0, NO superflex, NO TE premium ====
  insert into v2.fq_scoring_profile(
    scoring_profile_id, league_id, season, scoring_profile_version,
    name, ppr_per_reception, te_premium_bonus, superflex,
    qb_slots, rb_slots, wr_slots, te_slots, flex_slots, superflex_slots, k_slots, def_slots,
    bench_count, ir_count
  ) values (
    v_prof, 'owner_yahoo_league', 2025, 1,
    v2.fq_fn_canonical_scoring_name(1.0),   -- must resolve to 'PPR'
    1.0, 0, false,                          -- PPR 1.0; NO TE premium; NO superflex
    1, 2, 2, 1, 1, 0, 1, 1,                 -- QB1 RB2 WR2 TE1 FLEX1 (superflex 0) K1 DEF1 = 9
    6, 2
  );
  perform v2.fq_fn_sync_roster_slots(v_prof);

  -- F7: modifiers live as SEPARATE metadata and must NOT rename the league
  insert into v2.fq_scoring_modifier(scoring_profile_id, modifier_code, modifier_value, description) values
    (v_prof,'DST_SACK',      1.0,  'DST sack points'),
    (v_prof,'K_50PLUS',      5.0,  'Kicker 50+ yd FG'),
    (v_prof,'TE_BONUS_REC',  0.0,  'no TE reception bonus for this league'),
    (v_prof,'PASS_TD',       4.0,  'passing TD points');

  -- ==== STARTERS (9) — QB, RB, RB, WR, WR, TE, FLEX(RB), K, DEF ====
  insert into v2.fq_roster_player(scoring_profile_id, league_id, fantasy_team_id, season, week,
      roster_snapshot_id, player_id, display_name, position, lineup_state, roster_slot, rival, kickoff) values
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_qb1','QB One','QB','STARTER','QB','DAL', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_rb1','RB One','RB','STARTER','RB','NYG', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_rb2','RB Two','RB','STARTER','RB','PHI', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_wr1','WR One','WR','STARTER','WR','SF',  now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_wr2','WR Two','WR','STARTER','WR','SEA', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_te1','TE One','TE','STARTER','TE','GB',  now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_flx','Flex RB','RB','STARTER','FLEX','MIN', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_k1', 'Kicker','K','STARTER','K','CHI', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','p_def1','Defense','DEF','STARTER','DEF','ATL', now()+interval '2 day');

  -- ==== BENCH (6) ====
  insert into v2.fq_roster_player(scoring_profile_id, league_id, fantasy_team_id, season, week,
      roster_snapshot_id, player_id, display_name, position, lineup_state, rival, kickoff) values
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','b_wr3','Bench WR','WR','BENCH','LAR', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','b_rb3','Bench RB','RB','BENCH','TB',  now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','b_qb2','Bench QB','QB','BENCH','NO',  now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','b_te2','Bench TE','TE','BENCH','CAR', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','b_k2', 'Bench K','K','BENCH','JAX', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','b_def2','Bench DEF','DEF','BENCH','TEN', now()+interval '2 day');

  -- ==== IR (2) ====
  insert into v2.fq_roster_player(scoring_profile_id, league_id, fantasy_team_id, season, week,
      roster_snapshot_id, player_id, display_name, position, lineup_state, injury_status, rival, kickoff) values
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','ir_wr9','IR WR','WR','IR','OUT','HOU', now()+interval '2 day'),
    (v_prof,'owner_yahoo_league','owner_team',2025,1,'snap_w1','ir_rb9','IR RB','RB','IR','IR', 'KC',  now()+interval '2 day');

  -- ---- F7: scoring name is a pure function of reception points -------------
  select name into v from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  if v <> 'PPR' then raise exception 'FAIL F7a: owner league expected PPR, got %', v; end if;
  select ppr_per_reception into d from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  if d <> 1.0 then raise exception 'FAIL F7b: PPR reception points expected 1.0, got %', d; end if;
  if v2.fq_fn_canonical_scoring_name(0.0) <> 'STANDARD' then raise exception 'FAIL F7c: 0.0 not STANDARD'; end if;
  if v2.fq_fn_canonical_scoring_name(0.5) <> 'HALF PPR' then raise exception 'FAIL F7d: 0.5 not HALF PPR'; end if;
  if v2.fq_fn_canonical_scoring_name(1.0) <> 'PPR'      then raise exception 'FAIL F7e: 1.0 not PPR'; end if;
  if v2.fq_fn_canonical_scoring_name(0.7) <> 'CUSTOM'   then raise exception 'FAIL F7f: 0.7 not CUSTOM'; end if;
  -- modifiers exist and league is STILL PPR (modifiers never force CUSTOM)
  select count(*) into n from v2.fq_scoring_modifier where scoring_profile_id = v_prof;
  if n < 4 then raise exception 'FAIL F7g: expected modifier metadata rows, got %', n; end if;
  select name into v from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  if v <> 'PPR' then raise exception 'FAIL F7h: PPR-with-modifiers must stay PPR, got %', v; end if;
  raise notice 'PASS F7: label PPR (1.0); STANDARD/HALF PPR/PPR/CUSTOM by reception pts; % modifiers kept as separate metadata; league stays PPR', n;

  -- ---- F1: exact config + derived eligible_slots per position --------------
  -- no superflex slots configured
  select superflex_slots into n from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  if n <> 0 then raise exception 'FAIL F1a: owner league must have 0 superflex slots, got %', n; end if;
  select count(*) into n from v2.fq_roster_slots where scoring_profile_id=v_prof and slot_code='SUPERFLEX';
  if n <> 0 then raise exception 'FAIL F1b: SUPERFLEX slot must not exist for owner league'; end if;
  select te_premium_bonus into d from v2.fq_scoring_profile where scoring_profile_id=v_prof;
  if d <> 0 then raise exception 'FAIL F1c: owner league must have 0 TE premium, got %', d; end if;
  -- eligible_slots (server-derived, superflex=false)
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_qb1';
  if arr <> array['QB'] then raise exception 'FAIL F1d: QB eligible_slots must be {QB}, got %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_rb1';
  if not (arr <@ array['RB','FLEX'] and array['RB','FLEX'] <@ arr) then raise exception 'FAIL F1e: RB eligible_slots must be {RB,FLEX}, got %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_wr1';
  if not (arr <@ array['WR','FLEX'] and array['WR','FLEX'] <@ arr) then raise exception 'FAIL F1f: WR eligible_slots must be {WR,FLEX}, got %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_te1';
  if not (arr <@ array['TE','FLEX'] and array['TE','FLEX'] <@ arr) then raise exception 'FAIL F1g: TE eligible_slots must be {TE,FLEX}, got %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_k1';
  if arr <> array['K'] then raise exception 'FAIL F1h: K eligible_slots must be {K}, got %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_def1';
  if arr <> array['DEF'] then raise exception 'FAIL F1i: DEF eligible_slots must be {DEF}, got %', arr; end if;
  -- no player anywhere is SUPERFLEX-eligible
  select count(*) into n from v2.fq_roster_player where scoring_profile_id=v_prof and ('SUPERFLEX' = any(eligible_slots));
  if n <> 0 then raise exception 'FAIL F1j: no player may be SUPERFLEX-eligible in owner league (found %)', n; end if;
  raise notice 'PASS F1: owner config exact (no superflex/no TE-premium); QB={QB} RB={RB,FLEX} WR={WR,FLEX} TE={TE,FLEX} K={K} DEF={DEF}';

  -- ---- F2: first-class snapshot keys present + immutability ---------------
  select count(*) into n from v2.fq_roster_player
   where scoring_profile_id=v_prof and league_id='owner_yahoo_league' and fantasy_team_id='owner_team'
     and season=2025 and week=1 and roster_snapshot_id='snap_w1' and as_of is not null;
  if n <> 17 then raise exception 'FAIL F2a: snapshot keys not populated on all 17 rows, got %', n; end if;
  -- projection tuple columns exist and are NULL (no brain)
  select count(*) into n from v2.fq_roster_player where scoring_profile_id=v_prof
     and (projection_snapshot_id is not null or feature_snapshot_id is not null or model_version is not null
          or proj_as_of is not null or provenance is not null);
  if n <> 0 then raise exception 'FAIL F2b: projection tuple must be NULL until a brain exists (found %)', n; end if;
  -- immutability: mutating the snapshot identity must be rejected
  begin
    update v2.fq_roster_player set roster_snapshot_id='snap_w2'
     where scoring_profile_id=v_prof and player_id='p_qb1';
    raise exception 'FAIL F2c: snapshot identity mutation was allowed (should be immutable)';
  exception when others then
    if sqlerrm like 'FAIL F2c%' then raise; end if;  -- re-raise our own failure
    -- expected immutability rejection
  end;
  raise notice 'PASS F2: rosters keyed by league_id/fantasy_team_id/season/week/roster_snapshot_id/as_of/version; snapshot identity immutable';

  -- ---- F8 (no fabricated data): owner projections NULL, status NO_FANTASY_BRAIN
  select count(*) into n from v2.fq_roster_player where scoring_profile_id=v_prof
     and (proj_floor is not null or proj_median is not null or proj_ceiling is not null
          or projection_status <> 'NO_FANTASY_BRAIN');
  if n <> 0 then raise exception 'FAIL P: owner projections must be NULL / NO_FANTASY_BRAIN (found %)', n; end if;
  raise notice 'PASS P: projections NULL, projection_status=NO_FANTASY_BRAIN (no fabricated data)';

  -- ---- F3: full legal roster => COMPLETE ----------------------------------
  select status into v from v2.fq_fn_roster_status(v_prof);
  if v <> 'COMPLETE' then raise exception 'FAIL F3-complete: full legal owner roster expected COMPLETE, got %', v; end if;
  raise notice 'PASS F3-complete: full legal owner roster (9 starters, 6 BN, 2 IR) => COMPLETE';

  -- ---- F5(a): optimizer on complete legal roster => optimal == current -----
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof);
  if n <> 9 then raise exception 'FAIL F5a1: optimizer must emit 9 slot rows, got %', n; end if;
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof) o where o.is_move;
  if n <> 0 then raise exception 'FAIL F5a2: no moves expected on an already-optimal legal roster (no projections), got %', n; end if;
  -- no player used twice
  select count(*) into n from (
    select o.optimal_player_id from v2.fq_fn_optimize_lineup(v_prof) o where o.optimal_player_id is not null
    group by 1 having count(*) > 1
  ) dd;
  if n <> 0 then raise exception 'FAIL F5a3: a player was used twice in the optimal lineup (%)', n; end if;
  -- deltas NULL (no brain)
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof) o where o.delta_median is not null or o.delta_ceiling is not null;
  if n <> 0 then raise exception 'FAIL F5a4: fabricated delta on optimizer output (%)', n; end if;
  -- IR never appears in the optimal lineup
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof) o where o.optimal_player_id in ('ir_wr9','ir_rb9');
  if n <> 0 then raise exception 'FAIL F5a5: IR player placed in a starting slot (%)', n; end if;
  raise notice 'PASS F5a: optimizer on complete roster => 9 slots, 0 fabricated moves, no double-use, deltas NULL, IR excluded';

  -- cleanup
  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_modifier where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  raise notice '==== BLOCK 1 (owner fixture, F1/F2/F3-complete/F5a/F7) PASSED ====';
end;
$$;

-- ############################################################################
-- BLOCK 2 — F3 legal slot occupancy adversarials (9-QB, dup, incomplete)
-- ############################################################################
do $$
declare
  v_prof text := 'iss047v2_f3';
  v text; n int; rep jsonb; i int;
begin
  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  insert into v2.fq_scoring_profile(scoring_profile_id, name, ppr_per_reception,
      qb_slots,rb_slots,wr_slots,te_slots,flex_slots,superflex_slots,k_slots,def_slots,bench_count,ir_count)
    values (v_prof, v2.fq_fn_canonical_scoring_name(1.0), 1.0, 1,2,2,1,1,0,1,1,6,2);
  perform v2.fq_fn_sync_roster_slots(v_prof);

  -- ==== 9-QB adversarial: nine QBs all as starters in the QB slot ====
  for i in 1..9 loop
    insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, display_name,
        position, lineup_state, roster_slot)
      values (v_prof, 'snap_9qb', 'q'||i, 'QB '||i, 'QB', 'STARTER', 'QB');
  end loop;

  select status, slot_report into v, rep from v2.fq_fn_roster_status(v_prof);
  if v = 'COMPLETE' then raise exception 'FAIL F3-9qb-a: 9-QB lineup returned COMPLETE (must be INVALID/INCOMPLETE)'; end if;
  if v <> 'ROSTER_INVALID' then raise exception 'FAIL F3-9qb-b: 9-QB lineup expected ROSTER_INVALID, got %', v; end if;
  -- slot_report proves QB over-filled 9 vs 1
  select count(*) into n from jsonb_array_elements(rep) e
    where e->>'slot'='QB' and (e->>'present')::int = 9 and (e->>'required')::int = 1;
  if n <> 1 then raise exception 'FAIL F3-9qb-c: slot_report should show QB present=9 required=1; report=%', rep; end if;
  -- violation must name the over-filled slot
  select count(*) into n from v2.fq_fn_roster_status(v_prof) s, unnest(s.violations) vio
    where vio like 'SLOT_OVER_FILLED: QB%';
  if n < 1 then raise exception 'FAIL F3-9qb-d: expected SLOT_OVER_FILLED violation for QB'; end if;
  raise notice 'PASS F3-9qb: 9 QB starters => ROSTER_INVALID (QB present=9 required=1; SLOT_OVER_FILLED), never COMPLETE';

  -- ==== duplicate player_id adversarial ====
  delete from v2.fq_roster_player where scoring_profile_id=v_prof;
  -- a legal-shape lineup but with a duplicated canonical id via jsonb path
  select status, violations into v, rep from v2.fq_fn_roster_status(v_prof, jsonb_build_array(
    jsonb_build_object('player_id','dupe','position','RB','lineup_state','STARTER','roster_slot','RB'),
    jsonb_build_object('player_id','dupe','position','WR','lineup_state','STARTER','roster_slot','WR')
  ));
  if v <> 'ROSTER_INVALID' then raise exception 'FAIL F3-dup: duplicate player_id expected ROSTER_INVALID, got %', v; end if;
  raise notice 'PASS F3-dup: duplicate canonical player_id => ROSTER_INVALID';

  -- ==== incomplete (missing bench) => ROSTER_INCOMPLETE (not INVALID) ====
  delete from v2.fq_roster_player where scoring_profile_id=v_prof;
  insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, display_name, position, lineup_state, roster_slot) values
    (v_prof,'snap_inc','s_qb','QB','QB','STARTER','QB'),
    (v_prof,'snap_inc','s_rb1','RB1','RB','STARTER','RB'),
    (v_prof,'snap_inc','s_rb2','RB2','RB','STARTER','RB'),
    (v_prof,'snap_inc','s_wr1','WR1','WR','STARTER','WR'),
    (v_prof,'snap_inc','s_wr2','WR2','WR','STARTER','WR'),
    (v_prof,'snap_inc','s_te','TE','TE','STARTER','TE'),
    (v_prof,'snap_inc','s_flx','FLX','RB','STARTER','FLEX'),
    (v_prof,'snap_inc','s_k','K','K','STARTER','K'),
    (v_prof,'snap_inc','s_def','DEF','DEF','STARTER','DEF');
  select status into v from v2.fq_fn_roster_status(v_prof);
  if v <> 'ROSTER_INCOMPLETE' then raise exception 'FAIL F3-inc: legal starters but no bench/IR expected ROSTER_INCOMPLETE, got %', v; end if;
  raise notice 'PASS F3-inc: legal starters, missing bench/IR => ROSTER_INCOMPLETE (under, not invalid)';

  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  raise notice '==== BLOCK 2 (F3 legal-occupancy) PASSED ====';
end;
$$;

-- ############################################################################
-- BLOCK 3 — F4 server-derived eligibility (client input ignored)
-- ############################################################################
do $$
declare
  v_prof text := 'iss047v2_f4';
  n int; arr text[]; v_roster jsonb;
begin
  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  insert into v2.fq_scoring_profile(scoring_profile_id, name, ppr_per_reception,
      qb_slots,rb_slots,wr_slots,te_slots,flex_slots,superflex_slots,k_slots,def_slots,bench_count,ir_count)
    values (v_prof, v2.fq_fn_canonical_scoring_name(1.0), 1.0, 1,2,2,1,1,0,1,1,6,2);
  perform v2.fq_fn_sync_roster_slots(v_prof);

  -- table-path: a BENCH QB cannot smuggle in eligible_slots — trigger derives {QB}
  insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, display_name,
      position, lineup_state) values (v_prof,'snap_f4','b_qb_cheat','Cheat QB','QB','BENCH');
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='b_qb_cheat';
  if arr <> array['QB'] then raise exception 'FAIL F4a: trigger must derive QB eligible_slots={QB}, got %', arr; end if;

  -- client-supplied projection_status must be ignored (partial/no tuple => fail-close)
  insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, display_name,
      position, lineup_state, projection_status, proj_median)
    values (v_prof,'snap_f4','b_qb_cheat2','Cheat QB2','QB','BENCH','PROJECTED', 25.0);
  select projection_status into arr[1] from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='b_qb_cheat2';
  if (select projection_status from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='b_qb_cheat2') <> 'NO_FANTASY_BRAIN' then
    raise exception 'FAIL F4b: client projection_status=PROJECTED honored on partial data (must fail-close)';
  end if;

  -- jsonb-path optimizer: full legal starters + a BENCH QB claiming eligible_slots=['WR']
  -- with a huge projection. The server must derive QB->{QB} and NEVER offer it to WR.
  v_roster := jsonb_build_array(
    jsonb_build_object('player_id','p_qb','position','QB','lineup_state','STARTER','roster_slot','QB'),
    jsonb_build_object('player_id','p_rb1','position','RB','lineup_state','STARTER','roster_slot','RB'),
    jsonb_build_object('player_id','p_rb2','position','RB','lineup_state','STARTER','roster_slot','RB'),
    jsonb_build_object('player_id','p_wr1','position','WR','lineup_state','STARTER','roster_slot','WR'),
    jsonb_build_object('player_id','p_wr2','position','WR','lineup_state','STARTER','roster_slot','WR'),
    jsonb_build_object('player_id','p_te','position','TE','lineup_state','STARTER','roster_slot','TE'),
    jsonb_build_object('player_id','p_flx','position','RB','lineup_state','STARTER','roster_slot','FLEX'),
    jsonb_build_object('player_id','p_k','position','K','lineup_state','STARTER','roster_slot','K'),
    jsonb_build_object('player_id','p_def','position','DEF','lineup_state','STARTER','roster_slot','DEF'),
    -- the adversary: a bench QB LYING about eligibility + projection
    jsonb_build_object('player_id','cheat_qb','position','QB','lineup_state','BENCH',
                       'eligible_slots', jsonb_build_array('WR','FLEX'),
                       'projection_status','PROJECTED','proj_median', 99.9, 'proj_ceiling', 120.0)
  );
  -- the cheat QB must NEVER be placed in a WR (or FLEX) slot in the optimal lineup
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof, v_roster) o
    where o.optimal_player_id = 'cheat_qb' and o.slot_code in ('WR','FLEX');
  if n <> 0 then raise exception 'FAIL F4c: client eligible_slots trusted — cheat QB placed into WR/FLEX (%)', n; end if;
  -- and it must never appear as a bench alternative for a WR starter in start_sit
  select count(*) into n from v2.fq_fn_start_sit(v_prof, v_roster) ss
    where ss.best_bench_alternative_id = 'cheat_qb' and ss.starter_slot <> 'QB';
  if n <> 0 then raise exception 'FAIL F4d: cheat QB offered into a non-QB slot via start_sit (%)', n; end if;
  raise notice 'PASS F4: client-supplied eligible_slots & projection_status IGNORED; bench QB never offered into a WR/FLEX slot';

  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  raise notice '==== BLOCK 3 (F4 server-derived eligibility) PASSED ====';
end;
$$;

-- ############################################################################
-- BLOCK 4 — F5 whole-roster global optimizer (chain / illegal / no-reuse / lock)
-- ############################################################################
do $$
declare
  v_prof text := 'iss047v2_f5';
  n int; r record; arr text[];
  v_flex_wr_slot_opt text; v_wr2_opt text;
  v_base jsonb; v_locked jsonb;
begin
  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  insert into v2.fq_scoring_profile(scoring_profile_id, name, ppr_per_reception,
      qb_slots,rb_slots,wr_slots,te_slots,flex_slots,superflex_slots,k_slots,def_slots,bench_count,ir_count)
    values (v_prof, v2.fq_fn_canonical_scoring_name(1.0), 1.0, 1,2,2,1,1,0,1,1,6,2);
  perform v2.fq_fn_sync_roster_slots(v_prof);

  -- Forced legal CHAIN scenario:
  --   WR1, RB1, RB2, QB, TE, K, DEF are LOCKED starters (cannot move).
  --   A WR sits in FLEX (unlocked). WR2 slot is EMPTY. Bench has one RB.
  --   The ONLY way to complete the lineup legally is the chain:
  --     move the FLEX WR -> WR2, and promote the bench RB -> FLEX.
  v_base := jsonb_build_array(
    jsonb_build_object('player_id','wr_a','position','WR','lineup_state','STARTER','roster_slot','WR','locked',true),
    jsonb_build_object('player_id','rb_x','position','RB','lineup_state','STARTER','roster_slot','RB','locked',true),
    jsonb_build_object('player_id','rb_y','position','RB','lineup_state','STARTER','roster_slot','RB','locked',true),
    jsonb_build_object('player_id','qb_1','position','QB','lineup_state','STARTER','roster_slot','QB','locked',true),
    jsonb_build_object('player_id','te_1','position','TE','lineup_state','STARTER','roster_slot','TE','locked',true),
    jsonb_build_object('player_id','k_1', 'position','K','lineup_state','STARTER','roster_slot','K','locked',true),
    jsonb_build_object('player_id','def_1','position','DEF','lineup_state','STARTER','roster_slot','DEF','locked',true),
    jsonb_build_object('player_id','wr_b','position','WR','lineup_state','STARTER','roster_slot','FLEX','locked',false),
    jsonb_build_object('player_id','rb_c','position','RB','lineup_state','BENCH')
  );

  -- (chain) WR2 must be filled by the ex-FLEX WR; FLEX must be filled by the bench RB
  select o.optimal_player_id into v_wr2_opt from v2.fq_fn_optimize_lineup(v_prof, v_base) o
    where o.slot_code='WR' and o.slot_seq=2;
  select o.optimal_player_id into v_flex_wr_slot_opt from v2.fq_fn_optimize_lineup(v_prof, v_base) o
    where o.slot_code='FLEX';
  if v_wr2_opt <> 'wr_b' then raise exception 'FAIL F5-chain-a: WR2 should be filled by ex-FLEX WR (wr_b), got %', v_wr2_opt; end if;
  if v_flex_wr_slot_opt <> 'rb_c' then raise exception 'FAIL F5-chain-b: FLEX should be filled by bench RB (rb_c), got %', v_flex_wr_slot_opt; end if;
  -- the moves are flagged
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof, v_base) o where o.is_move;
  if n < 2 then raise exception 'FAIL F5-chain-c: chained reassignment should flag >=2 moves, got %', n; end if;
  raise notice 'PASS F5-chain: legal chained reassignment (FLEX WR -> WR2, bench RB -> FLEX)';

  -- (legality) every optimal assignment is eligible for its slot; no illegal swap
  for r in select o.slot_code, o.optimal_player_id from v2.fq_fn_optimize_lineup(v_prof, v_base) o
           where o.optimal_player_id is not null
  loop
    -- rebuild derived eligibility for the assigned player from the base roster
    select v2.fq_fn_eligible_slots(x->>'position', false) into arr
      from jsonb_array_elements(v_base) x where x->>'player_id' = r.optimal_player_id;
    if not (r.slot_code = any(arr)) then
      raise exception 'FAIL F5-legal: illegal assignment — % into % (eligible %)', r.optimal_player_id, r.slot_code, arr;
    end if;
  end loop;
  raise notice 'PASS F5-legal: every optimal assignment respects derived eligibility (illegal position swaps rejected)';

  -- (no double-use) no player assigned to two slots
  select count(*) into n from (
    select o.optimal_player_id from v2.fq_fn_optimize_lineup(v_prof, v_base) o
      where o.optimal_player_id is not null group by 1 having count(*)>1
  ) d;
  if n <> 0 then raise exception 'FAIL F5-nodup: a player was used in two slots (%)', n; end if;
  raise notice 'PASS F5-nodup: no bench/starter player used more than once';

  -- (locked cannot move) now LOCK the FLEX WR too: the chain becomes impossible,
  -- the locked WR stays in FLEX, and WR2 cannot be filled (EMPTY_UNFILLABLE).
  v_locked := jsonb_build_array(
    jsonb_build_object('player_id','wr_a','position','WR','lineup_state','STARTER','roster_slot','WR','locked',true),
    jsonb_build_object('player_id','rb_x','position','RB','lineup_state','STARTER','roster_slot','RB','locked',true),
    jsonb_build_object('player_id','rb_y','position','RB','lineup_state','STARTER','roster_slot','RB','locked',true),
    jsonb_build_object('player_id','qb_1','position','QB','lineup_state','STARTER','roster_slot','QB','locked',true),
    jsonb_build_object('player_id','te_1','position','TE','lineup_state','STARTER','roster_slot','TE','locked',true),
    jsonb_build_object('player_id','k_1', 'position','K','lineup_state','STARTER','roster_slot','K','locked',true),
    jsonb_build_object('player_id','def_1','position','DEF','lineup_state','STARTER','roster_slot','DEF','locked',true),
    jsonb_build_object('player_id','wr_b','position','WR','lineup_state','STARTER','roster_slot','FLEX','locked',true),
    jsonb_build_object('player_id','rb_c','position','RB','lineup_state','BENCH')
  );
  select o.optimal_player_id, o.move_note into v_flex_wr_slot_opt, arr[1]
    from v2.fq_fn_optimize_lineup(v_prof, v_locked) o where o.slot_code='FLEX';
  if v_flex_wr_slot_opt <> 'wr_b' then raise exception 'FAIL F5-lock-a: locked FLEX player moved (got % in FLEX)', v_flex_wr_slot_opt; end if;
  select o.move_note into v_flex_wr_slot_opt from v2.fq_fn_optimize_lineup(v_prof, v_locked) o where o.slot_code='FLEX';
  if v_flex_wr_slot_opt <> 'LOCKED_KEEP' then raise exception 'FAIL F5-lock-b: FLEX move_note expected LOCKED_KEEP, got %', v_flex_wr_slot_opt; end if;
  select o.optimal_player_id into v_wr2_opt from v2.fq_fn_optimize_lineup(v_prof, v_locked) o where o.slot_code='WR' and o.slot_seq=2;
  if v_wr2_opt is not null then raise exception 'FAIL F5-lock-c: WR2 should be unfillable when FLEX WR is locked, got %', v_wr2_opt; end if;
  -- the bench RB must NOT have displaced anyone (no double-use, lock respected)
  select count(*) into n from v2.fq_fn_optimize_lineup(v_prof, v_locked) o where o.optimal_player_id='rb_c';
  if n <> 0 then raise exception 'FAIL F5-lock-d: bench RB placed although its only path required moving a locked player (%)', n; end if;
  raise notice 'PASS F5-lock: locked (game-started) player never moves; late-swap chain blocked; WR2 stays EMPTY_UNFILLABLE';

  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  raise notice '==== BLOCK 4 (F5 global optimizer) PASSED ====';
end;
$$;

-- ############################################################################
-- BLOCK 5 — F6 immutable projection contract (partial => fail-close)
-- ############################################################################
do $$
declare
  v_prof text := 'iss047v2_f6';
  v text;
begin
  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  insert into v2.fq_scoring_profile(scoring_profile_id, name, ppr_per_reception,
      qb_slots,rb_slots,wr_slots,te_slots,flex_slots,superflex_slots,k_slots,def_slots,bench_count,ir_count)
    values (v_prof, v2.fq_fn_canonical_scoring_name(1.0), 1.0, 1,2,2,1,1,0,1,1,6,2);
  perform v2.fq_fn_sync_roster_slots(v_prof);

  -- partial tuple: only median present => fail-close
  insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, position, lineup_state, proj_median)
    values (v_prof,'snap_f6','pp_partial1','WR','BENCH', 14.2);
  select projection_status into v from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='pp_partial1';
  if v <> 'NO_FANTASY_BRAIN' then raise exception 'FAIL F6a: partial (median-only) flipped to %, must stay NO_FANTASY_BRAIN', v; end if;

  -- partial tuple: all three numbers but missing snapshot metadata => fail-close
  insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, position, lineup_state,
      proj_floor, proj_median, proj_ceiling, model_version)
    values (v_prof,'snap_f6','pp_partial2','WR','BENCH', 5.0, 12.0, 22.0, 'mv1');  -- no proj_snapshot/feature/as_of/provenance
  select projection_status into v from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='pp_partial2';
  if v <> 'NO_FANTASY_BRAIN' then raise exception 'FAIL F6b: numbers-without-provenance flipped to %, must fail-close', v; end if;

  -- COMPLETE immutable tuple => gate opens to PROJECTED (proves the gate is real,
  -- not merely always-closed). This is a synthetic tuple; production stays NULL.
  insert into v2.fq_roster_player(scoring_profile_id, roster_snapshot_id, player_id, position, lineup_state,
      proj_floor, proj_median, proj_ceiling,
      projection_snapshot_id, feature_snapshot_id, model_version, proj_as_of, provenance)
    values (v_prof,'snap_f6','pp_full','WR','BENCH', 6.0, 13.5, 24.0,
      'projsnap_1','featsnap_1','fantasy_brain_v0', now(), 'unit_test_synthetic');
  select projection_status into v from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='pp_full';
  if v <> 'PROJECTED' then raise exception 'FAIL F6c: complete immutable tuple did not open gate (got %)', v; end if;

  -- resolver unit checks
  if v2.fq_fn_projection_status(1,2,3,'a','b','c', now(), 'p') <> 'PROJECTED' then raise exception 'FAIL F6d: complete tuple resolver'; end if;
  if v2.fq_fn_projection_status(null,2,3,'a','b','c', now(), 'p') <> 'NO_FANTASY_BRAIN' then raise exception 'FAIL F6e: null floor must fail-close'; end if;
  if v2.fq_fn_projection_status(1,2,3,'a','b','c', now(), null) <> 'NO_FANTASY_BRAIN' then raise exception 'FAIL F6f: null provenance must fail-close'; end if;
  raise notice 'PASS F6: partial projection => fail-close (NO_FANTASY_BRAIN); gate opens only on the complete immutable tuple';

  delete from v2.fq_roster_player   where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots    where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  raise notice '==== BLOCK 5 (F6 projection contract) PASSED ====';
end;
$$;

do $$ begin raise notice '===================================================';
             raise notice '==== iss047 v2 — ALL FANTASY ASSERTIONS PASSED ====';
             raise notice '==================================================='; end; $$;
