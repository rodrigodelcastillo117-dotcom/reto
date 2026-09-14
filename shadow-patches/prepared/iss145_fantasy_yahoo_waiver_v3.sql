-- ISS145: additive Fantasy Yahoo availability + exact B1 waiver board V3
-- Does not replace or mutate legacy Fantasy RPCs.

create table if not exists v2.fantasy_available_snapshot_v1 (
  id uuid primary key default gen_random_uuid(),
  league_id text not null,
  season integer not null,
  week integer not null,
  captured_at timestamptz not null,
  provider text not null,
  provider_player_id text,
  espn_player_id text,
  player_name text not null,
  position text,
  team text,
  acquisition_state text not null default 'AVAILABLE_UNSPECIFIED',
  source_verified boolean not null default false,
  identity_status text not null default 'UNRESOLVED',
  raw jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_fantasy_available_snapshot_v1_lookup
  on v2.fantasy_available_snapshot_v1(league_id,season,week,captured_at desc);

create or replace function v2.guard_fantasy_available_snapshot_v1()
returns trigger language plpgsql as $$
begin
  raise exception 'fantasy availability snapshots are immutable';
end $$;

drop trigger if exists trg_fantasy_available_snapshot_v1_immutable on v2.fantasy_available_snapshot_v1;
create trigger trg_fantasy_available_snapshot_v1_immutable
before update or delete on v2.fantasy_available_snapshot_v1
for each row execute function v2.guard_fantasy_available_snapshot_v1();

create or replace function v2.fantasy_lineup_eval_v3(
  p_players jsonb,
  p_season integer,
  p_week integer,
  p_asof timestamptz default now()
) returns jsonb
language sql stable
set search_path = public,v2,pg_temp
as $$
with src as (
  select
    x->>'espn_player_id' espn_player_id,
    coalesce(x->>'name',x->>'player_name',x->>'nombre') player_name,
    v2.fn_fantasy_pos_norm(coalesce(x->>'position',x->>'posicion','')) pos
  from jsonb_array_elements(coalesce(p_players,'[]'::jsonb)) x
  where nullif(x->>'espn_player_id','') is not null
), proj as (
  select s.*,p.projected_mean,p.floor_points,p.ceiling_points,p.n_history,p.model_status,p.quality_flag
  from src s
  cross join lateral v2.fn_fantasy_project_b1_rq80_v2(s.espn_player_id,s.pos,p_season,p_week,p_asof) p
  where s.pos in ('QB','RB','WR','TE') and p.model_status='READY'
), ranked as (
  select *,row_number() over(partition by pos order by projected_mean desc,player_name,espn_player_id) rn
  from proj
), core as (
  select * from ranked where (pos='QB' and rn<=1) or (pos='RB' and rn<=2) or (pos='WR' and rn<=2) or (pos='TE' and rn<=1)
), flex_pool as (
  select p.* from proj p
  where p.pos in ('RB','WR','TE')
    and not exists(select 1 from core c where c.espn_player_id=p.espn_player_id)
  order by p.projected_mean desc,p.player_name,p.espn_player_id
  limit 1
), chosen as (
  select 'CORE' slot_group,* from core
  union all
  select 'FLEX' slot_group,* from flex_pool
)
select jsonb_build_object(
  'ok',true,
  'model_version','fantasy-b1-rq80-2026.09.1',
  'lineup_total',round(coalesce(sum(projected_mean),0),2),
  'filled_slots',count(*),
  'complete',(count(*)=7),
  'lineup',coalesce(jsonb_agg(jsonb_build_object(
    'slot_group',slot_group,'espn_player_id',espn_player_id,'player_name',player_name,
    'position',pos,'projection',projected_mean,'floor',floor_points,'ceiling',ceiling_points,
    'n_history',n_history,'quality_flag',quality_flag
  ) order by case when slot_group='CORE' then 0 else 1 end,pos,projected_mean desc),'[]'::jsonb)
)
from chosen;
$$;

create or replace function v2.fantasy_waiver_board_v3(
  p_apodo text,
  p_league_id text,
  p_season integer,
  p_week integer,
  p_asof timestamptz default now()
) returns jsonb
language plpgsql stable security definer
set search_path = public,v2,pg_temp
as $$
declare
  v_roster jsonb;
  v_players jsonb;
  v_current jsonb;
  v_current_total numeric;
  v_capture timestamptz;
  v_rows jsonb := '[]'::jsonb;
  c record;
  d record;
  v_after jsonb;
  v_after_total numeric;
  v_best_total numeric;
  v_best_drop text;
  v_best_drop_name text;
  v_best_drop_proj numeric;
  v_cand_proj numeric;
  v_cand_floor numeric;
  v_cand_ceiling numeric;
  v_n integer;
  v_quality text;
  v_status text;
  v_new_players jsonb;
begin
  select v2.fn_fantasy_roster_canonicalize_v1(r.jugadores,p_season,p_week)
    into v_roster
  from public.fantasy_roster_semanal r
  where r.apodo=p_apodo and r.temporada=p_season and r.semana<=p_week
  order by r.semana desc,r.guardado_at desc limit 1;

  if v_roster is null then
    return jsonb_build_object('ok',false,'status','ROSTER_NOT_FOUND');
  end if;

  select jsonb_agg(jsonb_build_object(
    'espn_player_id',x->>'espn_player_id','name',coalesce(x->>'nombre',x->>'name'),
    'position',v2.fn_fantasy_pos_norm(coalesce(x->>'posicion',x->>'position',''))
  )) into v_players
  from jsonb_array_elements(v_roster) x
  where nullif(x->>'espn_player_id','') is not null
    and v2.fn_fantasy_pos_norm(coalesce(x->>'posicion',x->>'position','')) in ('QB','RB','WR','TE');

  v_current := v2.fantasy_lineup_eval_v3(v_players,p_season,p_week,p_asof);
  v_current_total := nullif(v_current->>'lineup_total','')::numeric;
  if coalesce((v_current->>'complete')::boolean,false)=false then
    return jsonb_build_object('ok',true,'status','CURRENT_LINEUP_INCOMPLETE','current',v_current);
  end if;

  select max(captured_at) into v_capture
  from v2.fantasy_available_snapshot_v1
  where league_id=p_league_id and season=p_season and week=p_week and source_verified;
  if v_capture is null then
    return jsonb_build_object('ok',true,'status','AVAILABILITY_NOT_CONNECTED','league_id',p_league_id);
  end if;

  for c in
    select distinct on (coalesce(espn_player_id,provider_player_id)) *
    from v2.fantasy_available_snapshot_v1
    where league_id=p_league_id and season=p_season and week=p_week
      and captured_at=v_capture and source_verified
    order by coalesce(espn_player_id,provider_player_id),id desc
  loop
    if c.espn_player_id is null or v2.fn_fantasy_pos_norm(coalesce(c.position,'')) not in ('QB','RB','WR','TE') then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'player',c.player_name,'position',c.position,'team',c.team,'provider_player_id',c.provider_player_id,
        'status','IDENTITY_OR_POSITION_UNSUPPORTED','recommended',false));
      continue;
    end if;

    select p.projected_mean,p.floor_points,p.ceiling_points,p.n_history,p.quality_flag,p.model_status
      into v_cand_proj,v_cand_floor,v_cand_ceiling,v_n,v_quality,v_status
    from v2.fn_fantasy_project_b1_rq80_v2(c.espn_player_id,v2.fn_fantasy_pos_norm(c.position),p_season,p_week,p_asof) p;

    if v_status is distinct from 'READY' then
      v_rows := v_rows || jsonb_build_array(jsonb_build_object(
        'player',c.player_name,'position',c.position,'team',c.team,'espn_player_id',c.espn_player_id,
        'status',coalesce(v_status,'MODEL_UNAVAILABLE'),'recommended',false,'model_version','fantasy-b1-rq80-2026.09.1'));
      continue;
    end if;

    v_best_total := null; v_best_drop := null; v_best_drop_name := null; v_best_drop_proj := null;
    for d in
      select x->>'espn_player_id' espn_player_id,x->>'name' player_name,x->>'position' pos
      from jsonb_array_elements(v_players) x
    loop
      select coalesce(jsonb_agg(e),'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
        'espn_player_id',c.espn_player_id,'name',c.player_name,'position',v2.fn_fantasy_pos_norm(c.position)))
        into v_new_players
      from jsonb_array_elements(v_players) e
      where e->>'espn_player_id' <> d.espn_player_id;

      v_after := v2.fantasy_lineup_eval_v3(v_new_players,p_season,p_week,p_asof);
      if coalesce((v_after->>'complete')::boolean,false) then
        v_after_total := nullif(v_after->>'lineup_total','')::numeric;
        if v_best_total is null or v_after_total > v_best_total then
          v_best_total := v_after_total; v_best_drop := d.espn_player_id; v_best_drop_name := d.player_name;
          select p.projected_mean into v_best_drop_proj
          from v2.fn_fantasy_project_b1_rq80_v2(d.espn_player_id,d.pos,p_season,p_week,p_asof) p;
        end if;
      end if;
    end loop;

    v_rows := v_rows || jsonb_build_array(jsonb_build_object(
      'player',c.player_name,'position',v2.fn_fantasy_pos_norm(c.position),'team',c.team,
      'espn_player_id',c.espn_player_id,'provider_player_id',c.provider_player_id,
      'acquisition_state',c.acquisition_state,
      'projection',v_cand_proj,'floor',v_cand_floor,'ceiling',v_cand_ceiling,'n_history',v_n,'quality_flag',v_quality,
      'drop_player',v_best_drop_name,'drop_player_id',v_best_drop,'drop_projection',v_best_drop_proj,
      'lineup_before',v_current_total,'lineup_after',v_best_total,
      'lineup_delta',round(coalesce(v_best_total,v_current_total)-v_current_total,2),
      'bench_value_delta',round(coalesce(v_cand_proj,0)-coalesce(v_best_drop_proj,0),2),
      'status',case when v_quality='LOW_SAMPLE' then 'CAUTION_LOW_SAMPLE'
                    when coalesce(v_best_total,v_current_total)-v_current_total >= 0.50 then 'STARTER_UPGRADE'
                    when coalesce(v_cand_proj,0)-coalesce(v_best_drop_proj,0) >= 1.00 then 'DEPTH_UPGRADE'
                    else 'NO_MATERIAL_GAIN' end,
      'recommended',(v_quality<>'LOW_SAMPLE' and (coalesce(v_best_total,v_current_total)-v_current_total >= 0.50 or coalesce(v_cand_proj,0)-coalesce(v_best_drop_proj,0) >= 1.00)),
      'model_version','fantasy-b1-rq80-2026.09.1'
    ));
  end loop;

  return jsonb_build_object(
    'ok',true,'status','READY','contract_version','fantasy_waiver_board_v3',
    'league_id',p_league_id,'season',p_season,'week',p_week,'availability_snapshot_at',v_capture,
    'current_lineup',v_current,
    'candidates',(select coalesce(jsonb_agg(x order by
      coalesce((x->>'recommended')::boolean,false) desc,
      coalesce((x->>'lineup_delta')::numeric,-999) desc,
      coalesce((x->>'bench_value_delta')::numeric,-999) desc,
      x->>'player'),'[]'::jsonb) from jsonb_array_elements(v_rows) x),
    'principles',jsonb_build_object('one_brain','fantasy-b1-rq80-2026.09.1','verified_availability_only',true,'cold_start_invented',false,'acquisition_subtype_invented',false)
  );
end $$;

grant select on v2.fantasy_available_snapshot_v1 to authenticated;
grant execute on function v2.fantasy_waiver_board_v3(text,text,integer,integer,timestamptz) to authenticated;
grant execute on function v2.fantasy_lineup_eval_v3(jsonb,integer,integer,timestamptz) to authenticated;
