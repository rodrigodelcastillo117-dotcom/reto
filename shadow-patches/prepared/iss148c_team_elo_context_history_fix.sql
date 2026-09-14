-- ISS148c — team Elo context must use the canonical history table used by the model.
create or replace function public.team_elo_event_context_v1(p_event_id text)
returns jsonb
language plpgsql stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  s record; g record; home_l5 jsonb; away_l5 jsonb; h2h jsonb;
begin
  select * into s from v2.team_elo_learning_snapshot where espn_event_id=p_event_id order by captured_at desc limit 1;
  if not found then return jsonb_build_object('ok',false,'status','NOT_FOUND'); end if;
  select * into g from v2.team_elo_product_release_gate where model_version=s.model_version and league_name=s.league_name limit 1;

  with x as (
    select game_date,home_name,away_name,home_score,away_score
    from v2.team_history_event
    where league_name=s.league_name and game_date<s.kickoff and (home_name=s.home_name or away_name=s.home_name)
    order by game_date desc limit 5
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'date',game_date,'home',home_name,'away',away_name,'score',home_score::text||'-'||away_score::text,
      'result',case when (home_name=s.home_name and home_score>away_score) or (away_name=s.home_name and away_score>home_score) then 'W' else 'L' end
    ) order by game_date desc),'[]'::jsonb) into home_l5 from x;

  with x as (
    select game_date,home_name,away_name,home_score,away_score
    from v2.team_history_event
    where league_name=s.league_name and game_date<s.kickoff and (home_name=s.away_name or away_name=s.away_name)
    order by game_date desc limit 5
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'date',game_date,'home',home_name,'away',away_name,'score',home_score::text||'-'||away_score::text,
      'result',case when (home_name=s.away_name and home_score>away_score) or (away_name=s.away_name and away_score>home_score) then 'W' else 'L' end
    ) order by game_date desc),'[]'::jsonb) into away_l5 from x;

  with x as (
    select game_date,home_name,away_name,home_score,away_score
    from v2.team_history_event
    where league_name=s.league_name and game_date<s.kickoff and
      ((home_name=s.home_name and away_name=s.away_name) or (home_name=s.away_name and away_name=s.home_name))
    order by game_date desc limit 10
  ) select coalesce(jsonb_agg(jsonb_build_object('date',game_date,'home',home_name,'away',away_name,'score',home_score::text||'-'||away_score::text) order by game_date desc),'[]'::jsonb) into h2h from x;

  return jsonb_build_object(
    'ok',true,'contract_version','team_elo_event_context_v1','event_id',s.espn_event_id,'sport',s.sport,'league',s.league_name,
    'kickoff',s.kickoff,'home',s.home_name,'away',s.away_name,'model_version',s.model_version,
    'model_view',jsonb_build_object('home_pct',round(100*s.p_home,1),'away_pct',round(100*s.p_away,1),'captured_at',s.captured_at,'temporal_safe',s.temporal_safe),
    'authority',jsonb_build_object('product_authorized',coalesce(g.product_authorized,false),'money_authorized',coalesce(g.money_authorized,false),'release_status',coalesce(g.release_status,'UNVALIDATED'),'evidence',g.evidence),
    'trends',jsonb_build_object('home_last5',home_l5,'away_last5',away_l5,'h2h',h2h),
    'interpretation',case when coalesce(g.product_authorized,false) then 'OFFICIAL_P_RETO' else 'RESEARCH_CHALLENGER' end
  );
end $$;
grant execute on function public.team_elo_event_context_v1(text) to authenticated;