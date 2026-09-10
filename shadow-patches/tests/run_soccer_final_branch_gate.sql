-- ============================================================================
-- run_soccer_final_branch_gate.sql — SOCCER FINAL BRANCH GATE (audit runner)
-- ============================================================================
-- Reproducible, executable, self-contained proof. Apply AFTER the normal migrations
-- chain (shadow-patches/prepared/*.sql in DAG order) + the two committed seeds
-- (seed_soccer_branch_data.sql, seed_soccer_owner_fixtures.sql). Every assertion
-- RAISE EXCEPTIONs on failure; a clean run prints the 7 stage banners and ends with
-- "==== SOCCER FINAL BRANCH GATE: ALL STAGES PASS ====". NO PROD MUTATION.
--
-- Stages, in order: SCHEMA_BOOTSTRAP_PASS, DATA_BUILDER_PASS, COHERENCE_PASS,
-- TEMPORAL_PASS, SELECTOR_PASS, DOSSIER_TRACEABILITY_PASS, REPLAY_IDEMPOTENCE_PASS.
-- Plus the full adversarial battery (MATRIX / SCALARS / PUSH / TOP_SCORES / OWNER
-- REGRESSION), each fail-closed as specified.
--
-- Decision epoch FIXED for reproducibility: 2026-09-10 17:00:00+00 (after real pregame
-- odds ~16:49, before fixture kickoffs). model_version dc-2026.09.1.
-- ============================================================================

do $GATE$
declare
  T_DEC     constant timestamptz := timestamptz '2026-09-10 17:00:00+00';
  MV        constant text := 'dc-2026.09.1';
  n int; m int; r record;
  e_id text; e_home text; e_liga int; b0 boolean; b1 boolean; df text;
  h1 text; h2 text; v_snap uuid; v_snap2 uuid; v_eff numeric; v_eff2 numeric;
  n_src int; n_proc int; n_pub int; n_rej int; n_ready int;
begin
  -- =========================================================================
  raise notice '--- STAGE 1: SCHEMA_BOOTSTRAP ---';
  -- =========================================================================
  if to_regprocedure('v2.fn_dist_from_lambda(numeric,numeric,numeric,numeric,integer)') is null
     then raise exception 'SCHEMA FAIL: v2.fn_dist_from_lambda missing'; end if;
  if to_regprocedure('v2.build_soccer_prediction_v2_staged(timestamptz,boolean,text)') is null
     then raise exception 'SCHEMA FAIL: builder missing'; end if;
  if to_regclass('v2.soccer_prediction_v2_staged') is null then raise exception 'SCHEMA FAIL: staged table missing'; end if;
  if to_regclass('v2.feature_snapshot') is null then raise exception 'SCHEMA FAIL: feature_snapshot missing'; end if;
  if to_regclass('v2.gate_fixture_soccer_cards') is null then raise exception 'SCHEMA FAIL: fixture table missing'; end if;
  if to_regclass('v2.v_soccer_daily_candidates') is null then raise exception 'SCHEMA FAIL: selector view missing'; end if;
  if to_regprocedure('v2.fn_soccer_dossier_manifest(text,timestamptz)') is null then raise exception 'SCHEMA FAIL: dossier manifest missing'; end if;
  select count(*) into n from pg_proc p join pg_namespace np on np.oid=p.pronamespace
    where np.nspname='v2' and p.proname='fn_event_gate_status';
  if n <> 1 then raise exception 'SCHEMA FAIL: fn_event_gate_status has % signatures (want 1)', n; end if;
  raise notice 'STAGE 1 SCHEMA_BOOTSTRAP_PASS (core objects present; single gate signature)';

  -- =========================================================================
  raise notice '--- STAGE 2: DATA_BUILDER ---';
  -- =========================================================================
  select count(*) into n from public.agenda_espn where deporte='soccer';
  if n < 200 then raise exception 'DATA FAIL: agenda universe % (<200) — seed_soccer_branch_data not applied', n; end if;
  n_src := n;
  select count(*) into n from public.historico_partidos_espn where liga_id=140;
  if n < 200 then raise exception 'DATA FAIL: La Liga historico % (<200)', n; end if;
  select count(*) into n from public.v_momios_confiables; if n < 140 then raise exception 'DATA FAIL: momios % (<140)', n; end if;
  select count(*) into n from v2.model_registry where sport='soccer' and approved; if n <> 11 then raise exception 'DATA FAIL: approved ligas % (want 11)', n; end if;
  select count(*) into n from v2.gate_fixture_soccer_cards; if n <> 6 then raise exception 'DATA FAIL: owner fixtures % (want 6)', n; end if;

  delete from v2.soccer_prediction_v2_staged where decision_time = T_DEC and model_version = MV;
  select v2.build_soccer_prediction_v2_staged(T_DEC) into n_proc;
  select count(*) into n_ready from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_version=MV and model_status='READY_UNVALIDATED';
  select count(*) into n_rej   from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_version=MV and model_status<>'READY_UNVALIDATED';
  n_pub := n_ready;
  if n_proc < 200 then raise exception 'DATA_BUILDER FAIL: processed % (<200)', n_proc; end if;
  if n_ready < 1 then raise exception 'DATA_BUILDER FAIL: 0 READY rows'; end if;
  if n_pub + n_rej <> n_proc then raise exception 'DATA_BUILDER FAIL: published(%)+rejected(%)!=processed(%)', n_pub, n_rej, n_proc; end if;
  raise notice 'STAGE 2 DATA_BUILDER_PASS: source=% processed=% published(READY)=% rejected(fail-closed)=%', n_src, n_proc, n_pub, n_rej;
  for r in select model_status_reason, count(*) c from v2.soccer_prediction_v2_staged
           where decision_time=T_DEC and model_version=MV and model_status<>'READY_UNVALIDATED'
           group by 1 order by 2 desc loop
    raise notice '   rejection: % -> %', r.model_status_reason, r.c;
  end loop;

  -- =========================================================================
  raise notice '--- STAGE 3: COHERENCE (same-distribution) ---';
  -- =========================================================================
  select count(*) into n from v2.v_soccer_event_gate g
   where g.decision_time=T_DEC and g.model_version=MV and g.coherence_ok is not true
     and exists (select 1 from v2.soccer_prediction_v2_staged s
                 where s.espn_event_id=g.canonical_event_id and s.decision_time=g.decision_time
                   and s.model_version=g.model_version and s.model_status='READY_UNVALIDATED');
  if n <> 0 then raise exception 'COHERENCE FAIL: % READY staged rows not coherence_ok', n; end if;

  for r in select * from v2.soccer_prediction_v2_staged
           where decision_time=T_DEC and model_version=MV and model_status='READY_UNVALIDATED' loop
    if abs(r.p_home - v2.fn_matrix_market(r.score_dist,'1X2','HOME')) > 0.2 then raise exception 'DIST FAIL % p_home', r.espn_event_id; end if;
    if abs(r.p_draw - v2.fn_matrix_market(r.score_dist,'1X2','DRAW')) > 0.2 then raise exception 'DIST FAIL % p_draw', r.espn_event_id; end if;
    if abs(r.p_away - v2.fn_matrix_market(r.score_dist,'1X2','AWAY')) > 0.2 then raise exception 'DIST FAIL % p_away', r.espn_event_id; end if;
    if abs(r.btts_yes - v2.fn_matrix_market(r.score_dist,'BTTS','YES')) > 0.2 then raise exception 'DIST FAIL % btts_yes', r.espn_event_id; end if;
    if abs(r.btts_no  - v2.fn_matrix_market(r.score_dist,'BTTS','NO'))  > 0.2 then raise exception 'DIST FAIL % btts_no', r.espn_event_id; end if;
    if round(coalesce(r.btts_yes,0)+coalesce(r.btts_no,0),1) <> 100.0 then raise exception 'DIST FAIL % btts sum', r.espn_event_id; end if;
    if jsonb_array_length(r.top_scores) <> 5 then raise exception 'DIST FAIL % top_scores len', r.espn_event_id; end if;
    if r.over_line is not null and r.ou_supported then
      if abs(r.p_over  - v2.fn_matrix_market(r.score_dist,'OU','OVER', r.over_line)) > 0.2 then raise exception 'DIST FAIL % p_over', r.espn_event_id; end if;
      if abs(r.p_under - v2.fn_matrix_market(r.score_dist,'OU','UNDER',r.over_line)) > 0.2 then raise exception 'DIST FAIL % p_under', r.espn_event_id; end if;
      if round(coalesce(r.p_over,0)+coalesce(r.p_push,0)+coalesce(r.p_under,0),1) <> 100.0 then raise exception 'DIST FAIL % ou sum', r.espn_event_id; end if;
    end if;
  end loop;

  for r in select f.espn_event_id, f.home_team,
             (select count(*) filter (where not g.ok) from v2.fn_soccer_coherence_gate(
                v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,coalesce(f.maxg,10)),
                f.over_line) g) fails
           from v2.gate_fixture_soccer_cards f loop
    if r.fails <> 0 then raise exception 'COHERENCE FAIL: fixture % (%) has % failing markets', r.espn_event_id, r.home_team, r.fails; end if;
  end loop;
  raise notice 'STAGE 3 COHERENCE_PASS: % READY rows derive from persisted matrix (<=0.2pp; coherence_ok enforces top_scores order+prob); 6/6 owner fixtures coherent', n_ready;

  -- =========================================================================
  raise notice '--- STAGE 4: TEMPORAL ---';
  -- =========================================================================
  select g.canonical_event_id into e_id from v2.v_soccer_event_gate g
   join v2.soccer_prediction_v2_staged s on s.espn_event_id=g.canonical_event_id and s.decision_time=g.decision_time and s.model_version=g.model_version
   where g.decision_time=T_DEC and g.model_version=MV and g.top_only_eligible
     and s.over_line is not null and g.disc_flag in ('OK','NO_MARKET_DIAGNOSTIC')
   order by g.canonical_event_id limit 1;
  if e_id is null then raise exception 'TEMPORAL FAIL: no eligible OK event to probe'; end if;
  select top_only_eligible into b0 from v2.v_soccer_event_gate where canonical_event_id=e_id and decision_time=T_DEC and model_version=MV;
  -- post-decision extreme odds row: must be ignored
  insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
    select e_id, 9.00,7.00,1.05,8.00,1.05, over_line, T_DEC + interval '2 hours','ADV_POST',true
    from v2.soccer_prediction_v2_staged where espn_event_id=e_id and decision_time=T_DEC and model_version=MV;
  select top_only_eligible into b1 from v2.v_soccer_event_gate where canonical_event_id=e_id and decision_time=T_DEC and model_version=MV;
  if b1 is distinct from b0 then raise exception 'TEMPORAL FAIL: post-decision odds changed eligibility of %', e_id; end if;
  -- wrong-line pregame row (line 9.5): must not drive the total diagnostic
  insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
    values (e_id, 2.0,3.4,3.6, 8.00,1.05, 9.5, T_DEC - interval '2 hours','ADV_WRONGLINE',true);
  select disc_flag into df from v2.v_soccer_event_gate where canonical_event_id=e_id and decision_time=T_DEC and model_version=MV;
  if df = 'QUALITY_DOWNGRADE' then raise exception 'TEMPORAL FAIL: wrong-line (9.5) forced false QUALITY_DOWNGRADE on %', e_id; end if;
  delete from public.v_momios_confiables where bookmaker in ('ADV_POST','ADV_WRONGLINE');
  raise notice 'STAGE 4 TEMPORAL_PASS: post-decision odds ignored (eligibility stable); wrong-line O/U ignored (event %)', e_id;

  -- =========================================================================
  raise notice '--- STAGE 5: SELECTOR (real staged -> selector) ---';
  -- =========================================================================
  select count(*) into n from v2.v_soccer_analysis_all where decision_time=T_DEC and model_version=MV;
  if n <> n_ready then raise exception 'SELECTOR FAIL: analysis surface % (want % READY)', n, n_ready; end if;
  select coalesce(max(c),0) into m from (select canonical_event_id, count(*) c from v2.v_soccer_daily_candidates
     where decision_time=T_DEC and model_version=MV group by canonical_event_id) z;
  if m > 7 then raise exception 'SELECTOR FAIL: NxM duplication, % candidates for one event', m; end if;
  select count(*) into n from (select canonical_event_id, decision_time, model_version, count(*) c
     from v2.v_soccer_event_gate where decision_time=T_DEC and model_version=MV group by 1,2,3 having count(*)>1) z;
  if n <> 0 then raise exception 'SELECTOR FAIL: % staged PKs have >1 gate row', n; end if;
  select count(distinct canonical_event_id) into n from v2.v_soccer_daily_candidates where decision_time=T_DEC and model_version=MV;
  raise notice 'STAGE 5 SELECTOR_PASS: analysis keeps % visible; % eligible event(s) in candidates; <=7/event (no NxM); 1 gate row per PK', n_ready, n;

  -- =========================================================================
  raise notice '--- STAGE 6: DOSSIER_TRACEABILITY (iss030 v3) ---';
  -- =========================================================================
  select s.espn_event_id, s.feature_snapshot_id, a.home_espn_id, s.competition_id
    into e_id, v_snap, e_home, e_liga
    from v2.soccer_prediction_v2_staged s
    join public.agenda_espn a on a.espn_event_id=s.espn_event_id
   where s.decision_time=T_DEC and s.model_version=MV and s.model_status='READY_UNVALIDATED'
   order by s.espn_event_id limit 1;
  select count(*) into n from v2.fn_soccer_dossier_manifest(e_id, T_DEC)
    where role='MODEL_ACTIVE' and used_in_p_reto and feature_snapshot_id = v_snap;
  if n < 1 then raise exception 'DOSSIER FAIL: no MODEL_ACTIVE row anchored to feature_snapshot_id % for %', v_snap, e_id; end if;
  select effective_value into v_eff from v2.fn_soccer_dossier_manifest(e_id, T_DEC) where source_name='feat_goal_rate_home' limit 1;
  -- adversarial: a POST-decision-captured aggregate refresh (new historico, cargado_at>decision)
  -- must NOT alter the frozen MODEL dossier (temporal freeze of the model inputs).
  insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
    values ('ADV_FREEZE', e_liga, T_DEC - interval '1 day', e_home, '999999', 9, 0, T_DEC + interval '1 day');
  select feature_snapshot_id, effective_value into v_snap2, v_eff2
    from v2.fn_soccer_dossier_manifest(e_id, T_DEC) where source_name='feat_goal_rate_home' limit 1;
  if v_snap2 is distinct from v_snap then raise exception 'DOSSIER FAIL: post-decision refresh changed anchored feature_snapshot_id'; end if;
  if v_eff2 is distinct from v_eff then raise exception 'DOSSIER FAIL: post-decision refresh changed frozen effective_value (% vs %)', v_eff2, v_eff; end if;
  delete from public.historico_partidos_espn where espn_event_id='ADV_FREEZE';
  raise notice 'STAGE 6 DOSSIER_TRACEABILITY_PASS: % MODEL_ACTIVE anchored to snapshot %; post-decision aggregate refresh did NOT alter frozen dossier (eff %)', e_id, v_snap, v_eff;

  -- =========================================================================
  raise notice '--- STAGE 7: REPLAY_IDEMPOTENCE ---';
  -- =========================================================================
  select md5(string_agg(espn_event_id||':'||coalesce(model_status,'')||':'||coalesce(p_home::text,'')||':'
             ||coalesce(p_over::text,'')||':'||coalesce(score_dist::text,''), '|' order by espn_event_id)) into h1
    from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_version=MV;
  delete from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_version=MV;
  perform v2.build_soccer_prediction_v2_staged(T_DEC);
  select md5(string_agg(espn_event_id||':'||coalesce(model_status,'')||':'||coalesce(p_home::text,'')||':'
             ||coalesce(p_over::text,'')||':'||coalesce(score_dist::text,''), '|' order by espn_event_id)) into h2
    from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_version=MV;
  if h1 is distinct from h2 then raise exception 'REPLAY FAIL: rebuild differs (% vs %)', h1, h2; end if;
  raise notice 'STAGE 7 REPLAY_IDEMPOTENCE_PASS: build twice -> identical staged output (md5 %)', h1;

  raise notice '==== SOCCER FINAL BRANCH GATE: ALL 7 STAGES PASS ====';
end $GATE$;

-- ============================================================================
-- ADVERSARIAL BATTERY — each must FAIL-CLOSED (RAISE on any that does not).
-- ============================================================================
do $ADV$
declare
  d jsonb; dist jsonb; ph numeric; pd numeric; pa numeric; byy numeric; bn numeric;
  po numeric; pu numeric; ts jsonb; ok boolean; caught boolean;
  n_supp int; n_ok int; bay text; man text; nfail int;
begin
  d := v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10);
  dist:=d->'dist'; ph:=(d->>'p_home')::numeric; pd:=(d->>'p_draw')::numeric; pa:=(d->>'p_away')::numeric;
  byy:=(d->>'btts_yes')::numeric; bn:=(d->>'btts_no')::numeric; po:=(d->>'p_over')::numeric;
  pu:=(d->>'p_under')::numeric; ts:=d->'top_scores';

  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  if not ok then raise exception 'ADV setup FAIL: baseline not coherent'; end if;

  -- MATRIX
  select coherence_ok into ok from v2.fn_event_gate_status(
    (select jsonb_agg(jsonb_build_object('s',c->>'s','p',round((c->>'p')::numeric*0.9,2))) from jsonb_array_elements(dist) c),
    ph,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV MATRIX FAIL: dist summing 90pct passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(
    (select jsonb_agg(jsonb_build_object('s',c->>'s','p',round((c->>'p')::numeric*1.1,2))) from jsonb_array_elements(dist) c),
    ph,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV MATRIX FAIL: dist summing >100pct passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(
    dist || jsonb_build_array(jsonb_build_object('s','7-7','p',-5.0)), ph,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV MATRIX FAIL: negative-prob cell passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(
    dist || jsonb_build_array(jsonb_build_object('s',(ts->0->>'s'),'p',10.0)), ph,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV MATRIX FAIL: duplicate score cell passed'; end if;
  caught := false;
  begin
    perform coherence_ok from v2.fn_event_gate_status(
      dist || jsonb_build_array(jsonb_build_object('s','x-y','p',1.0)), ph,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  exception when others then caught := true; end;
  if not caught then raise exception 'ADV MATRIX FAIL: invalid score key did not fail-close'; end if;
  raise notice 'ADV MATRIX: sum90 / sum>100 / negative / duplicate / invalid-key all FAIL-closed';

  -- SCALARS
  select coherence_ok into ok from v2.fn_event_gate_status(dist,null,pd,pa,po,pu,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV SCALARS FAIL: p_home NULL passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,null,ts,null,null,null,null,null);
  if ok then raise exception 'ADV SCALARS FAIL: btts_no NULL passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,null,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV SCALARS FAIL: p_under NULL on supported line passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn+15,ts,null,null,null,null,null);
  if ok then raise exception 'ADV SCALARS FAIL: btts_no +15pp passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu+15,4.5,byy,bn,ts,null,null,null,null,null);
  if ok then raise exception 'ADV SCALARS FAIL: p_under +15pp passed'; end if;
  raise notice 'ADV SCALARS: p_home/btts_no/p_under NULL + btts_no/p_under +15pp all FAIL-closed';

  -- PUSH / TOTAL LINE TYPES
  if (v2.fn_dist_from_lambda(2.697,1.266,3.5,0.0705,10)->>'ou_line_type') <> 'HALF' then raise exception 'ADV PUSH FAIL: 3.5 not HALF'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10)->>'ou_line_type') <> 'WHOLE' then raise exception 'ADV PUSH FAIL: 4.0 not WHOLE'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10)->>'p_push')::numeric <= 0 then raise exception 'ADV PUSH FAIL: 4.0 no push mass'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,2.25,-0.05,10)->>'ou_line_type') <> 'QUARTER' then raise exception 'ADV PUSH FAIL: 2.25 not QUARTER'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,2.75,-0.05,10)->>'ou_line_type') <> 'QUARTER' then raise exception 'ADV PUSH FAIL: 2.75 not QUARTER'; end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,3.1,-0.05,10);
  if (d->>'ou_supported')::boolean or (d->>'p_over') is not null then raise exception 'ADV PUSH FAIL: 3.1 not fail-closed'; end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10);
  if round(coalesce((d->>'p_over')::numeric,0)+coalesce((d->>'p_push')::numeric,0)+coalesce((d->>'p_under')::numeric,0),1) <> 100.0
     then raise exception 'ADV PUSH FAIL: whole-line over+push+under != 100'; end if;
  select count(*) filter (where not g.ok) into nfail from v2.fn_soccer_coherence_gate(
     jsonb_set(d,'{p_push}', to_jsonb(((d->>'p_push')::numeric+15))), 4.0) g;
  if nfail = 0 then raise exception 'ADV PUSH FAIL: p_push +15pp passed coherence'; end if;
  raise notice 'ADV PUSH: 3.5=HALF 4.0=WHOLE(push>0) 2.25/2.75=QUARTER 3.1=UNSUPPORTED; over+push+under=100; p_push+15 FAIL-closed';

  -- TOP_SCORES
  d := v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10); dist:=d->'dist'; ts:=d->'top_scores';
  ph:=(d->>'p_home')::numeric; pd:=(d->>'p_draw')::numeric; pa:=(d->>'p_away')::numeric;
  byy:=(d->>'btts_yes')::numeric; bn:=(d->>'btts_no')::numeric; po:=(d->>'p_over')::numeric; pu:=(d->>'p_under')::numeric;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,null,null,null,null,null,null);
  if ok then raise exception 'ADV TOPSCORES FAIL: NULL passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,'[]'::jsonb,null,null,null,null,null);
  if ok then raise exception 'ADV TOPSCORES FAIL: [] passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->0),null,null,null,null,null);
  if ok then raise exception 'ADV TOPSCORES FAIL: length-1 passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,
     jsonb_build_array(ts->0,ts->0,ts->2,ts->3,ts->4),null,null,null,null,null);
  if ok then raise exception 'ADV TOPSCORES FAIL: duplicate passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,
     jsonb_build_array(ts->1,ts->0,ts->2,ts->3,ts->4),null,null,null,null,null);
  if ok then raise exception 'ADV TOPSCORES FAIL: wrong-order passed'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,
     jsonb_build_array(jsonb_build_object('s',ts->0->>'s','p',((ts->0->>'p')::numeric+15)),ts->1,ts->2,ts->3,ts->4),
     null,null,null,null,null);
  if ok then raise exception 'ADV TOPSCORES FAIL: wrong-prob passed'; end if;
  raise notice 'ADV TOP_SCORES: NULL / [] / len1 / duplicate / wrong-order / wrong-prob all FAIL-closed';

  -- OWNER REGRESSION (discrepancy from the 6 real fixtures)
  create temporary table if not exists _adv_owner (eid text, flag text, suppress boolean) on commit drop;
  delete from _adv_owner;
  insert into _adv_owner
    select f.espn_event_id, dd.flag, dd.suppress
    from v2.gate_fixture_soccer_cards f
    cross join lateral v2.fn_model_market_discrepancy(
      f.disp_p_home,f.disp_p_draw,f.disp_p_away,f.disp_p_over,
      f.odds_home,f.odds_draw,f.odds_away,f.odds_over,f.odds_under) dd;
  select flag into bay from _adv_owner where eid='401915443';
  select flag into man from _adv_owner where eid='401915442';
  select count(*) filter (where suppress), count(*) filter (where flag='OK') into n_supp, n_ok from _adv_owner;
  if bay <> 'QUALITY_DOWNGRADE' then raise exception 'ADV OWNER FAIL: Bayern flag % (want QUALITY_DOWNGRADE)', bay; end if;
  if man <> 'QUALITY_DOWNGRADE' then raise exception 'ADV OWNER FAIL: Man United flag % (want QUALITY_DOWNGRADE)', man; end if;
  if n_supp <> 2 then raise exception 'ADV OWNER FAIL: % suppressed (want 2)', n_supp; end if;
  if n_ok <> 4 then raise exception 'ADV OWNER FAIL: % OK (want 4)', n_ok; end if;
  raise notice 'ADV OWNER REGRESSION: Bayern+Man United QUALITY_DOWNGRADE+suppress; other 4 OK (no-vig diagnostic, never P_RETO)';

  raise notice '==== ADVERSARIAL BATTERY: ALL FAIL-CLOSED AS SPECIFIED ====';
end $ADV$;
