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
-- ============================================================================
-- ADVERSARIAL BATTERY — each must FAIL-CLOSED (RAISE on any that does not).
-- Targets the v5 gate (iss045b): fn_event_gate_status 19-arg signature with the
-- persisted O/U settlement columns (p_push, p_ou_line_type, p_ou_supported).
-- ============================================================================
do $ADV$
declare
  d jsonb; dist jsonb; ph numeric; pd numeric; pa numeric; byy numeric; bn numeric;
  po numeric; pu numeric; ts jsonb; pp numeric; olt text; osup boolean; ok boolean; failclosed boolean;
  bay text; man text; bays boolean; mans boolean; nfail int; NN numeric := null;
begin
  d := v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10);
  dist:=d->'dist'; ph:=(d->>'p_home')::numeric; pd:=(d->>'p_draw')::numeric; pa:=(d->>'p_away')::numeric;
  byy:=(d->>'btts_yes')::numeric; bn:=(d->>'btts_no')::numeric; po:=(d->>'p_over')::numeric; pu:=(d->>'p_under')::numeric; ts:=d->'top_scores';
  pp:=(d->>'p_push')::numeric; olt:=(d->>'ou_line_type'); osup:=(d->>'ou_supported')::boolean;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if not ok then raise exception 'ADV baseline not coherent'; end if;
  -- MATRIX
  select coherence_ok into ok from v2.fn_event_gate_status((select jsonb_agg(jsonb_build_object('s',c->>'s','p',round((c->>'p')::numeric*0.9,2))) from jsonb_array_elements(dist) c),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV MATRIX sum90'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status((select jsonb_agg(jsonb_build_object('s',c->>'s','p',round((c->>'p')::numeric*1.1,2))) from jsonb_array_elements(dist) c),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV MATRIX sum110'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist||jsonb_build_array(jsonb_build_object('s','7-7','p',-5.0)),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV MATRIX negative'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist||jsonb_build_array(jsonb_build_object('s',(ts->0->>'s'),'p',10.0)),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV MATRIX duplicate'; end if;
  failclosed:=false; begin select coherence_ok into ok from v2.fn_event_gate_status(dist||jsonb_build_array(jsonb_build_object('s','x-y','p',1.0)),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if not ok then failclosed:=true; end if; exception when others then failclosed:=true; end;
  if not failclosed then raise exception 'ADV MATRIX invalid-key not fail-closed'; end if;
  raise notice 'ADV MATRIX: sum90/sum>100/negative/duplicate/invalid-key all FAIL-closed';
  -- SCALARS
  select coherence_ok into ok from v2.fn_event_gate_status(dist,NN,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV p_home null'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,NN,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV btts_no null'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,NN,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV p_under null'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn+15,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV btts_no+15'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu+15,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV p_under+15'; end if;
  raise notice 'ADV SCALARS: p_home/btts_no/p_under NULL + btts_no/p_under +15pp all FAIL-closed';
  -- PUSH / TOTAL LINE TYPES
  if (v2.fn_dist_from_lambda(2.697,1.266,3.5,0.0705,10)->>'ou_line_type')<>'HALF' then raise exception 'ADV 3.5 not HALF'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10)->>'ou_line_type')<>'WHOLE' then raise exception 'ADV 4.0 not WHOLE'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10)->>'p_push')::numeric<=0 then raise exception 'ADV 4.0 no push'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,2.25,-0.05,10)->>'ou_line_type')<>'QUARTER' then raise exception 'ADV 2.25 not QUARTER'; end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,2.75,-0.05,10)->>'ou_line_type')<>'QUARTER' then raise exception 'ADV 2.75 not QUARTER'; end if;
  d:=v2.fn_dist_from_lambda(3.2,1.1,3.1,-0.05,10); if (d->>'ou_supported')::boolean or (d->>'p_over') is not null then raise exception 'ADV 3.1 not fail-closed'; end if;
  d:=v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10);
  if round(coalesce((d->>'p_over')::numeric,0)+coalesce((d->>'p_push')::numeric,0)+coalesce((d->>'p_under')::numeric,0),1)<>100.0 then raise exception 'ADV whole over+push+under!=100'; end if;
  select count(*) filter (where not g.ok) into nfail from v2.fn_soccer_coherence_gate(jsonb_set(d,'{p_push}',to_jsonb(((d->>'p_push')::numeric+15))),4.0) g; if nfail=0 then raise exception 'ADV p_push+15 passed'; end if;
  raise notice 'ADV PUSH: 3.5=HALF 4.0=WHOLE(push>0) 2.25/2.75=QUARTER 3.1=UNSUPPORTED; over+push+under=100; p_push+15 FAIL-closed';
  -- TOP_SCORES
  d:=v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10); dist:=d->'dist'; ts:=d->'top_scores'; ph:=(d->>'p_home')::numeric; pd:=(d->>'p_draw')::numeric; pa:=(d->>'p_away')::numeric; byy:=(d->>'btts_yes')::numeric; bn:=(d->>'btts_no')::numeric; po:=(d->>'p_over')::numeric; pu:=(d->>'p_under')::numeric; pp:=(d->>'p_push')::numeric; olt:=(d->>'ou_line_type'); osup:=(d->>'ou_supported')::boolean;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,null::jsonb,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV ts null'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,'[]'::jsonb,pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV ts []'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->0),pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV ts len1'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->0,ts->0,ts->2,ts->3,ts->4),pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV ts dup'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->1,ts->0,ts->2,ts->3,ts->4),pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV ts order'; end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(jsonb_build_object('s',ts->0->>'s','p',((ts->0->>'p')::numeric+15)),ts->1,ts->2,ts->3,ts->4),pp,olt,osup,NN,NN,NN,NN,NN); if ok then raise exception 'ADV ts prob'; end if;
  raise notice 'ADV TOP_SCORES: NULL / [] / len1 / duplicate / wrong-order / wrong-prob all FAIL-closed';
  -- OWNER REGRESSION: Bayern + Man United must be QUALITY_DOWNGRADE + suppress (owner-documented pair).
  -- (With the REAL prod owner-card odds, Como 401915441 also flags REVIEW_REQUIRED on a genuine
  --  total_gap -13pp discrepancy — a legitimate gate hit, reported but not asserted as the pair.)
  select flag, suppress into bay, bays from v2.gate_fixture_soccer_cards f cross join lateral v2.fn_model_market_discrepancy(f.disp_p_home,f.disp_p_draw,f.disp_p_away,f.disp_p_over,f.odds_home,f.odds_draw,f.odds_away,f.odds_over,f.odds_under) dd where f.espn_event_id='401915443';
  select flag, suppress into man, mans from v2.gate_fixture_soccer_cards f cross join lateral v2.fn_model_market_discrepancy(f.disp_p_home,f.disp_p_draw,f.disp_p_away,f.disp_p_over,f.odds_home,f.odds_draw,f.odds_away,f.odds_over,f.odds_under) dd where f.espn_event_id='401915442';
  if bay<>'QUALITY_DOWNGRADE' or not bays then raise exception 'ADV OWNER Bayern % %',bay,bays; end if;
  if man<>'QUALITY_DOWNGRADE' or not mans then raise exception 'ADV OWNER ManU % %',man,mans; end if;
  raise notice 'ADV OWNER REGRESSION: Bayern + Man United QUALITY_DOWNGRADE + suppress (no-vig diagnostic from real odds, never P_RETO)';
  raise notice '==== ADVERSARIAL BATTERY: ALL FAIL-CLOSED AS SPECIFIED ====';
