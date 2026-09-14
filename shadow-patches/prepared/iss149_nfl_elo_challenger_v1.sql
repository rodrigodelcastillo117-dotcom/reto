-- ISS149: additive, versioned NFL Moneyline Elo challenger.
-- Hyperparameters K=20 / HFA=25 were selected on TRAIN ONLY from a predefined grid.
-- The final 30% chronological holdout remains untouched by hyperparameter selection.

create table if not exists v2.nfl_elo_holdout_prediction_v1 (
  model_version text not null,
  espn_event_id text not null,
  game_date timestamptz not null,
  home_id text,
  away_id text,
  home_name text not null,
  away_name text not null,
  p_home numeric not null,
  outcome_home integer not null check(outcome_home in (0,1)),
  home_score integer not null,
  away_score integer not null,
  brier numeric not null,
  primary key(model_version,espn_event_id)
);

create table if not exists v2.nfl_elo_current_rating_v1 (
  model_version text not null,
  team_key text not null,
  team_name text not null,
  rating numeric not null,
  games integer not null,
  asof timestamptz not null,
  primary key(model_version,team_key)
);

create table if not exists v2.nfl_elo_challenger_gate_v1 (
  model_version text primary key,
  hyperparameter_policy text not null,
  k_factor numeric not null,
  hfa_elo numeric not null,
  n_train integer not null,
  n_holdout integer not null,
  brier_train numeric not null,
  brier_holdout numeric not null,
  accuracy_holdout_pct numeric not null,
  brier_vs_naive_upper95 numeric,
  supported_calibration_gap_pp numeric,
  supported_bucket_count integer not null default 0,
  scientific_ready boolean not null default false,
  product_authorized boolean not null default false,
  money_authorized boolean not null default false,
  status text not null,
  evidence jsonb not null default '{}'::jsonb,
  sealed_at timestamptz not null default now()
);

create or replace function v2.rebuild_nfl_elo_challenger_v1()
returns jsonb
language plpgsql security definer
set search_path=v2,public,pg_temp
as $$
declare
  r record;
  tot integer;
  cutn integer;
  i integer:=0;
  rh numeric; ra numeric; gh integer; ga integer;
  ph numeric; y integer; delta numeric;
  trn integer:=0; ten integer:=0; hit integer:=0;
  trb numeric:=0; teb numeric:=0;
  upper95 numeric; maxgap numeric; nbuckets integer;
  statusv text; readyv boolean;
  mv constant text:='nfl_elo_v1_k20_h25';
  kval constant numeric:=20;
  hfa constant numeric:=25;
