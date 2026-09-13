-- ISS130c — hardening discovered by disposable execution. STAGED / NO PROD MUTATION.
-- Depends on ISS130b.

-- 1) Qualify model/config columns so PL/pgSQL OUT variables never shadow table columns.
create or replace function v2.fn_fantasy_project_b1_rq80_v2(
  p_player_id text,p_position text,p_season int,p_week int,p_decision_time timestamptz
) returns table(
  model_version text,projected_mean numeric,floor_points numeric,ceiling_points numeric,
  uncertainty numeric,n_history int,cold_start boolean,feature_data_asof timestamptz,
  model_status text,quality_flag text,provenance jsonb
) language plpgsql stable as $$
declare
  cfg v2.fantasy_model_config_v2%rowtype;
  cal v2.fantasy_residual_calibration_v2%rowtype;
  v_mean numeric; v_n int; v_asof timestamptz;
begin
  select c.* into cfg
  from v2.fantasy_model_config_v2 c
  where c.model_version='fantasy-b1-rq80-2026.09.1';
  model_version:=cfg.model_version;

  if cfg.model_version is null or not cfg.publish_authorized then
    model_status:='MODEL_NOT_AUTHORIZED'; quality_flag:='BLOCKED'; return next; return;
  end if;
  if p_season<>2026 then
    model_status:='MODEL_SEASON_UNSUPPORTED'; quality_flag:='BLOCKED'; return next; return;
  end if;
  if p_decision_time is null or p_decision_time<cfg.training_data_sealed_at then
    model_status:='NO_TEMPORAL_DECISION'; quality_flag:='BLOCKED'; return next; return;
  end if;

  select r.* into cal
  from v2.fantasy_residual_calibration_v2 r
  where r.model_version=cfg.model_version and r.position=upper(p_position);
  if cal.position is null then
    model_status:='UNSUPPORTED_POSITION'; quality_flag:='BLOCKED'; return next; return;
  end if;

  with hist as (
    select f.actual_points::numeric as pts,cfg.training_data_sealed_at as available_at
    from public.lab_ff_playerweek f
    where f.espn_player_id=p_player_id
      and f.status in ('PLAYED','ACTIVE_ZERO_USAGE')
      and f.actual_points is not null
    union all
    select s.actual_points::numeric,s.graded_at
    from public.v_lab_ff_official_snapshot s
    where s.espn_player_id=p_player_id
      and s.temporada=p_season
      and s.semana<p_week
      and s.actual_points is not null
      and s.graded_at is not null
      and s.graded_at<=p_decision_time
  )
  select count(*)::int,avg(h.pts),max(h.available_at)
    into v_n,v_mean,v_asof
  from hist h;

  n_history:=coalesce(v_n,0);
  cold_start:=(coalesce(v_n,0)=0);
  feature_data_asof:=coalesce(v_asof,cfg.training_data_sealed_at);

  if cold_start then
    model_status:='COLD_START_UNVALIDATED'; quality_flag:='BLOCKED';
    provenance:=jsonb_build_object(
      'reason','no NFL player history; position prior intentionally not release-authorized',
      'market_used',false
    );
    return next; return;
  end if;

  projected_mean:=round(v_mean,2);
  floor_points:=round(v_mean+cal.q10_residual,2);
  ceiling_points:=round(v_mean+cal.q90_residual,2);
  uncertainty:=round((cal.q90_residual-cal.q10_residual)/2.0,2);
  model_status:='READY';
  quality_flag:=case when v_n<4 then 'LOW_SAMPLE' else 'OK' end;
  provenance:=jsonb_build_object(
    'brain','B1_POOLED_PLAYER_PPR',
    'training_season',2025,
    'inseason_rule','graded prior weeks only',
    'interval','position residual q10/q90',
    'n_history',v_n,
    'feature_data_asof',feature_data_asof,
    'market_used',false
  );
  return next;
end $$;

-- 2) A blocked late/no-schedule row is legitimate audit evidence. Only READY rows
-- must satisfy a real pre-kickoff decision. This prevents one already-started game
-- from aborting the entire roster snapshot while preserving fail-close semantics.
alter table v2.fantasy_projection_snapshot_v2
  drop constraint if exists fantasy_snapshot_v2_temporal_ck;
alter table v2.fantasy_projection_snapshot_v2
  add constraint fantasy_snapshot_v2_temporal_ck
  check (model_status <> 'READY' or (kickoff is not null and decision_time < kickoff));
