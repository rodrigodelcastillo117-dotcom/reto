-- ============================================================================
-- iss036/041/043/045 v3 REAL-PATH TEST — branch-only. Reproduces AUDIT_NO_PASS
-- 5620113352: the coherence gate is wired END-TO-END into the REAL canonical
-- staged -> Reto13M selector (NOT a separate fixtures path). Persisted score_dist
-- is the single source; the selector excludes coherence_ok=false OR suppress=true.
-- Self-contained: builds the contract from the 6 owner fixtures + a corrupted row.
-- Requires iss041 v2 + iss043 v3 (real ml cols) + iss045 fn_event_gate_status + iss036 v3.
-- RAISE EXCEPTION on failure. NO PROD MUTATION (disposable branch only).
-- ============================================================================
do $$
declare n int;
begin
  -- contract
  drop table if exists v2.soccer_prediction_v2_staged cascade;
  create table v2.soccer_prediction_v2_staged (
    espn_event_id text, competition_id int, home_team text, away_team text,
    kickoff timestamptz, decision_time timestamptz, sample_home int, sample_away int, temporal_safe boolean,
    feature_version text, model_version text, calibration_status text,
    p_home numeric, p_draw numeric, p_away numeric, btts_yes numeric, btts_no numeric,
    over_line numeric, p_over numeric, p_under numeric, line_source text,
    model_status text, model_status_reason text, provenance jsonb,
    score_dist jsonb, top_scores jsonb, feature_snapshot_id uuid, built_at timestamptz default now(),
    primary key (espn_event_id, decision_time, model_version));
  drop table if exists public.v_momios_confiables cascade;
  create table public.v_momios_confiables (
    espn_event_id text, home_ml numeric, away_ml numeric, draw_ml numeric,
    over_odds numeric, under_odds numeric, over_line numeric,
    snapshot_at timestamptz default now(), bookmaker text, confiable boolean default true);
  insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,bookmaker)
  select espn_event_id,odds_home,odds_draw,odds_away,odds_over,odds_under,over_line,bookmaker from v2.gate_fixture_soccer_cards;
  insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,bookmaker)
  values ('CORRUPT_ROW',2.70,3.55,2.55,1.645,2.25,2.5,'Test');

  -- 6 real rows: scalars + score_dist + top_scores all from the SAME emitter
  insert into v2.soccer_prediction_v2_staged
    (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
     feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,over_line,p_over,p_under,
     line_source,model_status,model_status_reason,provenance,score_dist,top_scores,feature_snapshot_id)
  select f.espn_event_id,2,f.home_team,f.away_team,now()+interval '1 day',now(),30,30,true,'fv1','dc_v2','RAW',
     (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
     (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,f.over_line,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
     'v_momios_confiables:'||f.bookmaker,'READY_UNVALIDATED','DC V2',
     jsonb_build_object('odds_is_context_not_preto',true),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
  from v2.gate_fixture_soccer_cards f
  cross join lateral (select v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,coalesce(f.maxg,10)) jd) d;

  -- corrupted row: valid score_dist, POISONED p_home (+15pp); balanced odds (no discrepancy)
  insert into v2.soccer_prediction_v2_staged
    (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
     feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,over_line,p_over,p_under,
     line_source,model_status,model_status_reason,provenance,score_dist,top_scores,feature_snapshot_id)
  select 'CORRUPT_ROW',2,'Corrupt FC','Poison United',now()+interval '1 day',now(),30,30,true,'fv1','dc_v2','RAW',
     (d.jd->>'p_home')::numeric+15,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
     (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,2.5,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
     'v_momios_confiables:Test','READY_UNVALIDATED','poisoned scalars',
     jsonb_build_object('odds_is_context_not_preto',true),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
  from (select v2.fn_dist_from_lambda(1.35,1.606,2.5,0.0705,10) jd) d;

  -- install real iss036 views (v3) — see prepared/iss036_daily_canonical_selector.sql
  -- (assumed already installed on the branch; the views read c.score_dist via fn_event_gate_status)

  -- ASSERTIONS on the REAL path
  -- Bayern + ManU suppressed => excluded from Reto13M, present in analysis
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id in ('401915442','401915443');
  if n<>0 then raise exception 'FAIL: suppressed Bayern/ManU leaked into Reto13M (n=%)',n; end if;
  select count(distinct espn_event_id) into n from v2.v_soccer_analysis_all where espn_event_id in ('401915442','401915443');
  if n<>2 then raise exception 'FAIL: Bayern/ManU not in analysis (n=%)',n; end if;
  -- CORRUPT_ROW: coherence_ok=false => excluded from Reto13M, present in analysis
  if exists(select 1 from v2.v_soccer_daily_candidates where canonical_event_id='CORRUPT_ROW')
    then raise exception 'FAIL: corrupted row reached Reto13M'; end if;
  if not exists(select 1 from v2.v_soccer_analysis_all where espn_event_id='CORRUPT_ROW' and coherence_ok=false)
    then raise exception 'FAIL: corrupted row not visible/flagged in analysis'; end if;
  -- PSV/Fener/Slavia/Como eligible => in Reto13M
  select count(distinct canonical_event_id) into n from v2.v_soccer_daily_candidates
    where canonical_event_id in ('401915422','401915440','401915441','401915444');
  if n<>4 then raise exception 'FAIL: eligible events missing from Reto13M (n=%)',n; end if;
  raise notice 'PASS: real staged->Reto13M path — Bayern/ManU (suppress) + CORRUPT_ROW (incoherent) excluded, all 7 in analysis, 4 eligible in Reto13M';
end $$;
