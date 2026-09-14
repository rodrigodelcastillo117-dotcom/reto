-- ISS150: additive product-story repairs. Existing publication/model authority remains untouched.

-- 1) Soccer score story: distinguish the modal exact score from the score
--    compatible with the canonical 1X2 outcome. No probability is recomputed.
create or replace view public.v_soccer_score_story_v1 as
with b as (
  select f.*,
    case
      when f.p_reto_home is null or f.p_reto_draw is null or f.p_reto_away is null then null
      when f.p_reto_home>f.p_reto_draw and f.p_reto_home>f.p_reto_away then 'HOME'
      when f.p_reto_draw>f.p_reto_home and f.p_reto_draw>f.p_reto_away then 'DRAW'
      when f.p_reto_away>f.p_reto_home and f.p_reto_away>f.p_reto_draw then 'AWAY'
      else null
    end canonical_outcome,
    case
      when f.predicted_score is null or position('-' in f.predicted_score)=0 then null
      when split_part(f.predicted_score,'-',1)::int > split_part(f.predicted_score,'-',2)::int then 'HOME'
      when split_part(f.predicted_score,'-',1)::int = split_part(f.predicted_score,'-',2)::int then 'DRAW'
      else 'AWAY'
    end modal_score_outcome
  from public.v_futpro_publication_v3 f
), aligned as (
  select b.*,
    a.aligned_score,
    a.aligned_score_prob
  from b
  left join lateral (
    select e->>'s' aligned_score,(e->>'p')::numeric aligned_score_prob
    from jsonb_array_elements(coalesce(b.score_dist,'[]'::jsonb)) e
    where case b.canonical_outcome
      when 'HOME' then split_part(e->>'s','-',1)::int > split_part(e->>'s','-',2)::int
      when 'DRAW' then split_part(e->>'s','-',1)::int = split_part(e->>'s','-',2)::int
      when 'AWAY' then split_part(e->>'s','-',1)::int < split_part(e->>'s','-',2)::int
      else false end
    order by (e->>'p')::numeric desc,e->>'s'
    limit 1
  ) a on true
)
select canonical_event_id,competition_id,competition_name,home_team,away_team,kickoff,
       canonical_pick_status,canonical_pick,canonical_pick_prob,canonical_outcome,
       predicted_score as modal_exact_score,predicted_score_prob as modal_exact_score_prob,
       modal_score_outcome,
       (canonical_outcome is not null and canonical_outcome=modal_score_outcome) modal_matches_canonical,
       aligned_score as canonical_aligned_score,aligned_score_prob as canonical_aligned_score_prob,
       score_dist,lambda_home,lambda_away,exp_goals_total,model_version,selector_version,
       case
         when canonical_outcome is null or predicted_score is null then 'UNAVAILABLE'
         when canonical_outcome=modal_score_outcome then 'MODAL_ALIGNED'
         else 'MODAL_DIFFERS_FROM_CANONICAL'
       end score_story_status,
       'El marcador exacto modal es la celda individual más probable; el pick 1X2 suma todas las celdas del mismo desenlace.'::text explanation
from aligned;

grant select on public.v_soccer_score_story_v1 to authenticated;

