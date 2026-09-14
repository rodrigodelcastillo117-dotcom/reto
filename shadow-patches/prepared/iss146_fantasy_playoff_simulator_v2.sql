-- ISS146: additive Fantasy playoff simulator V2.
-- Keeps V1 intact; consumes only verified league state snapshots.
create or replace function public.fantasy_playoff_simulator_v2(
  p_league_id text,
  p_season integer,
  p_sims integer default 20000
) returns jsonb
language plpgsql volatile security definer
set search_path=public,v2,pg_temp
as $$
declare
  sid uuid;
  pteams int;
  nteams int;
  nmatches int;
  outj jsonb;
  vasof timestamptz;
begin
  if p_sims < 1000 or p_sims > 100000 then
    return jsonb_build_object('ok',false,'status','INVALID_SIM_COUNT','min',1000,'max',100000);
  end if;

  select state_id,playoff_teams,asof into sid,pteams,vasof
  from v2.fantasy_league_state_v1
  where league_id=p_league_id and season=p_season and source_verified
  order by asof desc limit 1;

  if sid is null then
    return jsonb_build_object('ok',true,'status','LEAGUE_STATE_NOT_CONNECTED','league_id',p_league_id,'season',p_season,
      'reason','Se requieren standings, puntos y calendario restante verificados. RETO no inventa el estado de la liga.');
  end if;

  select count(*) into nteams from v2.fantasy_league_team_state_v1 where state_id=sid;
  select count(*) into nmatches from v2.fantasy_league_matchup_state_v1 where state_id=sid;
  if nteams<2 or nmatches<1 or pteams<1 or pteams>=nteams then
    return jsonb_build_object('ok',true,'status','LEAGUE_STATE_INCOMPLETE','teams',nteams,'remaining_matchups',nmatches,'playoff_teams',pteams);
  end if;

  with team as materialized (
    select * from v2.fantasy_league_team_state_v1 where state_id=sid
  ), matchup as materialized (
    select m.matchup_week,m.home_team_id,m.away_team_id,
      h.power_mean hm,h.power_sd hs,a.power_mean am,a.power_sd aps,
      1.0/(1.0+exp(-((h.power_mean-a.power_mean)/greatest(sqrt(h.power_sd*h.power_sd+a.power_sd*a.power_sd),1)))) p_home
    from v2.fantasy_league_matchup_state_v1 m
    join team h on h.team_id=m.home_team_id
    join team a on a.team_id=m.away_team_id
    where m.state_id=sid
  ), outcomes as materialized (
    select gs sim,
      case when random() < m.p_home then m.home_team_id else m.away_team_id end winner
    from generate_series(1,p_sims) gs
    cross join matchup m
  ), win_add as materialized (
    select sim,winner team_id,count(*)::numeric extra_wins
    from outcomes group by sim,winner
  ), simteam as (
    select gs sim,t.team_id,t.team_name,t.points_for,
      t.wins+coalesce(w.extra_wins,0) final_wins
    from generate_series(1,p_sims) gs
    cross join team t
    left join win_add w on w.sim=gs and w.team_id=t.team_id
  ), ranked as (
    select *,row_number() over(partition by sim order by final_wins desc,points_for desc,team_id) seed
    from simteam
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
    'ok',true,'status','READY','contract_version','fantasy_playoff_simulator_v2',
    'league_id',p_league_id,'season',p_season,'state_id',sid,'state_asof',vasof,
    'simulations',p_sims,'remaining_matchups',nmatches,'playoff_teams',pteams,'teams',outj,
    'model_note','Win probability per matchup uses verified schedule plus team power mean/uncertainty frozen in the league-state snapshot.',
    'tiebreaker_note','Ties in simulated wins use current points_for as a deterministic proxy; Yahoo reseeding remains a downstream playoff-bracket rule.',
    'principles',jsonb_build_object('verified_state_only',true,'invented_standings',false,'invented_schedule',false)
  );
end $$;

grant execute on function public.fantasy_playoff_simulator_v2(text,integer,integer) to authenticated;
