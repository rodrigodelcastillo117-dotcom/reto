-- ISS139 — World-class canonical Parlay Engine V2
-- ADDITIVE ONLY. Does not replace or mutate legacy parlay functions/tables.
-- Canonical legs come only from RETO Brain-authorized Pick Story surfaces.
-- Market odds are diagnostic/economic context and NEVER create P_RETO.
-- Same-event multi-leg parlays fail closed until those secondary markets are independently release-authorized.

create or replace view public.v_reto_parlay_candidate_pool_v2 as
select
  c.espn_event_id,
  'soccer'::text as sport,
  c.competition_id,
  c.competition_name,
  c.home_team,
  c.away_team,
  c.kickoff,
  c.canonical_market as market,
  c.canonical_pick as pick,
  c.selected_side,
  c.p_reto_pct,
  c.confidence_band,
  c.separation_pp,
  c.model_version,
  c.feature_version,
  c.selector_version,
  c.prediction_time,
  c.data_asof,
  c.scientific_ready,
  c.product_release_authorized,
  c.money_authorized,
  c.market_novig_pct,
  c.discrepancy_vs_market_pp,
  c.odds_bookmaker,
  c.odds_captured_at,
  case c.selected_side
    when 'HOME' then f.odds_home
    when 'DRAW' then f.odds_draw
    when 'AWAY' then f.odds_away
  end::numeric as selected_decimal_odds,
  c.change_vs_24h_pp,
  c.live_status,
  c.live_n,
  c.authority_reason,
  c.canonical_pick_version,
  true::boolean as canonical_leg
from public.v_reto_pick_story_cards_v1 c
join public.v_futpro_publication_v3 f
  on f.canonical_event_id=c.espn_event_id
 and f.canonical_pick_version=c.canonical_pick_version
where c.scientific_ready
  and c.product_release_authorized
  and c.temporal_safe
  and c.kickoff>now();

comment on view public.v_reto_parlay_candidate_pool_v2 is
'Additive Parlay V2 candidate pool. Legs are canonical product-authorized P_RETO only. No market-derived probability may enter.';

grant select on public.v_reto_parlay_candidate_pool_v2 to anon,authenticated;

create or replace function public.reto_parlay_lab_v2(
  p_legs jsonb,
  p_scenarios integer default 100000
)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  v_requested int;
  v_resolved int;
  v_duplicate_events int;
  v_joint numeric;
  v_book_total numeric;
  v_book_implied numeric;
  v_ev numeric;
  v_same_book boolean;
  v_all_money boolean;
  v_all_odds boolean;
  v_bookmaker text;
  v_legs jsonb;
  v_risk jsonb;
  v_riskiest jsonb;
  v_expected_survivors bigint;
  v_status text;
  v_money_status text;
