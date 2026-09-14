-- ISS137 — RETO Brain world-class core
-- 2026-09-13/14
-- Goals:
--   * separate RELEASE AUTHORITY from LIVE MONITORING;
--   * expose one auditable cross-sport model authority contract;
--   * expose immutable pregame prediction history + deltas + outcomes;
--   * expose public trust scorecards;
--   * fail closed on unauthorized money/product publication;
--   * freeze prediction fields in graded learning observations.
-- Market/no-vig remains diagnostic/economic context only; it never replaces P_RETO.

create or replace function v2.guard_model_learning_prediction_immutable_v1()
returns trigger
language plpgsql
set search_path='v2','public','pg_temp'
as $$
begin
  if new.source_system is distinct from old.source_system
     or new.source_key is distinct from old.source_key
     or new.espn_event_id is distinct from old.espn_event_id
     or new.sport is distinct from old.sport
     or new.league is distinct from old.league
     or new.market is distinct from old.market
     or new.model_version is distinct from old.model_version
     or new.feature_version is distinct from old.feature_version
     or new.eval_window is distinct from old.eval_window
     or new.snapshot_at is distinct from old.snapshot_at
     or new.kickoff is distinct from old.kickoff
     or new.temporal_safe is distinct from old.temporal_safe
     or new.n_classes is distinct from old.n_classes
     or new.p1 is distinct from old.p1
     or new.p2 is distinct from old.p2
     or new.p3 is distinct from old.p3
     or new.ref1 is distinct from old.ref1
     or new.ref2 is distinct from old.ref2
     or new.ref3 is distinct from old.ref3
     or new.line is distinct from old.line then
    raise exception 'RETO Brain prediction fields are immutable; append a corrected version instead of rewriting history';
  end if;
  return new;
end $$;

drop trigger if exists trg_model_learning_prediction_immutable_v1 on v2.model_learning_observation;
create trigger trg_model_learning_prediction_immutable_v1
before update on v2.model_learning_observation
for each row execute function v2.guard_model_learning_prediction_immutable_v1();

