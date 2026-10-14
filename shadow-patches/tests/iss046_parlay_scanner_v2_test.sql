-- ============================================================================
-- iss046 TEST — permanent adversarial fixture: the EXACT 11-leg owner ticket.
-- STAGED, branch-only (kmasawoljjyfmxadbvou). Requires iss046 applied.
-- Every check RAISE EXCEPTION on failure (fail-close). No weakened assertions.
-- ----------------------------------------------------------------------------
-- Raw leg text is exactly as the OCR produced it (incl. the L1 garble
-- 'Fenerb'||chr(233)||'çe' and OCR leagues that disagree with the canonical
-- Champions League agenda). Decision time is fixed BEFORE all kickoffs.
-- ============================================================================
do $$
declare
  v_kickoff  timestamptz := '2026-01-21 20:00:00+00';
  v_decision timestamptz := '2026-01-21 18:00:00+00';   -- before kickoffs
  v_idate    text := '2026-01-21';
  v_legs     jsonb;
  v_out      jsonb;
  v_bad      jsonb;
  v_tmp      int;
  v_pct      numeric;
  v_leg      jsonb;
begin
  ---------------------------------------------------------------- seed agenda
  perform v2.fn_seed_parlay_scanner_agenda(v_kickoff);

  ------------------------------------------------- assert alias normalization
  if v2.fn_norm_team('Sabah FC') <> v2.fn_norm_team('Sabah FK')
     or v2.fn_norm_team('Sabah FK') <> v2.fn_norm_team('Sabah FA') then
    raise exception 'ALIAS FAIL: Sabah FC/FK/FA do not share one key (% / % / %)',
      v2.fn_norm_team('Sabah FC'), v2.fn_norm_team('Sabah FK'), v2.fn_norm_team('Sabah FA');
  end if;
  if v2.fn_norm_team('Bayern München') <> v2.fn_norm_team('Bayern Munich') then
    raise exception 'ALIAS FAIL: Bayern München/Munich not one key (% / %)',
      v2.fn_norm_team('Bayern München'), v2.fn_norm_team('Bayern Munich');
  end if;
  if v2.fn_norm_team('RC Lens') <> v2.fn_norm_team('Lens') then
    raise exception 'ALIAS FAIL: RC Lens/Lens not one key (% / %)',
      v2.fn_norm_team('RC Lens'), v2.fn_norm_team('Lens');
  end if;
  if v2.fn_norm_team('RB Leipzig') <> 'leipzig' then
    raise exception 'ALIAS FAIL: RB Leipzig did not fold to leipzig key (%)',
      v2.fn_norm_team('RB Leipzig');
  end if;
  if v2.fn_norm_team('Fenerbahçe') <> v2.fn_norm_team('Fenerbahce') then
    raise exception 'ALIAS FAIL: Fenerbahçe/Fenerbahce not one key (% / %)',
      v2.fn_norm_team('Fenerbahçe'), v2.fn_norm_team('Fenerbahce');
  end if;

  ---------------------------------------------- build the 11-leg owner ticket
  v_legs := jsonb_build_array(
    jsonb_build_object('home_raw','Fenerb'||chr(233)||'çe','away_raw','AS Roma',
      'market_raw','BTTS Yes','ocr_league','Europa League','intended_date',v_idate,
      'ticket_total_odds',750.0,'odds_source','OCR'),
    jsonb_build_object('home_raw','Fenerbahce','away_raw','AS Roma',
      'market_raw','Total Más de 2.5','ocr_league','Europa League','intended_date',v_idate,
      'individual_odds',1.588,'ticket_total_odds',750.0,'odds_source','book'),
    jsonb_build_object('home_raw','PSV Eindhoven','away_raw','Shakhtar Donetsk',
      'market_raw','BTTS Yes','ocr_league','UEFA Champions League','intended_date',v_idate,
      'ticket_total_odds',750.0,'odds_source','OCR'),
    jsonb_build_object('home_raw','PSV Eindhoven','away_raw','Shakhtar Donetsk',
      'market_raw','PSV Eindhoven ML','ocr_league','UEFA Champions League','intended_date',v_idate,
      'same_game_price',2.50,'ticket_total_odds',750.0,'odds_source','grouped'),
    jsonb_build_object('home_raw','Bayern München','away_raw','Bodo/Glimt',
      'market_raw','Bayern Asian Handicap -1.5','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',750.0,'odds_source','OCR'),
    jsonb_build_object('home_raw','Bayern München','away_raw','Bodo/Glimt',
      'market_raw','BTTS Yes','ocr_league','UCL','intended_date',v_idate,
      'same_game_price',1.90,'ticket_total_odds',750.0,'odds_source','grouped'),
    jsonb_build_object('home_raw','Como','away_raw','RB Leipzig',
      'market_raw','Como ML','ocr_league','Europa League','intended_date',v_idate,
      'individual_odds',1.769,'ticket_total_odds',750.0,'odds_source','book'),
    jsonb_build_object('home_raw','Como','away_raw','RB Leipzig',
      'market_raw','Como Total Más de 1.5','ocr_league','Europa League','intended_date',v_idate,
      'ticket_total_odds',750.0,'odds_source','OCR'),
    jsonb_build_object('home_raw','Slavia Prague','away_raw','RC Lens',
      'market_raw','BTTS Yes','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',750.0,'odds_source','OCR'),
    jsonb_build_object('home_raw','Manchester United','away_raw','Sabah FC',
      'market_raw','Manchester United Asian Handicap -1.5','ocr_league','UCL','intended_date',v_idate,
      'ticket_total_odds',750.0,'odds_source','OCR'),
    jsonb_build_object('home_raw','Manchester United','away_raw','Sabah FA',
      'market_raw','Manchester United Total Más de 1.5','ocr_league','UCL','intended_date',v_idate,
      'same_game_price',1.60,'ticket_total_odds',750.0,'odds_source','grouped')
  );

  -- stake 100 / bankroll 5000 / NO explicit bonus
  v_out := v2.fn_parlay_ticket_structure(v_legs, v_decision, 100::numeric, 5000::numeric, null::numeric);

  ------------------------------------------------------------ 1) all resolve
  if (v_out->>'n_legs')::int <> 11 then
    raise exception 'LEG COUNT: expected 11 got %', v_out->>'n_legs';
  end if;
  select count(*) into v_tmp
  from jsonb_array_elements(v_out->'legs') el
  where el->>'identity_status' <> 'RESOLVED';
  if v_tmp <> 0 then
    raise exception 'IDENTITY: % leg(s) not RESOLVED: %', v_tmp,
      (select jsonb_agg(jsonb_build_object('leg',el->>'leg_no','st',el->>'identity_status'))
       from jsonb_array_elements(v_out->'legs') el where el->>'identity_status'<>'RESOLVED');
  end if;
  -- Fener/Roma and Como/Leipzig resolve UNIQUELY despite OCR "Europa League"
  if (v_out->'legs'->0->>'canonical_event_id') <> '401915444' then
    raise exception 'L1 Fener/Roma did not resolve to 401915444 (got %)',
      v_out->'legs'->0->>'canonical_event_id';
  end if;
  if (v_out->'legs'->6->>'canonical_event_id') <> '401915441' then
    raise exception 'L7 Como/Leipzig did not resolve to 401915441 (got %)',
      v_out->'legs'->6->>'canonical_event_id';
  end if;

  ------------------------------------------- 3) market discrimination L2/L8/L11
  if (v_out->'legs'->1->>'canonical_market') <> 'MATCH_TOTAL' then
    raise exception 'L2 must be MATCH_TOTAL (got %)', v_out->'legs'->1->>'canonical_market';
  end if;
  if (v_out->'legs'->7->>'canonical_market') <> 'TEAM_TOTAL'
     or (v_out->'legs'->7->>'team_scope') is null then
    raise exception 'L8 must be TEAM_TOTAL with team_scope set (mkt=% scope=%)',
      v_out->'legs'->7->>'canonical_market', v_out->'legs'->7->>'team_scope';
  end if;
  if (v_out->'legs'->10->>'canonical_market') <> 'TEAM_TOTAL'
     or (v_out->'legs'->10->>'team_scope') is null then
    raise exception 'L11 must be TEAM_TOTAL with team_scope set (mkt=% scope=%)',
      v_out->'legs'->10->>'canonical_market', v_out->'legs'->10->>'team_scope';
  end if;
  if (v_out->'legs'->1->>'canonical_market') = (v_out->'legs'->7->>'canonical_market') then
    raise exception 'L2 (match total) and L8 (team total) must NOT be the same market';
  end if;

  ---------------------------------------- 4) grouped legs valid, no fake 1.0 odds
  for v_leg in select el from jsonb_array_elements(v_out->'legs') el
           where (el->>'leg_no')::int in (4,6,11)
  loop
    if (v_leg->>'leg_valid') <> 'true' then
      raise exception 'Grouped leg % must be VALID', v_leg->>'leg_no';
    end if;
    if (v_leg->>'individual_odds') is not null then
      raise exception 'Grouped leg % must NOT carry a fabricated individual price (got %)',
        v_leg->>'leg_no', v_leg->>'individual_odds';
    end if;
    if (v_leg->>'same_game_price') is null then
      raise exception 'Grouped leg % must carry a same_game_price', v_leg->>'leg_no';
    end if;
  end loop;
  -- and NO leg anywhere may carry a fabricated 1.0 individual price
  if exists (select 1 from jsonb_array_elements(v_out->'legs') el
             where (el->>'individual_odds')::numeric = 1.0) then
    raise exception 'A leg carries a fabricated 1.0 individual price';
  end if;

  ----------------------------------------- 5) 6 groups, 5 correlated, status
  if (v_out->>'n_event_groups')::int <> 6 then
    raise exception 'Expected 6 event groups, got %', v_out->>'n_event_groups';
  end if;
  if (v_out->>'n_correlated_groups')::int <> 5
     or jsonb_array_length(v_out->'correlated_groups') <> 5 then
    raise exception 'Expected 5 correlated groups, got % (array len %)',
      v_out->>'n_correlated_groups', jsonb_array_length(v_out->'correlated_groups');
  end if;
  if (v_out->>'CORRELATION_STATUS') <> 'UNMODELED_REQUIRES_JOINT_MODEL' then
    raise exception 'CORRELATION_STATUS wrong: %', v_out->>'CORRELATION_STATUS';
  end if;
  -- PROHIBITED phrase must never appear
  if v_out::text ilike '%sin correlaci%' then
    raise exception 'PROHIBITED: output contains "Sin correlación detectada"';
  end if;

  ------------------------------------------- 6) joint / EV / house_edge NULL
  if jsonb_typeof(v_out->'joint_probability') <> 'null' then
    raise exception 'joint_probability MUST be NULL (got %)', v_out->'joint_probability';
  end if;
  if jsonb_typeof(v_out->'EV_REAL') <> 'null' then
    raise exception 'EV_REAL MUST be NULL (got %)', v_out->'EV_REAL';
  end if;
  if jsonb_typeof(v_out->'house_edge') <> 'null' then
    raise exception 'house_edge MUST be NULL (got %)', v_out->'house_edge';
  end if;
  -- never 1/ticket_odds smuggled in as a probability
  if (v_out->>'joint_probability') is not null then
    raise exception 'joint_probability must not be populated (never 1/ticket_odds)';
  end if;

  ------------------------------------------------ 7) exactly one bankroll pct
  if (v_out->>'bankroll_pct_count')::int <> 1 then
    raise exception 'Expected exactly one bankroll pct, got count %',
      v_out->>'bankroll_pct_count';
  end if;
  v_pct := (v_out->'bankroll'->>'bankroll_pct')::numeric;
  if v_pct is null then
    raise exception 'Bankroll percentage missing';
  end if;
  if v_pct <> 2.0 then
    raise exception 'Bankroll pct should be 2.0 (100/5000), got %', v_pct;
  end if;
  if (v_out->'bankroll'->>'snapshot_id') is null then
    raise exception 'Bankroll snapshot id missing';
  end if;

  ---------------------------------------------------------- 8) bonus handling
  if jsonb_typeof(v_out->'bonus') <> 'null' then
    raise exception 'bonus MUST be NULL when no explicit bonus (got %)', v_out->'bonus';
  end if;
  if (v_out->>'bonus_reason') <> 'NO_EXPLICIT_BONUS' then
    raise exception 'bonus_reason wrong: %', v_out->>'bonus_reason';
  end if;
  -- payout without bonus = stake*ticket_odds = 100*750
  if (v_out->>'payout')::numeric <> 75000 then
    raise exception 'payout should be 75000 (100*750, no bonus), got %', v_out->>'payout';
  end if;

  -- 8b) explicit bonus path: bonus honored and added to payout
  declare v_wb jsonb; begin
    v_wb := v2.fn_parlay_ticket_structure(v_legs, v_decision, 100::numeric, 5000::numeric, 250::numeric);
    if (v_wb->>'bonus')::numeric <> 250 or (v_wb->>'bonus_reason') <> 'EXPLICIT_BONUS' then
      raise exception 'Explicit bonus not honored (bonus=% reason=%)',
        v_wb->>'bonus', v_wb->>'bonus_reason';
    end if;
    if (v_wb->>'payout')::numeric <> 75250 then
      raise exception 'payout with bonus should be 75250 (100*750+250), got %', v_wb->>'payout';
    end if;
  end;

  --------------------------------- 9) fully-resolved ticket is NOT canonical
  -- (joint model unavailable => not a canonical RETO 13M parlay)
  if (v_out->>'is_canonical_reto13m') <> 'false' then
    raise exception 'Fully-resolved-but-unmodeled ticket must have is_canonical_reto13m=false';
  end if;
  if (v_out->>'status') <> 'RESOLVED_NO_JOINT_MODEL' then
    raise exception 'Fully-resolved ticket status should be RESOLVED_NO_JOINT_MODEL, got %',
      v_out->>'status';
  end if;

  ----------------------------- 10) a ticket with an UNRESOLVED leg -> review
  v_bad := v2.fn_parlay_ticket_structure(
    jsonb_build_array(
      jsonb_build_object('home_raw','Fenerbahce','away_raw','AS Roma',
        'market_raw','BTTS Yes','intended_date',v_idate,'ticket_total_odds',2.0),
      jsonb_build_object('home_raw','Nonexistent United','away_raw','Phantom City',
        'market_raw','BTTS Yes','intended_date',v_idate,'ticket_total_odds',2.0)
    ), v_decision, 100::numeric, 5000::numeric, null::numeric);
  if (v_bad->>'status') <> 'NEEDS_REVIEW' then
    raise exception 'Ticket with unresolved leg must be NEEDS_REVIEW, got %', v_bad->>'status';
  end if;
  if (v_bad->>'is_canonical_reto13m') <> 'false' then
    raise exception 'Ticket with unresolved leg must have is_canonical_reto13m=false';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_bad->'legs') el
                 where el->>'identity_status' = 'UNRESOLVED') then
    raise exception 'Expected an UNRESOLVED leg in the bad ticket';
  end if;

  raise notice 'iss046 ALL ASSERTIONS PASSED (11-leg ticket + adversarial paths).';
end $$;