begin
  if p_legs is null or jsonb_typeof(p_legs)<>'array' then
    return jsonb_build_object('ok',false,'status','INVALID_INPUT','reason','legs debe ser un arreglo JSON');
  end if;
  v_requested := jsonb_array_length(p_legs);
  if v_requested<2 or v_requested>8 then
    return jsonb_build_object('ok',false,'status','INVALID_LEG_COUNT','requested_legs',v_requested,'min',2,'max',8);
  end if;
  if p_scenarios<1000 or p_scenarios>1000000 then
    return jsonb_build_object('ok',false,'status','INVALID_SCENARIOS','min',1000,'max',1000000);
  end if;

  with req as (
    select ord::int,
           x->>'espn_event_id' as espn_event_id,
           nullif(x->>'market','') as requested_market,
           nullif(x->>'pick','') as requested_pick
    from jsonb_array_elements(p_legs) with ordinality q(x,ord)
  ), resolved as (
    select r.ord,r.requested_market,r.requested_pick,c.*
    from req r
    join public.v_reto_parlay_candidate_pool_v2 c using(espn_event_id)
    where (r.requested_market is null or r.requested_market=c.market)
      and (r.requested_pick is null or r.requested_pick=c.pick)
  )
  select count(*)::int,
         count(*)-count(distinct espn_event_id),
         exp(sum(ln(greatest(p_reto_pct/100.0,0.000001)))),
         bool_and(money_authorized),
         bool_and(selected_decimal_odds is not null and selected_decimal_odds>1),
         (count(distinct odds_bookmaker)=1 and count(odds_bookmaker)=count(*)),
         min(odds_bookmaker),
         case when bool_and(selected_decimal_odds is not null and selected_decimal_odds>1)
              then exp(sum(ln(selected_decimal_odds))) end,
         jsonb_agg(jsonb_build_object(
           'espn_event_id',espn_event_id,'sport',sport,'competition_id',competition_id,'competition_name',competition_name,
           'home_team',home_team,'away_team',away_team,'kickoff',kickoff,'market',market,'pick',pick,
           'p_reto_pct',p_reto_pct,'confidence_band',confidence_band,'separation_pp',separation_pp,
           'model_version',model_version,'prediction_time',prediction_time,'money_authorized',money_authorized,
           'bookmaker',odds_bookmaker,'selected_decimal_odds',selected_decimal_odds,
           'market_novig_pct',market_novig_pct,'discrepancy_vs_market_pp',discrepancy_vs_market_pp,
           'canonical_leg',canonical_leg
         ) order by ord)
    into v_resolved,v_duplicate_events,v_joint,v_all_money,v_all_odds,v_same_book,v_bookmaker,v_book_total,v_legs
  from resolved;

  if v_resolved<>v_requested then
    return jsonb_build_object(
      'ok',false,'status','NON_CANONICAL_OR_UNAVAILABLE_LEG',
      'requested_legs',v_requested,'resolved_canonical_legs',v_resolved,
      'reason','Cada pata debe resolver exactamente a un pick canónico actualmente autorizado por RETO Brain.');
  end if;
  if v_duplicate_events>0 then
    return jsonb_build_object(
      'ok',false,'status','SAME_EVENT_MULTI_LEG_BLOCKED',
      'reason','Parlay V2 no permite dos patas del mismo evento hasta que same-game correlation y mercados secundarios estén certificados.');
  end if;

  select jsonb_agg(jsonb_build_object(
           'espn_event_id',x->>'espn_event_id',
           'pick',x->>'pick',
           'p_reto_pct',(x->>'p_reto_pct')::numeric,
           'failure_probability_pct',round((100-(x->>'p_reto_pct')::numeric),2),
           'risk_share_pct',round(100*(100-(x->>'p_reto_pct')::numeric)
             /nullif(sum(100-(x->>'p_reto_pct')::numeric) over(),0),2)
         ) order by (x->>'p_reto_pct')::numeric asc),
         (jsonb_agg(jsonb_build_object(
           'espn_event_id',x->>'espn_event_id','pick',x->>'pick','p_reto_pct',(x->>'p_reto_pct')::numeric
         ) order by (x->>'p_reto_pct')::numeric asc))->0
    into v_risk,v_riskiest
  from jsonb_array_elements(v_legs) x;

  v_expected_survivors := round(v_joint*p_scenarios);
  if v_all_money and v_all_odds and v_same_book then
    v_book_implied := 100/nullif(v_book_total,0);
    v_ev := 100*(v_joint*v_book_total-1);
    v_money_status := 'AUTHORIZED';
  else
    v_book_implied := case when v_all_odds and v_same_book then 100/nullif(v_book_total,0) end;
    v_ev := null;
    v_money_status := 'BLOCKED';
  end if;

  v_status := case when v_all_money then 'READY_WITH_MONEY_AUTHORITY' else 'PREDICTION_ONLY' end;

  return jsonb_build_object(
    'ok',true,'status',v_status,'contract_version','parlay_lab_v2',
    'legs_count',v_requested,'legs',v_legs,
    'probability',jsonb_build_object(
      'joint_independence_estimate_pct',round(100*v_joint,2),
      'dependence_model','DISTINCT_EVENTS_INDEPENDENCE_V1',
      'dependence_status','UNMEASURED_CROSS_EVENT',
      'same_event_multi_leg_allowed',false,
      'note','No se afirma correlación cero: la dependencia entre eventos distintos aún no está certificada. El valor mostrado es la estimación bajo independencia.'),
    'scenario_equivalent',jsonb_build_object(
      'scenarios',p_scenarios,'expected_survivors',v_expected_survivors,
      'expected_survival_pct',round(100*v_joint,2),
      'method','ANALYTIC_EXPECTATION_NOT_RANDOM_MONTE_CARLO'),
    'risk',jsonb_build_object('riskiest_leg',v_riskiest,'leg_risk_breakdown',v_risk),
    'market_context',jsonb_build_object(
      'same_bookmaker',v_same_book,'bookmaker',case when v_same_book then v_bookmaker end,
      'all_decimal_odds_available',v_all_odds,
      'combined_decimal_odds',case when v_all_odds and v_same_book then round(v_book_total,4) end,
      'combined_implied_pct',case when v_all_odds and v_same_book then round(v_book_implied,2) end,
      'role','DIAGNOSTIC_ECONOMIC_ONLY'),
    'economics',jsonb_build_object(
      'money_status',v_money_status,
      'ev_pct',case when v_money_status='AUTHORIZED' then round(v_ev,2) end,
      'reason',case when v_money_status='AUTHORIZED' then 'Todas las patas tienen autoridad económica.'
                    else 'EV bloqueado: al menos una pata no tiene money_authorized=true o no existe precio coherente de una sola casa.' end),
    'principles',jsonb_build_object(
      'canonical_legs_only',true,'market_can_create_probability',false,'unknown_dependence_is_invented',false,'legacy_parlay_mutated',false));