create or replace view public.v_reto_brain_release_authority_v1 as
with live as (
  select distinct on (g.sport,g.market,g.model_version)
    g.sport,g.market,g.model_version,g.n_events,g.n_market_ref,g.brier_model,g.brier_naive,g.brier_market,
    g.brier_vs_naive_upper95,g.brier_vs_market_upper95,g.leader_accuracy_pct,g.avg_confidence_pct,
    g.max_calibration_gap_pp,g.market_coverage_pct,g.prediction_authorized,g.money_authorized,
    g.lifecycle_stage,g.status,g.reason,g.computed_at
  from v2.model_learning_gate g
  where g.scope='GLOBAL'
  order by g.sport,g.market,g.model_version,g.computed_at desc
), soccer as (
  select 'soccer'::text sport,
    ('competition:'||p.competition_id)::text league_scope,
    '1X2'::text market,p.model_version,
    (r.validation_status like 'OOS_VALIDATED%') as scientific_ready,
    (p.status='PROD_APPROVED' and r.validation_status like 'OOS_VALIDATED%') as product_release_authorized,
    false as money_authorized,
    p.status::text release_status,
    r.validation_status::text validation_status,
    l.status::text live_status,l.n_events as live_n,l.n_market_ref as live_market_n,
    l.brier_model as live_brier_model,l.brier_naive as live_brier_naive,l.brier_market as live_brier_reference,
    l.brier_vs_naive_upper95 as live_vs_naive_upper95,l.brier_vs_market_upper95 as live_vs_market_upper95,
    l.max_calibration_gap_pp as live_calibration_gap_pp,l.leader_accuracy_pct as live_accuracy_pct,
    l.avg_confidence_pct as live_avg_confidence_pct,l.market_coverage_pct,
    coalesce(l.reason,'Release authority derives from crossleague registry + exact competition policy.')::text reason,
    jsonb_build_object('release',p.evidence,'validation',r.validation_evidence,'source_commit',r.source_commit,
      'live_monitor_is_release_authority',false) evidence,
    greatest(coalesce(p.updated_at,p.approved_at),r.created_at,coalesce(l.computed_at,r.created_at)) updated_at
  from v2.crossleague_competition_policy p
  join v2.crossleague_model_registry r using(model_version)
  left join live l on l.sport='soccer' and l.market='1X2' and l.model_version=p.model_version
), nfl as (
  select 'football'::text sport,'NFL'::text league_scope,v.market,c.model_version,
    coalesce(g.publish_authorized,false) scientific_ready,
    (c.publish_authorized and coalesce(g.publish_authorized,false)) product_release_authorized,
    false money_authorized,
    case when c.publish_authorized and coalesce(g.publish_authorized,false) then 'RELEASE_READY' else 'FAIL_CLOSED' end::text release_status,
    coalesce(g.validation_status,c.calibration_status)::text validation_status,
    l.status::text live_status,l.n_events live_n,l.n_market_ref live_market_n,
    l.brier_model live_brier_model,l.brier_naive live_brier_naive,l.brier_market live_brier_reference,
    l.brier_vs_naive_upper95 live_vs_naive_upper95,l.brier_vs_market_upper95 live_vs_market_upper95,
    l.max_calibration_gap_pp live_calibration_gap_pp,l.leader_accuracy_pct live_accuracy_pct,
    l.avg_confidence_pct live_avg_confidence_pct,l.market_coverage_pct,
    coalesce(l.reason,g.evidence->>'reason','NFL release gate')::text reason,
    jsonb_build_object('validation_gate',g.evidence,'feature_version',c.feature_version,
      'config_publish_flag',c.publish_authorized,'release_gate_publish_flag',coalesce(g.publish_authorized,false),
      'live_monitor_is_release_authority',false) evidence,
    greatest(c.sealed_at,coalesce(g.sealed_at,c.sealed_at),coalesce(l.computed_at,c.sealed_at)) updated_at
  from v2.nfl_model_config c
  left join v2.nfl_model_validation_gate g on g.model_version=c.model_version
  cross join lateral (values ('Moneyline'::text),('Spread'::text),('Total'::text)) v(market)
  left join live l on l.sport='football' and l.market=v.market and l.model_version=c.model_version
), fantasy as (
  select 'fantasy'::text sport,'NFL_FANTASY'::text league_scope,'PPR_PROJECTION'::text market,c.model_version,
    (c.validation_status='TEMPORAL_HOLDOUT_VALIDATED') scientific_ready,
    (c.publish_authorized and c.validation_status='TEMPORAL_HOLDOUT_VALIDATED') product_release_authorized,
    false money_authorized,
    case when c.publish_authorized and c.validation_status='TEMPORAL_HOLDOUT_VALIDATED' then 'RELEASE_READY' else 'FAIL_CLOSED' end::text release_status,
    c.validation_status::text validation_status,
    null::text live_status,null::int live_n,null::int live_market_n,
    null::numeric live_brier_model,null::numeric live_brier_naive,null::numeric live_brier_reference,
    null::numeric live_vs_naive_upper95,null::numeric live_vs_market_upper95,
    null::numeric live_calibration_gap_pp,null::numeric live_accuracy_pct,null::numeric live_avg_confidence_pct,null::numeric market_coverage_pct,
    'Fantasy B1 publication is limited to validated QB/RB/WR/TE; K/DST remain identity-only.'::text reason,
    c.evidence||jsonb_build_object('release_scope',c.release_scope,'cold_start_authorized',c.cold_start_authorized) evidence,
    c.sealed_at updated_at
  from v2.fantasy_model_config_v2 c
), teamelo as (
  select t.sport,t.league_name::text league_scope,'Moneyline'::text market,t.model_version,
    coalesce(l.prediction_authorized,false) scientific_ready,
    false product_release_authorized,
    false money_authorized,
    'LAB_ONLY'::text release_status,
    coalesce(case when l.prediction_authorized then l.status end,t.status)::text validation_status,
    l.status::text live_status,l.n_events live_n,l.n_market_ref live_market_n,
    l.brier_model live_brier_model,l.brier_naive live_brier_naive,l.brier_market live_brier_reference,
    l.brier_vs_naive_upper95 live_vs_naive_upper95,l.brier_vs_market_upper95 live_vs_market_upper95,
    l.max_calibration_gap_pp live_calibration_gap_pp,l.leader_accuracy_pct live_accuracy_pct,
    l.avg_confidence_pct live_avg_confidence_pct,l.market_coverage_pct,
    coalesce(l.reason,'Validated laboratory challenger; product publication requires an explicit release gate.')::text reason,
    jsonb_build_object('selected_model_status_raw',t.status,'n_train',t.n_train,'n_holdout',t.n_holdout,
      'brier_holdout_binary',t.brier_holdout,'brier_vs_naive_upper95_binary',t.brier_vs_naive_upper95,
      'accuracy_holdout_pct',t.accuracy_holdout_pct,'live_monitor_is_release_authority',false) evidence,
    greatest(t.computed_at,coalesce(l.computed_at,t.computed_at)) updated_at
  from v2.team_elo_selected_model t
  left join live l on l.sport=t.sport and l.market='Moneyline' and l.model_version=t.model_version
), mlb as (
  select 'baseball'::text sport,'MLB'::text league_scope,r.mercado::text market,r.model_version,
    (r.estado='PRODUCCION') scientific_ready,
    false product_release_authorized,
    false money_authorized,
    r.estado::text release_status,r.estado::text validation_status,
    l.status::text live_status,l.n_events live_n,l.n_market_ref live_market_n,
    l.brier_model live_brier_model,l.brier_naive live_brier_naive,l.brier_market live_brier_reference,
    l.brier_vs_naive_upper95 live_vs_naive_upper95,l.brier_vs_market_upper95 live_vs_market_upper95,
    l.max_calibration_gap_pp live_calibration_gap_pp,l.leader_accuracy_pct live_accuracy_pct,
    l.avg_confidence_pct live_avg_confidence_pct,l.market_coverage_pct,
    r.motivo_estado::text reason,
    jsonb_build_object('familia',r.familia,'evidencia',r.evidencia,'live_monitor_is_release_authority',false) evidence,
    greatest(r.actualizado_at,coalesce(l.computed_at,r.actualizado_at)) updated_at
  from public.modelo_registry r
  left join live l on l.sport='baseball' and l.market=r.mercado and l.model_version=r.model_version
  where r.deporte='baseball'
), tennis as (
  select 'tennis'::text sport,'ATP_WTA'::text league_scope,'Moneyline'::text market,
    ('tennis_elo_v1_k'||t.k_factor::int)::text model_version,
    false scientific_ready,false product_release_authorized,false money_authorized,
    'MODEL_REJECTED'::text release_status,'OOS_FAIL'::text validation_status,
    null::text live_status,t.n_holdout live_n,0::int live_market_n,
    (2*t.brier_holdout)::numeric live_brier_model,0.5::numeric live_brier_naive,null::numeric live_brier_reference,
    null::numeric live_vs_naive_upper95,null::numeric live_vs_market_upper95,
    null::numeric live_calibration_gap_pp,t.accuracy_holdout_pct live_accuracy_pct,null::numeric live_avg_confidence_pct,0::numeric market_coverage_pct,
    'Elo baseline did not beat 0.25 binary Brier in temporal holdout; richer tennis features are required.'::text reason,
    jsonb_build_object('k_factor',t.k_factor,'n_train',t.n_train,'brier_train_binary',t.brier_train,
      'n_holdout',t.n_holdout,'brier_holdout_binary',t.brier_holdout,'accuracy_holdout_pct',t.accuracy_holdout_pct) evidence,
    t.evaluated_at updated_at
  from v2.tennis_elo_backtest_result t
  where t.brier_holdout=(select min(x.brier_holdout) from v2.tennis_elo_backtest_result x)
), known as (
  select * from soccer
  union all select * from nfl
  union all select * from fantasy
  union all select * from teamelo
  union all select * from mlb
  union all select * from tennis
), learning_only as (
  select l.sport,'GLOBAL'::text league_scope,l.market,l.model_version,
    l.prediction_authorized scientific_ready,false product_release_authorized,false money_authorized,
    'LAB_ONLY'::text release_status,l.status::text validation_status,l.status::text live_status,
    l.n_events live_n,l.n_market_ref live_market_n,l.brier_model live_brier_model,l.brier_naive live_brier_naive,l.brier_market live_brier_reference,
    l.brier_vs_naive_upper95 live_vs_naive_upper95,l.brier_vs_market_upper95 live_vs_market_upper95,
    l.max_calibration_gap_pp live_calibration_gap_pp,l.leader_accuracy_pct live_accuracy_pct,l.avg_confidence_pct live_avg_confidence_pct,l.market_coverage_pct,
    l.reason::text reason,jsonb_build_object('lifecycle_stage',l.lifecycle_stage,'live_monitor_is_release_authority',false) evidence,l.computed_at updated_at
  from live l
  where not exists(select 1 from known k where k.sport=l.sport and k.market=l.market and k.model_version=l.model_version)
)
select * from known
union all
select * from learning_only;