begin
  create temp table if not exists _nfl_elo_v1(team_key text primary key,team_name text,rating numeric not null,games integer not null) on commit drop;
  truncate _nfl_elo_v1;
  delete from v2.nfl_elo_holdout_prediction_v1 where model_version=mv;
  delete from v2.nfl_elo_current_rating_v1 where model_version=mv;

  select count(*) into tot
  from v2.team_history_event
  where sport='football' and espn_endpoint='football/nfl' and home_score<>away_score;
  cutn:=floor(tot*0.70);

  for r in
    select * from v2.team_history_event
    where sport='football' and espn_endpoint='football/nfl' and home_score<>away_score
    order by game_date,espn_event_id
  loop
    i:=i+1;
    select rating,games into rh,gh from _nfl_elo_v1 where team_key=coalesce(r.home_id,public.norm_equipo(r.home_name));
    if not found then rh:=1500; gh:=0; end if;
    select rating,games into ra,ga from _nfl_elo_v1 where team_key=coalesce(r.away_id,public.norm_equipo(r.away_name));
    if not found then ra:=1500; ga:=0; end if;

    ph:=1.0/(1.0+power(10.0,(ra-(rh+hfa))/400.0));
    y:=case when r.home_score>r.away_score then 1 else 0 end;

    if gh>=5 and ga>=5 then
      if i<=cutn then
        trn:=trn+1; trb:=trb+power(ph-y,2);
      else
        ten:=ten+1; teb:=teb+power(ph-y,2);
        if (ph>=.5 and y=1) or (ph<.5 and y=0) then hit:=hit+1; end if;
        insert into v2.nfl_elo_holdout_prediction_v1(
          model_version,espn_event_id,game_date,home_id,away_id,home_name,away_name,p_home,outcome_home,home_score,away_score,brier)
        values(mv,r.espn_event_id,r.game_date,r.home_id,r.away_id,r.home_name,r.away_name,ph,y,r.home_score,r.away_score,power(ph-y,2))
        on conflict(model_version,espn_event_id) do update set
          game_date=excluded.game_date,home_id=excluded.home_id,away_id=excluded.away_id,home_name=excluded.home_name,away_name=excluded.away_name,
          p_home=excluded.p_home,outcome_home=excluded.outcome_home,home_score=excluded.home_score,away_score=excluded.away_score,brier=excluded.brier;
      end if;
    end if;

    delta:=kval*(y-ph);
    insert into _nfl_elo_v1 values(coalesce(r.home_id,public.norm_equipo(r.home_name)),r.home_name,rh+delta,gh+1)
      on conflict(team_key) do update set team_name=excluded.team_name,rating=excluded.rating,games=excluded.games;
    insert into _nfl_elo_v1 values(coalesce(r.away_id,public.norm_equipo(r.away_name)),r.away_name,ra-delta,ga+1)
      on conflict(team_key) do update set team_name=excluded.team_name,rating=excluded.rating,games=excluded.games;
  end loop;

  insert into v2.nfl_elo_current_rating_v1(model_version,team_key,team_name,rating,games,asof)
  select mv,team_key,team_name,rating,games,now() from _nfl_elo_v1;

  select avg(brier-.25)+1.96*stddev_samp(brier-.25)/sqrt(count(*))
    into upper95
  from v2.nfl_elo_holdout_prediction_v1 where model_version=mv;

  with b as (
    select width_bucket(greatest(p_home,1-p_home),0.5,1.000001,5) bucket,
           count(*) n,
           abs(avg(case when (p_home>=.5 and outcome_home=1) or (p_home<.5 and outcome_home=0) then 1.0 else 0.0 end)
             - avg(greatest(p_home,1-p_home)))*100 gap
    from v2.nfl_elo_holdout_prediction_v1
    where model_version=mv
    group by 1
  )
  select max(gap) filter(where n>=20),count(*) filter(where n>=20)
    into maxgap,nbuckets from b;

  readyv := ten>=200 and coalesce(upper95,999)<0 and coalesce(maxgap,999)<=7.5 and coalesce(nbuckets,0)>=3;
  statusv := case when ten<200 then 'INSUFFICIENT_HOLDOUT'
                  when coalesce(upper95,999)>=0 then 'NO_OOS_SKILL'
                  when coalesce(maxgap,999)>7.5 or coalesce(nbuckets,0)<3 then 'CALIBRATION_FAIL'
                  else 'PREDICTION_GATE_PASS' end;

  insert into v2.nfl_elo_challenger_gate_v1(
    model_version,hyperparameter_policy,k_factor,hfa_elo,n_train,n_holdout,brier_train,brier_holdout,accuracy_holdout_pct,
    brier_vs_naive_upper95,supported_calibration_gap_pp,supported_bucket_count,scientific_ready,product_authorized,money_authorized,status,evidence,sealed_at)
  values(mv,'TRAIN_ONLY_GRID_K_HFA',kval,hfa,trn,ten,trb/nullif(trn,0),teb/nullif(ten,0),100.0*hit/nullif(ten,0),upper95,maxgap,coalesce(nbuckets,0),readyv,false,false,statusv,
    jsonb_build_object('history_events',tot,'split','chronological_70_30','min_prior_games',5,'hyperparameters_selected_on','TRAIN_ONLY',
      'holdout_not_used_for_selection',true,'neutral_binary_brier',0.25,'calibration_authority','leader-confidence buckets n>=20','market_used',false),now())
  on conflict(model_version) do update set
    n_train=excluded.n_train,n_holdout=excluded.n_holdout,brier_train=excluded.brier_train,brier_holdout=excluded.brier_holdout,
    accuracy_holdout_pct=excluded.accuracy_holdout_pct,brier_vs_naive_upper95=excluded.brier_vs_naive_upper95,
    supported_calibration_gap_pp=excluded.supported_calibration_gap_pp,supported_bucket_count=excluded.supported_bucket_count,
    scientific_ready=excluded.scientific_ready,product_authorized=false,money_authorized=false,status=excluded.status,evidence=excluded.evidence,sealed_at=excluded.sealed_at;

  return (select to_jsonb(g) from v2.nfl_elo_challenger_gate_v1 g where g.model_version=mv);
end $$;

grant select on v2.nfl_elo_holdout_prediction_v1,v2.nfl_elo_current_rating_v1,v2.nfl_elo_challenger_gate_v1 to authenticated;
grant execute on function v2.rebuild_nfl_elo_challenger_v1() to authenticated;