end $$;

grant execute on function public.reto_parlay_lab_v2(jsonb,integer) to anon,authenticated;

create or replace function public.reto_parlay_generate_v2(
  p_profile text default 'EQUILIBRADO',
  p_horizon_hours integer default 192,
  p_scenarios integer default 100000
)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  v_profile text := upper(trim(coalesce(p_profile,'EQUILIBRADO')));
  v_target int;
  v_min_p numeric;
  v_min_sep numeric;
  v_allowed_conf text[];
  v_legs jsonb;
  v_n int;
  v_lab jsonb;
begin
  if v_profile='CONSERVADOR' then
    v_target:=2; v_min_p:=70; v_min_sep:=45; v_allowed_conf:=array['ALTA'];
  elsif v_profile='EQUILIBRADO' then
    v_target:=3; v_min_p:=64; v_min_sep:=38; v_allowed_conf:=array['ALTA','MEDIA'];
  elsif v_profile='AGRESIVO' then
    v_target:=4; v_min_p:=58; v_min_sep:=28; v_allowed_conf:=array['ALTA','MEDIA','CAUTELOSA'];
  else
    return jsonb_build_object('ok',false,'status','INVALID_PROFILE','allowed',jsonb_build_array('CONSERVADOR','EQUILIBRADO','AGRESIVO'));
  end if;
  if p_horizon_hours<1 or p_horizon_hours>336 then
    return jsonb_build_object('ok',false,'status','INVALID_HORIZON','min_hours',1,'max_hours',336);
  end if;

  with eligible as (
    select c.*,
           row_number() over(partition by c.competition_id order by c.p_reto_pct desc,c.separation_pp desc,c.kickoff,c.espn_event_id) league_rn
    from public.v_reto_parlay_candidate_pool_v2 c
    where c.kickoff<=now()+make_interval(hours=>p_horizon_hours)
      and c.p_reto_pct>=v_min_p
      and c.separation_pp>=v_min_sep
      and c.confidence_band=any(v_allowed_conf)
  ), chosen as (
    select * from eligible where league_rn=1
    order by p_reto_pct desc,separation_pp desc,kickoff,espn_event_id
    limit v_target
  )
  select count(*)::int,
         coalesce(jsonb_agg(jsonb_build_object('espn_event_id',espn_event_id,'market',market,'pick',pick)
           order by p_reto_pct desc,separation_pp desc,kickoff,espn_event_id),'[]'::jsonb)
    into v_n,v_legs
  from chosen;

  if v_n<v_target then
    return jsonb_build_object(
      'ok',true,'status','NO_QUALITY_PARLAY','profile',v_profile,
      'target_legs',v_target,'eligible_diversified_legs',v_n,'legs',v_legs,
      'thresholds',jsonb_build_object('min_p_reto_pct',v_min_p,'min_separation_pp',v_min_sep,'allowed_confidence',v_allowed_conf),
      'reason','RETO prefiere no fabricar un parlay cuando faltan patas canónicas que cumplan el perfil.');
  end if;

  v_lab:=public.reto_parlay_lab_v2(v_legs,p_scenarios);
  return jsonb_build_object(
    'ok',coalesce((v_lab->>'ok')::boolean,false),
    'status',v_lab->>'status','profile',v_profile,
    'profile_contract',case v_profile
      when 'CONSERVADOR' then '2 patas · P_RETO>=70 · confianza ALTA · una por competición'
      when 'EQUILIBRADO' then '3 patas · P_RETO>=64 · confianza ALTA/MEDIA · una por competición'
      else '4 patas · P_RETO>=58 · una por competición; más varianza, misma autoridad científica' end,
    'selection_role','P_RETO_AND_MODEL_SEPARATION_ONLY',
    'market_used_for_selection',false,
    'sport_coverage','SOCCER_1X2_ONLY_UNTIL_OTHER_SPORTS_GAIN_PRODUCT_RELEASE_AUTHORITY',
    'lab',v_lab);
end $$;

grant execute on function public.reto_parlay_generate_v2(text,integer,integer) to anon,authenticated;

create or replace view public.v_reto_parlay_v2_invariant_leaks as
select espn_event_id,'NON_CANONICAL'::text leak
from public.v_reto_parlay_candidate_pool_v2 where not canonical_leg
union all
select espn_event_id,'AUTHORITY_MISMATCH'
from public.v_reto_parlay_candidate_pool_v2 where not scientific_ready or not product_release_authorized
union all
select espn_event_id,'TEMPORAL_OR_KICKOFF_INVALID'
from public.v_reto_parlay_candidate_pool_v2 where data_asof>prediction_time or prediction_time>=kickoff or kickoff<=now();

grant select on public.v_reto_parlay_v2_invariant_leaks to authenticated;
