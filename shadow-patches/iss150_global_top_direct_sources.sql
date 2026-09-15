-- ISS150 — Global TOP_ONLY V2 direct canonical sources
-- Removes the remaining indirection through legacy ranking views.
-- Selection inputs: official P_RETO only, after product/scientific authority.
-- Market/odds never participate in ranking. Research rows are ineligible.

create or replace view public.v_reto13m_global_candidate_v2 as
with official_union as (
  select
    s.canonical_event_id::text as espn_event_id,
    'soccer'::text as sport,
    s.competition_name::text as league_name,
    s.kickoff,
    s.home_team,
    s.away_team,
    'Moneyline'::text as market,
    s.canonical_pick::text as selection_label,
    s.canonical_pick_prob::numeric as p_reto_pct,
    s.model_version::text,
    s.calibration_status::text as validation_status,
    'futpro_terminal_v2'::text as analysis_contract,
    'v_futpro_publication_v3'::text as source_contract,
    s.canonical_pick_status::text as source_pick_status,
    s.selector_authoritative as source_selector_authoritative,
    (s.canonical_pick_status='READY' and s.selector_authoritative and s.calibration_status='OOS_VALIDATED' and s.temporal_safe is true)::boolean as source_product_authorized,
    case when s.canonical_pick_prob is not null and s.p_reto_home is not null and s.p_reto_draw is not null and s.p_reto_away is not null
      then round(s.canonical_pick_prob - ((s.p_reto_home+s.p_reto_draw+s.p_reto_away) - greatest(s.p_reto_home,s.p_reto_draw,s.p_reto_away) - least(s.p_reto_home,s.p_reto_draw,s.p_reto_away)),2)
      else null end::numeric as model_separation_pp
  from public.v_futpro_publication_v3 s
  where s.kickoff > now()
    and s.kickoff < now()+interval '48 hours'
    and s.canonical_pick_status='READY'
    and s.selector_authoritative=true
    and s.canonical_pick is not null
    and s.canonical_pick_prob is not null

  union all

  select
    t.espn_event_id::text,
    t.sport::text,
    t.league_name::text,
    t.kickoff,
    t.home_name::text,
    t.away_name::text,
    'Moneyline'::text,
    t.canonical_pick::text,
    t.canonical_probability_pct::numeric,
    t.model_version::text,
    t.validation_status::text,
    'team_elo_event_context_v1'::text,
    'v_team_sports_publication_v1'::text,
    t.canonical_pick_status::text,
    t.selector_authoritative,
    (t.canonical_pick_status='READY' and t.selector_authoritative)::boolean,
    case when t.p_home_pct is not null and t.p_away_pct is not null then round(abs(t.p_home_pct-t.p_away_pct),2) else null end::numeric
  from public.v_team_sports_publication_v1 t
  where t.kickoff > now()
    and t.kickoff < now()+interval '48 hours'
    and t.canonical_pick_status='READY'
    and t.selector_authoritative=true
    and t.canonical_pick is not null
    and t.canonical_probability_pct is not null
), with_counts as (
  select u.*, count(*) over(partition by u.espn_event_id) as source_event_rows
  from official_union u
)
select
  espn_event_id,sport,league_name,kickoff,home_team,away_team,market,selection_label,p_reto_pct,
  model_version,validation_status,analysis_contract,source_contract,source_pick_status,
  source_selector_authoritative,source_product_authorized,source_event_rows,
  (kickoff at time zone 'America/Mexico_City')::date as dia_mx,
  'OFFICIAL_P_RETO'::text as display_class,
  false as money_authorized,
  model_separation_pp
from with_counts;

create or replace view public.v_reto13m_global_top_v2 as
with eligible as (
  select * from public.v_reto13m_global_candidate_v2
  where source_event_rows=1
    and source_pick_status='READY'
    and source_selector_authoritative=true
    and source_product_authorized=true
    and p_reto_pct between 0 and 100
), ranked as (
  select e.*,
    row_number() over(order by e.p_reto_pct desc,e.kickoff,e.espn_event_id) as rank_global,
    row_number() over(partition by e.dia_mx order by e.p_reto_pct desc,e.kickoff,e.espn_event_id) as rank_dia
  from eligible e
)
select
  espn_event_id,sport,league_name,kickoff,dia_mx,home_team,away_team,market,selection_label,p_reto_pct,
  model_version,validation_status,analysis_contract,source_contract,display_class,rank_global,rank_dia,
  rank_global=1 as is_global_top_1,
  rank_dia=1 as is_day_top_1,
  true as product_authorized,
  false as money_authorized,
  true as top_only_authoritative,
  'P_RETO_ARGMAX_GLOBAL_V1'::text as rank_policy_version,
  'FROZEN'::text as rank_policy_status,
  jsonb_build_object(
    'source_contract',source_contract,
    'source_pick_status',source_pick_status,
    'source_selector_authoritative',source_selector_authoritative,
    'source_product_authorized',source_product_authorized,
    'source_event_rows',source_event_rows,
    'global_rank_policy','P_RETO_ARGMAX_GLOBAL_V1',
    'rank_inputs','P_RETO_ONLY_AFTER_PRODUCT_AUTHORITY',
    'market_used_for_ranking',false,
    'research_rows_eligible',false,
    'model_separation_used_for_ranking',false
  ) as provenance,
  model_separation_pp
from ranked;
