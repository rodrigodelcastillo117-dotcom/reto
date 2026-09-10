-- iss052a — runtime qualification fix for fn_crossleague_v11_staged
-- PostgreSQL OUT params training_cutoff/config_hash shadowed identically named table columns.
-- Qualify every affected registry/strength reference. STAGED ONLY.
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
  select cp.* into pol
  from v2.crossleague_competition_policy cp
  where cp.competition_id=p_competition_id and cp.status='PROD_APPROVED'
    and cp.model_version='crossleague_v1_1';
  if not found then
    model_status:='DATA_INCOMPLETE';model_status_reason:='NO_APPROVED_CROSSLEAGUE_V11_POLICY';return next;return;
  end if;

  select mr.* into m
  from v2.crossleague_model_registry mr
  where mr.model_version=pol.model_version and mr.training_cutoff<=p_decision_time
  order by mr.training_cutoff desc limit 1;
  if not found or not v2.fn_crossleague_strength_integrity(m.model_version,m.training_cutoff) then
    model_status:='DATA_INCOMPLETE';model_status_reason:='NO_INTACT_CROSSLEAGUE_V11_SNAPSHOT_ASOF';return next;return;
  end if;

  select * into h from v2.fn_crossleague_features_canonical(p_home_espn_id,p_decision_time,540);
  select * into a from v2.fn_crossleague_features_canonical(p_away_espn_id,p_decision_time,540);
  sample_home:=h.n; sample_away:=a.n;
  home_domestic_league_id:=h.domestic_league_id; away_domestic_league_id:=a.domestic_league_id;
  source_home:=h.source_provider; source_away:=a.source_provider;
  gf_home:=h.gf;ga_home:=h.ga;gf_away:=a.gf;ga_away:=a.ga;
  data_asof:=greatest(h.data_asof,a.data_asof); loaded_asof:=greatest(h.loaded_asof,a.loaded_asof);

  if h.n is null or h.n<m.sample_floor_domestic then
    model_status:='DATA_INCOMPLETE';model_status_reason:='HOME_DOMESTIC_SAMPLE_BELOW_'||m.sample_floor_domestic;return next;return;
  end if;
  if a.n is null or a.n<m.sample_floor_domestic then
    model_status:='DATA_INCOMPLETE';model_status_reason:='AWAY_DOMESTIC_SAMPLE_BELOW_'||m.sample_floor_domestic;return next;return;
  end if;
  if h.data_asof>p_decision_time or a.data_asof>p_decision_time or h.loaded_asof>p_decision_time or a.loaded_asof>p_decision_time then
    model_status:='TEMPORAL_UNSAFE';model_status_reason:='CROSSLEAGUE_FEATURE_FUTURE';return next;return;
  end if;

  select ls.phi,ls.servable,ls.config_hash into ph
  from v2.crossleague_league_strength ls
  where ls.model_version=m.model_version and ls.training_cutoff=m.training_cutoff
    and ls.league_id=h.domestic_league_id;
  select ls.phi,ls.servable,ls.config_hash into pa
  from v2.crossleague_league_strength ls
  where ls.model_version=m.model_version and ls.training_cutoff=m.training_cutoff
    and ls.league_id=a.domestic_league_id;
  if ph.phi is null or pa.phi is null or ph.servable is distinct from true or pa.servable is distinct from true then
    model_status:='DATA_INCOMPLETE';model_status_reason:='DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF';return next;return;
  end if;

  phi_home:=ph.phi;phi_away:=pa.phi;training_cutoff:=m.training_cutoff;config_hash:=ph.config_hash;
  lh:=exp(least(m.a0+m.batt*ln(greatest(h.gf,0.05))+m.bdef*ln(greatest(a.ga,0.05))+m.home_adv+(ph.phi-pa.phi),2.5));
  la:=exp(least(m.a0+m.batt*ln(greatest(a.gf,0.05))+m.bdef*ln(greatest(h.ga,0.05))+(pa.phi-ph.phi),2.5));
  lambda_home:=round(lh,4);lambda_away:=round(la,4);
  d:=v2.fn_dist_from_lambda(lambda_home,lambda_away,p_provider_total_line,m.rho,10);
  if d is null then
    model_status:='DATA_INCOMPLETE';model_status_reason:='SOCCER_SCORE_DIST_FAILED';return next;return;
  end if;

  p_home:=(d->>'p_home')::numeric;p_draw:=(d->>'p_draw')::numeric;p_away:=(d->>'p_away')::numeric;
  btts_yes:=(d->>'btts_yes')::numeric;btts_no:=(d->>'btts_no')::numeric;
  p_over:=(d->>'p_over')::numeric;p_under:=(d->>'p_under')::numeric;p_push:=(d->>'p_push')::numeric;
  ou_line_type:=d->>'ou_line_type';ou_supported:=(d->>'ou_supported')::boolean;
  score_dist:=d->'dist';top_scores:=d->'top_scores';
  model_status:='READY_UNVALIDATED';
  model_status_reason:='crossleague_v1_1 OOS validated + canonical domestic features + sealed phi as-of';
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
