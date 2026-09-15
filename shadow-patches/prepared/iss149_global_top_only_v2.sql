-- ISS149 — GLOBAL TOP_ONLY V2
-- ONE BRAIN / ONE P_RETO: central cross-sport ranking over OFFICIAL, product-authorized event picks only.
-- Research/challenger rows never enter this selector. Market/no-vig/EV/Kelly never rank or alter P_RETO.
-- Fixed discovery horizon: next 48 hours. Ranking is global across sports, never one-per-sport.
-- Policy V1 is intentionally conservative and auditable: P_RETO DESC after strict publication gates,
-- deterministic tie-break by kickoff/event_id. No empirically-unproven composite weights.

create or replace view public.v_reto13m_global_candidate_v2 as
with official_union as (
  -- Soccer event selection is already canonical in v_futpro_publication_v3. We use the
  -- lightweight projection v_reto13m_lo_mejor ONLY for its event-selected fields and
  -- explicitly IGNORE its legacy downstream top_only_authoritative/rank_policy fields.
  select
    l.espn_event_id::text as espn_event_id,
    'soccer'::text as sport,
    l.liga::text as league_name,
    l.arranca_en as kickoff,
    l.home::text as home_team,
    l.away::text as away_team,
    l.mercado::text as market,
    l.pick_desc::text as selection_label,
    l.probabilidad_pct::numeric as p_reto_pct,
    l.model_version::text as model_version,
    l.calibration_version::text as validation_status,
    'futpro_terminal_v2'::text as analysis_contract,
    'v_futpro_publication_v3'::text as source_contract,
    l.canonical_pick_status::text as source_pick_status,
    l.selector_authoritative as source_selector_authoritative,
    (l.es_validado is true and l.validado_fuera_de_muestra is true) as source_product_authorized
  from public.v_reto13m_lo_mejor l
  where l.arranca_en > now()
    and l.arranca_en < now() + interval '48 hours'
    and l.canonical_pick_status='READY'
    and l.selector_authoritative=true
    and l.es_validado=true
    and l.validado_fuera_de_muestra=true
    and l.pick_desc is not null
    and l.probabilidad_pct is not null

  union all

  -- NBA/WNBA/NHL-style team models only enter when their own publication contract says READY.
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
    t.selector_authoritative
  from public.v_team_sports_publication_v1 t
  where t.kickoff > now()
    and t.kickoff < now() + interval '48 hours'
    and t.canonical_pick_status='READY'
    and t.selector_authoritative=true
    and t.canonical_pick is not null
    and t.canonical_probability_pct is not null
), with_counts as (
  select u.*, count(*) over(partition by u.espn_event_id) as source_event_rows
  from official_union u
)
select *,
       (kickoff at time zone 'America/Mexico_City')::date as dia_mx,
       'OFFICIAL_P_RETO'::text as display_class,
       false as money_authorized
from with_counts;

grant select on public.v_reto13m_global_candidate_v2 to authenticated;

create or replace view public.v_reto13m_global_top_v2 as
with eligible as (
  select *
  from public.v_reto13m_global_candidate_v2
  where source_event_rows=1
    and source_pick_status='READY'
    and source_selector_authoritative=true
    and source_product_authorized=true
    and p_reto_pct between 0 and 100
), ranked as (
  select e.*,
         row_number() over(
           order by e.p_reto_pct desc,e.kickoff,e.espn_event_id
         ) as rank_global,
         row_number() over(
           partition by e.dia_mx
           order by e.p_reto_pct desc,e.kickoff,e.espn_event_id
         ) as rank_dia
  from eligible e
)
select
  espn_event_id,
  sport,
  league_name,
  kickoff,
  dia_mx,
  home_team,
  away_team,
  market,
  selection_label,
  p_reto_pct,
  model_version,
  validation_status,
  analysis_contract,
  source_contract,
  display_class,
  rank_global,
  rank_dia,
  (rank_global=1) as is_global_top_1,
  (rank_dia=1) as is_day_top_1,
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
    'research_rows_eligible',false
  ) as provenance
from ranked;

grant select on public.v_reto13m_global_top_v2 to authenticated;

create or replace view public.v_reto13m_global_top_leaks_v2 as
with leaks as (
  select
    'SOURCE_DUPLICATE_EVENT'::text as leak_type,
    espn_event_id,
    ('rows='||source_event_rows)::text as detail
  from public.v_reto13m_global_candidate_v2
  where source_event_rows<>1

  union all

  select
    'BAD_SOURCE_AUTHORITY',
    espn_event_id,
    source_pick_status||'|selector='||source_selector_authoritative::text||'|product='||source_product_authorized::text
  from public.v_reto13m_global_candidate_v2
  where source_pick_status<>'READY'
     or source_selector_authoritative is distinct from true
     or source_product_authorized is distinct from true

  union all

  select 'BAD_P_RETO',espn_event_id,coalesce(p_reto_pct::text,'NULL')
  from public.v_reto13m_global_top_v2
  where p_reto_pct is null or p_reto_pct<0 or p_reto_pct>100

  union all

  select 'RANK_POLICY_DRIFT',espn_event_id,rank_policy_version||'|'||rank_policy_status
  from public.v_reto13m_global_top_v2
  where rank_policy_version<>'P_RETO_ARGMAX_GLOBAL_V1'
     or rank_policy_status<>'FROZEN'
     or top_only_authoritative is distinct from true

  union all

  select 'GLOBAL_TOP_COUNT',null::text,count(*)::text
  from public.v_reto13m_global_top_v2
  having count(*)>0 and count(*) filter(where is_global_top_1)<>1

  union all

  select 'DAY_TOP_COUNT',null::text,dia_mx::text||'|top1='||count(*) filter(where is_day_top_1)::text
  from public.v_reto13m_global_top_v2
  group by dia_mx
  having count(*) filter(where is_day_top_1)<>1
)
select * from leaks;

grant select on public.v_reto13m_global_top_leaks_v2 to authenticated;