-- 2) MLB real recent-form + H2H from 11k+ historical scored games.
--    This is factual context only and never authorizes a winner pick.
create or replace function public.mlb_tendencias_v1(p_event text)
returns jsonb
language sql stable security definer
set search_path=public,pg_temp
as $$
with g as (
  select f.espn_event_id,f.arranca_en,f.home_nombre,f.away_nombre,
         hm.team_espn_id home_id,am.team_espn_id away_id,
         e.escudo_local,e.escudo_visitante
  from public.v_favorito_mlb f
  left join public.v_mlb_nombre_espn hm on hm.nombre=f.home_nombre
  left join public.v_mlb_nombre_espn am on am.nombre=f.away_nombre
  left join public.escudos_evento e on e.espn_event_id=f.espn_event_id
  where f.espn_event_id=p_event
  limit 1
), team_games as (
  select s.kickoff,s.home_espn_id team_id,s.away_espn_id rival_id,
         s.home_nombre team_name,s.away_nombre rival_name,
         s.home_score gf,s.away_score ga,true es_local
  from public.mlb_backfill_staging s,g
  where s.home_score is not null and s.away_score is not null and s.kickoff<g.arranca_en
  union all
  select s.kickoff,s.away_espn_id,s.home_espn_id,
         s.away_nombre,s.home_nombre,s.away_score,s.home_score,false
  from public.mlb_backfill_staging s,g
  where s.home_score is not null and s.away_score is not null and s.kickoff<g.arranca_en
), hl5 as (
  select * from team_games,g where team_id=g.home_id order by kickoff desc limit 5
), al5 as (
  select * from team_games,g where team_id=g.away_id order by kickoff desc limit 5
), hl10 as (
  select * from team_games,g where team_id=g.home_id order by kickoff desc limit 10
), al10 as (
  select * from team_games,g where team_id=g.away_id order by kickoff desc limit 10
), h2 as (
  select t.* from team_games t,g
  where t.team_id=g.home_id and t.rival_id=g.away_id
  order by t.kickoff desc limit 10
), hs5 as (
  select count(*) n,count(*) filter(where gf>ga) wins,count(*) filter(where gf<ga) losses,
         round(avg(gf)::numeric,2) runs_for_pg,round(avg(ga)::numeric,2) runs_against_pg,
         string_agg(case when gf>ga then 'W' else 'L' end,'' order by kickoff asc) form
  from hl5
), as5 as (
  select count(*) n,count(*) filter(where gf>ga) wins,count(*) filter(where gf<ga) losses,
         round(avg(gf)::numeric,2) runs_for_pg,round(avg(ga)::numeric,2) runs_against_pg,
         string_agg(case when gf>ga then 'W' else 'L' end,'' order by kickoff asc) form
  from al5
), hs10 as (
  select count(*) n,count(*) filter(where gf>ga) wins,count(*) filter(where gf<ga) losses,
         round(avg(gf)::numeric,2) runs_for_pg,round(avg(ga)::numeric,2) runs_against_pg
  from hl10
), as10 as (
  select count(*) n,count(*) filter(where gf>ga) wins,count(*) filter(where gf<ga) losses,
         round(avg(gf)::numeric,2) runs_for_pg,round(avg(ga)::numeric,2) runs_against_pg
  from al10
), h2s as (
  select count(*) n,count(*) filter(where gf>ga) home_current_team_wins,count(*) filter(where gf<ga) away_current_team_wins,
         round(avg(gf)::numeric,2) current_home_runs_pg,round(avg(ga)::numeric,2) current_away_runs_pg,
         round(avg((gf+ga)::numeric),2) total_runs_pg,
         string_agg(case when gf>ga then 'W' else 'L' end,'' order by kickoff asc) current_home_form
  from h2
)
select case when g.espn_event_id is null then jsonb_build_object('ok',false,'status','EVENT_NOT_FOUND')
else jsonb_build_object(
  'ok',true,'status','READY','contract_version','mlb_tendencias_v1','event_id',g.espn_event_id,'kickoff',g.arranca_en,
  'logos',jsonb_build_object('home',g.escudo_local,'away',g.escudo_visitante),
  'home',jsonb_build_object('team',g.home_nombre,'team_id',g.home_id,
    'last5',jsonb_build_object('n',hs5.n,'wins',hs5.wins,'losses',hs5.losses,'form',hs5.form,'runs_for_pg',hs5.runs_for_pg,'runs_against_pg',hs5.runs_against_pg),
    'last10',jsonb_build_object('n',hs10.n,'wins',hs10.wins,'losses',hs10.losses,'runs_for_pg',hs10.runs_for_pg,'runs_against_pg',hs10.runs_against_pg)),
  'away',jsonb_build_object('team',g.away_nombre,'team_id',g.away_id,
    'last5',jsonb_build_object('n',as5.n,'wins',as5.wins,'losses',as5.losses,'form',as5.form,'runs_for_pg',as5.runs_for_pg,'runs_against_pg',as5.runs_against_pg),
    'last10',jsonb_build_object('n',as10.n,'wins',as10.wins,'losses',as10.losses,'runs_for_pg',as10.runs_for_pg,'runs_against_pg',as10.runs_against_pg)),
  'h2h',jsonb_build_object('n',h2s.n,'current_home_team_wins',h2s.home_current_team_wins,'current_away_team_wins',h2s.away_current_team_wins,
    'current_home_runs_pg',h2s.current_home_runs_pg,'current_away_runs_pg',h2s.current_away_runs_pg,'total_runs_pg',h2s.total_runs_pg,'current_home_form',h2s.current_home_form),
  'source','mlb_backfill_staging','temporal_safe',true,'authoritative_role','CONTEXT_ONLY'
) end
from g cross join hs5 cross join as5 cross join hs10 cross join as10 cross join h2s;
$$;

grant execute on function public.mlb_tendencias_v1(text) to authenticated;
