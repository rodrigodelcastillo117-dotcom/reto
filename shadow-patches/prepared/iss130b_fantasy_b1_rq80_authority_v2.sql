-- ============================================================================
-- ISS130b — NFL FANTASY CANONICAL AUTHORITY V2 · STAGED / NO PROD MUTATION
-- Supersedes ISS130 after disposable audit found an incompatible old table using
-- the same snapshot name. ONE BRAIN authority uses *_v2 objects below.
-- ============================================================================

create schema if not exists v2;

create table if not exists v2.fantasy_model_config_v2 (
  model_version text primary key,
  scoring_config_version text not null,
  training_season int not null,
  training_data_sealed_at timestamptz not null,
  validation_status text not null,
  publish_authorized boolean not null default false,
  release_scope text not null,
  cold_start_authorized boolean not null default false,
  evidence jsonb not null,
  sealed_at timestamptz not null default now(),
  constraint fantasy_model_v2_publish_ck check(
    publish_authorized=false or validation_status='TEMPORAL_HOLDOUT_VALIDATED'
  )
);

create table if not exists v2.fantasy_residual_calibration_v2 (
  model_version text not null references v2.fantasy_model_config_v2(model_version),
  position text not null check(position in ('QB','RB','WR','TE')),
  q10_residual numeric not null,
  q90_residual numeric not null,
  n_cal int not null,
  n_holdout int not null,
  holdout_coverage_pct numeric not null,
  holdout_bias numeric not null,
  holdout_mae numeric not null,
  primary key(model_version,position),
  constraint fantasy_cal_v2_interval_ck check(q10_residual<q90_residual)
);

create or replace function v2.fn_fantasy_authority_v2_immutable()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' or to_jsonb(new) is distinct from to_jsonb(old) then
    raise exception 'FANTASY_V2_AUTHORITY_IMMUTABLE: use a new version';
  end if;
  return new;
end $$;

drop trigger if exists trg_fantasy_model_config_v2_immutable on v2.fantasy_model_config_v2;
create trigger trg_fantasy_model_config_v2_immutable
before update or delete on v2.fantasy_model_config_v2
for each row execute function v2.fn_fantasy_authority_v2_immutable();

drop trigger if exists trg_fantasy_residual_cal_v2_immutable on v2.fantasy_residual_calibration_v2;
create trigger trg_fantasy_residual_cal_v2_immutable
before update or delete on v2.fantasy_residual_calibration_v2
for each row execute function v2.fn_fantasy_authority_v2_immutable();

insert into v2.fantasy_model_config_v2(
  model_version,scoring_config_version,training_season,training_data_sealed_at,
  validation_status,publish_authorized,release_scope,cold_start_authorized,evidence
) values (
  'fantasy-b1-rq80-2026.09.1','PPR_FULL_v1',2025,'2026-09-07 01:43:10.822271+00',
  'TEMPORAL_HOLDOUT_VALIDATED',true,'QB_RB_WR_TE_ESTABLISHED_ONLY',false,
  jsonb_build_object(
    'temporal_recompute','6400/6400 exact B1 matches; n_prev mismatch=0; B1 mismatch=0',
    'aggregate_mae',jsonb_build_object('QB',6.482,'RB',4.715,'WR',4.345,'TE',3.033),
    'challenger_result','B1 beats EWMA3 all positions; beats last3 RB/WR/TE; QB-vs-last3 CI crosses zero',
    'interval_calibration','q10/q90 residuals fit weeks 2-9, validated weeks 10-18',
    'holdout_coverage_pct',jsonb_build_object('QB',82.5,'RB',81.6,'WR',79.4,'TE',82.1),
    'holdout_bias',jsonb_build_object('QB',-0.08,'RB',0.43,'WR',-0.24,'TE',0.14),
    'market_used',false,
    'forward_2026_note','pregame captures exist; no graded live-forward outcomes at seal, so claim is temporal historical holdout validation only'
  )
) on conflict(model_version) do nothing;

insert into v2.fantasy_residual_calibration_v2 values
 ('fantasy-b1-rq80-2026.09.1','QB',-10.37,11.45,267,338,82.5,-0.08,6.46),
 ('fantasy-b1-rq80-2026.09.1','RB', -6.48, 9.70,596,716,81.6, 0.43,4.63),
 ('fantasy-b1-rq80-2026.09.1','TE', -4.27, 7.10,676,820,82.1, 0.14,2.91),
 ('fantasy-b1-rq80-2026.09.1','WR', -6.25, 8.60,1102,1287,79.4,-0.24,4.26)
