-- ISS141 — Fantasy Trade Analyzer + Playoff Simulator contracts
-- ADDITIVE ONLY. Existing Fantasy B1/V2/V3 remains untouched.

create or replace function v2.fantasy_trade_side_eval_v1(
  p_players jsonb,
  p_season integer,
  p_week integer,
  p_asof timestamptz default now()
) returns jsonb
language sql stable security definer
set search_path='v2','public','pg_temp'
as $$
with req as (
  select ord::int,
         x->>'espn_player_id' espn_player_id,
         upper(coalesce(x->>'position','')) position,
         nullif(x->>'name','') supplied_name
  from jsonb_array_elements(coalesce(p_players,'[]'::jsonb)) with ordinality q(x,ord)
), ev as (
  select r.*,
         p.model_version,p.projected_mean,p.floor_points,p.ceiling_points,p.uncertainty,
         p.n_history,p.cold_start,p.feature_data_asof,p.model_status,p.quality_flag,p.provenance
  from req r
  left join lateral v2.fn_fantasy_project_b1_rq80_v2(r.espn_player_id,r.position,p_season,p_week,p_asof) p on true
)
select jsonb_build_object(
  'status',case when count(*)=0 then 'EMPTY' when count(*) filter(where model_status='READY')=count(*) then 'READY' else 'DATA_INCOMPLETE' end,
  'count',count(*),
  'ready_count',count(*) filter(where model_status='READY'),
  'projected_mean_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(projected_mean),2) end,
  'floor_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(floor_points),2) end,
  'ceiling_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(ceiling_points),2) end,
  'uncertainty_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(uncertainty),2) end,
  'players',coalesce(jsonb_agg(jsonb_build_object(
    'espn_player_id',espn_player_id,'position',position,'name',supplied_name,
    'model_version',model_version,'projected_mean',projected_mean,'floor',floor_points,'ceiling',ceiling_points,
    'uncertainty',uncertainty,'n_history',n_history,'cold_start',cold_start,'model_status',model_status,
    'quality_flag',quality_flag,'feature_data_asof',feature_data_asof
  ) order by ord),'[]'::jsonb)
)
from ev;
$$;

grant execute on function v2.fantasy_trade_side_eval_v1(jsonb,integer,integer,timestamptz) to authenticated;

create or replace function public.fantasy_trade_analyzer_v1(
  p_send jsonb,
  p_receive jsonb,
  p_season integer,
  p_week integer,
  p_asof timestamptz default now()
) returns jsonb
language plpgsql stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  s jsonb; r jsonb; ns int; nr int; dmean numeric; dfloor numeric; dceil numeric; status text; verdict text;
begin
  if jsonb_typeof(coalesce(p_send,'null'::jsonb))<>'array' or jsonb_typeof(coalesce(p_receive,'null'::jsonb))<>'array' then
    return jsonb_build_object('ok',false,'status','INVALID_INPUT','reason','send y receive deben ser arreglos JSON');
  end if;
  ns:=jsonb_array_length(p_send); nr:=jsonb_array_length(p_receive);
  if ns<1 or nr<1 or ns>4 or nr>4 then
    return jsonb_build_object('ok',false,'status','INVALID_PLAYER_COUNT','min_each_side',1,'max_each_side',4);
  end if;

  s:=v2.fantasy_trade_side_eval_v1(p_send,p_season,p_week,p_asof);
  r:=v2.fantasy_trade_side_eval_v1(p_receive,p_season,p_week,p_asof);
  if s->>'status'<>'READY' or r->>'status'<>'READY' then
    return jsonb_build_object('ok',true,'status','DATA_INCOMPLETE','send',s,'receive',r,
      'verdict','NO_VERDICT','reason','RETO no emite veredicto si cualquier jugador carece de proyección B1 READY.');
  end if;
  if ns<>nr then
    return jsonb_build_object('ok',true,'status','ROSTER_IMPACT_REQUIRED','send',s,'receive',r,
      'verdict','NO_VERDICT','reason','Trades con distinto número de jugadores requieren valorar el slot liberado/reemplazo dentro del roster; RETO no suma jugadores como si los slots fueran infinitos.');
  end if;

  dmean:=round((r->>'projected_mean_total')::numeric-(s->>'projected_mean_total')::numeric,2);
  dfloor:=round((r->>'floor_total')::numeric-(s->>'floor_total')::numeric,2);
  dceil:=round((r->>'ceiling_total')::numeric-(s->>'ceiling_total')::numeric,2);
  verdict:=case when dmean>=2 and dfloor>=0 then 'RECEIVE_SIDE_STRONGER'
                when dmean<=-2 and dfloor<=0 then 'SEND_SIDE_STRONGER'
                else 'CLOSE_OR_PROFILE_DEPENDENT' end;
  status:='READY_EQUAL_COUNT';
  return jsonb_build_object(
    'ok',true,'status',status,'contract_version','fantasy_trade_analyzer_v1','brain','fantasy-b1-rq80-2026.09.1',
    'send',s,'receive',r,
    'delta_receive_minus_send',jsonb_build_object('mean',dmean,'floor',dfloor,'ceiling',dceil),
    'verdict',verdict,
    'note','Este V1 compara valor proyectado B1 intrínseco en trades de igual cantidad. No inventa valor de roster/waiver para trades desiguales.',
    'principles',jsonb_build_object('one_brain',true,'market_used',false,'missing_projection_invented',false));
