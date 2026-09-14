-- ISS139d — Parlay Lab V2 over lightweight canonical pool. ADDITIVE ONLY.
create or replace function public.reto_parlay_lab_v2(p_legs jsonb,p_scenarios integer default 100000)
returns jsonb language plpgsql stable security definer set search_path='public','v2','pg_temp' as $$
declare
  v_requested int; v_resolved int; v_duplicate_events int; v_joint numeric; v_book_total numeric;
  v_book_implied numeric; v_ev numeric; v_same_book boolean; v_all_money boolean; v_all_odds boolean;
  v_bookmaker text; v_legs jsonb; v_risk jsonb; v_riskiest jsonb; v_expected_survivors bigint;
  v_status text; v_money_status text;
begin
  if p_legs is null or jsonb_typeof(p_legs)<>'array' then return jsonb_build_object('ok',false,'status','INVALID_INPUT'); end if;
  v_requested:=jsonb_array_length(p_legs);
  if v_requested<2 or v_requested>8 then return jsonb_build_object('ok',false,'status','INVALID_LEG_COUNT','requested_legs',v_requested); end if;
  if p_scenarios<1000 or p_scenarios>1000000 then return jsonb_build_object('ok',false,'status','INVALID_SCENARIOS'); end if;

  with req as (
    select ord::int,x->>'espn_event_id' espn_event_id,nullif(x->>'market','') requested_market,nullif(x->>'pick','') requested_pick
    from jsonb_array_elements(p_legs) with ordinality q(x,ord)
  ), resolved as (
    select r.ord,c.* from req r join public.v_reto_parlay_candidate_pool_v2_fast c using(espn_event_id)
    where (r.requested_market is null or r.requested_market=c.market) and (r.requested_pick is null or r.requested_pick=c.pick)
  )
  select count(*)::int,count(*)-count(distinct espn_event_id),exp(sum(ln(greatest(p_reto_pct/100.0,0.000001)))),
    bool_and(money_authorized),bool_and(selected_decimal_odds is not null and selected_decimal_odds>1),
    (count(distinct odds_bookmaker)=1 and count(odds_bookmaker)=count(*)),min(odds_bookmaker),
    case when bool_and(selected_decimal_odds is not null and selected_decimal_odds>1) then exp(sum(ln(selected_decimal_odds))) end,
    jsonb_agg(jsonb_build_object('espn_event_id',espn_event_id,'sport',sport,'competition',competition_name,
      'home_team',home_team,'away_team',away_team,'kickoff',kickoff,'market',market,'pick',pick,'p_reto_pct',p_reto_pct,
      'confidence_band',confidence_band,'separation_pp',separation_pp,'model_version',model_version,'money_authorized',money_authorized,
      'bookmaker',odds_bookmaker,'selected_decimal_odds',selected_decimal_odds,'book_implied_raw_pct',book_implied_raw_pct,
      'discrepancy_vs_book_raw_pp',discrepancy_vs_book_raw_pp,'canonical_leg',canonical_leg) order by ord)
  into v_resolved,v_duplicate_events,v_joint,v_all_money,v_all_odds,v_same_book,v_bookmaker,v_book_total,v_legs
  from resolved;

  if v_resolved<>v_requested then return jsonb_build_object('ok',false,'status','NON_CANONICAL_OR_UNAVAILABLE_LEG','requested_legs',v_requested,'resolved_canonical_legs',v_resolved); end if;
  if v_duplicate_events>0 then return jsonb_build_object('ok',false,'status','SAME_EVENT_MULTI_LEG_BLOCKED','reason','Same-event multi-leg permanece cerrado hasta certificar mercados secundarios y dependencia.'); end if;

  with rr as (
    select x,(x->>'p_reto_pct')::numeric p,sum(100-(x->>'p_reto_pct')::numeric) over() total_failure from jsonb_array_elements(v_legs) x
  )
  select jsonb_agg(jsonb_build_object('espn_event_id',x->>'espn_event_id','pick',x->>'pick','p_reto_pct',p,
      'failure_probability_pct',round(100-p,2),'risk_share_pct',round(100*(100-p)/nullif(total_failure,0),2)) order by p asc),
    (jsonb_agg(jsonb_build_object('espn_event_id',x->>'espn_event_id','pick',x->>'pick','p_reto_pct',p) order by p asc))->0
  into v_risk,v_riskiest from rr;

  v_expected_survivors:=round(v_joint*p_scenarios);
  if v_all_money and v_all_odds and v_same_book then
    v_book_implied:=100/nullif(v_book_total,0); v_ev:=100*(v_joint*v_book_total-1); v_money_status:='AUTHORIZED';
  else
    v_book_implied:=case when v_all_odds and v_same_book then 100/nullif(v_book_total,0) end; v_ev:=null; v_money_status:='BLOCKED';
  end if;
  v_status:=case when v_all_money then 'READY_WITH_MONEY_AUTHORITY' else 'PREDICTION_ONLY' end;

  return jsonb_build_object('ok',true,'status',v_status,'contract_version','parlay_lab_v2','legs_count',v_requested,'legs',v_legs,
    'probability',jsonb_build_object('joint_independence_estimate_pct',round(100*v_joint,2),'dependence_model','DISTINCT_EVENTS_INDEPENDENCE_V1',
      'dependence_status','UNMEASURED_CROSS_EVENT','same_event_multi_leg_allowed',false,
      'note','No se afirma correlación cero; se muestra la estimación bajo independencia entre eventos distintos.'),
    'scenario_equivalent',jsonb_build_object('scenarios',p_scenarios,'expected_survivors',v_expected_survivors,'expected_survival_pct',round(100*v_joint,2),'method','ANALYTIC_EXPECTATION_NOT_RANDOM_MONTE_CARLO'),
    'risk',jsonb_build_object('riskiest_leg',v_riskiest,'leg_risk_breakdown',v_risk),
    'market_context',jsonb_build_object('same_bookmaker',v_same_book,'bookmaker',case when v_same_book then v_bookmaker end,
      'all_decimal_odds_available',v_all_odds,'combined_decimal_odds',case when v_all_odds and v_same_book then round(v_book_total,4) end,
      'combined_implied_raw_pct',case when v_all_odds and v_same_book then round(v_book_implied,2) end,'role','DIAGNOSTIC_ECONOMIC_ONLY','note','Implied raw no es no-vig y nunca sustituye P_RETO.'),
    'economics',jsonb_build_object('money_status',v_money_status,'ev_pct',case when v_money_status='AUTHORIZED' then round(v_ev,2) end,
      'reason',case when v_money_status='AUTHORIZED' then 'Todas las patas tienen autoridad económica.' else 'EV bloqueado: money gate canónico no abierto para todas las patas.' end),
    'principles',jsonb_build_object('canonical_legs_only',true,'market_can_create_probability',false,'unknown_dependence_is_invented',false,'legacy_parlay_mutated',false));
end $$;

grant execute on function public.reto_parlay_lab_v2(jsonb,integer) to anon,authenticated;