on conflict(model_version,position) do nothing;

create or replace function v2.fn_fantasy_release_allowed_v2(
  p_model_version text,p_position text,p_cold_start boolean
) returns boolean language sql stable as $$
  select coalesce((
    select c.publish_authorized
       and c.validation_status='TEMPORAL_HOLDOUT_VALIDATED'
       and upper(p_position) in ('QB','RB','WR','TE')
       and (not coalesce(p_cold_start,true) or c.cold_start_authorized)
    from v2.fantasy_model_config_v2 c
    where c.model_version=p_model_version
  ),false);
$$;

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
  select * into cfg from v2.fantasy_model_config_v2
   where model_version='fantasy-b1-rq80-2026.09.1';
  model_version:=cfg.model_version;
  if cfg.model_version is null or not cfg.publish_authorized then
    model_status:='MODEL_NOT_AUTHORIZED';quality_flag:='BLOCKED';return next;return;
  end if;
  if p_season<>2026 then
    model_status:='MODEL_SEASON_UNSUPPORTED';quality_flag:='BLOCKED';return next;return;
  end if;
  if p_decision_time is null or p_decision_time<cfg.training_data_sealed_at then
    model_status:='NO_TEMPORAL_DECISION';quality_flag:='BLOCKED';return next;return;
  end if;
  select * into cal from v2.fantasy_residual_calibration_v2
   where model_version=cfg.model_version and position=upper(p_position);
  if cal.position is null then
    model_status:='UNSUPPORTED_POSITION';quality_flag:='BLOCKED';return next;return;
  end if;

  with hist as (
    -- 2025 corpus was frozen before the 2026 season decision horizon.
    select f.actual_points::numeric pts,cfg.training_data_sealed_at available_at
    from public.lab_ff_playerweek f
    where f.espn_player_id=p_player_id
      and f.status in ('PLAYED','ACTIVE_ZERO_USAGE') and f.actual_points is not null
    union all
    -- In-season adaptation can use only earlier-week outcomes graded by decision_time.
    select s.actual_points::numeric,s.graded_at
    from public.v_lab_ff_official_snapshot s
    where s.espn_player_id=p_player_id and s.temporada=p_season
      and s.semana<p_week and s.actual_points is not null
      and s.graded_at is not null and s.graded_at<=p_decision_time
  )
  select count(*)::int,avg(pts),max(available_at)
    into v_n,v_mean,v_asof from hist;

  n_history:=coalesce(v_n,0);
  cold_start:=(coalesce(v_n,0)=0);
  feature_data_asof:=coalesce(v_asof,cfg.training_data_sealed_at);
  if cold_start then
    model_status:='COLD_START_UNVALIDATED';quality_flag:='BLOCKED';
    provenance:=jsonb_build_object('reason','no NFL player history; position prior intentionally not release-authorized','market_used',false);
    return next;return;
  end if;

  projected_mean:=round(v_mean,2);
  floor_points:=round(v_mean+cal.q10_residual,2);
  ceiling_points:=round(v_mean+cal.q90_residual,2);
  uncertainty:=round((cal.q90_residual-cal.q10_residual)/2.0,2);
  model_status:='READY';
  quality_flag:=case when v_n<4 then 'LOW_SAMPLE' else 'OK' end;
  provenance:=jsonb_build_object(
    'brain','B1_POOLED_PLAYER_PPR','training_season',2025,
    'inseason_rule','graded prior weeks only','interval','position residual q10/q90',
    'n_history',v_n,'feature_data_asof',feature_data_asof,'market_used',false
  );
  return next;
end $$;