comment on view public.v_reto_brain_release_authority_v1 is
'Canonical RETO Brain authority contract. RELEASE authority and LIVE monitoring are separate. Market reference never becomes P_RETO.';

create or replace view public.v_reto_brain_prediction_timeline_v1 as
with t as (
  select 'SOCCER_V2'::text source_system,p.espn_event_id,'soccer'::text sport,coalesce(p.competition_id,'UNKNOWN')::text league,
    '1X2'::text market,p.model_version,p.feature_version,p.prediction_time snapshot_at,p.kickoff,p.home_team,p.away_team,
    p.home_team::text p1_label,'Draw'::text p2_label,p.away_team::text p3_label,
    p.p_home/100.0 p1,p.p_draw/100.0 p2,p.p_away/100.0 p3,
    case when p.odds_home>1 and p.odds_draw>1 and p.odds_away>1 then (1/p.odds_home)/((1/p.odds_home)+(1/p.odds_draw)+(1/p.odds_away)) end ref1,
    case when p.odds_home>1 and p.odds_draw>1 and p.odds_away>1 then (1/p.odds_draw)/((1/p.odds_home)+(1/p.odds_draw)+(1/p.odds_away)) end ref2,
    case when p.odds_home>1 and p.odds_draw>1 and p.odds_away>1 then (1/p.odds_away)/((1/p.odds_home)+(1/p.odds_draw)+(1/p.odds_away)) end ref3,
    null::numeric line,p.temporal_safe,
    jsonb_build_object('model_status',p.model_status,'calibration_status',p.calibration_status,'data_asof',p.data_asof,
      'computed_at',p.computed_at,'odds_bookmaker',p.odds_bookmaker,'odds_captured_at',p.odds_captured_at,
      'predicted_score',p.predicted_score,'predicted_score_prob',p.predicted_score_prob,'score_dist',p.score_dist,'provenance',p.provenance) provenance
  from v2.soccer_prediction_v2 p where p.p_home is not null and p.p_draw is not null and p.p_away is not null

  union all
  select 'SOCCER_V2',p.espn_event_id,'soccer',coalesce(p.competition_id,'UNKNOWN'),'Over/Under',p.model_version,p.feature_version,p.prediction_time,p.kickoff,p.home_team,p.away_team,
    'Over','Under',null,p.p_over/100.0,p.p_under/100.0,null,
    case when p.odds_over>1 and p.odds_under>1 then (1/p.odds_over)/((1/p.odds_over)+(1/p.odds_under)) end,
    case when p.odds_over>1 and p.odds_under>1 then (1/p.odds_under)/((1/p.odds_over)+(1/p.odds_under)) end,null,p.over_line,p.temporal_safe,
    jsonb_build_object('model_status',p.model_status,'calibration_status',p.calibration_status,'data_asof',p.data_asof,
      'computed_at',p.computed_at,'odds_bookmaker',p.odds_bookmaker,'odds_captured_at',p.odds_captured_at,'provenance',p.provenance)
  from v2.soccer_prediction_v2 p where p.p_over is not null and p.p_under is not null

  union all
  select 'SOCCER_V2',p.espn_event_id,'soccer',coalesce(p.competition_id,'UNKNOWN'),'BTTS',p.model_version,p.feature_version,p.prediction_time,p.kickoff,p.home_team,p.away_team,
    'Yes','No',null,p.btts_yes/100.0,p.btts_no/100.0,null,null,null,null,null,p.temporal_safe,
    jsonb_build_object('model_status',p.model_status,'calibration_status',p.calibration_status,'data_asof',p.data_asof,'computed_at',p.computed_at,'provenance',p.provenance)
  from v2.soccer_prediction_v2 p where p.btts_yes is not null and p.btts_no is not null

  union all
  select 'NFL_V2',n.espn_event_id,'football','NFL','Moneyline',n.model_version,n.feature_version,n.decision_time,n.kickoff,n.home_team,n.away_team,
    n.home_team,n.away_team,null,n.p_home_ml/100.0,n.p_away_ml/100.0,null,
    case when n.dk_ml_home is not null and n.dk_ml_away is not null then
      (case when n.dk_ml_home<0 then (-n.dk_ml_home)::numeric/((-n.dk_ml_home)+100) else 100.0/(n.dk_ml_home+100) end) /
      ((case when n.dk_ml_home<0 then (-n.dk_ml_home)::numeric/((-n.dk_ml_home)+100) else 100.0/(n.dk_ml_home+100) end)+(case when n.dk_ml_away<0 then (-n.dk_ml_away)::numeric/((-n.dk_ml_away)+100) else 100.0/(n.dk_ml_away+100) end)) end,
    case when n.dk_ml_home is not null and n.dk_ml_away is not null then
      (case when n.dk_ml_away<0 then (-n.dk_ml_away)::numeric/((-n.dk_ml_away)+100) else 100.0/(n.dk_ml_away+100) end) /
      ((case when n.dk_ml_home<0 then (-n.dk_ml_home)::numeric/((-n.dk_ml_home)+100) else 100.0/(n.dk_ml_home+100) end)+(case when n.dk_ml_away<0 then (-n.dk_ml_away)::numeric/((-n.dk_ml_away)+100) else 100.0/(n.dk_ml_away+100) end)) end,null,null,n.asof_proven,
    jsonb_build_object('model_status',n.model_status,'quality_status',n.quality_status,'data_asof',n.data_asof,'ratings_asof',n.ratings_asof,
      'prob_source',n.prob_source,'bookmaker',n.dk_bookmaker,'market_snapshot_at',n.dk_snapshot_at,'provenance',n.provenance)
  from v2.nfl_decision_snapshot n where n.p_home_ml is not null and n.p_away_ml is not null

  union all
  select 'NFL_V2',n.espn_event_id,'football','NFL','Spread',n.model_version,n.feature_version,n.decision_time,n.kickoff,n.home_team,n.away_team,
    n.home_team||' cover',n.away_team||' cover',null,n.p_home_cover/nullif(n.p_home_cover+n.p_away_cover,0),n.p_away_cover/nullif(n.p_home_cover+n.p_away_cover,0),null,
    null,null,null,n.dk_spread_home,n.asof_proven,
    jsonb_build_object('model_status',n.model_status,'quality_status',n.quality_status,'data_asof',n.data_asof,'ratings_asof',n.ratings_asof,'provenance',n.provenance)
  from v2.nfl_decision_snapshot n where n.p_home_cover is not null and n.p_away_cover is not null

  union all
  select 'NFL_V2',n.espn_event_id,'football','NFL','Total',n.model_version,n.feature_version,n.decision_time,n.kickoff,n.home_team,n.away_team,
    'Over','Under',null,n.p_over/nullif(n.p_over+n.p_under,0),n.p_under/nullif(n.p_over+n.p_under,0),null,
    case when n.dk_over_odds is not null and n.dk_under_odds is not null then
      (case when n.dk_over_odds<0 then (-n.dk_over_odds)::numeric/((-n.dk_over_odds)+100) else 100.0/(n.dk_over_odds+100) end) /
      ((case when n.dk_over_odds<0 then (-n.dk_over_odds)::numeric/((-n.dk_over_odds)+100) else 100.0/(n.dk_over_odds+100) end)+(case when n.dk_under_odds<0 then (-n.dk_under_odds)::numeric/((-n.dk_under_odds)+100) else 100.0/(n.dk_under_odds+100) end)) end,
    case when n.dk_over_odds is not null and n.dk_under_odds is not null then
      (case when n.dk_under_odds<0 then (-n.dk_under_odds)::numeric/((-n.dk_under_odds)+100) else 100.0/(n.dk_under_odds+100) end) /
      ((case when n.dk_over_odds<0 then (-n.dk_over_odds)::numeric/((-n.dk_over_odds)+100) else 100.0/(n.dk_over_odds+100) end)+(case when n.dk_under_odds<0 then (-n.dk_under_odds)::numeric/((-n.dk_under_odds)+100) else 100.0/(n.dk_under_odds+100) end)) end,null,n.dk_total,n.asof_proven,
    jsonb_build_object('model_status',n.model_status,'quality_status',n.quality_status,'data_asof',n.data_asof,'ratings_asof',n.ratings_asof,
      'bookmaker',n.dk_bookmaker,'market_snapshot_at',n.dk_snapshot_at,'provenance',n.provenance)
  from v2.nfl_decision_snapshot n where n.p_over is not null and n.p_under is not null

  union all
  select 'MLB_LEARNING',m.espn_event_id,'baseball',coalesce(m.league,'MLB'),'Moneyline',m.model_version,null,m.captured_at,m.kickoff,m.home_team,m.away_team,
    m.home_team,m.away_team,null,m.p_home/100.0,m.p_away/100.0,null,null,null,null,null,m.temporal_safe,m.prediction
  from v2.mlb_learning_snapshot m where m.p_home is not null and m.p_away is not null

  union all
  select 'MLB_LEARNING',m.espn_event_id,'baseball',coalesce(m.league,'MLB'),'Over/Under',m.model_version,null,m.captured_at,m.kickoff,m.home_team,m.away_team,
    'Over','Under',null,m.p_over/100.0,m.p_under/100.0,null,null,null,null,m.total_line,m.temporal_safe,m.prediction
  from v2.mlb_learning_snapshot m where m.p_over is not null and m.p_under is not null

  union all
  select 'TEAM_ELO',e.espn_event_id,e.sport,e.league_name,'Moneyline',e.model_version,null,e.captured_at,e.kickoff,e.home_name,e.away_name,
    e.home_name,e.away_name,null,e.p_home,e.p_away,null,null,null,null,null,e.temporal_safe,e.meta
  from v2.team_elo_learning_snapshot e where e.p_home is not null and e.p_away is not null
)
select t.*,
  md5(concat_ws('|',t.source_system,t.espn_event_id,t.sport,t.league,t.market,t.model_version,
    coalesce(t.snapshot_at::text,''),coalesce(t.p1::text,''),coalesce(t.p2::text,''),coalesce(t.p3::text,''),coalesce(t.line::text,''))) as prediction_fingerprint
