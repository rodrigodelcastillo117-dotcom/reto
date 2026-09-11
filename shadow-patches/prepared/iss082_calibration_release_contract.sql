-- iss082 — CALIBRATION_RELEASE_V1 · STAGED ONLY · NO PROD CUTOVER
-- Goal: one temporal/OOS calibration authority per sport+market+model_version.
-- Important: market/no-vig is benchmark context only; it is never P_RETO and never a calibration target.

create schema if not exists v2;

create table if not exists v2.calibration_registry_v1 (
  sport text not null,
  market text not null,
  model_version text not null,
  calibration_version text not null,
  method text not null,
  status text not null,
  train_start timestamptz,
  train_end timestamptz,
  oos_start timestamptz,
  oos_end timestamptz,
  data_cutoff timestamptz not null,
  n_train int not null default 0,
  n_oos int not null default 0,
  brier_raw numeric,
  brier_cal numeric,
  logloss_raw numeric,
  logloss_cal numeric,
  ece_raw numeric,
  ece_cal numeric,
  max_gap_raw numeric,
  max_gap_cal numeric,
  slope_raw numeric,
  slope_cal numeric,
  intercept_raw numeric,
  intercept_cal numeric,
  stable_windows int,
  total_windows int,
  params jsonb not null default '{}'::jsonb,
  evidence jsonb not null default '{}'::jsonb,
  reason text,
  created_at timestamptz not null default now(),
  primary key (sport,market,model_version,calibration_version),
  constraint calibration_registry_status_ck check (status in ('IDENTITY','EARLY','CALIBRATED','REJECTED','INSUFFICIENT')),
  constraint calibration_registry_method_ck check (method in ('IDENTITY','TEMPERATURE','VECTOR','DIRICHLET','PLATT','BETA','ISOTONIC','POINT_DISTRIBUTION')),
  constraint calibration_registry_sample_ck check (n_train >= 0 and n_oos >= 0),
  constraint calibration_registry_time_ck check (
    (train_end is null or train_start is null or train_start <= train_end)
    and (oos_end is null or oos_start is null or oos_start <= oos_end)
    and (train_end is null or data_cutoff >= train_end)
    and (oos_end is null or data_cutoff >= oos_end)
  )
);

create table if not exists v2.calibration_reliability_bin_v1 (
  sport text not null,
  market text not null,
  model_version text not null,
  calibration_version text not null,
  split text not null,
  bin_no int not null,
  n int not null,
  p_mean numeric not null,
  observed_rate numeric not null,
  ci_low numeric,
  ci_high numeric,
  created_at timestamptz not null default now(),
  primary key (sport,market,model_version,calibration_version,split,bin_no),
  constraint calibration_bin_split_ck check (split in ('TRAIN','OOS')),
  constraint calibration_bin_n_ck check (n > 0),
  constraint calibration_bin_prob_ck check (
    p_mean between 0 and 1 and observed_rate between 0 and 1
    and (ci_low is null or ci_low between 0 and 1)
    and (ci_high is null or ci_high between 0 and 1)
  )
);

create or replace view v2.v_calibration_latest_v1 as
select distinct on (sport,market,model_version)
  sport,market,model_version,calibration_version,method,status,
  train_start,train_end,oos_start,oos_end,data_cutoff,n_train,n_oos,
  brier_raw,brier_cal,logloss_raw,logloss_cal,ece_raw,ece_cal,
  max_gap_raw,max_gap_cal,slope_raw,slope_cal,intercept_raw,intercept_cal,
  stable_windows,total_windows,params,evidence,reason,created_at
from v2.calibration_registry_v1
order by sport,market,model_version,created_at desc,calibration_version desc;

create or replace function v2.fn_calibration_gate_v1(
  p_sport text,
  p_market text,
  p_model_version text,
  p_decision_time timestamptz
) returns jsonb
language plpgsql stable
set search_path to pg_catalog,v2
as $$
declare r record;
begin
  select * into r
  from v2.v_calibration_latest_v1
  where sport=p_sport and market=p_market and model_version=p_model_version
  limit 1;

  if not found then
    return jsonb_build_object(
      'apply_calibration',false,
      'status','INSUFFICIENT',
      'method','IDENTITY',
      'reason','NO_VERSIONED_CALIBRATION_EVIDENCE'
    );
  end if;

  if r.data_cutoff > p_decision_time then
    return jsonb_build_object(
      'apply_calibration',false,
      'status','REJECTED',
      'method','IDENTITY',
      'reason','CALIBRATION_LOOKAHEAD_BLOCKED',
      'calibration_version',r.calibration_version,
      'data_cutoff',r.data_cutoff
    );
  end if;

  if r.status <> 'CALIBRATED' then
    return jsonb_build_object(
      'apply_calibration',false,
      'status',r.status,
      'method','IDENTITY',
      'reason',coalesce(r.reason,'CALIBRATOR_NOT_OOS_APPROVED'),
      'calibration_version',r.calibration_version,
      'data_cutoff',r.data_cutoff,
      'n_oos',r.n_oos
    );
  end if;

  return jsonb_build_object(
    'apply_calibration',true,
    'status','CALIBRATED',
    'method',r.method,
    'calibration_version',r.calibration_version,
    'data_cutoff',r.data_cutoff,
    'n_oos',r.n_oos,
    'params',r.params
  );
end $$;

comment on table v2.calibration_registry_v1 is
'Versioned OOS calibration authority. No EV/Kelly/market edge. Calibrator may be applied only when status=CALIBRATED and data_cutoff<=decision_time.';

comment on function v2.fn_calibration_gate_v1(text,text,text,timestamptz) is
'Fail-closed calibration gate. IDENTITY whenever evidence is absent/early/rejected/insufficient or would introduce lookahead.';

-- RELEASE RULES (enforced by audit/runner, not inferred from UI):
-- 1) P_RETO_RAW is immutable and persisted.
-- 2) P_RETO_CAL is generated during snapshot build only, never recomputed on read.
-- 3) Soccer 1X2 calibration must preserve simplex exactly; no independent class curves without reconciliation.
-- 4) Binary calibrators are selected by nested walk-forward from IDENTITY/PLATT/BETA/ISOTONIC.
-- 5) A calibrator wins only with stable OOS improvement; otherwise method=IDENTITY.
-- 6) Market probability may be stored as benchmark evidence but cannot enter params or P_RETO_CAL.
-- 7) Fantasy uses POINT_DISTRIBUTION calibration (MAE/RMSE/interval coverage/sharpness), not Brier.