create table if not exists v2.fantasy_projection_snapshot_v2 (
  projection_snapshot_id uuid primary key default gen_random_uuid(),
  espn_player_id text,
  player_name text not null,
  position text not null,
  team text,
  opponent text,
  espn_event_id text,
  season int not null,
  week int not null,
  roster_slot text,
  decision_time timestamptz not null,
  kickoff timestamptz,
  model_version text not null,
  scoring_config_version text not null,
  projected_mean numeric,
  floor_points numeric,
  ceiling_points numeric,
  uncertainty numeric,
  n_history int not null default 0,
  cold_start boolean not null default true,
  feature_data_asof timestamptz,
  availability_status text,
  model_status text not null,
  quality_flag text,
  identity_status text not null,
  provenance jsonb not null default '{}'::jsonb,
  built_at timestamptz not null default now(),
  unique(player_name,team,season,week,decision_time,model_version),
  constraint fantasy_snapshot_v2_temporal_ck check(kickoff is null or decision_time<kickoff),
  constraint fantasy_snapshot_v2_ready_ck check(
    model_status<>'READY' or (
      espn_player_id is not null and projected_mean is not null and floor_points is not null
      and ceiling_points is not null and feature_data_asof is not null
      and feature_data_asof<=decision_time and cold_start=false and kickoff is not null
    )
  )
);

create or replace function v2.fn_fantasy_snapshot_v2_immutable()
returns trigger language plpgsql as $$
begin
  if tg_op='DELETE' or to_jsonb(new) is distinct from to_jsonb(old) then
    raise exception 'FANTASY_PROJECTION_SNAPSHOT_V2_IMMUTABLE';
  end if;
  return new;
end $$;

drop trigger if exists trg_fantasy_projection_snapshot_v2_immutable on v2.fantasy_projection_snapshot_v2;
create trigger trg_fantasy_projection_snapshot_v2_immutable
before update or delete on v2.fantasy_projection_snapshot_v2
for each row execute function v2.fn_fantasy_snapshot_v2_immutable();

create or replace function v2.build_fantasy_projection_snapshot_v2(
  p_apodo text,p_season int,p_week int,p_decision_time timestamptz
) returns integer language plpgsql as $$
declare
  v_roster jsonb; j jsonb;
  v_pid text;v_id_count int;v_pos text;v_team text;v_name text;v_slot text;v_identity text;
  v_event text;v_kickoff timestamptz;v_opp text;v_avail text;
  v_model text;v_mean numeric;v_floor numeric;v_ceil numeric;v_unc numeric;v_nhist int;
  v_cold boolean;v_data_asof timestamptz;v_pstatus text;v_qflag text;v_prov jsonb;
  v_final_status text;v_n int:=0;