end $$;

grant execute on function public.fantasy_trade_analyzer_v1(jsonb,jsonb,integer,integer,timestamptz) to authenticated;

create table if not exists v2.fantasy_league_state_v1 (
  state_id uuid primary key default gen_random_uuid(),
  league_id text not null,
  season integer not null,
  week integer not null,
  asof timestamptz not null,
  source text not null,
  source_verified boolean not null default false,
  playoff_teams integer not null,
  created_at timestamptz not null default now(),
  unique(league_id,season,week,asof)
);

create table if not exists v2.fantasy_league_team_state_v1 (
  state_id uuid not null references v2.fantasy_league_state_v1(state_id) on delete cascade,
  team_id text not null,
  team_name text not null,
  wins numeric not null,
  losses numeric not null,
  points_for numeric not null default 0,
  power_mean numeric not null,
  power_sd numeric not null check(power_sd>0),
  primary key(state_id,team_id)
);

create table if not exists v2.fantasy_league_matchup_state_v1 (
  state_id uuid not null references v2.fantasy_league_state_v1(state_id) on delete cascade,
  matchup_week integer not null,
  home_team_id text not null,
  away_team_id text not null,
  primary key(state_id,matchup_week,home_team_id,away_team_id)
);

create or replace function public.fantasy_playoff_simulator_v1(
  p_league_id text,
  p_season integer,
  p_sims integer default 20000
) returns jsonb
language plpgsql volatile security definer
set search_path='public','v2','pg_temp'
as $$
declare sid uuid; pteams int; nteams int; nmatches int; outj jsonb;
begin
  if p_sims<1000 or p_sims>100000 then
    return jsonb_build_object('ok',false,'status','INVALID_SIM_COUNT','min',1000,'max',100000);
  end if;
  select state_id,playoff_teams into sid,pteams
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

  with team as (
    select * from v2.fantasy_league_team_state_v1 where state_id=sid
  ), matchup as (
    select m.*,h.power_mean hm,h.power_sd hs,a.power_mean am,a.power_sd aps
    from v2.fantasy_league_matchup_state_v1 m
    join team h on h.team_id=m.home_team_id
    join team a on a.team_id=m.away_team_id
    where m.state_id=sid
  ), draws as (
    select gs sim,m.*,
      case when random() < (1.0/(1.0+exp(-((hm-am)/greatest(sqrt(hs*hs+aps*aps),1))))) then home_team_id else away_team_id end winner
    from generate_series(1,p_sims) gs cross join matchup m
  ), simteam as (
    select gs sim,t.team_id,t.team_name,t.points_for,t.wins+
      coalesce((select count(*) from draws d where d.sim=gs and d.winner=t.team_id),0) final_wins
    from generate_series(1,p_sims) gs cross join team t
  ), ranked as (
    select *,row_number() over(partition by sim order by final_wins desc,points_for desc,team_id) seed
    from simteam
  ), agg as (
    select team_id,max(team_name) team_name,
      round(100.0*count(*) filter(where seed<=pteams)/p_sims,2) playoff_pct,
      round(avg(final_wins),2) avg_final_wins,
      round(avg(seed),2) avg_seed
    from ranked group by team_id
  )
  select jsonb_agg(jsonb_build_object('team_id',team_id,'team_name',team_name,'playoff_pct',playoff_pct,
    'avg_final_wins',avg_final_wins,'avg_seed',avg_seed) order by playoff_pct desc,avg_seed) into outj from agg;

  return jsonb_build_object('ok',true,'status','READY','contract_version','fantasy_playoff_simulator_v1',
    'league_id',p_league_id,'season',p_season,'state_id',sid,'simulations',p_sims,'teams',outj,
    'tiebreaker_note','Empates de victorias usan points_for actual como desempate determinístico en V1.',
    'principles',jsonb_build_object('verified_state_only',true,'invented_standings',false));
end $$;

grant execute on function public.fantasy_playoff_simulator_v1(text,integer,integer) to authenticated;