end $ADV$;

-- ============================================================================
-- REAL-PATH ASSERTIONS — 6 owner UEFA Champions League fixtures (crossleague route)
-- ============================================================================
-- Blocker AUDIT 5623863543 / 5623894301: on the REAL path
--   build_soccer_prediction_v2_staged -> v_soccer_event_gate -> v_soccer_daily_candidates
-- the 6 owner UCL fixtures used to fail-close as "Competencia no aprobada para el
-- modelo" (competition_id=2 is UEFA Champions League; approval lives in
-- v2.crossleague_competencias, not the domestic v2.model_registry). iss033 now routes
-- crossleague-approved competitions through v2.fn_crossleague_staged (crossleague
-- Dixon-Coles + phi liga + REAL provider line via the SAME v2.fn_dist_from_lambda
-- matrix source). This block builds at a decision BEFORE the earliest kickoff (16:45)
-- so ALL SIX fixtures are in the future universe, and asserts each one over the REAL
-- path. RAISE on any violation. Requires seed_soccer_branch_data.sql (which now seeds
-- the 6 real agenda rows, real DraftKings momios, real 540d club historico) applied.
--
-- REAL-DATA OUTCOME (documented, honest — verified on branch qcfjvnmjjfiiwugrxksv):
--   401915441 Como–RB Leipzig      READY  coherence_ok  disc OK              -> IN candidates (7)
--   401915444 Fenerbahce–AS Roma   READY  coherence_ok  disc OK              -> IN candidates (7)
--   401915443 Bayern–Bodo/Glimt    READY  coherence_ok  QUALITY_DOWNGRADE    -> suppressed AFTER a real prediction (NOT in candidates)
--   401915422 PSV–Shakhtar         DATA_INCOMPLETE  (Shakhtar: 0 tracked domestic matches) -> legitimate real-data fail-close
--   401915440 Slavia Praha–Lens    DATA_INCOMPLETE  (Slavia:   0 tracked domestic matches) -> legitimate real-data fail-close
--   401915442 Manchester Utd–Sabah DATA_INCOMPLETE  (Sabah:    0 tracked domestic matches) -> legitimate real-data fail-close
-- The three fail-closes are AFTER the builder attempts the crossleague model, for the
-- REAL reason "sin muestra doméstica suficiente" — never from empty config/mapping.
-- (Their away leagues — Ukrainian, Czech, Azerbaijani — are not in historico_partidos_espn.)
-- ============================================================================
do $XL$
declare
  T_XL constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  MV   constant text := 'dc-2026.09.1';
  ready_ids  text[] := array['401915441','401915443','401915444'];      -- crossleague produced P_RETO
  elig_ids   text[] := array['401915441','401915444'];                  -- eligible -> candidates
  supp_ids   text[] := array['401915443'];                              -- coherent but suppressed (disc)
  failc_ids  text[] := array['401915422','401915440','401915442'];      -- legitimate real-data fail-close
  all6       text[] := array['401915422','401915440','401915441','401915442','401915443','401915444'];
  r record; n int; e text;
