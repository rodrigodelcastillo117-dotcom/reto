-- ISS144 — Lo Mejor Editorial V2 + Trust Center V1
-- ADDITIVE ONLY. Every editorial card is a reading of canonical contracts, never a new prediction brain.

create or replace function public.reto_lo_mejor_editorial_v2(p_apodo text default null,p_horizon_hours integer default 72)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  v_top jsonb; v_safe jsonb; v_disagree jsonb; v_avoid jsonb; v_upset jsonb; v_parlay jsonb; v_fantasy jsonb; v_coverage jsonb;
begin
  if p_horizon_hours<1 or p_horizon_hours>336 then
    return jsonb_build_object('ok',false,'status','INVALID_HORIZON');
  end if;

  select to_jsonb(x) into v_top from (
    select espn_event_id,deporte,liga,home,away,arranca_en,mercado,pick_desc,probabilidad_pct,model_version,
      discriminacion_pp,canonical_pick_status,selector_authoritative,top_only_authoritative,rank_policy_status
    from public.v_reto13m_lo_mejor
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours)
      and es_validado and selector_authoritative and top_only_authoritative and rank_policy_status='FROZEN'
    order by rank_global nulls last,rn_deporte,probabilidad_pct desc limit 1
  ) x;

  select to_jsonb(x) into v_safe from (
    select espn_event_id,competition_name,home_team,away_team,kickoff,canonical_pick,p_reto_pct,confidence_band,separation_pp,model_version
    from public.v_reto_pick_story_cards_v1
    where kickoff>=now() and kickoff<=now()+make_interval(hours=>p_horizon_hours)
    order by p_reto_pct desc,separation_pp desc,kickoff limit 1
  ) x;

  select to_jsonb(x) into v_disagree from (
    select espn_event_id,competition_name,home_team,away_team,kickoff,canonical_pick,p_reto_pct,market_novig_pct,
      discrepancy_vs_market_pp,market_disagreement_direction,odds_bookmaker
    from public.v_reto_pick_story_cards_v1
    where kickoff>=now() and kickoff<=now()+make_interval(hours=>p_horizon_hours) and market_novig_pct is not null
    order by abs(discrepancy_vs_market_pp) desc,kickoff limit 1
  ) x;

  select to_jsonb(x) into v_avoid from (
    select espn_event_id,competition_name,home_team,away_team,kickoff,canonical_pick,p_reto_pct,confidence_band,separation_pp,
      discrepancy_vs_market_pp,live_status,
      case when confidence_band='CAUTELOSA' then 'CONFIANZA_CAUTEL0SA'
           when abs(coalesce(discrepancy_vs_market_pp,0))>=12 then 'FUERTE_DESACUERDO_CON_MERCADO'
           when live_status is not null and live_status<>'PREDICTION_GATE_PASS' then 'MONITOREO_LIVE_AUN_NO_CONCLUYENTE'
           else 'MAYOR_CAUTELA_RELATIVA' end reason
    from public.v_reto_pick_story_cards_v1
    where kickoff>=now() and kickoff<=now()+make_interval(hours=>p_horizon_hours)
    order by (confidence_band='CAUTELOSA') desc,abs(coalesce(discrepancy_vs_market_pp,0)) desc,separation_pp asc,kickoff limit 1
  ) x;

  select to_jsonb(x) into v_upset from (
    select c.espn_event_id,c.competition_name,c.home_team,c.away_team,c.kickoff,c.canonical_pick,c.p_reto_pct,c.selected_side,
      case when f.odds_home<=f.odds_draw and f.odds_home<=f.odds_away then 'HOME'
           when f.odds_draw<=f.odds_home and f.odds_draw<=f.odds_away then 'DRAW' else 'AWAY' end market_favorite_side,
      c.market_novig_pct,c.discrepancy_vs_market_pp
    from public.v_reto_pick_story_cards_v1 c
    join public.v_futpro_publication_v3 f on f.canonical_event_id=c.espn_event_id
    where c.kickoff>=now() and c.kickoff<=now()+make_interval(hours=>p_horizon_hours)
      and f.odds_home>1 and f.odds_draw>1 and f.odds_away>1 and c.p_reto_pct>=40
      and c.selected_side<>case when f.odds_home<=f.odds_draw and f.odds_home<=f.odds_away then 'HOME'
           when f.odds_draw<=f.odds_home and f.odds_draw<=f.odds_away then 'DRAW' else 'AWAY' end
    order by c.p_reto_pct desc,c.separation_pp desc,c.kickoff limit 1
  ) x;

  v_parlay:=public.reto_parlay_generate_v2('CONSERVADOR',least(p_horizon_hours,192),100000);

  if p_apodo is null then
    v_fantasy:=jsonb_build_object('status','NOT_PERSONALIZED','reason','Se necesita apodo/roster para mostrar el movimiento Fantasy de la semana.');
  else
    select jsonb_build_object('status','READY','season',s.season,'week',s.week,'decision_time',s.decision_time,'model_version',s.model_version,
      'move',m.value,'recommendation_id',s.recommendation_id)
    into v_fantasy
    from v2.fantasy_recommendation_snapshot_v3 s
    cross join lateral jsonb_array_elements(s.changes) m(value)
    where s.apodo=p_apodo and jsonb_array_length(s.changes)>0
    order by s.season desc,s.week desc,s.decision_time desc,coalesce((m.value->>'ganancia')::numeric,-999) desc limit 1;
    if v_fantasy is null then v_fantasy:=jsonb_build_object('status','NO_RECOMMENDED_MOVE_YET'); end if;
  end if;

  select jsonb_agg(jsonb_build_object('sport',sport,'product_ready_scopes',ready,'blocked_scopes',blocked) order by sport)
  into v_coverage from (
    select sport,count(*) filter(where product_release_authorized) ready,count(*) filter(where not product_release_authorized) blocked
    from public.v_reto_brain_release_authority_v1 group by sport
  ) z;

  return jsonb_build_object(
    'ok',true,'status','READY','contract_version','reto_lo_mejor_editorial_v2','generated_at',now(),
    'top_opportunity',coalesce(v_top,jsonb_build_object('status','NONE_IN_WINDOW')),
    'safest_by_p_reto',coalesce(v_safe,jsonb_build_object('status','NONE_IN_WINDOW')),
    'biggest_model_market_disagreement',coalesce(v_disagree,jsonb_build_object('status','NO_MARKET_COMPARISON')),
    'avoid_or_caution',coalesce(v_avoid,jsonb_build_object('status','NONE_IN_WINDOW')),
    'upset_watch',coalesce(v_upset,jsonb_build_object('status','NONE_QUALIFIED')),
    'reto_parlay',v_parlay,
    'fantasy_move_of_week',v_fantasy,
    'coverage',v_coverage,
    'labels',jsonb_build_object('biggest_disagreement','No significa edge ni EV. Sólo mide cuánto difieren RETO y mercado.',
      'avoid','No revoca un pick oficial; señala el evento que merece mayor cautela relativa.'),
    'principles',jsonb_build_object('one_brain',true,'editorial_creates_probability',false,'market_creates_pick',false));
