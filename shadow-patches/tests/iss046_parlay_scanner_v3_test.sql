-- ============================================================================
-- iss046 v3 TEST — resolves issue #4 comment 5620923816 (6 STOP-SHIP findings
-- against parlay scanner v2 @ 6e11994). STAGED, branch-only (kmasawoljjyfmxadbvou).
-- Requires iss046_parlay_scanner_v2.sql (v3) applied. Every check RAISE EXCEPTION
-- on failure (fail-close). No weakened assertions; no fabricated data.
-- ----------------------------------------------------------------------------
-- F1  REAL owner ticket (Sep 10 2026): grouped ticket_total_odds = 5.71,
--     stake = $1,156, 11 legs over the 6 REAL Champions League events. Any field
--     not observable on the ticket stays NULL — per-leg individual/grouped prices
--     are NOT invented, and no bankroll is invented (a single EXPLICIT snapshot is
--     supplied and exactly ONE pct is asserted). The source ticket itself showed a
--     self-contradictory 11.4% / 12.6% stake-of-bankroll — that dual-percentage is
--     the very bug the single-snapshot contract prevents.
-- F2  Resolves against the REAL public.agenda_espn universe
--     (fn_seed_parlay_scanner_agenda_real), not the synthetic gate_fixture path.
-- F3  Adversarial ticket-price conflict (5.71 vs 750) -> TICKET_PRICE_CONFLICT.
-- F4  Numeric-team-name fixtures (Schalke 04 / 1860 Munich / Bayer 04 Leverkusen).
-- F6  Alias-collision fixture (Sabah FK vs Sabah FA) -> AMBIGUOUS fail-close, and
--     provider-id disambiguation.
-- ============================================================================
do $$
declare
  v_idate    text := '2026-09-10';                       -- REAL intended date
  v_decision timestamptz := '2026-09-10 15:00:00+00';    -- before all kickoffs
  v_stake    numeric := 1156;                            -- REAL observed stake
  v_tto      numeric := 5.71;                            -- REAL grouped total odds
  v_bankroll numeric := 10000;                           -- EXPLICIT test snapshot
                                                         -- (NOT extracted from the
                                                         --  ticket; the ticket's own
                                                         --  11.4%/12.6% is the bug)
  v_legs jsonb; v_out jsonb; v_conf jsonb; v_coll jsonb; v_uniq jsonb;
  v_tmp int; v_pct numeric; v_leg jsonb; v_line numeric;
