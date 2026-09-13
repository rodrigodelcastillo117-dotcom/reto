-- ============================================================================
-- ISS128 — MLB EXACT-MODEL FORWARD VALIDATION + PUBLICATION FAIL-CLOSE
-- 2026-09-13 · staged / disposable only · NO PROD MODEL CUTOVER
-- ============================================================================
-- Governance objective:
--   * ONE BRAIN / ONE P_RETO for MLB remains v2.mlb_prediction_snapshot.
--   * market/no-vig is diagnostic only and NEVER supplies or calibrates P_RETO.
--   * an UNVALIDATED model may be inspected, but cannot create candidates/TOP_ONLY.
--   * publication eligibility requires a sealed validation decision for EXACT model_version.
--
-- Independent auditor reconstruction of the exact mlb_runs_nb_v1 candidate over the
-- strictly-forward post-development window (historico_partidos_espn, every target using
-- only games with fecha < target.fecha; 365d run-rate features; NB r=5; ties removed by
-- renormalization exactly as fn_mlb_run_dist):
--   window: 2026-08-30..2026-09-11 18:20Z
--   n=161, Brier=0.246864 vs coinflip=0.250000, skill=+1.254%
--   mean Brier gain vs coinflip=0.003136, SE=0.006079, t=0.516
-- This is directionally positive but statistically weak. It is NOT evidence for a
-- publishable predictive edge. Correct action: FAIL CLOSED, not fit a calibrator on the
-- same 161 outcomes and call it validation.
-- ============================================================================

create schema if not exists v2;

create table if not exists v2.mlb_validation_seal (
  model_version text primary key,
  model_name text not null,
  feature_version text not null,
  calibration_version text not null,
  evaluation_kind text not null,
  window_start timestamptz not null,
  window_end timestamptz not null,
  data_cutoff_at timestamptz not null,
  n_scored int not null,
  brier_ml numeric,
  brier_reference numeric,
  skill_vs_reference numeric,
  mean_gain numeric,
  se_gain numeric,
  t_stat numeric,
  calibration_status text not null,
  publish_authorized boolean not null default false,
  verdict text not null,
  evidence jsonb not null,
  sealed_at timestamptz not null default now(),
  check (window_end <= data_cutoff_at + interval '1 second'),
  check (publish_authorized = false or calibration_status in ('FORWARD_VALIDATED','VALIDATED'))
);

create or replace function v2.fn_mlb_validation_seal_immutable() returns trigger
language plpgsql as $$
begin
  raise exception 'MLB_VALIDATION_SEAL_IMMUTABLE: validation decisions are append/versioned; use a new model_version';
end $$;
drop trigger if exists trg_mlb_validation_seal_immutable on v2.mlb_validation_seal;
create trigger trg_mlb_validation_seal_immutable before update or delete on v2.mlb_validation_seal
for each row execute function v2.fn_mlb_validation_seal_immutable();

insert into v2.mlb_validation_seal(
  model_version,model_name,feature_version,calibration_version,evaluation_kind,
  window_start,window_end,data_cutoff_at,n_scored,brier_ml,brier_reference,
  skill_vs_reference,mean_gain,se_gain,t_stat,calibration_status,publish_authorized,
  verdict,evidence
) values (
  'mlb-2026.09.1','mlb_runs_nb_v1','mlb_runrates_asof_v1','IDENTITY_V1',
  'FINAL_TEST_FORWARD_EXACT_MODEL',
  '2026-08-30 00:00:00+00','2026-09-11 18:20:00+00','2026-09-11 18:20:00+00',
  161,0.246864,0.250000,0.01254,0.003136,0.006079,0.516,
  'UNVALIDATED',false,'NO_DEMONSTRATED_SKILL_FORWARD',
  jsonb_build_object(
    'reference','coinflip_0.5_outcome_only',
    'market_role','DIAGNOSTIC_ONLY_NOT_P_RETO',
    'reconstruction','365d team run-rates strictly before each target; lambda_home=RS_home*RA_away/league_rpg; lambda_away=RS_away*RA_home/league_rpg; independent NB r=5; 0..18 grid; regulation-tie mass removed and renormalized',
    'anti_leak','target outcome excluded by fecha < target.fecha',
    'decision','raw candidate remains analysis-only; no post-hoc calibration is fitted on final-test outcomes',
    'auditor_query_result',jsonb_build_object('avg_p_home',0.5010,'actual_home_win',0.5217,'logloss',0.686635)
  )
) on conflict (model_version) do nothing;

