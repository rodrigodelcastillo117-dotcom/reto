-- ============================================================================
-- iss047 FANTASY "EQUIPO" START/SIT TEST — branch-only (kmasawoljjyfmxadbvou).
-- Requires iss047_fantasy_equipo_startsit.sql applied. RAISE EXCEPTION on any
-- failure; a clean run (final NOTICE) = all assertions passed.
--
-- Seeds the owner's league: PPR (1.0) + FLEX + Superflex + TE Premium, 6 BN,
-- 2 IR. Seeds a full roster: starters + a full 6-man bench (incl a clearly
-- better bench WR option) + an IR player. Asserts scoring names, eligible_slots,
-- LEGAL-only swaps, illegal-swap exclusion, IR exclusion, NULL projections /
-- PROJECTION_UNAVAILABLE recommendation, and the ROSTER_INCOMPLETE gate.
-- Owner contract: issue #4 comment 5620342324.
-- ============================================================================
do $$
declare
  v_prof text := 'iss047_test_ppr_owner';
  r record; n int; v text; d numeric; arr text[];
begin
  -- clean any prior run
  delete from v2.fq_roster_player where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots  where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  -- ==========================================================================
  -- SEED: owner's PPR league (Superflex + TE Premium), 10 starter slots, 6 BN, 2 IR
  --   Starters: QB1, RB2, WR2, TE1, FLEX1, SUPERFLEX1, K1, DEF1 = 10
  -- ==========================================================================
  insert into v2.fq_scoring_profile(
    scoring_profile_id, name, ppr_per_reception, te_premium_bonus, superflex,
    qb_slots, rb_slots, wr_slots, te_slots, flex_slots, superflex_slots, k_slots, def_slots,
    bench_count, ir_count
  ) values (
    v_prof,
    v2.fq_fn_canonical_scoring_name(1.0, false),  -- must resolve to 'PPR'
    1.0, 0.5, true,
    1, 2, 2, 1, 1, 1, 1, 1,
    6, 2
  );
  perform v2.fq_fn_sync_roster_slots(v_prof);

  -- STARTERS (10)
  insert into v2.fq_roster_player(scoring_profile_id, player_id, display_name, position, lineup_state, roster_slot, rival, kickoff) values
    (v_prof,'p_qb1', 'QB One',  'QB', 'STARTER','QB',        'DAL', now()+interval '2 day'),
    (v_prof,'p_rb1', 'RB One',  'RB', 'STARTER','RB',        'NYG', now()+interval '2 day'),
    (v_prof,'p_rb2', 'RB Two',  'RB', 'STARTER','RB',        'PHI', now()+interval '2 day'),
    (v_prof,'p_wr1', 'WR One',  'WR', 'STARTER','WR',        'SF',  now()+interval '2 day'),
    (v_prof,'p_wr2', 'WR Two',  'WR', 'STARTER','WR',        'SEA', now()+interval '2 day'),
    (v_prof,'p_te1', 'TE One',  'TE', 'STARTER','TE',        'GB',  now()+interval '2 day'),
    (v_prof,'p_flx', 'Flex RB', 'RB', 'STARTER','FLEX',      'MIN', now()+interval '2 day'),
    (v_prof,'p_sfx', 'SF QB',   'QB', 'STARTER','SUPERFLEX', 'DET', now()+interval '2 day'),
    (v_prof,'p_k1',  'Kicker',  'K',  'STARTER','K',         'CHI', now()+interval '2 day'),
    (v_prof,'p_def1','Defense', 'DEF','STARTER','DEF',       'ATL', now()+interval '2 day');

  -- BENCH (6): incl a clearly-better WR (structurally the legal alternative at WR/FLEX)
  insert into v2.fq_roster_player(scoring_profile_id, player_id, display_name, position, lineup_state, rival, kickoff) values
    (v_prof,'b_wr3', 'Bench WR (better)', 'WR', 'BENCH','LAR', now()+interval '2 day'),
    (v_prof,'b_rb3', 'Bench RB',          'RB', 'BENCH','TB',  now()+interval '2 day'),
    (v_prof,'b_qb2', 'Bench QB',          'QB', 'BENCH','NO',  now()+interval '2 day'),
    (v_prof,'b_te2', 'Bench TE',          'TE', 'BENCH','CAR', now()+interval '2 day'),
    (v_prof,'b_k2',  'Bench Kicker',      'K',  'BENCH','JAX', now()+interval '2 day'),
    (v_prof,'b_def2','Bench Defense',     'DEF','BENCH','TEN', now()+interval '2 day');

  -- IR (1): must NEVER be offered as a start candidate
  insert into v2.fq_roster_player(scoring_profile_id, player_id, display_name, position, lineup_state, injury_status, rival, kickoff) values
    (v_prof,'ir_wr9', 'IR WR', 'WR', 'IR', 'OUT', 'HOU', now()+interval '2 day');

  -- ==========================================================================
  -- ASSERT 1: scoring profile name is exactly one of the four; PPR->1.0
  -- ==========================================================================
  select name into v from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  if v not in ('STANDARD','HALF PPR','PPR','CUSTOM') then
    raise exception 'FAIL A1a: profile name % not in canonical set', v;
  end if;
  if v <> 'PPR' then raise exception 'FAIL A1b: owner league expected PPR, got %', v; end if;
  select ppr_per_reception into d from v2.fq_scoring_profile where scoring_profile_id = v_prof;
  if d <> 1.0 then raise exception 'FAIL A1c: PPR ppr expected 1.0, got %', d; end if;
  if v2.fq_fn_canonical_scoring_name(0.0,false) <> 'STANDARD' then raise exception 'FAIL A1d: 0.0 not STANDARD'; end if;
  if v2.fq_fn_canonical_scoring_name(0.5,false) <> 'HALF PPR' then raise exception 'FAIL A1e: 0.5 not HALF PPR'; end if;
  if v2.fq_fn_canonical_scoring_name(1.0,false) <> 'PPR'      then raise exception 'FAIL A1f: 1.0 not PPR'; end if;
  if v2.fq_fn_canonical_scoring_name(0.7,false) <> 'CUSTOM'   then raise exception 'FAIL A1g: 0.7 not CUSTOM'; end if;
  if v2.fq_fn_canonical_scoring_name(1.0,true)  <> 'CUSTOM'   then raise exception 'FAIL A1h: extra rules not CUSTOM'; end if;
  raise notice 'PASS A1: scoring names canonical (STANDARD/HALF PPR/PPR/CUSTOM); owner league = PPR (1.0)';

  -- ==========================================================================
  -- ASSERT 2: eligible_slots correct (RB FLEX+SUPERFLEX; QB SUPERFLEX not FLEX;
  --           K only K; DEF only DEF)
  -- ==========================================================================
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_rb1';
  if not ('FLEX' = any(arr)) or not ('SUPERFLEX' = any(arr)) or not ('RB' = any(arr)) then
    raise exception 'FAIL A2a: RB eligible_slots wrong: %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_qb1';
  if not ('SUPERFLEX' = any(arr)) then raise exception 'FAIL A2b: QB not SUPERFLEX-eligible: %', arr; end if;
  if ('FLEX' = any(arr)) then raise exception 'FAIL A2c: QB must NOT be FLEX-eligible: %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_k1';
  if arr <> array['K'] then raise exception 'FAIL A2d: K eligible_slots must be {K}: %', arr; end if;
  select eligible_slots into arr from v2.fq_roster_player where scoring_profile_id=v_prof and player_id='p_def1';
  if arr <> array['DEF'] then raise exception 'FAIL A2e: DEF eligible_slots must be {DEF}: %', arr; end if;
  raise notice 'PASS A2: eligible_slots correct (RB=RB/FLEX/SUPERFLEX, QB=QB/SUPERFLEX not FLEX, K={K}, DEF={DEF})';

  -- ==========================================================================
  -- ASSERT 3: optimizer offers ONLY legal swaps; illegal swaps NEVER offered
  -- ==========================================================================
  -- every offered swap must be legal: bench alt must be eligible for the starter slot
  for r in
    select ss.starter_player_id, ss.starter_slot, ss.best_bench_alternative_id
    from v2.fq_fn_start_sit(v_prof) ss
    where ss.best_bench_alternative_id is not null
  loop
    select eligible_slots into arr from v2.fq_roster_player
      where scoring_profile_id=v_prof and player_id=r.best_bench_alternative_id;
    if not (r.starter_slot = any(arr)) then
      raise exception 'FAIL A3a: ILLEGAL swap offered — % into slot % (bench eligible: %)',
        r.best_bench_alternative_id, r.starter_slot, arr;
    end if;
  end loop;
  -- specific illegal cases must never appear:
  --   K bench (b_k2) into any non-K slot; DEF bench (b_def2) into any non-DEF slot
  select count(*) into n from v2.fq_fn_start_sit(v_prof) ss
    where ss.best_bench_alternative_id = 'b_k2' and ss.starter_slot <> 'K';
  if n <> 0 then raise exception 'FAIL A3b: kicker offered into a non-K slot (%)', n; end if;
  select count(*) into n from v2.fq_fn_start_sit(v_prof) ss
    where ss.best_bench_alternative_id = 'b_def2' and ss.starter_slot <> 'DEF';
  if n <> 0 then raise exception 'FAIL A3c: defense offered into a non-DEF slot (%)', n; end if;
  -- and the WR starter slot must be able to receive the legal bench WR (structure real now)
  select count(*) into n from v2.fq_fn_start_sit(v_prof) ss
    where ss.starter_slot='WR' and ss.best_bench_alternative_id is not null;
  if n = 0 then raise exception 'FAIL A3d: WR starters have no legal bench alternative (expected b_wr3 eligible)'; end if;
  raise notice 'PASS A3: only LEGAL swaps offered; K/DEF never cross into WR/other slots';

  -- ==========================================================================
  -- ASSERT 4: projections NULL & recommendation = PROJECTION_UNAVAILABLE...
  -- ==========================================================================
  select count(*) into n from v2.fq_fn_start_sit(v_prof) ss
    where ss.best_bench_alternative_id is not null
      and (ss.delta_median is not null or ss.delta_ceiling is not null
           or ss.recommendation <> 'PROJECTION_UNAVAILABLE_NO_FANTASY_BRAIN');
  if n <> 0 then raise exception 'FAIL A4a: fabricated projection/delta or non-unavailable recommendation (%)', n; end if;
  -- the underlying player projections are NULL and status NO_FANTASY_BRAIN
  select count(*) into n from v2.fq_roster_player
    where scoring_profile_id=v_prof
      and (proj_floor is not null or proj_median is not null or proj_ceiling is not null
           or projection_status <> 'NO_FANTASY_BRAIN');
  if n <> 0 then raise exception 'FAIL A4b: player projections not NULL / status not NO_FANTASY_BRAIN (%)', n; end if;
  raise notice 'PASS A4: projections NULL, deltas NULL, recommendation=PROJECTION_UNAVAILABLE_NO_FANTASY_BRAIN';

  -- ==========================================================================
  -- ASSERT 5: IR player never offered as a start candidate
  -- ==========================================================================
  select count(*) into n from v2.fq_fn_start_sit(v_prof) ss where ss.best_bench_alternative_id = 'ir_wr9';
  if n <> 0 then raise exception 'FAIL A5: IR player offered as start candidate (%)', n; end if;
  raise notice 'PASS A5: IR player never offered as a start candidate';

  -- ==========================================================================
  -- ASSERT 6: COMPLETE roster => optimizer emits one row per starter (10)
  -- ==========================================================================
  select status into v from v2.fq_fn_roster_status(v_prof);
  if v <> 'COMPLETE' then raise exception 'FAIL A6a: full roster expected COMPLETE, got %', v; end if;
  select count(*) into n from v2.fq_fn_start_sit(v_prof);
  if n <> 10 then raise exception 'FAIL A6b: expected 10 starter rows on COMPLETE roster, got %', n; end if;
  raise notice 'PASS A6: COMPLETE roster => 10 starter rows emitted';

  -- ==========================================================================
  -- ASSERT 7: remove the full bench => ROSTER_INCOMPLETE and recs WITHHELD
  -- ==========================================================================
  delete from v2.fq_roster_player where scoring_profile_id=v_prof and lineup_state='BENCH';
  select status, missing_count into v, n from v2.fq_fn_roster_status(v_prof);
  if v <> 'ROSTER_INCOMPLETE' then raise exception 'FAIL A7a: bench removed but status=%', v; end if;
  if n < 6 then raise exception 'FAIL A7b: expected >=6 missing (6 bench), got %', n; end if;
  select count(*) into n from v2.fq_fn_start_sit(v_prof);
  if n <> 0 then raise exception 'FAIL A7c: recommendations NOT withheld on incomplete roster (% rows)', n; end if;
  raise notice 'PASS A7: bench removed => ROSTER_INCOMPLETE, recommendations withheld (0 rows)';

  -- cleanup
  delete from v2.fq_roster_player where scoring_profile_id = v_prof;
  delete from v2.fq_roster_slots  where scoring_profile_id = v_prof;
  delete from v2.fq_scoring_profile where scoring_profile_id = v_prof;

  raise notice '==== iss047 ALL ASSERTIONS PASSED ====';
end;
$$;
