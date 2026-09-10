-- iss052 PARLAY SCANNER v4 adversarial tests. Branch-only.
begin;
select v2.fn_seed_parlay_scanner_agenda_real();

do $t$
declare j jsonb; r jsonb; v text;
begin
  j := v2.fn_resolve_event('Fenerbahce','AS Roma','2026-09-10','Europa League','401915422',1);
  if j->>'status'<>'IDENTITY_CONFLICT' or j->>'canonical_event_id' is not null then
    raise exception 'explicit-id contradiction leaked: %',j;
  end if;

  j := v2.fn_resolve_event('Fenerbahce','AS Roma','2026-09-10','Europa League','401915444',1);
  if j->>'status'<>'RESOLVED' or j->>'canonical_event_id'<>'401915444' then
    raise exception 'valid explicit id rejected: %',j;
  end if;

  foreach v in array array['-5.71','0','1','1.00','101','NaN','abc'] loop
    if v2.fn_decimal_odds_valid(v) then raise exception 'invalid odds accepted: %',v; end if;
  end loop;
  if not v2.fn_decimal_odds_valid('5.71') then raise exception '5.71 rejected'; end if;
  if not v2.fn_decimal_odds_valid(null) then raise exception 'NULL odds should mean absent, not invalid'; end if;

  r := v2.fn_parlay_ticket_structure(
    jsonb_build_array(jsonb_build_object(
      'home_raw','Fenerbahce','away_raw','AS Roma','market_raw','Fenerbahce ML',
      'intended_date','2026-09-10','explicit_event_id','401915422','ticket_total_odds','5.71')),
    timestamptz '2026-09-10 15:00+00',1156,null,null,1);
  if r->>'status'<>'NEEDS_REVIEW' or r->>'is_canonical_reason'<>'IDENTITY_CONFLICT'
     or r->>'payout' is not null or r->>'joint_probability' is not null or r->>'EV_REAL' is not null then
    raise exception 'ticket identity conflict did not fail-close: %',r;
  end if;
  if r->'legs'->0->>'identity_status'<>'IDENTITY_CONFLICT' or r->'legs'->0->>'canonical_event_id' is not null then
    raise exception 'leg-level identity conflict missing: %',r->'legs'->0;
  end if;

  r := v2.fn_parlay_ticket_structure(
    jsonb_build_array(jsonb_build_object(
      'home_raw','Fenerbahce','away_raw','AS Roma','market_raw','Fenerbahce ML',
      'intended_date','2026-09-10','home_provider_id','148','away_provider_id','493',
      'ticket_total_odds','5.71')),
    timestamptz '2026-09-10 15:00+00',1156,null,null,1);
  if r->>'status'<>'NEEDS_REVIEW' or r->>'is_canonical_reason'<>'IDENTITY_CONFLICT' then
    raise exception 'provider-id contradiction leaked: %',r;
  end if;

  r := v2.fn_parlay_ticket_structure(
    jsonb_build_array(jsonb_build_object(
      'home_raw','Fenerbahce','away_raw','AS Roma','market_raw','Fenerbahce ML',
      'intended_date','2026-09-10','ticket_total_odds','-5.71')),
    timestamptz '2026-09-10 15:00+00',1156,null,null,1);
  if r->>'status'<>'NEEDS_REVIEW' or r->>'ticket_price_status'<>'INVALID_TICKET_PRICE'
     or r->>'ticket_total_odds' is not null or r->>'payout' is not null then
    raise exception 'negative ticket price leaked: %',r;
  end if;

  -- Team-name digits must never become the market line.
  if (v2.fn_canon_market('Schalke 04 Total Over 1.5')->>'line')::numeric<>1.5 then raise exception 'Schalke line parser regression'; end if;
  if (v2.fn_canon_market('1860 Munich Handicap -1.5')->>'line')::numeric<>-1.5 then raise exception '1860 line parser regression'; end if;
  if (v2.fn_canon_market('Bayer 04 Leverkusen Total Over 2.5')->>'line')::numeric<>2.5 then raise exception 'Bayer 04 line parser regression'; end if;
end
$t$;
rollback;
select 'PARLAY_SCANNER_V4_ADVERSARIAL_PASS' result;
