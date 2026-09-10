-- ============================================================================
-- iss052 — PARLAY SCANNER v4 HARDENING (ChatGPT parallel closeout)
-- Branch-only. NO PROD mutation. Builds on iss046 v3 core.
-- Fixes two independently reproduced STOP-SHIP defects:
--   1) explicit/provider identity could override contradictory ticket teams/date
--   2) decimal odds outside 1.01..100 could produce nonsensical payout
-- ============================================================================
create schema if not exists v2;

create or replace function v2.fn_decimal_odds_valid(p_raw text)
returns boolean language plpgsql immutable as $fn$
declare v numeric;
begin
  if p_raw is null or btrim(p_raw)='' then return true; end if; -- absent is allowed
  if btrim(p_raw) !~ '^[0-9]+([.][0-9]+)?$' then return false; end if;
  begin v := btrim(p_raw)::numeric; exception when others then return false; end;
  if v::text='NaN' then return false; end if;
  return v between 1.01 and 100;
end
$fn$;

-- Convenience resolver: an explicit event id is evidence, never absolute authority.
-- It must agree with observable teams/date before being accepted.
create or replace function v2.fn_resolve_event(
  p_home_raw text, p_away_raw text, p_intended_date date, p_ocr_league text,
  p_explicit_event_id text default null, p_window_days int default 1
)
returns jsonb language plpgsql stable as $fn$
declare
  lh text := v2.fn_canon_team_key(p_home_raw);
  la text := v2.fn_canon_team_key(p_away_raw);
  v_cand jsonb;
  v_n int;
  r record;
  team_evidence boolean;
begin
  if nullif(p_explicit_event_id,'') is not null then
    select * into r from v2.parlay_canonical_agenda a where a.canonical_event_id=p_explicit_event_id;
    if not found then
      return jsonb_build_object('status','IDENTITY_CONFLICT','canonical_event_id',null,
        'identity_confidence',0,'reason','EXPLICIT_EVENT_ID_NOT_FOUND',
        'explicit_event_id',p_explicit_event_id,'candidates','[]'::jsonb);
    end if;

    team_evidence := lh is not null and la is not null;
    if (team_evidence and not (
          (r.home_norm=lh and r.away_norm=la) or (r.home_norm=la and r.away_norm=lh)
       ))
       or (p_intended_date is not null and
           r.kickoff::date not between p_intended_date-p_window_days and p_intended_date+p_window_days)
    then
      return jsonb_build_object('status','IDENTITY_CONFLICT','canonical_event_id',null,
        'identity_confidence',0,'reason','EXPLICIT_EVENT_ID_CONTRADICTS_TEAMS_OR_DATE',
        'explicit_event_id',p_explicit_event_id,
        'observed',jsonb_build_object('home_raw',p_home_raw,'away_raw',p_away_raw,'intended_date',p_intended_date),
        'explicit_event',jsonb_build_object('home',r.home_canonical,'away',r.away_canonical,'kickoff',r.kickoff),
        'candidates',jsonb_build_array(r.canonical_event_id));
    end if;

    return jsonb_build_object('status','RESOLVED','canonical_event_id',r.canonical_event_id,
      'home_canonical',r.home_canonical,'away_canonical',r.away_canonical,
      'kickoff',r.kickoff,'competition_id',r.competition_id,'identity_confidence',1.0,
      'evidence',jsonb_build_object('rule','EXPLICIT_EVENT_ID_VERIFIED','ocr_league',p_ocr_league,
        'ocr_league_role','SUPPORTING_ONLY'),
      'candidates',jsonb_build_array(r.canonical_event_id));
  end if;

  select jsonb_agg(a.canonical_event_id order by a.canonical_event_id),count(*)
    into v_cand,v_n
  from v2.parlay_canonical_agenda a
  where ((a.home_norm=lh and a.away_norm=la) or (a.home_norm=la and a.away_norm=lh))
    and a.kickoff::date between coalesce(p_intended_date,a.kickoff::date)-p_window_days
                           and coalesce(p_intended_date,a.kickoff::date)+p_window_days;

  if coalesce(v_n,0)=0 then
    return jsonb_build_object('status','UNRESOLVED','canonical_event_id',null,'identity_confidence',0,
      'evidence',jsonb_build_object('rule','NO_TEAM_DATE_MATCH','home_norm',lh,'away_norm',la,
        'ocr_league',p_ocr_league,'ocr_league_role','SUPPORTING_ONLY'),'candidates','[]'::jsonb);
  elsif v_n>1 then
    return jsonb_build_object('status','AMBIGUOUS','canonical_event_id',null,'identity_confidence',0,
      'evidence',jsonb_build_object('rule','MULTIPLE_TEAM_DATE_CANDIDATES','ocr_league',p_ocr_league,
        'ocr_league_role','SUPPORTING_ONLY'),'candidates',v_cand);
  end if;

  select * into r from v2.parlay_canonical_agenda a where a.canonical_event_id=(v_cand->>0);
  return jsonb_build_object('status','RESOLVED','canonical_event_id',r.canonical_event_id,
    'home_canonical',r.home_canonical,'away_canonical',r.away_canonical,
    'kickoff',r.kickoff,'competition_id',r.competition_id,'identity_confidence',1.0,
    'evidence',jsonb_build_object('rule','TEAMS_PLUS_DATE_UNIQUE','ocr_league',p_ocr_league,
      'ocr_league_role','SUPPORTING_ONLY'),'candidates',v_cand);
