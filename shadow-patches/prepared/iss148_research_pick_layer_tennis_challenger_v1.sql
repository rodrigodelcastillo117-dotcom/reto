-- ISS148 — additive, honest multi-sport research-pick layer.
-- Does NOT modify any canonical publication view or existing model gate.
-- OFFICIAL rows keep P_RETO only when the existing release gate authorizes product publication.
-- RESEARCH rows expose a model direction separately, with p_reto_pct = NULL and money_authorized = false.

create table if not exists v2.tennis_elo_current_rating_v1 (
  player_name text primary key,
  rating numeric not null,
  games integer not null,
  asof timestamptz not null,
  model_version text not null default 'tennis_elo_challenger_v1_k8'
);

create or replace function v2.refresh_tennis_elo_current_ratings_v1()
returns jsonb
language plpgsql
security definer
set search_path='v2','public','pg_temp'
as $$
declare
  r record;
  rh numeric; ra numeric; gh int; ga int; ph numeric; y int; delta numeric;
  v_k numeric := 8;
  v_asof timestamptz := '-infinity'::timestamptz;
  v_n int := 0;
begin
  truncate table v2.tennis_elo_current_rating_v1;
  for r in
    select espn_event_id,game_date,home_team,away_team,home_sets,away_sets
    from public.live_scores
    where (deporte_clave='tennis' or deporte_norm='🎾 Tenis' or deporte='🎾 Tenis')
      and status ilike '%final%'
      and home_sets is not null and away_sets is not null and home_sets<>away_sets
      and home_team is not null and away_team is not null and home_team<>away_team
      and home_team not like '%/%' and away_team not like '%/%'
    order by game_date,espn_event_id
  loop
    select rating,games into rh,gh from v2.tennis_elo_current_rating_v1 where player_name=r.home_team;
    if not found then rh:=1500; gh:=0; end if;
    select rating,games into ra,ga from v2.tennis_elo_current_rating_v1 where player_name=r.away_team;
    if not found then ra:=1500; ga:=0; end if;
    ph:=1.0/(1.0+power(10.0,(ra-rh)/400.0));
    y:=case when r.home_sets>r.away_sets then 1 else 0 end;
    delta:=v_k*(y-ph);
    insert into v2.tennis_elo_current_rating_v1(player_name,rating,games,asof)
      values(r.home_team,rh+delta,gh+1,r.game_date)
      on conflict(player_name) do update set rating=excluded.rating,games=excluded.games,asof=excluded.asof;
    insert into v2.tennis_elo_current_rating_v1(player_name,rating,games,asof)
      values(r.away_team,ra-delta,ga+1,r.game_date)
      on conflict(player_name) do update set rating=excluded.rating,games=excluded.games,asof=excluded.asof;
    v_n:=v_n+1;
    v_asof:=greatest(v_asof,r.game_date);
  end loop;
  return jsonb_build_object('ok',true,'model_version','tennis_elo_challenger_v1_k8','events_fitted',v_n,'asof',v_asof,'players',(select count(*) from v2.tennis_elo_current_rating_v1));
end $$;

create table if not exists v2.tennis_elo_future_snapshot_v1 (
  snapshot_id bigserial primary key,
  espn_event_id text not null,
  model_version text not null,
  captured_at timestamptz not null default now(),
  kickoff timestamptz not null,
  league_name text,
  home_name text not null,
  away_name text not null,
  home_games integer,
  away_games integer,
  home_rating numeric,
  away_rating numeric,
  p_home numeric,
  p_away numeric,
  temporal_safe boolean not null,
  status text not null,
  provenance jsonb not null default '{}'::jsonb
);
create index if not exists ix_tennis_elo_future_snapshot_v1_event on v2.tennis_elo_future_snapshot_v1(espn_event_id,captured_at desc);

create or replace function v2.guard_tennis_elo_future_snapshot_v1()
returns trigger language plpgsql as $$
begin
  raise exception 'tennis_elo_future_snapshot_v1 is append-only';
end $$;
drop trigger if exists trg_tennis_elo_future_snapshot_v1_immutable on v2.tennis_elo_future_snapshot_v1;
create trigger trg_tennis_elo_future_snapshot_v1_immutable before update or delete on v2.tennis_elo_future_snapshot_v1
for each row execute function v2.guard_tennis_elo_future_snapshot_v1();

