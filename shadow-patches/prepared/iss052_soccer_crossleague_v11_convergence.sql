-- iss052 — SOCCER CROSSLEAGUE v1_1 CONVERGENCE · STAGED ONLY
-- Owner closeout 2026-09-10. No production deploy in this commit.
-- Purpose: make crossleague_v1_1 the single canonical cross-league brain for staged SOCCER,
-- using a versioned, temporally sealed model snapshot. crossleague_v1 remains legacy/shadow only.

create schema if not exists v2;

-- Minimal dependency closure for clean bootstrap. Existing production tables are left intact.
create table if not exists public.catalogo_equipos_espn (
  deporte text, espn_team_id text, nombre text, pais text, bandera_emoji text,
  liga_nombre text, liga_casa text, competencias bigint, partidos bigint,
  ultimo_partido timestamptz
);
alter table public.ligas_master add column if not exists espn_endpoint text;
alter table public.ligas_master add column if not exists api_sports_id integer;

create table if not exists v2.soccer_domestic_observation (
  team_espn_id text not null,
  provider text not null,
  provider_team_id text,
  provider_fixture_id text not null,
  domestic_league_id integer not null,
  domestic_league_name text,
  kickoff timestamptz not null,
  gf integer not null,
  ga integer not null,
  loaded_at timestamptz not null,
  metadata jsonb not null default '{}'::jsonb,
  primary key (team_espn_id, provider, provider_fixture_id)
);

create table if not exists v2.crossleague_model_registry (
  model_version text not null,
  training_cutoff timestamptz not null,
  a0 numeric not null,
  batt numeric not null,
  bdef numeric not null,
  home_adv numeric not null,
  rho numeric not null,
  ridge numeric not null,
  ref_league_id integer,
  sample_floor_domestic integer not null,
  validation_status text not null,
  validation_evidence jsonb not null,
  source_commit text,
  created_at timestamptz not null default now(),
  primary key (model_version, training_cutoff)
);

create table if not exists v2.crossleague_league_strength (
  model_version text not null,
  training_cutoff timestamptz not null,
  league_id integer not null,
  league_name text,
  phi numeric not null,
  n_cross integer not null,
  servable boolean not null,
  config_hash text not null,
  fitted_at timestamptz not null default now(),
  primary key (model_version, training_cutoff, league_id)
);

create table if not exists v2.crossleague_strength_seal (
  model_version text not null,
  training_cutoff timestamptz not null,
  league_count integer not null,
  config_hash text not null,
  snapshot_hash text not null,
  sealed_at timestamptz not null default now(),
  primary key (model_version, training_cutoff)
);

create table if not exists v2.crossleague_competition_policy (
  competition_id text primary key,
  model_version text not null,
  status text not null,
  evidence jsonb not null default '{}'::jsonb,
  approved_at timestamptz,
  updated_at timestamptz not null default now()
);

-- Frozen champion parameters measured read-only from production on 2026-09-10.
insert into v2.crossleague_model_registry
(model_version,training_cutoff,a0,batt,bdef,home_adv,rho,ridge,ref_league_id,
 sample_floor_domestic,validation_status,validation_evidence,source_commit)
values
('crossleague_v1_1','2026-09-08 19:00:00+00',-0.2214,0.6057,0.3896,0.3568,0.0705,10.0,39,15,
 'OOS_VALIDATED_PROD_EXTENDED',
 '{"UCL":{"n":207,"ece":0.018,"brier":0.6069,"logloss":1.0118,"delta_brier_vs_base":0.0166},"UEL":{"n":136,"ece":0.028,"brier":0.5979,"logloss":1.0006,"delta_brier_vs_base":0.0285},"floor_selected_on_validation":15,"training_last_usable_event_time":"2026-09-08T19:00:00Z"}'::jsonb,
 '8c9fb1f52bfad82f8c767e64ac28cc35e5682d85')
on conflict (model_version,training_cutoff) do nothing;