from t;

comment on view public.v_reto_brain_prediction_timeline_v1 is
'Immutable-source cross-sport prediction timeline. Probabilities are normalized to 0..1; market refs are no-vig diagnostics only.';

create or replace view public.v_reto_brain_event_audit_v1 as
with hist as (
  select t.*,
    lag(t.p1) over(partition by t.source_system,t.espn_event_id,t.market,t.model_version order by t.snapshot_at) prev_p1,
    lag(t.p2) over(partition by t.source_system,t.espn_event_id,t.market,t.model_version order by t.snapshot_at) prev_p2,
    lag(t.p3) over(partition by t.source_system,t.espn_event_id,t.market,t.model_version order by t.snapshot_at) prev_p3,
    lag(t.snapshot_at) over(partition by t.source_system,t.espn_event_id,t.market,t.model_version order by t.snapshot_at) prev_snapshot_at
  from public.v_reto_brain_prediction_timeline_v1 t
), outcome as (
  select distinct on (s.espn_event_id,s.sport,s.market,s.model_version)
    s.espn_event_id,s.sport,s.market,s.model_version,s.outcome_idx,s.score_home,s.score_away,
    s.brier_model,s.brier_ref,s.brier_naive,s.logloss_model,s.logloss_ref,s.leader_correct,s.created_at graded_observation_at
  from v2.v_model_learning_scored s
  order by s.espn_event_id,s.sport,s.market,s.model_version,s.created_at desc
)
select h.*,
  round(100*(h.p1-h.prev_p1),2) delta_p1_pp,
  round(100*(h.p2-h.prev_p2),2) delta_p2_pp,
  round(100*(h.p3-h.prev_p3),2) delta_p3_pp,
  o.outcome_idx,o.score_home,o.score_away,o.brier_model,o.brier_ref,o.brier_naive,o.logloss_model,o.logloss_ref,o.leader_correct,o.graded_observation_at,
  a.scientific_ready,a.product_release_authorized,a.money_authorized,a.release_status,a.validation_status,a.live_status,
  a.reason as authority_reason