begin
  raise notice '--- REAL-PATH: 6 owner UCL fixtures (decision %) ---', T_XL;

  -- rebuild the universe at the pre-kickoff decision
  delete from v2.soccer_prediction_v2_staged where decision_time=T_XL and model_version=MV;
  perform v2.build_soccer_prediction_v2_staged(T_XL);

  -- (0) all six must be STAGED (agenda universe visibility; competition resolves to id 2)
  select count(distinct espn_event_id) into n from v2.soccer_prediction_v2_staged
    where decision_time=T_XL and model_version=MV and espn_event_id = any(all6);
  if n <> 6 then raise exception 'REALPATH FAIL: only %/6 owner fixtures staged (agenda universe drop)', n; end if;
  perform 1 from v2.soccer_prediction_v2_staged where decision_time=T_XL and espn_event_id=any(all6) and competition_id <> 2;
  if found then raise exception 'REALPATH FAIL: an owner fixture did not resolve to competition_id=2 (UCL)'; end if;

  -- (1) the three crossleague-servible fixtures are READY with the full persisted contract
  foreach e in array ready_ids loop
    select * into r from v2.soccer_prediction_v2_staged where espn_event_id=e and decision_time=T_XL and model_version=MV;
    if r.model_status <> 'READY_UNVALIDATED' then raise exception 'REALPATH FAIL: % expected READY, got % (%)', e, r.model_status, r.model_status_reason; end if;
    if r.p_home is null or r.p_draw is null or r.p_away is null or r.btts_yes is null or r.btts_no is null then raise exception 'REALPATH FAIL: % READY but P_RETO/BTTS null', e; end if;
    if r.score_dist is null or jsonb_array_length(r.top_scores) <> 5 then raise exception 'REALPATH FAIL: % missing score_dist/top-5', e; end if;
    if r.over_line is null or not r.ou_supported or r.p_over is null or r.p_under is null or r.p_push is null then raise exception 'REALPATH FAIL: % READY but O/U settlement incomplete at real line', e; end if;
    if r.feature_snapshot_id is null then raise exception 'REALPATH FAIL: % READY but no feature_snapshot (provenance)', e; end if;
    if not r.temporal_safe then raise exception 'REALPATH FAIL: % READY but temporal_safe=false', e; end if;
    if (r.provenance->>'model_family') <> 'crossleague_v1' then raise exception 'REALPATH FAIL: % not routed through crossleague model (family=%)', e, r.provenance->>'model_family'; end if;
    -- coherence: every published market sums the persisted matrix within 0.2pp
    if abs(r.p_home - v2.fn_matrix_market(r.score_dist,'1X2','HOME')) > 0.2
       or abs(r.btts_yes - v2.fn_matrix_market(r.score_dist,'BTTS','YES')) > 0.2
       or abs(r.p_over - v2.fn_matrix_market(r.score_dist,'OU','OVER',r.over_line)) > 0.2
       or round(coalesce(r.p_over,0)+coalesce(r.p_push,0)+coalesce(r.p_under,0),1) <> 100.0
    then raise exception 'REALPATH FAIL: % markets do not derive from persisted matrix', e; end if;
  end loop;

  -- (2) gate coherence_ok=true for all READY; suppressed set has suppress=true; eligible set eligible
  foreach e in array ready_ids loop
    select * into r from v2.v_soccer_event_gate where canonical_event_id=e and decision_time=T_XL and model_version=MV;
    if not r.coherence_ok then raise exception 'REALPATH FAIL: % READY not coherence_ok (%)', e, r.gate_reason; end if;
    if r.gate_reason like '%; ;%' or r.gate_reason like '; %' then raise exception 'REALPATH FAIL: % gate_reason malformed: %', e, r.gate_reason; end if;
  end loop;
  foreach e in array supp_ids loop
    select * into r from v2.v_soccer_event_gate where canonical_event_id=e and decision_time=T_XL and model_version=MV;
    if not r.coherence_ok then raise exception 'REALPATH FAIL: % expected coherent-but-suppressed, coherence_ok=false', e; end if;
    if not r.suppress or r.disc_flag not in ('QUALITY_DOWNGRADE','REVIEW_REQUIRED') then raise exception 'REALPATH FAIL: % expected suppress via discrepancy, got flag=% suppress=%', e, r.disc_flag, r.suppress; end if;
    if r.top_only_eligible then raise exception 'REALPATH FAIL: % suppressed yet top_only_eligible', e; end if;
  end loop;
  foreach e in array elig_ids loop
    select top_only_eligible into r from v2.v_soccer_event_gate where canonical_event_id=e and decision_time=T_XL and model_version=MV;
    if not r.top_only_eligible then raise exception 'REALPATH FAIL: % expected top_only_eligible', e; end if;
  end loop;

  -- (3) legitimate real-data fail-close: DATA_INCOMPLETE, null P_RETO, reason is domestic-sample, NOT eligible
  foreach e in array failc_ids loop
    select * into r from v2.soccer_prediction_v2_staged where espn_event_id=e and decision_time=T_XL and model_version=MV;
    if r.model_status = 'READY_UNVALIDATED' then raise exception 'REALPATH FAIL: % unexpectedly READY (should fail-close on real data)', e; end if;
    if r.p_home is not null then raise exception 'REALPATH FAIL: % fail-close but P_RETO not null', e; end if;
    if r.model_status_reason not ilike '%muestra dom%' then raise exception 'REALPATH FAIL: % fail-close reason not domestic-sample: %', e, r.model_status_reason; end if;
    if exists (select 1 from v2.v_soccer_event_gate g where g.canonical_event_id=e and g.decision_time=T_XL and g.top_only_eligible) then raise exception 'REALPATH FAIL: % fail-close yet eligible', e; end if;
  end loop;

  -- (4) candidates surface = exactly the eligible fixtures (coherent + not suppressed)
  select array_agg(distinct canonical_event_id order by canonical_event_id) into ready_ids
    from v2.v_soccer_daily_candidates where decision_time=T_XL and model_version=MV and canonical_event_id = any(all6);
  if ready_ids is distinct from elig_ids then raise exception 'REALPATH FAIL: candidates % != eligible %', ready_ids, elig_ids; end if;
  -- no NxM duplication
  select coalesce(max(c),0) into n from (select canonical_event_id, count(*) c from v2.v_soccer_daily_candidates where decision_time=T_XL and model_version=MV group by 1) z;
  if n > 7 then raise exception 'REALPATH FAIL: NxM duplication (% candidates for one event)', n; end if;

  raise notice 'REAL-PATH 6-FIXTURE PASS: Como+Fenerbahce READY->eligible->candidates; Bayern READY+coherent->QUALITY_DOWNGRADE suppressed; PSV/Slavia/ManU legitimate DATA_INCOMPLETE (away team 0 tracked domestic matches). Gate reasons clean.';
end $XL$;