end
$fn$;

-- Preserve the already-tested v3 implementation as a private core once.
do $rename$
begin
  if to_regprocedure('v2.fn_parlay_ticket_structure_v3_core(jsonb,timestamp with time zone,numeric,numeric,numeric,integer)') is null then
    if to_regprocedure('v2.fn_parlay_ticket_structure(jsonb,timestamp with time zone,numeric,numeric,numeric,integer)') is null then
      raise exception 'iss052 prerequisite missing: fn_parlay_ticket_structure v3';
    end if;
    alter function v2.fn_parlay_ticket_structure(jsonb,timestamptz,numeric,numeric,numeric,int)
      rename to fn_parlay_ticket_structure_v3_core;
  end if;
end
$rename$;

-- Public v4 wrapper: validate identity evidence and odds BEFORE the v3 core is allowed
-- to resolve/calculate. Contradictory legs are deliberately sanitized to unresolved in
-- the core, then surfaced as IDENTITY_CONFLICT in the final response.
create or replace function v2.fn_parlay_ticket_structure(
  p_legs jsonb, p_decision timestamptz,
  p_stake numeric default null, p_bankroll_snapshot numeric default null,
  p_bonus numeric default null, p_window_days int default 1
)
returns jsonb language plpgsql stable as $fn$
declare
  v_sanitized jsonb := '[]'::jsonb;
  v_conflicts jsonb := '[]'::jsonb;
  v_bad_prices jsonb := '[]'::jsonb;
  v_result jsonb;
  rec record;
  leg jsonb;
  a record;
  provider_n int;
  provider_event text;
  reason text;
  f text;
  rawv text;
  idx int;
  conflict boolean;
  bad_price boolean;