from hist h
left join outcome o on o.espn_event_id=h.espn_event_id and o.sport=h.sport and o.market=h.market and o.model_version=h.model_version
left join public.v_reto_brain_release_authority_v1 a
  on a.sport=h.sport and a.market=h.market and a.model_version=h.model_version
 and a.league_scope=(case when h.sport='soccer' then 'competition:'||h.league else h.league end);

comment on view public.v_reto_brain_event_audit_v1 is
'What RETO predicted, when, with which version, how probabilities changed, release authority, and how the event graded.';

create or replace view public.v_reto_brain_scorecard_v1 as
select sport,league_scope,market,model_version,scientific_ready,product_release_authorized,money_authorized,
  release_status,validation_status,live_status,live_n,live_market_n,live_brier_model,live_brier_naive,live_brier_reference,
  live_vs_naive_upper95,live_vs_market_upper95,live_calibration_gap_pp,live_accuracy_pct,live_avg_confidence_pct,
  market_coverage_pct,reason,evidence,updated_at
from public.v_reto_brain_release_authority_v1;

comment on view public.v_reto_brain_scorecard_v1 is
'Public-ready model trust scorecard. No win-rate-only certification; authority and statistical evidence are explicit.';

create or replace view public.v_reto_brain_invariant_leaks_v1 as
with checks as (
  select 'GLOBAL_PUBLICATION_AUTHORITY_LEAKS'::text invariant_name,(select count(*) from public.v_publication_authority_leaks)::bigint leak_count,
    'Legacy/cross-sport surfaces exposing non-canonical authority.'::text detail
  union all
  select 'SOCCER_PUBLICATION_INVARIANT_LEAKS',(select count(*) from public.v_soccer_publication_invariant_leaks)::bigint,
    'Soccer identity/distribution/temporal/selector authority leaks.'
  union all
  select 'LEARNING_TEMPORAL_LEAKS',coalesce((select temporal_leaks from v2.v_model_learning_health limit 1),0)::bigint,
    'Learning rows marked promotable despite temporal leakage.'
  union all
  select 'UNVERSIONED_PROMOTABLE_ROWS',coalesce((select unversioned_promotable_rows from v2.v_model_learning_health limit 1),0)::bigint,
    'Promotable learning rows missing exact model identity.'
  union all
  select 'LEARNING_PUBLICATION_AUTHORITY_LEAKS',coalesce((select publication_authority_leaks from v2.v_model_learning_health limit 1),0)::bigint,
    'Learning layer contradicts publication authority.'
  union all
  select 'BRAIN_TIMELINE_TEMPORAL_LEAKS',(select count(*) from public.v_reto_brain_prediction_timeline_v1 where temporal_safe is distinct from true or snapshot_at>=kickoff)::bigint,
    'Canonical Brain timeline contains a non-pregame/unsafe prediction.'
  union all
  select 'MONEY_WITHOUT_RELEASE_AUTHORITY',(select count(*) from public.v_reto_brain_release_authority_v1 where money_authorized and (not scientific_ready or not product_release_authorized))::bigint,
    'Money authority may never exceed scientific + product release authority.'
  union all
  select 'BANNED_LEGACY_AUTOMUTATORS_ACTIVE',(select count(*) from cron.job where active and jobname in ('recalibrate-model-weights-monday','recalcular-competencia-modelo'))::bigint,
    'Legacy heuristics that mutate weights or replace model probability with market must stay off.'
)
select * from checks where leak_count<>0;