-- Primary validation is outcome-based. Market comparisons remain diagnostics only.
create or replace function v2.fn_mlb_validation_status(p_model_version text)
returns table(
  calibration_status text, publish_authorized boolean, verdict text,
  n_scored int, brier_ml numeric, brier_reference numeric, t_stat numeric
) language sql stable as $$
  select s.calibration_status,s.publish_authorized,s.verdict,
         s.n_scored,s.brier_ml,s.brier_reference,s.t_stat
  from v2.mlb_validation_seal s where s.model_version=p_model_version;
$$;

-- Publication gate wraps the coherence/event gate. A coherent probability is not the
-- same thing as a validated probability. The model can remain visible to audit/analysis,
-- but cannot enter candidates while validation is red.
create or replace view v2.v_mlb_event_gate as
select s.espn_event_id as canonical_event_id, s.decision_time, s.model_version,
       g.coherence_ok, g.disc_flag,
       (coalesce(g.suppress,false) or not coalesce(v.publish_authorized,false)) as suppress,
       (s.model_status='READY_UNVALIDATED'
        and coalesce(g.coherence_ok,false)
        and not coalesce(g.suppress,false)
        and coalesce(v.publish_authorized,false)) as top_only_eligible,
       nullif(concat_ws('; ',
          g.gate_reason,
          case when not coalesce(v.publish_authorized,false)
               then 'MODEL_VALIDATION_FAIL_CLOSE:'||coalesce(v.verdict,'NO_VALIDATION_SEAL') end
       ),'') as gate_reason
from v2.mlb_prediction_snapshot s
left join lateral (
  select mc.home_ml, mc.away_ml from public.v_momios_confiables mc
  where mc.espn_event_id=s.espn_event_id and mc.confiable is true
    and mc.snapshot_at<=s.decision_time
  order by mc.snapshot_at desc limit 1
) oml on true
left join lateral (
  select mc.over_odds,mc.under_odds from public.v_momios_confiables mc
  where mc.espn_event_id=s.espn_event_id and mc.confiable is true
    and mc.snapshot_at<=s.decision_time and mc.over_line=s.total_line
  order by mc.snapshot_at desc limit 1
) oou on true
left join lateral v2.fn_mlb_event_gate_status(
  s.run_dist,s.p_home_ml,s.p_away_ml,s.total_line,s.p_over,s.p_under,s.p_push,
  s.ou_line_type,s.ou_supported,s.top_scores,
  oml.home_ml,oml.away_ml,oou.over_odds,oou.under_odds
) g on true
left join v2.mlb_validation_seal v on v.model_version=s.model_version;

-- Keep candidate contract unchanged. The event gate above makes this empty for an
-- unvalidated model, which is the intended fail-close behavior.
create or replace view v2.v_mlb_daily_candidates as
select s.espn_event_id as canonical_event_id,s.home_team,s.away_team,s.liga_nombre,
       s.scheduled_at,s.decision_time,s.model_version,
       s.feature_snapshot_id as model_snapshot_id,
       cand.canonical_market,cand.canonical_side,cand.canonical_line,
       cand.canonical_probability,cand.canonical_push,cand.canonical_line_type,
       s.data_readiness
from v2.mlb_prediction_snapshot s
join v2.v_mlb_event_gate g
  on g.canonical_event_id=s.espn_event_id
 and g.decision_time=s.decision_time
 and g.model_version=s.model_version
 and g.top_only_eligible
cross join lateral (values
  ('ML'::text,'HOME'::text,null::numeric,s.p_home_ml,null::numeric,null::text),
  ('ML','AWAY',null,s.p_away_ml,null,null),
  ('OU','OVER',s.total_line,case when s.total_line is not null then s.p_over end,s.p_push,s.ou_line_type),
  ('OU','UNDER',s.total_line,case when s.total_line is not null then s.p_under end,s.p_push,s.ou_line_type)
) cand(canonical_market,canonical_side,canonical_line,canonical_probability,canonical_push,canonical_line_type)
where s.model_status='READY_UNVALIDATED' and cand.canonical_probability is not null;

-- Safety/audit surface. Must be zero before any future MLB promotion.
create or replace view v2.v_mlb_unvalidated_publication_violations as
select s.espn_event_id,s.decision_time,s.model_version,g.top_only_eligible,
       v.calibration_status,v.publish_authorized,v.verdict
from v2.mlb_prediction_snapshot s
join v2.v_mlb_event_gate g
  on g.canonical_event_id=s.espn_event_id and g.decision_time=s.decision_time and g.model_version=s.model_version
left join v2.mlb_validation_seal v on v.model_version=s.model_version
where g.top_only_eligible
  and (v.model_version is null or not v.publish_authorized or v.calibration_status='UNVALIDATED');