begin
  ----------------------------------------------------- F2: seed the REAL agenda
  perform v2.fn_seed_parlay_scanner_agenda_real();
  select count(*) into v_tmp from v2.parlay_canonical_agenda
   where canonical_event_id in ('401915444','401915422','401915443','401915441','401915440','401915442');
  if v_tmp <> 6 then
    raise exception 'F2: real agenda_espn universe not seeded (found % of 6 events)', v_tmp;
  end if;

  ---------------------------------------------- F1: the REAL 11-leg owner ticket
  -- Raw leg text as OCR produced it (incl. the L1 garble + OCR leagues that
  -- disagree with the canonical UCL agenda). No per-leg prices are invented:
  -- only the grouped ticket_total_odds (5.71) is carried, verbatim, on each leg.
  v_legs := jsonb_build_array(
    jsonb_build_object('home_raw','Fenerb'||chr(233)||'çe','away_raw','AS Roma',
      'market_raw','BTTS Yes','ocr_league','Europa League','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','Fenerbahce','away_raw','AS Roma',
      'market_raw','Total Más de 2.5','ocr_league','Europa League','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','PSV Eindhoven','away_raw','Shakhtar Donetsk',
      'market_raw','BTTS Yes','ocr_league','UEFA Champions League','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','PSV Eindhoven','away_raw','Shakhtar Donetsk',
      'market_raw','PSV Eindhoven ML','ocr_league','UEFA Champions League','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','grouped'),
    jsonb_build_object('home_raw','Bayern München','away_raw','Bodo/Glimt',
      'market_raw','Bayern Asian Handicap -1.5','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','Bayern München','away_raw','Bodo/Glimt',
      'market_raw','BTTS Yes','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','grouped'),
    jsonb_build_object('home_raw','Como','away_raw','RB Leipzig',
      'market_raw','Como ML','ocr_league','Europa League','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','Como','away_raw','RB Leipzig',
      'market_raw','Como Total Más de 1.5','ocr_league','Europa League','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','Slavia Prague','away_raw','RC Lens',
      'market_raw','BTTS Yes','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','Manchester United','away_raw','Sabah FK',
      'market_raw','Manchester United Asian Handicap -1.5','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','OCR'),
    jsonb_build_object('home_raw','Manchester United','away_raw','Sabah FK',
      'market_raw','Manchester United Total Más de 1.5','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',v_tto,'odds_source','grouped')
  );

  v_out := v2.fn_parlay_ticket_structure(v_legs, v_decision, v_stake, v_bankroll, null::numeric);

  ---- 1) leg count + all resolve against the REAL agenda (by alias, no ids) ----
  if (v_out->>'n_legs')::int <> 11 then
    raise exception 'F1 LEG COUNT: expected 11 got %', v_out->>'n_legs';
  end if;
  select count(*) into v_tmp
  from jsonb_array_elements(v_out->'legs') el
  where el->>'identity_status' <> 'RESOLVED';
  if v_tmp <> 0 then
    raise exception 'F1 IDENTITY: % leg(s) not RESOLVED against real agenda: %', v_tmp,
      (select jsonb_agg(jsonb_build_object('leg',el->>'leg_no','st',el->>'identity_status'))
       from jsonb_array_elements(v_out->'legs') el where el->>'identity_status'<>'RESOLVED');
  end if;

  ---- 2) exact REAL event ids per leg (against agenda_espn snapshot) ----
  if (v_out->'legs'->0 ->>'canonical_event_id') <> '401915444'   -- Fenerbahce/Roma
   or (v_out->'legs'->2 ->>'canonical_event_id') <> '401915422'   -- PSV/Shakhtar
   or (v_out->'legs'->4 ->>'canonical_event_id') <> '401915443'   -- Bayern/Bodo
   or (v_out->'legs'->6 ->>'canonical_event_id') <> '401915441'   -- Como/Leipzig
   or (v_out->'legs'->8 ->>'canonical_event_id') <> '401915440'   -- Slavia/Lens
   or (v_out->'legs'->9 ->>'canonical_event_id') <> '401915442'   -- Man Utd/Sabah
  then
    raise exception 'F1 EVENT IDS: real event resolution mismatch: %',
      (select jsonb_agg(el->>'canonical_event_id' order by (el->>'leg_no')::int)
         from jsonb_array_elements(v_out->'legs') el);
  end if;

  ---- 3) market discrimination + F4 line correctness on the real legs ----
  if (v_out->'legs'->1 ->>'canonical_market') <> 'MATCH_TOTAL' then
    raise exception 'F1 L2 must be MATCH_TOTAL (got %)', v_out->'legs'->1->>'canonical_market';
  end if;
  if (v_out->'legs'->7 ->>'canonical_market') <> 'TEAM_TOTAL'
     or (v_out->'legs'->7->>'team_scope') is null then
    raise exception 'F1 L8 must be TEAM_TOTAL with team_scope (mkt=% scope=%)',
      v_out->'legs'->7->>'canonical_market', v_out->'legs'->7->>'team_scope';
  end if;
  if (v_out->'legs'->4 ->>'canonical_market') <> 'ASIAN_HANDICAP'
     or (v_out->'legs'->4->>'canonical_line')::numeric <> -1.5 then
    raise exception 'F1 L5 must be ASIAN_HANDICAP line -1.5 (mkt=% line=%)',
      v_out->'legs'->4->>'canonical_market', v_out->'legs'->4->>'canonical_line';
  end if;

  ---- 4) no invented per-leg prices (unobservable fields stay NULL) ----
  if exists (select 1 from jsonb_array_elements(v_out->'legs') el
             where (el->>'individual_odds') is not null) then
    raise exception 'F1: an individual per-leg price was invented (all must stay NULL)';
  end if;
  if exists (select 1 from jsonb_array_elements(v_out->'legs') el
             where (el->>'individual_odds')::numeric = 1.0) then
    raise exception 'F1: a fabricated 1.0 individual price leaked';
  end if;

  ---- 5) stake 1156 / odds 5.71 flow through; ONE bankroll pct; bonus only if explicit
  if (v_out->>'ticket_total_odds')::numeric <> 5.71 then
    raise exception 'F1 ticket_total_odds must flow as 5.71 (got %)', v_out->>'ticket_total_odds';
  end if;
  if (v_out->>'ticket_price_status') <> 'AGREED' then
    raise exception 'F1 real ticket prices must AGREE (got %)', v_out->>'ticket_price_status';
  end if;
  if (v_out->>'payout')::numeric <> round(v_stake * v_tto, 2) then
    raise exception 'F1 payout must be stake*odds = % (got %)', round(v_stake*v_tto,2), v_out->>'payout';
  end if;
  if (v_out->>'bankroll_pct_count')::int <> 1 then
    raise exception 'F1 must emit exactly ONE bankroll pct (anti 11.4%%/12.6%% bug), got count %',
      v_out->>'bankroll_pct_count';
  end if;
  v_pct := (v_out->'bankroll'->>'bankroll_pct')::numeric;
  if v_pct is distinct from round(v_stake / v_bankroll * 100, 4) then
    raise exception 'F1 single bankroll pct wrong: expected % got %',
      round(v_stake/v_bankroll*100,4), v_pct;
  end if;
  if (v_out->'bankroll'->>'snapshot_id') is null then
    raise exception 'F1 bankroll snapshot id missing';
  end if;
  if jsonb_typeof(v_out->'bonus') <> 'null' or (v_out->>'bonus_reason') <> 'NO_EXPLICIT_BONUS' then
    raise exception 'F1 bonus must be NULL / NO_EXPLICIT_BONUS (bonus=% reason=%)',
      v_out->'bonus', v_out->>'bonus_reason';
  end if;

  ---- 6) 6 groups, 5 correlated, correlation emitted, joint/EV/house NULL ----
  if (v_out->>'n_event_groups')::int <> 6 then
    raise exception 'F1 expected 6 event groups, got %', v_out->>'n_event_groups';
  end if;
  if (v_out->>'n_correlated_groups')::int <> 5
     or jsonb_array_length(v_out->'correlated_groups') <> 5 then
    raise exception 'F1 expected 5 correlated groups, got % (arr %)',
      v_out->>'n_correlated_groups', jsonb_array_length(v_out->'correlated_groups');
  end if;
  if (v_out->>'CORRELATION_STATUS') <> 'UNMODELED_REQUIRES_JOINT_MODEL' then
    raise exception 'F1 CORRELATION_STATUS wrong: %', v_out->>'CORRELATION_STATUS';
  end if;
  if v_out::text ilike '%sin correlaci%' then
    raise exception 'F1 PROHIBITED phrase "Sin correlación detectada" present';
  end if;
  if jsonb_typeof(v_out->'joint_probability') <> 'null'
     or jsonb_typeof(v_out->'EV_REAL') <> 'null'
     or jsonb_typeof(v_out->'house_edge') <> 'null' then
    raise exception 'F1 joint/EV/house_edge must all be NULL (joint=% ev=% he=%)',
      v_out->'joint_probability', v_out->'EV_REAL', v_out->'house_edge';
  end if;
  if (v_out->>'status') <> 'RESOLVED_NO_JOINT_MODEL'
     or (v_out->>'is_canonical_reto13m') <> 'false' then
    raise exception 'F1 status/canon wrong (status=% canon=%)',
      v_out->>'status', v_out->>'is_canonical_reto13m';
  end if;

  --------------------------------------- F3: ticket-total-odds CONFLICT fail-close
  -- Same event, two contradictory ticket totals (5.71 vs 750). v2 did MAX() and
  -- silently accepted 750; v3 must fail-close.
  v_conf := v2.fn_parlay_ticket_structure(jsonb_build_array(
     jsonb_build_object('home_raw','Fenerbahce','away_raw','AS Roma',
       'market_raw','BTTS Yes','intended_date',v_idate,'ticket_total_odds',5.71),
     jsonb_build_object('home_raw','Fenerbahce','away_raw','AS Roma',
       'market_raw','Total Más de 2.5','intended_date',v_idate,'ticket_total_odds',750)
  ), v_decision, v_stake, v_bankroll, null::numeric);
  if (v_conf->>'ticket_price_status') <> 'TICKET_PRICE_CONFLICT'
     or (v_conf->>'ticket_price_conflict') <> 'true' then
    raise exception 'F3 must flag TICKET_PRICE_CONFLICT (status=% flag=%)',
      v_conf->>'ticket_price_status', v_conf->>'ticket_price_conflict';
  end if;
  if (v_conf->>'status') <> 'NEEDS_REVIEW' then
    raise exception 'F3 price conflict must be NEEDS_REVIEW, got %', v_conf->>'status';
  end if;
  if jsonb_typeof(v_conf->'payout') <> 'null' or jsonb_typeof(v_conf->'ticket_total_odds') <> 'null' then
    raise exception 'F3 payout AND ticket_total_odds must be NULL on conflict (never accept 750): payout=% tto=%',
      v_conf->'payout', v_conf->'ticket_total_odds';
  end if;
  if (v_conf->>'is_canonical_reto13m') <> 'false' then
    raise exception 'F3 price conflict must have is_canonical_reto13m=false';
  end if;

  ------------------------------------------- F4: numeric team-name line parsing
  -- The line/handicap must come from the market-expression AFTER the token, never
  -- from digits in the team name. v2 gave 4 / 04 / 1860; v3 must give 1.5/-1.5/2.5.
  v_line := (v2.fn_canon_market('Schalke 04 Total Más de 1.5')->>'line')::numeric;
  if v_line is distinct from 1.5 then
    raise exception 'F4 Schalke 04 total line must be 1.5 (not 4/04), got %', v_line;
  end if;
  v_line := (v2.fn_canon_market('1860 Munich Handicap -1.5')->>'line')::numeric;
  if v_line is distinct from -1.5 then
    raise exception 'F4 1860 Munich handicap line must be -1.5 (not 1860), got %', v_line;
  end if;
  v_line := (v2.fn_canon_market('Bayer 04 Leverkusen Total Más de 2.5')->>'line')::numeric;
  if v_line is distinct from 2.5 then
    raise exception 'F4 Bayer 04 Leverkusen total line must be 2.5 (not 04), got %', v_line;
  end if;
  -- explicit negative assertions: the team-name digits must NEVER become the line
  if (v2.fn_canon_market('Schalke 04 Total Más de 1.5')->>'line')::numeric in (4, 04)
   or (v2.fn_canon_market('1860 Munich Handicap -1.5')->>'line')::numeric = 1860 then
    raise exception 'F4 REGRESSION: a team-name digit leaked into the market line';
  end if;

  ------------------------------------- F6: alias-collision fail-close + provider id
  -- Sabah FK (Azerbaijan, event 401915442) and Sabah FA (Malaysia) are DISTINCT
  -- real clubs that both strip to the same normalized key 'sabah'. Inject the
  -- Malaysian side as a second distinct event on the same matchup+date. A leg that
  -- carries only aliases must go AMBIGUOUS (fail-close), never guess. Providing the
  -- canonical provider team ids must disambiguate back to the unique real event.
  insert into v2.parlay_canonical_agenda
    (canonical_event_id, home_canonical, away_canonical, home_norm, away_norm,
     kickoff, competition_id, home_provider_id, away_provider_id)
  values ('ADV_COLL_SABAH_MY','Manchester United','Sabah FA (MY)',
     v2.fn_norm_team('Manchester United'), v2.fn_norm_team('Sabah FA'),
     '2026-09-10 19:00:00+00','2','360','99999')
  on conflict (canonical_event_id) do nothing;

  v_coll := v2.fn_parlay_ticket_structure(jsonb_build_array(
     jsonb_build_object('home_raw','Manchester United','away_raw','Sabah FK',
       'market_raw','BTTS Yes','intended_date',v_idate,'ticket_total_odds',2.0)
  ), v_decision, 100::numeric, v_bankroll, null::numeric);
  if (v_coll->'legs'->0->>'identity_status') <> 'AMBIGUOUS' then
    raise exception 'F6 alias collision must be AMBIGUOUS, got %', v_coll->'legs'->0->>'identity_status';
  end if;
  if (v_coll->'legs'->0->>'n_cand')::int < 2
     or jsonb_array_length(v_coll->'legs'->0->'candidates') < 2 then
    raise exception 'F6 ambiguous leg must expose >1 candidate (n_cand=% cands=%)',
      v_coll->'legs'->0->>'n_cand', v_coll->'legs'->0->'candidates';
  end if;
  if (v_coll->'legs'->0->>'canonical_event_id') is not null then
    raise exception 'F6 must NOT guess an event id when ambiguous (got %)',
      v_coll->'legs'->0->>'canonical_event_id';
  end if;
  if (v_coll->>'status') <> 'NEEDS_REVIEW' or (v_coll->>'is_canonical_reto13m') <> 'false' then
    raise exception 'F6 ambiguous ticket must be NEEDS_REVIEW / not canonical (status=% canon=%)',
      v_coll->>'status', v_coll->>'is_canonical_reto13m';
  end if;

  -- provider-id disambiguation resolves the SAME leg uniquely to the real event
  v_uniq := v2.fn_parlay_ticket_structure(jsonb_build_array(
     jsonb_build_object('home_raw','Manchester United','away_raw','Sabah FK',
       'home_provider_id','360','away_provider_id','21922',
       'market_raw','BTTS Yes','intended_date',v_idate,'ticket_total_odds',2.0)
  ), v_decision, 100::numeric, v_bankroll, null::numeric);
  if (v_uniq->'legs'->0->>'identity_status') <> 'RESOLVED'
     or (v_uniq->'legs'->0->>'canonical_event_id') <> '401915442' then
    raise exception 'F6 provider-id disambiguation must resolve to 401915442 (identity=% id=%)',
      v_uniq->'legs'->0->>'identity_status', v_uniq->'legs'->0->>'canonical_event_id';
  end if;

  -- restore the real agenda (drop the adversarial collision row)
  delete from v2.parlay_canonical_agenda where canonical_event_id = 'ADV_COLL_SABAH_MY';

  raise notice 'iss046 v3 ALL ASSERTIONS PASSED (real 11-leg fixture + F3/F4/F6 adversarials).';
end $$;