create or replace view public.v_reto_brain_health_v1 as
select
  now() checked_at,
  (select count(*) from public.v_reto_brain_release_authority_v1)::bigint authority_rows,
  (select count(*) from public.v_reto_brain_release_authority_v1 where scientific_ready)::bigint scientific_ready_rows,
  (select count(*) from public.v_reto_brain_release_authority_v1 where product_release_authorized)::bigint product_release_rows,
  (select count(*) from public.v_reto_brain_release_authority_v1 where money_authorized)::bigint money_authorized_rows,
  (select count(*) from public.v_reto_brain_prediction_timeline_v1)::bigint timeline_rows,
  (select count(*) from v2.model_learning_observation)::bigint graded_learning_rows,
  (select count(*) from public.v_reto_brain_invariant_leaks_v1)::bigint invariant_failures,
  case when not exists(select 1 from public.v_reto_brain_invariant_leaks_v1) then 'PASS' else 'FAIL' end::text status;

comment on view public.v_reto_brain_health_v1 is
'RETO Brain global health gate. PASS requires zero publication, temporal, versioning, money-authority, and banned-auto-mutator leaks.';

grant select on public.v_reto_brain_release_authority_v1 to anon,authenticated;
grant select on public.v_reto_brain_prediction_timeline_v1 to anon,authenticated;
grant select on public.v_reto_brain_event_audit_v1 to anon,authenticated;
grant select on public.v_reto_brain_scorecard_v1 to anon,authenticated;
grant select on public.v_reto_brain_health_v1 to anon,authenticated;
-- invariant details are intentionally restricted to authenticated users.
grant select on public.v_reto_brain_invariant_leaks_v1 to authenticated;
