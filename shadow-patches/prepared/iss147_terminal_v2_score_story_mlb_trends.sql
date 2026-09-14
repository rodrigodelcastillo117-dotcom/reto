-- ISS147 additive contracts. Legacy v1 functions remain unchanged.

create or replace function public.futpro_terminal_v2(p_espn_event_id text)
returns jsonb
language plpgsql stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  j jsonb; d jsonb; home text; away text; ph numeric; pd numeric; pa numeric;
  target text; rep_score text; rep_p numeric; modal text; modal_target text; top5 jsonb;
begin
  j := public.futpro_terminal_v1(p_espn_event_id);
  if coalesce((j->>'ok')::boolean,false)=false then return j; end if;
  d := j#>'{official_story,score_distribution,distribution}';
  home := j#>>'{official_story,event,home_team}'; away := j#>>'{official_story,event,away_team}';
  ph := nullif(j#>>'{official_story,prediction,distribution_1x2,home}','')::numeric;
  pd := nullif(j#>>'{official_story,prediction,distribution_1x2,draw}','')::numeric;
  pa := nullif(j#>>'{official_story,prediction,distribution_1x2,away}','')::numeric;
  if ph is null or pd is null or pa is null then return j || jsonb_build_object('score_story',jsonb_build_object('status','UNAVAILABLE')); end if;
  target := case when ph>=pd and ph>=pa then 'HOME' when pa>=ph and pa>=pd then 'AWAY' else 'DRAW' end;
  modal := j#>>'{official_story,score_distribution,most_likely}';

  with s as (
    select x->>'s' score,(x->>'p')::numeric p,
           split_part(x->>'s','-',1)::int hg, split_part(x->>'s','-',2)::int ag
    from jsonb_array_elements(coalesce(d,'[]'::jsonb)) x
  )
  select score,p into rep_score,rep_p from s
  where (target='HOME' and hg>ag) or (target='AWAY' and hg<ag) or (target='DRAW' and hg=ag)
  order by p desc,score limit 1;

  with s as (
    select x from jsonb_array_elements(coalesce(d,'[]'::jsonb)) x order by (x->>'p')::numeric desc limit 5
  ) select coalesce(jsonb_agg(x),'[]'::jsonb) into top5 from s;

  if modal is not null then
    modal_target := case when split_part(modal,'-',1)::int>split_part(modal,'-',2)::int then 'HOME'
                         when split_part(modal,'-',1)::int<split_part(modal,'-',2)::int then 'AWAY' else 'DRAW' end;
  end if;

  return j || jsonb_build_object('contract_version','futpro_terminal_v2','score_story',jsonb_build_object(
    'status','READY','canonical_outcome',target,
    'canonical_pick',j#>>'{official_story,prediction,pick}',
    'modal_exact_score',modal,
    'modal_exact_score_pct',j#>'{official_story,score_distribution,most_likely_pct}',
    'representative_score_consistent_with_pick',rep_score,
    'representative_score_pct',rep_p,
    'top_exact_scenarios',top5,
    'modal_alignment',case when modal_target=target then 'ALIGNED' else 'DIFFERENT_BUT_MATHEMATICALLY_VALID' end,
    'explanation','El marcador modal es la celda exacta más probable; el pick 1X2 suma todas las celdas de victoria/empate/derrota. Para el hero visual usar representative_score_consistent_with_pick.'
  ));
end $$;
grant execute on function public.futpro_terminal_v2(text) to authenticated;

create table if not exists v2.mlb_team_asset_v1(
 team_name text primary key, abbreviation text not null, logo_url text not null
);
insert into v2.mlb_team_asset_v1(team_name,abbreviation,logo_url) values
('Arizona Diamondbacks','ari','https://a.espncdn.com/i/teamlogos/mlb/500/ari.png'),('Athletics','ath','https://a.espncdn.com/i/teamlogos/mlb/500/ath.png'),('Atlanta Braves','atl','https://a.espncdn.com/i/teamlogos/mlb/500/atl.png'),('Baltimore Orioles','bal','https://a.espncdn.com/i/teamlogos/mlb/500/bal.png'),('Boston Red Sox','bos','https://a.espncdn.com/i/teamlogos/mlb/500/bos.png'),('Chicago Cubs','chc','https://a.espncdn.com/i/teamlogos/mlb/500/chc.png'),('Chicago White Sox','chw','https://a.espncdn.com/i/teamlogos/mlb/500/chw.png'),('Cincinnati Reds','cin','https://a.espncdn.com/i/teamlogos/mlb/500/cin.png'),('Cleveland Guardians','cle','https://a.espncdn.com/i/teamlogos/mlb/500/cle.png'),('Colorado Rockies','col','https://a.espncdn.com/i/teamlogos/mlb/500/col.png'),('Detroit Tigers','det','https://a.espncdn.com/i/teamlogos/mlb/500/det.png'),('Houston Astros','hou','https://a.espncdn.com/i/teamlogos/mlb/500/hou.png'),('Kansas City Royals','kc','https://a.espncdn.com/i/teamlogos/mlb/500/kc.png'),('Los Angeles Angels','laa','https://a.espncdn.com/i/teamlogos/mlb/500/laa.png'),('Los Angeles Dodgers','lad','https://a.espncdn.com/i/teamlogos/mlb/500/lad.png'),('Miami Marlins','mia','https://a.espncdn.com/i/teamlogos/mlb/500/mia.png'),('Milwaukee Brewers','mil','https://a.espncdn.com/i/teamlogos/mlb/500/mil.png'),('Minnesota Twins','min','https://a.espncdn.com/i/teamlogos/mlb/500/min.png'),('New York Mets','nym','https://a.espncdn.com/i/teamlogos/mlb/500/nym.png'),('New York Yankees','nyy','https://a.espncdn.com/i/teamlogos/mlb/500/nyy.png'),('Philadelphia Phillies','phi','https://a.espncdn.com/i/teamlogos/mlb/500/phi.png'),('Pittsburgh Pirates','pit','https://a.espncdn.com/i/teamlogos/mlb/500/pit.png'),('San Diego Padres','sd','https://a.espncdn.com/i/teamlogos/mlb/500/sd.png'),('San Francisco Giants','sf','https://a.espncdn.com/i/teamlogos/mlb/500/sf.png'),('Seattle Mariners','sea','https://a.espncdn.com/i/teamlogos/mlb/500/sea.png'),('St. Louis Cardinals','stl','https://a.espncdn.com/i/teamlogos/mlb/500/stl.png'),('Tampa Bay Rays','tb','https://a.espncdn.com/i/teamlogos/mlb/500/tb.png'),('Texas Rangers','tex','https://a.espncdn.com/i/teamlogos/mlb/500/tex.png'),('Toronto Blue Jays','tor','https://a.espncdn.com/i/teamlogos/mlb/500/tor.png'),('Washington Nationals','wsh','https://a.espncdn.com/i/teamlogos/mlb/500/wsh.png')
on conflict(team_name) do update set abbreviation=excluded.abbreviation,logo_url=excluded.logo_url;
alter table v2.mlb_team_asset_v1 enable row level security; grant select on v2.mlb_team_asset_v1 to authenticated;
drop policy if exists mlb_team_asset_read_auth on v2.mlb_team_asset_v1; create policy mlb_team_asset_read_auth on v2.mlb_team_asset_v1 for select to authenticated using(true);

create or replace function public.mlb_terminal_v2(p_espn_event_id text)
returns jsonb language plpgsql stable security definer set search_path='public','v2','pg_temp' as $$
declare j jsonb; h text; a text; hlogo text; alogo text; ht jsonb; at jsonb; hh jsonb; mkt jsonb;
begin
 j:=public.mlb_terminal_v1(p_espn_event_id); if coalesce((j->>'ok')::boolean,false)=false then return j; end if;
 h:=j#>>'{event,home}'; a:=j#>>'{event,away}';
 select logo_url into hlogo from v2.mlb_team_asset_v1 where team_name=h; select logo_url into alogo from v2.mlb_team_asset_v1 where team_name=a;
 with g as (select game_date,home_team,away_team,home_score,away_score from public.live_scores where deporte_clave='baseball' and status in ('FINAL','final','STATUS_FINAL') and game_date < (j#>>'{event,first_pitch}')::timestamptz and (home_team=h or away_team=h) order by game_date desc limit 5)
 select coalesce(jsonb_agg(jsonb_build_object('date',game_date,'home',home_team,'away',away_team,'score',home_score::text||'-'||away_score::text,'result',case when (home_team=h and home_score>away_score) or (away_team=h and away_score>home_score) then 'W' else 'L' end) order by game_date desc),'[]'::jsonb) into ht from g;
 with g as (select game_date,home_team,away_team,home_score,away_score from public.live_scores where deporte_clave='baseball' and status in ('FINAL','final','STATUS_FINAL') and game_date < (j#>>'{event,first_pitch}')::timestamptz and (home_team=a or away_team=a) order by game_date desc limit 5)
 select coalesce(jsonb_agg(jsonb_build_object('date',game_date,'home',home_team,'away',away_team,'score',home_score::text||'-'||away_score::text,'result',case when (home_team=a and home_score>away_score) or (away_team=a and away_score>home_score) then 'W' else 'L' end) order by game_date desc),'[]'::jsonb) into at from g;
 select to_jsonb(x) into hh from (select * from public.v_mlb_h2h where (equipo_a=h and equipo_b=a) or (equipo_a=a and equipo_b=h) order by juegos desc limit 1) x;
 mkt:=j#>'{market_context,data,prob_sin_vig}';
 return j || jsonb_build_object('contract_version','mlb_terminal_v2','visual_assets',jsonb_build_object('home_logo',hlogo,'away_logo',alogo),'trend_context',jsonb_build_object('home_last5',ht,'away_last5',at,'h2h',hh),'analysis_bars',jsonb_build_array(
  jsonb_build_object('id','market_novig','label','Mercado sin vig · diagnóstico','home',mkt->'prob_local','away',mkt->'prob_visita','authority','DIAGNOSTIC_ONLY'),
  jsonb_build_object('id','bullpen_fatigue','label','Fatiga bullpen','home',j#>'{bullpen,local_fatiga_pct}','away',j#>'{bullpen,visitante_fatiga_pct}','authority','FACTUAL_CONTEXT'),
  jsonb_build_object('id','recent_runs_per_game','label','Carreras por juego · últimos 10','home',j#>'{offense_splits,local_ultimos10,runs_per_game}','away',j#>'{offense_splits,visitante_ultimos10,runs_per_game}','authority','FACTUAL_CONTEXT')
 ),'official_probability_bar',jsonb_build_object('status','HIDDEN_NOT_RELEASE_AUTHORIZED','reason','MLB Moneyline no tiene P_RETO oficial validado.'));
end $$;
grant execute on function public.mlb_terminal_v2(text) to authenticated;
