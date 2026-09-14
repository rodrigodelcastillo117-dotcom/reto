-- ISS146: additive Fantasy playoff simulator using verified provider matchup projections.
-- Does not replace v1/v2; diagnostic only until all league rosters can be projected by B1.

create table if not exists v2.fantasy_league_matchup_projection_v3 (
  state_id uuid not null references v2.fantasy_league_state_v1(state_id) on delete cascade,
  matchup_week integer not null,
  home_team_id text not null,
  away_team_id text not null,
  home_points_now numeric,
  away_points_now numeric,
  home_projected_points numeric not null,
  away_projected_points numeric not null,
  provider text not null,
  source_verified boolean not null default false,
  captured_at timestamptz not null,
  primary key(state_id, matchup_week, home_team_id, away_team_id)
);

alter table v2.fantasy_league_matchup_projection_v3 enable row level security;
grant select on v2.fantasy_league_matchup_projection_v3 to authenticated;

drop policy if exists fantasy_matchup_projection_read_auth on v2.fantasy_league_matchup_projection_v3;
create policy fantasy_matchup_projection_read_auth on v2.fantasy_league_matchup_projection_v3 for select to authenticated using (true);

create or replace function public.fantasy_playoff_simulator_v3_external(
  p_league_id text,
  p_season integer,
  p_sims integer default 20000
) returns jsonb
language plpgsql
security definer
set search_path='public','v2','pg_temp'
as $$
declare
  sid uuid; pteams int; vasof timestamptz; nteams int; nmatches int; outj jsonb;
begin
  if p_sims < 1000 or p_sims > 100000 then
    return jsonb_build_object('ok',false,'status','INVALID_SIM_COUNT','min',1000,'max',100000);
  end if;

  select state_id, playoff_teams, asof into sid,pteams,vasof
  from v2.fantasy_league_state_v1
  where league_id=p_league_id and season=p_season and source_verified
  order by asof desc limit 1;

  if sid is null then
    return jsonb_build_object('ok',true,'status','LEAGUE_STATE_NOT_CONNECTED');
  end if;

  select count(*) into nteams from v2.fantasy_league_team_state_v1 where state_id=sid;
  select count(*) into nmatches from v2.fantasy_league_matchup_projection_v3 where state_id=sid and source_verified;
  if nteams < 2 or nmatches < 1 or pteams < 1 or pteams >= nteams then
    return jsonb_build_object('ok',true,'status','LEAGUE_STATE_INCOMPLETE','teams',nteams,'matchups',nmatches,'playoff_teams',pteams);
  end if;

  with team as materialized (
    select * from v2.fantasy_league_team_state_v1 where state_id=sid
  ), matchup as materialized (
    select m.*,
      -- Provider projections are external context, not P_RETO. 18 pts is an explicit diagnostic uncertainty scale.
      1.0/(1.0+exp(-((m.home_projected_points-m.away_projected_points)/18.0))) as p_home
    from v2.fantasy_league_matchup_projection_v3 m
    where m.state_id=sid and m.source_verified
  ), outcomes as materialized (
    select gs sim,
      case when random()<m.p_home then m.home_team_id else m.away_team_id end winner
    from generate_series(1,p_sims) gs cross join matchup m
  ), win_add as materialized (
    select sim,winner team_id,count(*)::numeric extra_wins from outcomes group by sim,winner
  ), simteam as (
    select gs sim,t.team_id,t.team_name,t.points_for,
      t.wins+coalesce(w.extra_wins,0) final_wins
    from generate_series(1,p_sims) gs cross join team t
    left join win_add w on w.sim=gs and w.team_id=t.team_id
  ), ranked as (
    select *,row_number() over(partition by sim order by final_wins desc,points_for desc,team_id) seed from simteam
  ), agg as (
    select team_id,max(team_name) team_name,
      round(100.0*count(*) filter(where seed<=pteams)/p_sims,2) playoff_pct,
      round(avg(final_wins),2) avg_final_wins,
      round(avg(seed),2) avg_seed,
      round(100.0*count(*) filter(where seed=1)/p_sims,2) top_seed_pct
    from ranked group by team_id
  )
  select jsonb_agg(jsonb_build_object(
    'team_id',team_id,'team_name',team_name,'playoff_pct',playoff_pct,
    'top_seed_pct',top_seed_pct,'avg_final_wins',avg_final_wins,'avg_seed',avg_seed
  ) order by playoff_pct desc,avg_seed) into outj from agg;

  return jsonb_build_object(
    'ok',true,'status','READY_DIAGNOSTIC','contract_version','fantasy_playoff_simulator_v3_external',
    'league_id',p_league_id,'season',p_season,'state_id',sid,'state_asof',vasof,
    'simulations',p_sims,'matchups',nmatches,'playoff_teams',pteams,'teams',outj,
    'authority','EXTERNAL_PROJECTION_SIMULATION',
    'not_p_reto',true,
    'uncertainty_note','18-point matchup uncertainty is explicit diagnostic scale; not a calibrated RETO league probability.',
    'upgrade_path','Promote to RETO_B1_LEAGUE_SIM only after all league rosters are imported and projected under the same B1 model.',
    'principles',jsonb_build_object('verified_provider_schedule_only',true,'invented_standings',false,'invented_schedule',false,'one_brain_not_claimed',true)
  );
end $$;

grant execute on function public.fantasy_playoff_simulator_v3_external(text,integer,integer) to authenticated;