begin
  select fr.jugadores into v_roster
  from public.fantasy_roster_semanal fr
  where fr.apodo=p_apodo and fr.temporada=p_season and fr.semana=p_week
  order by fr.guardado_at desc limit 1;
  if v_roster is null then return 0; end if;

  for j in select value from jsonb_array_elements(v_roster) loop
    v_name:=j->>'nombre';v_pos:=upper(coalesce(j->>'posicion',''));v_team:=upper(j->>'equipo');v_slot:=upper(j->>'slot');
    v_pid:=nullif(j->>'espn_player_id','');v_identity:='EXPLICIT_ID';

    if v_pid is null and v_pos in ('QB','RB','WR','TE','FB','K','PK') then
      select count(*),min(n.espn_player_id) into v_id_count,v_pid
      from public.nfl_jugadores n
      where lower(n.nombre)=lower(v_name) and upper(n.equipo)=v_team;
      if v_id_count=1 then v_identity:='RESOLVED_NAME_TEAM';else v_pid:=null;v_identity:='UNRESOLVED';end if;
    elsif v_pid is null then
      v_identity:='UNSUPPORTED_TEAM_ENTITY';
    end if;

    select c.espn_event_id,c.fecha,c.rival into v_event,v_kickoff,v_opp
    from public.nfl_calendario_equipo c
    where c.temporada=p_season and c.semana=p_week and c.equipo=v_team
    order by c.fecha limit 1;

    v_avail:=null;
    if v_pid is not null then
      select s.availability_status into v_avail
      from public.v_lab_ff_official_snapshot s
      where s.espn_player_id=v_pid and s.temporada=p_season and s.semana=p_week
        and s.captured_at<=p_decision_time
      order by s.captured_at desc limit 1;
    end if;

    v_model:='fantasy-b1-rq80-2026.09.1';v_mean:=null;v_floor:=null;v_ceil:=null;v_unc:=null;
    v_nhist:=0;v_cold:=true;v_data_asof:=null;v_pstatus:='NO_PROJECTION';v_qflag:='BLOCKED';v_prov:='{}'::jsonb;
    if v_pid is not null and v_pos in ('QB','RB','WR','TE') then
      select p.model_version,p.projected_mean,p.floor_points,p.ceiling_points,p.uncertainty,
             p.n_history,p.cold_start,p.feature_data_asof,p.model_status,p.quality_flag,p.provenance
      into v_model,v_mean,v_floor,v_ceil,v_unc,v_nhist,v_cold,v_data_asof,v_pstatus,v_qflag,v_prov
      from v2.fn_fantasy_project_b1_rq80_v2(v_pid,v_pos,p_season,p_week,p_decision_time) p;
    end if;

    v_final_status:=case
      when v_identity in ('UNRESOLVED','UNSUPPORTED_TEAM_ENTITY') then 'IDENTITY_BLOCKED'
      when v_kickoff is null then 'NO_SCHEDULE'
      when p_decision_time>=v_kickoff then 'LATE_DECISION_BLOCKED'
      when upper(coalesce(v_avail,''))='OUT' then 'UNAVAILABLE_OUT'
      when v_pos not in ('QB','RB','WR','TE') then 'UNSUPPORTED_POSITION'
      else coalesce(v_pstatus,'NO_PROJECTION') end;

    if v_final_status<>'READY' then
      v_mean:=null;v_floor:=null;v_ceil:=null;v_unc:=null;
    end if;

    insert into v2.fantasy_projection_snapshot_v2(
      espn_player_id,player_name,position,team,opponent,espn_event_id,season,week,roster_slot,
      decision_time,kickoff,model_version,scoring_config_version,projected_mean,floor_points,
      ceiling_points,uncertainty,n_history,cold_start,feature_data_asof,availability_status,
      model_status,quality_flag,identity_status,provenance
    ) values (
      v_pid,v_name,v_pos,v_team,v_opp,v_event,p_season,p_week,v_slot,p_decision_time,v_kickoff,
      coalesce(v_model,'fantasy-b1-rq80-2026.09.1'),'PPR_FULL_v1',v_mean,v_floor,v_ceil,v_unc,
      coalesce(v_nhist,0),coalesce(v_cold,true),v_data_asof,v_avail,v_final_status,v_qflag,v_identity,
      coalesce(v_prov,'{}'::jsonb)||jsonb_build_object('availability_status',coalesce(v_avail,'UNKNOWN'),'identity_status',v_identity)
    ) on conflict(player_name,team,season,week,decision_time,model_version) do nothing;
    v_n:=v_n+1;
  end loop;
  return v_n;
end $$;

create or replace view v2.v_fantasy_canonical_projections_v2 as
select s.*
from v2.fantasy_projection_snapshot_v2 s
where s.model_status='READY'
  and v2.fn_fantasy_release_allowed_v2(s.model_version,s.position,s.cold_start)
  and s.feature_data_asof<=s.decision_time
  and s.decision_time<s.kickoff;

create or replace function public.v_prediccion_reto_fantasy(
  p_semana integer default null,p_temporada integer default null
) returns table(
  canonical_player_id text,jugador text,posicion text,equipo text,semana integer,temporada integer,
  proyeccion_mean numeric,piso numeric,techo numeric,incertidumbre numeric,rival text,
  model_version text,model_status text,quality_flag text,availability_status text,
  identity_status text,data_asof timestamptz
) language sql stable security definer set search_path = public,v2 as $$
  with latest as (
    select distinct on (s.player_name,s.team,s.season,s.week) s.*
    from v2.fantasy_projection_snapshot_v2 s
    where (p_semana is null or s.week=p_semana)
      and (p_temporada is null or s.season=p_temporada)
    order by s.player_name,s.team,s.season,s.week,s.decision_time desc,s.built_at desc
  )
  select l.espn_player_id,l.player_name,l.position,l.team,l.week,l.season,
    case when l.model_status='READY' and v2.fn_fantasy_release_allowed_v2(l.model_version,l.position,l.cold_start) then l.projected_mean end,
    case when l.model_status='READY' and v2.fn_fantasy_release_allowed_v2(l.model_version,l.position,l.cold_start) then l.floor_points end,
    case when l.model_status='READY' and v2.fn_fantasy_release_allowed_v2(l.model_version,l.position,l.cold_start) then l.ceiling_points end,
    case when l.model_status='READY' and v2.fn_fantasy_release_allowed_v2(l.model_version,l.position,l.cold_start) then l.uncertainty end,
    l.opponent,l.model_version,l.model_status,l.quality_flag,l.availability_status,l.identity_status,l.feature_data_asof
  from latest l;
$$;