create or replace function v2.capture_tennis_elo_future_v1(p_horizon_hours integer default 168)
returns jsonb
language plpgsql
security definer
set search_path='v2','public','pg_temp'
as $$
declare v_capture timestamptz:=now(); v_n int;
begin
  perform v2.refresh_tennis_elo_current_ratings_v1();
  insert into v2.tennis_elo_future_snapshot_v1(
    espn_event_id,model_version,captured_at,kickoff,league_name,home_name,away_name,
    home_games,away_games,home_rating,away_rating,p_home,p_away,temporal_safe,status,provenance
  )
  select ls.espn_event_id,'tennis_elo_challenger_v1_k8',v_capture,ls.game_date,ls.liga,ls.home_team,ls.away_team,
         h.games,a.games,h.rating,a.rating,
         case when coalesce(h.games,0)>=2 and coalesce(a.games,0)>=2 then 1.0/(1.0+power(10.0,(a.rating-h.rating)/400.0)) end,
         case when coalesce(h.games,0)>=2 and coalesce(a.games,0)>=2 then 1.0-(1.0/(1.0+power(10.0,(a.rating-h.rating)/400.0))) end,
         (coalesce(h.asof,'-infinity'::timestamptz) < ls.game_date and coalesce(a.asof,'-infinity'::timestamptz) < ls.game_date),
         case when coalesce(h.games,0)>=2 and coalesce(a.games,0)>=2 then 'RESEARCH_CHALLENGER' else 'INSUFFICIENT_PLAYER_HISTORY' end,
         jsonb_build_object('source','live_scores_final_only','k_factor',8,'min_prior_games',2,'publication_authority',false,'money_authority',false)
  from public.live_scores ls
  left join v2.tennis_elo_current_rating_v1 h on h.player_name=ls.home_team
  left join v2.tennis_elo_current_rating_v1 a on a.player_name=ls.away_team
  where (ls.deporte_clave='tennis' or ls.deporte_norm='🎾 Tenis' or ls.deporte='🎾 Tenis')
    and ls.status in ('scheduled','pre','STATUS_SCHEDULED')
    and ls.game_date>=v_capture and ls.game_date<v_capture+make_interval(hours=>p_horizon_hours)
    and ls.home_team is not null and ls.away_team is not null
    and ls.home_team not like '%/%' and ls.away_team not like '%/%';
  get diagnostics v_n=row_count;
  return jsonb_build_object('ok',true,'captured_at',v_capture,'rows',v_n,'model_version','tennis_elo_challenger_v1_k8');
end $$;

grant select on v2.tennis_elo_current_rating_v1,v2.tennis_elo_future_snapshot_v1 to authenticated;
grant execute on function v2.capture_tennis_elo_future_v1(integer) to service_role;

