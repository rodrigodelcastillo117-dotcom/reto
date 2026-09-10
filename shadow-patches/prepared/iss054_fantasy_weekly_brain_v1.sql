-- iss054 — NFL FANTASY WEEKLY BRAIN v1 · STAGED / NO PROD CUTOVER
-- Purpose: own weekly PPR projections for Remix Reto 13M Fantasy.
-- Historical PPR/usage are FEATURES, never relabeled as the projection itself.
-- Current role/injury/schedule are point-in-time inputs. Market odds are not used.

create schema if not exists v2;

create table if not exists v2.fantasy_projection_snapshot (
  projection_snapshot_id uuid not null default gen_random_uuid(),
  season int not null,
  week int not null,
  espn_event_id text not null,
  kickoff timestamptz not null,
  decision_time timestamptz not null,
  espn_player_id text not null,
  player_name text not null,
  team text not null,
  opponent text,
  position text not null,
  depth_order int,
  injury_status text,
  sample_games int,
  base_season_ppr numeric,
  base_recent_ppr numeric,
  target_share numeric,
  rz5_share numeric,
  matchup_factor numeric,
  role_factor numeric,
  availability_factor numeric,
  projection_floor numeric,
  projection_median numeric,
  projection_ceiling numeric,
  uncertainty numeric,
  confidence_score int,
  projection_status text not null,
  feature_snapshot jsonb not null,
  feature_asof timestamptz not null,
  model_version text not null default 'fantasy_weekly_v1',
  built_at timestamptz not null default now(),
  primary key (season, week, espn_player_id, decision_time, model_version),
  constraint fantasy_projection_time_ck check (decision_time < kickoff),
  constraint fantasy_projection_band_ck check (
    (projection_floor is null and projection_median is null and projection_ceiling is null)
    or (projection_floor >= 0 and projection_floor <= projection_median and projection_median <= projection_ceiling)
  ),
  constraint fantasy_projection_status_ck check (projection_status in
    ('PROJECTED','BYE','OUT','LOCKED_NO_SNAPSHOT','DATA_INCOMPLETE'))
);

create or replace function v2.tg_fantasy_projection_immutable()
returns trigger language plpgsql as $$
begin
  raise exception 'fantasy_projection_snapshot is immutable';
end $$;

drop trigger if exists fantasy_projection_snapshot_immutable on v2.fantasy_projection_snapshot;
create trigger fantasy_projection_snapshot_immutable
before update or delete on v2.fantasy_projection_snapshot
for each row execute function v2.tg_fantasy_projection_immutable();

create or replace function v2.fn_fantasy_injury_factor(p_status text)
returns numeric language sql immutable as $$
  select case lower(coalesce(p_status,''))
    when 'active' then 1.00
    when 'questionable' then 0.84
    when 'doubtful' then 0.35
    when 'out' then 0.00
    when 'inactive' then 0.00
    when 'ir' then 0.00
    when 'ir-r' then 0.00
    when 'pup-r' then 0.00
    when 'nfi-r' then 0.00
    when 'reserve-sus' then 0.00
    when 'reserve-cel' then 0.00
    when 'reserve-dnr' then 0.00
    else 0.95
  end;
$$;

create or replace function v2.fn_fantasy_role_factor(p_position text, p_depth_order int)
returns numeric language sql immutable as $$
  select case upper(coalesce(p_position,''))
    when 'QB' then case coalesce(p_depth_order,99) when 1 then 1.00 else 0.00 end
    when 'RB' then case coalesce(p_depth_order,99) when 1 then 1.04 when 2 then 0.92 when 3 then 0.72 when 4 then 0.55 else 0.88 end
    when 'WR' then case coalesce(p_depth_order,99) when 1 then 1.02 when 2 then 1.00 when 3 then 0.94 when 4 then 0.78 else 0.90 end
    when 'TE' then case coalesce(p_depth_order,99) when 1 then 1.02 when 2 then 0.78 when 3 then 0.60 else 0.88 end
    when 'K'  then case coalesce(p_depth_order,99) when 1 then 1.00 else 0.00 end
    else 1.00
  end;
$$;