end $$;

grant execute on function public.reto_lo_mejor_editorial_v2(text,integer) to anon,authenticated;

create or replace view public.v_reto_trust_center_v1 as
select sport,league_scope,market,model_version,scientific_ready,product_release_authorized,money_authorized,
  release_status,validation_status,live_status,live_n,live_market_n,live_brier_model,live_brier_naive,live_brier_reference,
  live_vs_naive_upper95,live_vs_market_upper95,live_calibration_gap_pp,live_accuracy_pct,live_avg_confidence_pct,
  market_coverage_pct,reason,evidence,updated_at
from public.v_reto_brain_scorecard_v1;

grant select on public.v_reto_trust_center_v1 to anon,authenticated;

create or replace function public.reto_trust_center_summary_v1(p_days integer default 7,p_error_limit integer default 20)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare cards jsonb; errs jsonb; sums jsonb;
begin
  if p_days<1 or p_days>365 or p_error_limit<1 or p_error_limit>100 then
    return jsonb_build_object('ok',false,'status','INVALID_ARGUMENT');
  end if;
  select jsonb_build_object('scopes',count(*),'scientific_ready',count(*) filter(where scientific_ready),
    'product_authorized',count(*) filter(where product_release_authorized),'money_authorized',count(*) filter(where money_authorized),
    'blocked_or_rejected',count(*) filter(where not product_release_authorized)) into sums
  from public.v_reto_trust_center_v1;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sport,x.league_scope,x.market,x.model_version),'[]'::jsonb) into cards
  from public.v_reto_trust_center_v1 x;

  with latest as (
    select distinct on(espn_event_id,sport,market,model_version)
      espn_event_id,sport,league,market,model_version,kickoff,home_team,away_team,
      p1_label,p2_label,p3_label,p1,p2,p3,outcome_idx,score_home,score_away,brier_model,logloss_model,
      leader_correct,graded_observation_at,release_status,validation_status,authority_reason
    from public.v_reto_brain_event_audit_v1
    where product_release_authorized and graded_observation_at is not null
      and kickoff>=now()-make_interval(days=>p_days)
    order by espn_event_id,sport,market,model_version,snapshot_at desc
  ), wrong as (
    select *,case when p1>=coalesce(p2,-1) and p1>=coalesce(p3,-1) then p1_label
                  when p2>=coalesce(p1,-1) and p2>=coalesce(p3,-1) then p2_label else p3_label end predicted_label,
      case outcome_idx when 1 then p1_label when 2 then p2_label when 3 then p3_label end actual_label
    from latest where leader_correct=false
    order by kickoff desc limit p_error_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'espn_event_id',espn_event_id,'sport',sport,'league',league,'market',market,'model_version',model_version,'kickoff',kickoff,
    'home_team',home_team,'away_team',away_team,'predicted',predicted_label,'actual',actual_label,'score',jsonb_build_object('home',score_home,'away',score_away),
    'brier',brier_model,'logloss',logloss_model,'release_status',release_status,'validation_status',validation_status,
    'what_reto_says','La predicción pregame quedó congelada y falló. Se conserva públicamente; no se reescribe después del resultado.'
  ) order by kickoff desc),'[]'::jsonb) into errs from wrong;

  return jsonb_build_object('ok',true,'status','READY','contract_version','reto_trust_center_summary_v1','window_days',p_days,
    'summary',sums,'model_scorecards',cards,'recent_mistakes',errs,
    'principles',jsonb_build_object('losses_hidden',false,'historical_predictions_rewritten',false,'sample_size_visible',true,
      'brier_visible',true,'calibration_visible',true,'money_authority_separate',true));
end $$;

grant execute on function public.reto_trust_center_summary_v1(integer,integer) to anon,authenticated;

create or replace view public.v_reto_editorial_v2_invariant_leaks as
select c.espn_event_id,'EDITORIAL_NON_AUTHORITATIVE_PICK'::text leak
from public.v_reto_pick_story_cards_v1 c
where not c.scientific_ready or not c.product_release_authorized
union all
select espn_event_id,'EDITORIAL_TEMPORAL_UNSAFE'
from public.v_reto_pick_story_cards_v1 where not temporal_safe or prediction_time>=kickoff;

grant select on public.v_reto_editorial_v2_invariant_leaks to authenticated;