create or replace view public.v_reto_research_pick_v1 as
with soccer as (
  select canonical_event_id::text espn_event_id,'soccer'::text sport,competition_name::text league_name,kickoff,
         home_team,away_team,canonical_pick::text selection_label,canonical_pick_prob::numeric p_reto_pct,
         null::numeric research_probability_pct,'OFFICIAL_P_RETO'::text display_class,
         model_version::text,calibration_status::text validation_status,
         true product_authorized,false money_authorized,
         'futpro_terminal_v2'::text analysis_contract,
         jsonb_build_object('selector_authoritative',selector_authoritative,'rank_policy_status',rank_policy_status,'engine',engine) provenance
  from public.v_futpro_publication_v3
  where kickoff>=now() and canonical_pick_status='READY' and selector_authoritative=true
),
elo_latest as (
  select distinct on (s.espn_event_id,s.model_version)
         s.*,g.product_authorized,g.money_authorized,g.release_status
  from v2.team_elo_learning_snapshot s
  left join v2.team_elo_product_release_gate g on g.model_version=s.model_version and g.league_name=s.league_name
  where s.kickoff>=now()
  order by s.espn_event_id,s.model_version,s.captured_at desc
),
team_sports as (
  select espn_event_id,sport,league_name,kickoff,home_name home_team,away_name away_team,
         case when p_home>=p_away then 'Gana '||home_name else 'Gana '||away_name end selection_label,
         case when product_authorized and temporal_safe then 100*greatest(p_home,p_away) end p_reto_pct,
         case when not coalesce(product_authorized,false) and temporal_safe then 100*greatest(p_home,p_away) end research_probability_pct,
         case when product_authorized and temporal_safe then 'OFFICIAL_P_RETO' else 'RESEARCH_CHALLENGER' end display_class,
         model_version,release_status validation_status,coalesce(product_authorized,false) product_authorized,
         coalesce(money_authorized,false) money_authorized,
         case when league_name in ('NBA','WNBA','NHL') then 'team_elo_event_context_v1' else null end analysis_contract,
         jsonb_build_object('captured_at',captured_at,'temporal_safe',temporal_safe,'raw_model_probability',greatest(p_home,p_away)) provenance
  from elo_latest
  where p_home is not null and p_away is not null and temporal_safe=true
),
nfl_latest as (
  select distinct on (espn_event_id) * from v2.nfl_decision_snapshot
  where kickoff>=now() order by espn_event_id,decision_time desc
),
nfl as (
  select n.espn_event_id,'football'::text sport,'NFL'::text league_name,n.kickoff,n.home_team,n.away_team,
         case when n.p_home_ml>=n.p_away_ml then 'Gana '||n.home_team else 'Gana '||n.away_team end selection_label,
         null::numeric p_reto_pct,greatest(n.p_home_ml,n.p_away_ml)::numeric research_probability_pct,
         'RESEARCH_CHALLENGER'::text display_class,n.model_version,
         coalesce(g.status,'UNVALIDATED')::text validation_status,false product_authorized,false money_authorized,
         'nfl_dossier'::text analysis_contract,
         jsonb_build_object('decision_time',n.decision_time,'asof_proven',n.asof_proven,'quality_status',n.quality_status,'research_only',true) provenance
  from nfl_latest n
  left join lateral (
    select status from v2.model_learning_gate where sport='football' and market='Moneyline' and model_version=n.model_version and league='GLOBAL' order by computed_at desc limit 1
  ) g on true
  where n.asof_proven=true and n.p_home_ml is not null and n.p_away_ml is not null
),
mlb_latest as (
  select distinct on (m.espn_event_id) m.*,ls.game_date kickoff,ls.home_team,ls.away_team
  from public.mlb_modelo_snapshot m join public.live_scores ls on ls.espn_event_id=m.espn_event_id
  where ls.game_date>=now() order by m.espn_event_id,m.actualizado desc
),
mlb as (
  select espn_event_id,'baseball'::text sport,'MLB'::text league_name,kickoff,home_team,away_team,
         case when mod_home>=mod_away then 'Gana '||home_team else 'Gana '||away_team end selection_label,
         null::numeric p_reto_pct,greatest(mod_home,mod_away)::numeric research_probability_pct,
         'RESEARCH_CHALLENGER'::text display_class,'mlb_ml_poisson_v1'::text model_version,
         'MODEL_REJECTED_RESEARCH_ONLY'::text validation_status,false product_authorized,false money_authorized,
         'mlb_terminal_v2'::text analysis_contract,
         jsonb_build_object('captured_at',actualizado,'research_only',true,'official_probability_published',false) provenance
  from mlb_latest where mod_home is not null and mod_away is not null
),
tennis_latest as (
  select distinct on (espn_event_id) * from v2.tennis_elo_future_snapshot_v1
  where kickoff>=now() order by espn_event_id,captured_at desc
),
tennis as (
  select espn_event_id,'tennis'::text sport,league_name,kickoff,home_name home_team,away_name away_team,
         case when p_home is null or p_away is null then null when p_home>=p_away then 'Gana '||home_name else 'Gana '||away_name end selection_label,
         null::numeric p_reto_pct,case when p_home is not null and p_away is not null then 100*greatest(p_home,p_away) end research_probability_pct,
         case when p_home is not null and p_away is not null then 'RESEARCH_CHALLENGER' else 'ANALYSIS_ONLY' end display_class,
         model_version,status validation_status,false product_authorized,false money_authorized,
         'tennis_research_context_v1'::text analysis_contract,
         provenance || jsonb_build_object('captured_at',captured_at,'home_games',home_games,'away_games',away_games) provenance
  from tennis_latest where temporal_safe=true
)
select * from soccer
union all select * from team_sports
union all select * from nfl
union all select * from mlb
union all select * from tennis;

grant select on public.v_reto_research_pick_v1 to authenticated;

create or replace view public.v_reto_research_pick_invariant_leaks_v1 as
select * from public.v_reto_research_pick_v1
where (display_class='OFFICIAL_P_RETO' and (not product_authorized or p_reto_pct is null))
   or (display_class<>'OFFICIAL_P_RETO' and p_reto_pct is not null)
   or (money_authorized and display_class<>'OFFICIAL_P_RETO');
grant select on public.v_reto_research_pick_invariant_leaks_v1 to authenticated;

-- Capture once immediately after migration with SELECT v2.capture_tennis_elo_future_v1(168);