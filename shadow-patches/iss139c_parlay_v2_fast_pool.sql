-- ISS139c — lightweight canonical pool for Parlay V2. ADDITIVE ONLY.
create or replace view public.v_reto_parlay_candidate_pool_v2_fast as
select r.espn_event_id,'soccer'::text sport,r.liga::text competition_scope,r.liga::text competition_name,
  r.home home_team,r.away away_team,r.arranca_en kickoff,r.mercado market,r.pick_desc pick,
  r.probabilidad_pct p_reto_pct,r.discriminacion_pp separation_pp,
  case when r.probabilidad_pct>=70 and r.discriminacion_pp>=20 then 'ALTA'
       when r.probabilidad_pct>=58 and r.discriminacion_pp>=12 then 'MEDIA' else 'CAUTELOSA' end::text confidence_band,
  r.model_version,r.calibration_version,r.canonical_pick_version,r.canonical_pick_status,
  r.selector_authoritative,r.top_only_authoritative,r.rank_policy_status,
  r.validado_fuera_de_muestra scientific_ready,
  (r.es_validado and r.selector_authoritative and r.top_only_authoritative and r.canonical_pick_status='READY' and r.rank_policy_status='FROZEN') product_release_authorized,
  false::boolean money_authorized,r.momio_mercado selected_decimal_odds,r.casa odds_bookmaker,
  r.prob_que_implica_el_precio_pct book_implied_raw_pct,
  case when r.prob_que_implica_el_precio_pct is not null then round((r.probabilidad_pct-r.prob_que_implica_el_precio_pct)::numeric,2) end discrepancy_vs_book_raw_pp,
  r.rn_deporte,r.rank_global,r.razon,true::boolean canonical_leg
from public.v_reto13m_lo_mejor r
where r.arranca_en>now() and r.canonical_pick_status='READY' and r.selector_authoritative and r.top_only_authoritative
  and r.rank_policy_status='FROZEN' and r.es_validado;

grant select on public.v_reto_parlay_candidate_pool_v2_fast to anon,authenticated;

create or replace view public.v_reto_parlay_v2_fast_invariant_leaks as
select espn_event_id,'NON_CANONICAL'::text leak from public.v_reto_parlay_candidate_pool_v2_fast where not canonical_leg
union all
select espn_event_id,'AUTHORITY_MISMATCH' from public.v_reto_parlay_candidate_pool_v2_fast where not scientific_ready or not product_release_authorized
union all
select espn_event_id,'PAST_KICKOFF' from public.v_reto_parlay_candidate_pool_v2_fast where kickoff<=now();

grant select on public.v_reto_parlay_v2_fast_invariant_leaks to authenticated;