begin
  if p_legs is null or jsonb_typeof(p_legs)<>'array' then
    return jsonb_build_object('status','NEEDS_REVIEW','is_canonical_reto13m',false,
      'is_canonical_reason','INVALID_LEGS_PAYLOAD','legs','[]'::jsonb,
      'joint_probability',null,'EV_REAL',null,'payout',null);
  end if;

  for rec in select value as leg, ordinality::int as leg_no
             from jsonb_array_elements(p_legs) with ordinality loop
    leg := rec.leg;
    conflict := false;
    bad_price := false;
    reason := null;

    -- Price domain validation. Missing is valid; any supplied decimal price must be 1.01..100.
    foreach f in array array['ticket_total_odds','individual_odds','same_game_price','grouped_event_odds'] loop
      rawv := nullif(leg->>f,'');
      if rawv is not null and not v2.fn_decimal_odds_valid(rawv) then
        bad_price := true;
        v_bad_prices := v_bad_prices || jsonb_build_array(jsonb_build_object(
          'leg_no',rec.leg_no,'field',f,'raw',rawv,'reason','INVALID_DECIMAL_ODDS_DOMAIN'));
        leg := leg - f; -- core must never cast/use the invalid value
      end if;
    end loop;

    -- Explicit event ID must agree with ticket teams/date and any supplied provider IDs.
    if nullif(leg->>'explicit_event_id','') is not null then
      select * into a from v2.parlay_canonical_agenda
       where canonical_event_id=leg->>'explicit_event_id';
      if not found then
        conflict:=true; reason:='EXPLICIT_EVENT_ID_NOT_FOUND';
      else
        if nullif(leg->>'home_raw','') is not null and nullif(leg->>'away_raw','') is not null
           and not (
             (a.home_norm=v2.fn_canon_team_key(leg->>'home_raw') and a.away_norm=v2.fn_canon_team_key(leg->>'away_raw'))
             or
             (a.home_norm=v2.fn_canon_team_key(leg->>'away_raw') and a.away_norm=v2.fn_canon_team_key(leg->>'home_raw'))
           ) then conflict:=true; reason:='EXPLICIT_EVENT_ID_CONTRADICTS_TEAMS'; end if;
        if not conflict and nullif(leg->>'intended_date','') is not null
           and a.kickoff::date not between (leg->>'intended_date')::date-p_window_days
                                       and (leg->>'intended_date')::date+p_window_days
           then conflict:=true; reason:='EXPLICIT_EVENT_ID_CONTRADICTS_DATE'; end if;
        if not conflict and nullif(leg->>'home_provider_id','') is not null and nullif(leg->>'away_provider_id','') is not null
           and not (
             (a.home_provider_id=leg->>'home_provider_id' and a.away_provider_id=leg->>'away_provider_id')
             or
             (a.home_provider_id=leg->>'away_provider_id' and a.away_provider_id=leg->>'home_provider_id')
           ) then conflict:=true; reason:='EXPLICIT_EVENT_ID_CONTRADICTS_PROVIDER_IDS'; end if;
      end if;

    -- Provider IDs, when supplied without explicit id, must resolve uniquely and agree with teams/date.
    elsif nullif(leg->>'home_provider_id','') is not null and nullif(leg->>'away_provider_id','') is not null then
      select count(*),min(canonical_event_id) into provider_n,provider_event
      from v2.parlay_canonical_agenda x
      where (x.home_provider_id=leg->>'home_provider_id' and x.away_provider_id=leg->>'away_provider_id')
         or (x.home_provider_id=leg->>'away_provider_id' and x.away_provider_id=leg->>'home_provider_id');
      if provider_n<>1 then
        conflict:=true; reason:=case when provider_n=0 then 'PROVIDER_IDS_NOT_FOUND' else 'PROVIDER_IDS_AMBIGUOUS' end;
      else
        select * into a from v2.parlay_canonical_agenda where canonical_event_id=provider_event;
        if nullif(leg->>'home_raw','') is not null and nullif(leg->>'away_raw','') is not null
           and not (
             (a.home_norm=v2.fn_canon_team_key(leg->>'home_raw') and a.away_norm=v2.fn_canon_team_key(leg->>'away_raw'))
             or
             (a.home_norm=v2.fn_canon_team_key(leg->>'away_raw') and a.away_norm=v2.fn_canon_team_key(leg->>'home_raw'))
           ) then conflict:=true; reason:='PROVIDER_IDS_CONTRADICT_TEAMS'; end if;
        if not conflict and nullif(leg->>'intended_date','') is not null
           and a.kickoff::date not between (leg->>'intended_date')::date-p_window_days
                                       and (leg->>'intended_date')::date+p_window_days
           then conflict:=true; reason:='PROVIDER_IDS_CONTRADICT_DATE'; end if;
      end if;
    end if;

    if conflict then
      v_conflicts := v_conflicts || jsonb_build_array(jsonb_build_object(
        'leg_no',rec.leg_no,'reason',reason,
        'explicit_event_id',leg->>'explicit_event_id',
        'home_raw',leg->>'home_raw','away_raw',leg->>'away_raw',
        'home_provider_id',leg->>'home_provider_id','away_provider_id',leg->>'away_provider_id',
        'intended_date',leg->>'intended_date'));
      -- Sentinel forces the existing core to fail-close this leg instead of trusting an ID.
      leg := leg - 'explicit_event_id' - 'home_provider_id' - 'away_provider_id';
      leg := jsonb_set(leg,'{home_raw}',to_jsonb('__IDENTITY_CONFLICT_HOME__'::text),true);
      leg := jsonb_set(leg,'{away_raw}',to_jsonb('__IDENTITY_CONFLICT_AWAY__'::text),true);
    end if;

    v_sanitized := v_sanitized || jsonb_build_array(leg);
  end loop;

  v_result := v2.fn_parlay_ticket_structure_v3_core(
    v_sanitized,p_decision,p_stake,p_bankroll_snapshot,p_bonus,p_window_days);

  -- Patch leg-level identity status/reason back into the public result.
  for rec in select value as c from jsonb_array_elements(v_conflicts) loop
    idx := (rec.c->>'leg_no')::int - 1;
    if idx>=0 and jsonb_array_length(coalesce(v_result->'legs','[]'::jsonb))>idx then
      v_result := jsonb_set(v_result,array['legs',idx::text],
        (v_result->'legs'->idx) || jsonb_build_object(
          'identity_status','IDENTITY_CONFLICT','identity_reason',rec.c->>'reason',
          'canonical_event_id',null,'leg_valid',false),true);
    end if;
  end loop;

  if jsonb_array_length(v_conflicts)>0 then
    v_result := v_result || jsonb_build_object(
      'status','NEEDS_REVIEW','is_canonical_reto13m',false,
      'is_canonical_reason','IDENTITY_CONFLICT','identity_conflicts',v_conflicts,
      'joint_probability',null,'EV_REAL',null,'payout',null);
  else
    v_result := v_result || jsonb_build_object('identity_conflicts','[]'::jsonb);
  end if;

  if jsonb_array_length(v_bad_prices)>0 then
    v_result := v_result || jsonb_build_object(
      'status','NEEDS_REVIEW','is_canonical_reto13m',false,
      'is_canonical_reason','INVALID_TICKET_PRICE','ticket_price_status','INVALID_TICKET_PRICE',
      'ticket_total_odds',null,'payout',null,'invalid_price_details',v_bad_prices,
      'joint_probability',null,'EV_REAL',null);
  else
    v_result := v_result || jsonb_build_object('invalid_price_details','[]'::jsonb);
  end if;

  return v_result;
end
$fn$;

comment on function v2.fn_parlay_ticket_structure(jsonb,timestamptz,numeric,numeric,numeric,int) is
  'iss052 v4 public scanner contract: verifies explicit/provider identity against teams/date; invalid decimal odds fail-close before core; correlation/joint/EV discipline inherited from v3 core.';