create or replace function v2.build_fantasy_projection_week(
  p_season int,
  p_week int,
  p_decision_time timestamptz default now(),
  p_model_version text default 'fantasy_weekly_v1'
) returns jsonb
language plpgsql security definer
set search_path to public,v2
as $$
declare
  v_inserted int := 0;
begin
  if p_season is null or p_week is null or p_week < 1 or p_week > 22 then
    raise exception 'invalid season/week';
  end if;

  with schedule as (
    select c.espn_event_id,c.fecha kickoff,c.equipo team,c.rival opponent,
           public.nfl_equipo_en_bye(c.equipo,p_week,p_season) en_bye
    from public.nfl_calendario_equipo c
    where c.temporada=p_season and c.semana=p_week
  ),
  depth as (
    select distinct on (d.espn_player_id)
      d.espn_player_id,d.equipo,d.posicion,d.orden,d.cargado_at
    from public.nfl_depth_chart d
    where d.temporada=p_season and d.cargado_at <= p_decision_time
    order by d.espn_player_id,d.cargado_at desc,d.orden
  ),
  injury as (
    select distinct on (i.espn_player_id)
      i.espn_player_id,i.estado,i.lesion,i.nota,i.cargado_at
    from public.nfl_lesiones_semana i
    where i.temporada=p_season and i.semana=p_week and i.cargado_at <= p_decision_time
    order by i.espn_player_id,i.cargado_at desc
  ),
  dvp0 as (
    select d.*,
           avg(d.ppr_permitidos_pg) over(partition by d.posicion) pos_avg
    from public.nfl_defensa_vs_posicion_ppr d
    where d.temporada=(select max(x.temporada) from public.nfl_defensa_vs_posicion_ppr x where x.temporada <= p_season)
  ),
  base as (
    select j.espn_player_id,j.nombre player_name,j.posicion position,j.equipo team,
           s.espn_event_id,s.kickoff,s.opponent,coalesce(s.en_bye,false) en_bye,
           dep.orden depth_order,dep.cargado_at depth_asof,
           inj.estado injury_status,inj.lesion,inj.nota,inj.cargado_at injury_asof,
           u.juegos sample_games,u.ppr_pg base_season_ppr,
           coalesce(j.ppr_reg_ult5,u.ppr_p50,u.ppr_pg) base_recent_ppr,
           u.ppr_sd,u.target_share,u.rz5_share,u.cargado_at usage_asof,
           dvp.ppr_permitidos_pg,dvp.pos_avg
    from public.nfl_jugadores j
    join schedule s on s.team=j.equipo
    left join depth dep on dep.espn_player_id=j.espn_player_id
    left join injury inj on inj.espn_player_id=j.espn_player_id
    left join public.nfl_uso_jugador u on u.espn_player_id=j.espn_player_id and u.temporada=p_season-1
    left join dvp0 dvp on dvp.equipo_defensa=s.opponent and dvp.posicion=j.posicion
    where j.espn_player_id is not null
      and upper(j.posicion) in ('QB','RB','WR','TE')
      and s.kickoff > p_decision_time
  ),
  f as (
    select b.*,
      case when coalesce(b.pos_avg,0)>0 and b.ppr_permitidos_pg is not null
           then greatest(0.85::numeric,least(1.15::numeric,1 + 0.35*((b.ppr_permitidos_pg/b.pos_avg)-1)))
           else 1.00::numeric end matchup_factor,
      v2.fn_fantasy_role_factor(b.position,b.depth_order) role_factor,
      v2.fn_fantasy_injury_factor(b.injury_status) availability_factor,
      case
        when b.base_season_ppr is not null and b.base_recent_ppr is not null then 0.55*b.base_season_ppr + 0.45*b.base_recent_ppr
        when b.base_season_ppr is not null then b.base_season_ppr
        else b.base_recent_ppr
      end base_blend
    from base b
  ),
  calc as (
    select f.*,
      case when f.en_bye then 0
           when lower(coalesce(f.injury_status,'')) in ('out','inactive','ir','ir-r','pup-r','nfi-r','reserve-sus','reserve-cel','reserve-dnr') then 0
           when coalesce(f.sample_games,0) < 3 or f.base_blend is null then null
           else greatest(0, f.base_blend*f.matchup_factor*f.role_factor*f.availability_factor)
      end proj,
      greatest(2.5::numeric,coalesce(f.ppr_sd,6.0)) *
        (case when coalesce(f.sample_games,0)<8 then 1.25 else 1.0 end) *
        (case when lower(coalesce(f.injury_status,''))='questionable' then 1.20 else 1.0 end) *
        (case when coalesce((select cambio_equipo from public.nfl_jugadores j2 where j2.espn_player_id=f.espn_player_id),false) then 1.15 else 1.0 end) as unc,
      greatest(f.usage_asof,coalesce(f.depth_asof,'epoch'::timestamptz),coalesce(f.injury_asof,'epoch'::timestamptz)) feature_asof
    from f
  )
  insert into v2.fantasy_projection_snapshot(
    season,week,espn_event_id,kickoff,decision_time,espn_player_id,player_name,team,opponent,position,
    depth_order,injury_status,sample_games,base_season_ppr,base_recent_ppr,target_share,rz5_share,
    matchup_factor,role_factor,availability_factor,projection_floor,projection_median,projection_ceiling,
    uncertainty,confidence_score,projection_status,feature_snapshot,feature_asof,model_version)
  select p_season,p_week,c.espn_event_id,c.kickoff,p_decision_time,c.espn_player_id,c.player_name,c.team,c.opponent,c.position,
    c.depth_order,c.injury_status,c.sample_games,c.base_season_ppr,c.base_recent_ppr,c.target_share,c.rz5_share,
    round(c.matchup_factor,4),round(c.role_factor,4),round(c.availability_factor,4),
    case when c.proj is null then null else round(greatest(0,c.proj-0.90*c.unc),1) end,
    case when c.proj is null then null else round(c.proj,1) end,
    case when c.proj is null then null else round(c.proj+1.10*c.unc,1) end,
    case when c.proj is null then null else round(c.unc,2) end,
    greatest(0,least(100,
      35 + least(35,coalesce(c.sample_games,0)*2)
      + case when c.depth_order is not null then 12 else 0 end
      + case when lower(coalesce(c.injury_status,''))='active' then 10 when c.injury_status is null then 0 else -8 end
      - case when c.proj is null then 35 else 0 end))::int,
    case when c.en_bye then 'BYE'
         when lower(coalesce(c.injury_status,'')) in ('out','inactive','ir','ir-r','pup-r','nfi-r','reserve-sus','reserve-cel','reserve-dnr') then 'OUT'
         when c.proj is null then 'DATA_INCOMPLETE'
         else 'PROJECTED' end,
    jsonb_build_object(
      'source','Reto13M Fantasy Weekly Brain',
      'prior_season',p_season-1,
      'usage_games',c.sample_games,
      'base_season_ppr',c.base_season_ppr,
      'base_recent_ppr',c.base_recent_ppr,
      'target_share',c.target_share,
      'rz5_share',c.rz5_share,
      'depth_order',c.depth_order,
      'injury_status',c.injury_status,
      'opponent',c.opponent,
      'matchup_factor',round(c.matchup_factor,4),
      'role_factor',round(c.role_factor,4),
      'availability_factor',round(c.availability_factor,4),
      'market_used',false),
    c.feature_asof,p_model_version
  from calc c
  on conflict do nothing;

  get diagnostics v_inserted = row_count;
  return jsonb_build_object('ok',true,'season',p_season,'week',p_week,'decision_time',p_decision_time,'model_version',p_model_version,'inserted',v_inserted);
end $$;

create or replace function v2.fantasy_projection_week(
  p_season int,p_week int,p_asof timestamptz default now()
) returns setof v2.fantasy_projection_snapshot
language sql stable security definer
set search_path to public,v2
as $$
  select distinct on (s.espn_player_id) s.*
  from v2.fantasy_projection_snapshot s
  where s.season=p_season and s.week=p_week and s.decision_time <= p_asof
  order by s.espn_player_id,s.decision_time desc,s.built_at desc;
$$;

comment on table v2.fantasy_projection_snapshot is
  'Immutable weekly Fantasy projection snapshots. Projections are PPR points, never P_RETO/event probabilities.';
