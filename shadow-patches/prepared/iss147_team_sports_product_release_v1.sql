-- ISS147: additive product-release authority for versioned NBA/WNBA/NHL challengers.
-- Money authority remains false. Existing Brain V1 and existing publication surfaces are untouched.

create table if not exists v2.team_elo_product_release_gate (
  model_version text primary key,
  league_name text not null,
  release_status text not null,
  product_authorized boolean not null default false,
  money_authorized boolean not null default false,
  evidence jsonb not null default '{}'::jsonb,
  sealed_at timestamptz not null default now()
);

insert into v2.team_elo_product_release_gate(model_version,league_name,release_status,product_authorized,money_authorized,evidence,sealed_at)
values
 ('nba_elo_v1_k24_h50','NBA','PREDICTION_RELEASE_APPROVED',true,false,
  jsonb_build_object('basis','temporal holdout + supported calibration buckets','n_holdout',1352,'binary_brier_holdout',0.2093671362895718,'accuracy_pct',67.97,'supported_calibration_gap_pp',4.90,'money_gate','BLOCKED_PENDING_MARKET_EVIDENCE'),now()),
 ('wnba_elo_v1_k32_h25','WNBA','PREDICTION_RELEASE_APPROVED',true,false,
  jsonb_build_object('basis','temporal holdout + supported calibration buckets n>=20','n_holdout',343,'binary_brier_holdout',0.2143341775742810,'accuracy_pct',67.64,'supported_calibration_gap_pp',5.35,'money_gate','BLOCKED_PENDING_MARKET_EVIDENCE'),now()),
 ('nhl_elo_v1_k12_h25','NHL','MODEL_REJECTED',false,false,
  jsonb_build_object('basis','temporal holdout','n_holdout',863,'binary_brier_holdout',0.2476519398729412,'accuracy_pct',56.20,'reason','95% skill interval crosses neutral and calibration is weak'),now())
on conflict(model_version) do update set league_name=excluded.league_name,release_status=excluded.release_status,product_authorized=excluded.product_authorized,money_authorized=excluded.money_authorized,evidence=excluded.evidence,sealed_at=excluded.sealed_at;

create or replace view public.v_reto_brain_release_authority_v2 as
select a.sport,a.league_scope,a.market,a.model_version,a.scientific_ready,
       coalesce(g.product_authorized,a.product_release_authorized) product_release_authorized,
       coalesce(g.money_authorized,a.money_authorized) money_authorized,
       coalesce(g.release_status,a.release_status) release_status,
       a.validation_status,a.live_status,a.live_n,a.live_market_n,a.live_brier_model,a.live_brier_naive,a.live_brier_reference,
       a.live_vs_naive_upper95,a.live_vs_market_upper95,a.live_calibration_gap_pp,a.live_accuracy_pct,a.live_avg_confidence_pct,a.market_coverage_pct,
       case when g.model_version is not null then concat('Explicit product release gate: ',g.release_status,'. ',a.reason) else a.reason end reason,
       a.evidence || case when g.model_version is not null then jsonb_build_object('product_release_gate',g.evidence,'product_release_sealed_at',g.sealed_at) else '{}'::jsonb end evidence,
       greatest(a.updated_at,coalesce(g.sealed_at,a.updated_at)) updated_at
from public.v_reto_brain_release_authority_v1 a
left join v2.team_elo_product_release_gate g on g.model_version=a.model_version;

create or replace view public.v_team_sports_publication_v1 as
with latest as (
  select distinct on (s.model_version,s.espn_event_id)
    s.espn_event_id,s.model_version,s.captured_at,s.kickoff,s.sport,s.league_name,s.home_name,s.away_name,s.p_home,s.p_away,s.temporal_safe,s.meta
  from v2.team_elo_learning_snapshot s
  where s.kickoff>now()
  order by s.model_version,s.espn_event_id,s.captured_at desc
), auth as (
  select g.*,a.scientific_ready,a.live_n,a.live_calibration_gap_pp,a.live_accuracy_pct,a.validation_status
  from v2.team_elo_product_release_gate g
  join public.v_reto_brain_release_authority_v2 a using(model_version)
)
select l.espn_event_id,l.league_name,l.sport,l.kickoff,l.home_name,l.away_name,l.model_version,l.captured_at,
       round(100*l.p_home,2) p_home_pct,round(100*l.p_away,2) p_away_pct,
       case when l.p_home>l.p_away then l.home_name when l.p_away>l.p_home then l.away_name else null end canonical_pick,
       round(100*greatest(l.p_home,l.p_away),2) canonical_probability_pct,
       case when l.p_home=l.p_away then 'TIE_UNRESOLVED'
            when not l.temporal_safe then 'TEMPORAL_BLOCKED'
            when not a.product_authorized or not a.scientific_ready then 'NOT_RELEASE_AUTHORIZED'
            else 'READY' end canonical_pick_status,
       a.product_authorized selector_authoritative,
       false money_authorized,
       a.release_status,a.validation_status,a.live_n,a.live_calibration_gap_pp,a.live_accuracy_pct,
       'TEAM_ELO_ML_ARGMAX_V1' selector_version,
       l.meta
from latest l join auth a using(model_version);

create or replace view public.v_reto_brain_health_v2 as
select
  now() checked_at,
  count(*) authority_rows,
  count(*) filter(where scientific_ready) scientific_ready_rows,
  count(*) filter(where product_release_authorized) product_authorized_rows,
  count(*) filter(where money_authorized) money_authorized_rows,
  count(*) filter(where product_release_authorized and not scientific_ready) authority_leaks,
  count(*) filter(where money_authorized and not product_release_authorized) money_authority_leaks
from public.v_reto_brain_release_authority_v2;

grant select on v2.team_elo_product_release_gate to authenticated;
grant select on public.v_reto_brain_release_authority_v2 to authenticated;
grant select on public.v_team_sports_publication_v1 to authenticated;
grant select on public.v_reto_brain_health_v2 to authenticated;