insert into v2.crossleague_league_strength
(model_version,training_cutoff,league_id,league_name,phi,n_cross,servable,config_hash)
values
('crossleague_v1_1','2026-09-08 19:00:00+00',39,'Premier League',0.0000,186,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',61,'Ligue 1',-0.1104,133,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',78,'Bundesliga',-0.1202,150,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',88,'Eredivisie',-0.3837,91,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',94,'Primeira Liga',-0.2790,90,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',103,'Eliteserien',-0.2809,40,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',119,'Danish Superliga',-0.2862,30,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',135,'Serie A',-0.1053,152,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',140,'LaLiga',-0.0998,172,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',144,'Jupiler Pro League',-0.3207,66,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',179,'Scottish Premiership',-0.5045,25,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',197,'Super League Greece',-0.3552,38,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',203,'Super Lig',-0.3217,51,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',253,'MLS',-0.3035,54,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',262,'Liga MX',-0.0425,53,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',307,'Saudi Pro League',0.0650,3,false,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',333,'Ukrainian Premier League',-0.496,23,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',345,'Chance Liga',-0.512,21,true,'bbc4762f0eac440c72a3252febcbdeba'),
('crossleague_v1_1','2026-09-08 19:00:00+00',419,'Premyer Liqa',-0.548,20,true,'bbc4762f0eac440c72a3252febcbdeba')
on conflict (model_version,training_cutoff,league_id) do nothing;

insert into v2.crossleague_competition_policy(competition_id,model_version,status,evidence,approved_at)
values
('uefa_champions_league','crossleague_v1_1','PROD_APPROVED','{"basis":"UCL OOS n=207; extended league-strength holdouts passed"}'::jsonb,now()),
('uefa_europa_league','crossleague_v1_1','PROD_APPROVED','{"basis":"UEL OOS n=136; cross-league OOS improvement"}'::jsonb,now())
on conflict (competition_id) do update set
  model_version=excluded.model_version,status=excluded.status,evidence=excluded.evidence,
  approved_at=coalesce(v2.crossleague_competition_policy.approved_at,excluded.approved_at),updated_at=now();

-- Seal is derived from the exact frozen strength rows, never hand-written.
insert into v2.crossleague_strength_seal(model_version,training_cutoff,league_count,config_hash,snapshot_hash)
select 'crossleague_v1_1','2026-09-08 19:00:00+00'::timestamptz,count(*),max(config_hash),
       md5(string_agg(concat_ws(':',league_id::text,phi::text,n_cross::text,servable::text,config_hash),'|' order by league_id))
from v2.crossleague_league_strength
where model_version='crossleague_v1_1' and training_cutoff='2026-09-08 19:00:00+00'
on conflict (model_version,training_cutoff) do nothing;

create or replace function v2.fn_crossleague_strength_integrity(p_model_version text,p_cutoff timestamptz)
returns boolean language sql stable as $$
  select exists(
    select 1 from v2.crossleague_strength_seal s
    where s.model_version=p_model_version and s.training_cutoff=p_cutoff
      and s.league_count=(select count(*) from v2.crossleague_league_strength x where x.model_version=p_model_version and x.training_cutoff=p_cutoff)
      and s.config_hash=(select max(config_hash) from v2.crossleague_league_strength x where x.model_version=p_model_version and x.training_cutoff=p_cutoff)
      and s.snapshot_hash=(select md5(string_agg(concat_ws(':',league_id::text,phi::text,n_cross::text,servable::text,config_hash),'|' order by league_id)) from v2.crossleague_league_strength x where x.model_version=p_model_version and x.training_cutoff=p_cutoff)
  );
$$;

create or replace function v2.fn_crossleague_features_canonical(
  p_team_espn_id text,p_decision_time timestamptz,p_window_days integer default 540)
returns table(n int,gf numeric,ga numeric,domestic_league_id int,data_asof timestamptz,loaded_asof timestamptz,source_provider text)
language sql stable as $$
with preferred as (
  select lm.api_sports_id liga_id
  from public.catalogo_equipos_espn c
  join public.ligas_master lm on lm.espn_endpoint=c.liga_casa
  where c.deporte='soccer' and c.espn_team_id=p_team_espn_id and lm.api_sports_id is not null
  limit 1
), espn_groups as (
  select d.liga_id,count(*)::int n,
         avg(case when d.home_espn_id=p_team_espn_id then d.home_score else d.away_score end)::numeric gf,
         avg(case when d.home_espn_id=p_team_espn_id then d.away_score else d.home_score end)::numeric ga,
         max(d.fecha) data_asof,max(d.cargado_at) loaded_asof
  from public.historico_partidos_espn d
  join public.ligas_master lm on lm.api_sports_id=d.liga_id
  where (d.home_espn_id=p_team_espn_id or d.away_espn_id=p_team_espn_id)
    and d.home_score is not null and d.away_score is not null
    and d.fecha<p_decision_time and d.fecha>=p_decision_time-make_interval(days=>p_window_days)
    and d.cargado_at<=p_decision_time
    and (d.liga_id=(select liga_id from preferred) or ((select liga_id from preferred) is null and lm.espn_endpoint ~ '\\.1$'))
  group by d.liga_id
), espn_best as (
  select n,gf,ga,liga_id,data_asof,loaded_asof,'ESPN'::text source_provider
  from espn_groups order by case when liga_id=(select liga_id from preferred) then 0 else 1 end,n desc,data_asof desc limit 1
), api_groups as (
  select count(*)::int n,avg(o.gf)::numeric gf,avg(o.ga)::numeric ga,o.domestic_league_id liga_id,
         max(o.kickoff) data_asof,max(o.loaded_at) loaded_asof,max(o.provider)::text source_provider
  from v2.soccer_domestic_observation o
  where o.team_espn_id=p_team_espn_id and o.kickoff<p_decision_time
    and o.kickoff>=p_decision_time-make_interval(days=>p_window_days) and o.loaded_at<=p_decision_time
  group by o.domestic_league_id
), api_best as (
  select * from api_groups order by n desc,data_asof desc limit 1
), candidates as (
  select * from espn_best union all select * from api_best
)
select n,round(gf,4),round(ga,4),liga_id,data_asof,loaded_asof,source_provider
from candidates order by n desc,case when source_provider='ESPN' then 0 else 1 end,data_asof desc limit 1;
$$;

-- Staged-only canonical v1_1 emitter. It is deliberately narrower than the old generic
-- crossleague function: it serves only competitions whose policy explicitly points to v1_1.
create or replace function v2.fn_crossleague_v11_staged(
  p_home_espn_id text,p_away_espn_id text,p_decision_time timestamptz,
  p_competition_id text,p_provider_total_line numeric default null)
returns table(
  p_home numeric,p_draw numeric,p_away numeric,btts_yes numeric,btts_no numeric,
  p_over numeric,p_under numeric,p_push numeric,ou_line_type text,ou_supported boolean,
  lambda_home numeric,lambda_away numeric,score_dist jsonb,top_scores jsonb,
  model_status text,model_status_reason text,data_asof timestamptz,loaded_asof timestamptz,
  sample_home int,sample_away int,home_domestic_league_id int,away_domestic_league_id int,
  source_home text,source_away text,gf_home numeric,ga_home numeric,gf_away numeric,ga_away numeric,
  phi_home numeric,phi_away numeric,training_cutoff timestamptz,config_hash text,provenance jsonb)
language plpgsql stable set search_path to 'v2','public' as $$
declare pol record;m record;h record;a record;ph record;pa record;d jsonb;lh numeric;la numeric;
begin
  select * into pol from v2.crossleague_competition_policy
   where competition_id=p_competition_id and status='PROD_APPROVED' and model_version='crossleague_v1_1';
  if not found then model_status:='DATA_INCOMPLETE';model_status_reason:='NO_APPROVED_CROSSLEAGUE_V11_POLICY';return next;return;end if;

  select * into m from v2.crossleague_model_registry
   where model_version=pol.model_version and training_cutoff<=p_decision_time
   order by training_cutoff desc limit 1;
  if not found or not v2.fn_crossleague_strength_integrity(m.model_version,m.training_cutoff) then
    model_status:='DATA_INCOMPLETE';model_status_reason:='NO_INTACT_CROSSLEAGUE_V11_SNAPSHOT_ASOF';return next;return;
  end if;

  select * into h from v2.fn_crossleague_features_canonical(p_home_espn_id,p_decision_time,540);
  select * into a from v2.fn_crossleague_features_canonical(p_away_espn_id,p_decision_time,540);
  sample_home:=h.n; sample_away:=a.n; home_domestic_league_id:=h.domestic_league_id; away_domestic_league_id:=a.domestic_league_id;
  source_home:=h.source_provider; source_away:=a.source_provider; gf_home:=h.gf;ga_home:=h.ga;gf_away:=a.gf;ga_away:=a.ga;
  data_asof:=greatest(h.data_asof,a.data_asof); loaded_asof:=greatest(h.loaded_asof,a.loaded_asof);

  if h.n is null or h.n<m.sample_floor_domestic then model_status:='DATA_INCOMPLETE';model_status_reason:='HOME_DOMESTIC_SAMPLE_BELOW_'||m.sample_floor_domestic;return next;return;end if;
  if a.n is null or a.n<m.sample_floor_domestic then model_status:='DATA_INCOMPLETE';model_status_reason:='AWAY_DOMESTIC_SAMPLE_BELOW_'||m.sample_floor_domestic;return next;return;end if;
  if h.data_asof>p_decision_time or a.data_asof>p_decision_time or h.loaded_asof>p_decision_time or a.loaded_asof>p_decision_time then
    model_status:='TEMPORAL_UNSAFE';model_status_reason:='CROSSLEAGUE_FEATURE_FUTURE';return next;return;
  end if;

  select phi,servable,config_hash into ph from v2.crossleague_league_strength
   where model_version=m.model_version and training_cutoff=m.training_cutoff and league_id=h.domestic_league_id;
  select phi,servable,config_hash into pa from v2.crossleague_league_strength
   where model_version=m.model_version and training_cutoff=m.training_cutoff and league_id=a.domestic_league_id;
  if ph.phi is null or pa.phi is null or ph.servable is distinct from true or pa.servable is distinct from true then
    model_status:='DATA_INCOMPLETE';model_status_reason:='DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF';return next;return;
  end if;
  phi_home:=ph.phi;phi_away:=pa.phi;training_cutoff:=m.training_cutoff;config_hash:=ph.config_hash;

  lh:=exp(least(m.a0+m.batt*ln(greatest(h.gf,0.05))+m.bdef*ln(greatest(a.ga,0.05))+m.home_adv+(ph.phi-pa.phi),2.5));
  la:=exp(least(m.a0+m.batt*ln(greatest(a.gf,0.05))+m.bdef*ln(greatest(h.ga,0.05))+(pa.phi-ph.phi),2.5));
  lambda_home:=round(lh,4);lambda_away:=round(la,4);
  d:=v2.fn_dist_from_lambda(lambda_home,lambda_away,p_provider_total_line,m.rho,10);
  if d is null then model_status:='DATA_INCOMPLETE';model_status_reason:='SOCCER_SCORE_DIST_FAILED';return next;return;end if;

  p_home:=(d->>'p_home')::numeric;p_draw:=(d->>'p_draw')::numeric;p_away:=(d->>'p_away')::numeric;
  btts_yes:=(d->>'btts_yes')::numeric;btts_no:=(d->>'btts_no')::numeric;
  p_over:=(d->>'p_over')::numeric;p_under:=(d->>'p_under')::numeric;p_push:=(d->>'p_push')::numeric;
  ou_line_type:=d->>'ou_line_type';ou_supported:=(d->>'ou_supported')::boolean;
  score_dist:=d->'dist';top_scores:=d->'top_scores';
  model_status:='READY_UNVALIDATED';model_status_reason:='crossleague_v1_1 OOS validated + canonical domestic features + sealed phi as-of';
  provenance:=jsonb_build_object('engine','crossleague_v1_1','source_commit',m.source_commit,
    'training_cutoff',m.training_cutoff,'validation_status',m.validation_status,
    'decision_time',p_decision_time,'feature_data_asof',data_asof,'loaded_asof',loaded_asof,
    'home_n',h.n,'away_n',a.n,'home_domestic_league_id',h.domestic_league_id,
    'away_domestic_league_id',a.domestic_league_id,'feature_source_home',h.source_provider,
    'feature_source_away',a.source_provider,'phi_home',ph.phi,'phi_away',pa.phi,
    'provider_total_line',p_provider_total_line,'odds_price_used_in_p_reto',false,
    'validation_evidence',m.validation_evidence);
  return next;
end $$;

alter table v2.soccer_prediction_v2_staged add column if not exists model_name text;
alter table v2.soccer_prediction_v2_staged add column if not exists model_route text;
alter table v2.feature_snapshot add column if not exists phi_home numeric;
alter table v2.feature_snapshot add column if not exists phi_away numeric;
alter table v2.feature_snapshot add column if not exists phi_model_version text;
alter table v2.feature_snapshot add column if not exists phi_training_cutoff timestamptz;
alter table v2.feature_snapshot add column if not exists phi_config_hash text;

-- Preserve the v1 orchestrator as legacy/shadow and put the canonical name on the v1_1 wrapper.
do $$ begin
  if to_regprocedure('v2.build_soccer_prediction_v2_staged_v1_legacy(timestamptz,boolean,text)') is null
     and to_regprocedure('v2.build_soccer_prediction_v2_staged(timestamptz,boolean,text)') is not null then
    execute 'alter function v2.build_soccer_prediction_v2_staged(timestamptz,boolean,text) rename to build_soccer_prediction_v2_staged_v1_legacy';
  end if;
end $$;

create or replace function v2.build_soccer_prediction_v2_staged(
  p_decision_time timestamptz,p_enforce_availability boolean default true,p_mapping_version text default null)
returns integer language plpgsql as $$
declare n int;r record;x record;v_sid uuid;v_comp text;
begin
  n:=v2.build_soccer_prediction_v2_staged_v1_legacy(p_decision_time,p_enforce_availability,p_mapping_version);

  for r in
    select s.espn_event_id,a.home_espn_id,a.away_espn_id,a.liga_id,s.over_line,s.decision_time,
           s.feature_snapshot_id,c.competition_id catalog_competition_id
    from v2.soccer_prediction_v2_staged s
    join public.agenda_espn a on a.espn_event_id=s.espn_event_id
    join v2.competition_catalog c on c.sport='soccer' and c.provider='espn' and c.provider_competition_id=a.liga_id::text
    join v2.crossleague_competition_policy cp on cp.competition_id=c.competition_id and cp.status='PROD_APPROVED' and cp.model_version='crossleague_v1_1'
    where s.decision_time=p_decision_time
  loop
    select * into x from v2.fn_crossleague_v11_staged(r.home_espn_id,r.away_espn_id,p_decision_time,r.catalog_competition_id,r.over_line);
    v_sid:=null;
    if x.gf_home is not null and x.gf_away is not null then
      insert into v2.feature_snapshot(espn_event_id,decision_time,home_gf,home_gc,away_gf,away_gc,
        sample_home,sample_away,feature_data_asof,max_source_event_time,feature_version,
        phi_home,phi_away,phi_model_version,phi_training_cutoff,phi_config_hash)
      values(r.espn_event_id,p_decision_time,x.gf_home,x.ga_home,x.gf_away,x.ga_away,
        x.sample_home,x.sample_away,x.data_asof,x.data_asof,'domestic_form_phi_v1_1',
        x.phi_home,x.phi_away,'crossleague_v1_1',x.training_cutoff,x.config_hash)
      on conflict (espn_event_id,decision_time,feature_version) do nothing;
      select feature_snapshot_id into v_sid from v2.feature_snapshot
       where espn_event_id=r.espn_event_id and decision_time=p_decision_time and feature_version='domestic_form_phi_v1_1';
    end if;

    update v2.soccer_prediction_v2_staged s set
      model_name='reto_crossleague',model_route='CROSSLEAGUE',model_version='crossleague_v1_1',
      feature_version='domestic_form_phi_v1_1',calibration_status='OOS_VALIDATED',
      feature_data_asof=x.data_asof,max_source_event_time=x.data_asof,
      sample_home=x.sample_home,sample_away=x.sample_away,
      temporal_safe=(x.model_status='READY_UNVALIDATED' and x.data_asof<=p_decision_time and x.loaded_asof<=p_decision_time),
      p_home=case when x.model_status='READY_UNVALIDATED' then x.p_home end,
      p_draw=case when x.model_status='READY_UNVALIDATED' then x.p_draw end,
      p_away=case when x.model_status='READY_UNVALIDATED' then x.p_away end,
      btts_yes=case when x.model_status='READY_UNVALIDATED' then x.btts_yes end,
      btts_no=case when x.model_status='READY_UNVALIDATED' then x.btts_no end,
      p_over=case when x.model_status='READY_UNVALIDATED' then x.p_over end,
      p_under=case when x.model_status='READY_UNVALIDATED' then x.p_under end,
      p_push=case when x.model_status='READY_UNVALIDATED' then x.p_push end,
      ou_line_type=case when x.model_status='READY_UNVALIDATED' then x.ou_line_type end,
      ou_supported=case when x.model_status='READY_UNVALIDATED' then x.ou_supported end,
      score_dist=case when x.model_status='READY_UNVALIDATED' then x.score_dist end,
      top_scores=case when x.model_status='READY_UNVALIDATED' then x.top_scores end,
      model_status=x.model_status,model_status_reason=x.model_status_reason,
      provenance=coalesce(x.provenance,'{}'::jsonb)||jsonb_build_object('model_route','CROSSLEAGUE','canonical_brain',true),
      availability_verified=true,feature_snapshot_id=v_sid,built_at=now()
    where s.espn_event_id=r.espn_event_id and s.decision_time=p_decision_time;
  end loop;

  return n;
end $$;

-- Fail if any v1_1-policy event is still labelled as another crossleague model after a build.
create or replace view v2.v_soccer_crossleague_authority_violations as
select s.espn_event_id,s.decision_time,s.model_version,s.provenance
from v2.soccer_prediction_v2_staged s
join public.agenda_espn a on a.espn_event_id=s.espn_event_id
join v2.competition_catalog c on c.sport='soccer' and c.provider='espn' and c.provider_competition_id=a.liga_id::text
join v2.crossleague_competition_policy cp on cp.competition_id=c.competition_id and cp.status='PROD_APPROVED' and cp.model_version='crossleague_v1_1'
where s.model_version<>'crossleague_v1_1' or coalesce(s.provenance->>'engine','')<>'crossleague_v1_1';
