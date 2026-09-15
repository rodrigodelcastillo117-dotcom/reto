-- ============================================================================
-- run_soccer_final_branch_gate.sql — SOCCER FINAL BRANCH GATE (audit runner) v2
-- ============================================================================
-- Reproducible, executable, self-contained real-path proof. Apply AFTER the ordered
-- migrations chain + the three committed seeds. NO PROD MUTATION.
--
-- WHY v2 (auditor 5624210107): the v1 runner could FALSE-GREEN. Its Stage 2 only required
-- `n_ready >= 1` from the DOMESTIC builder, and its six-owner proof came from the separate
-- `v2.gate_fixture_soccer_cards` math-unit views — so "ALL STAGES PASS" was reachable with
-- La Liga rows passing while the six owner UCL cards never traversed
-- builder -> staged -> v_soccer_event_gate -> v_soccer_daily_candidates.
-- v2 makes the six-owner REAL-PATH check an EXACT-SET assertion over that real chain, and
-- `gate_fixture_*` is demoted to what it actually is: a math unit test.
--
-- DECISION EPOCH: 2026-09-10 12:00:00+00.
--   Every owner fixture kicks off at 16:45Z or 19:00Z, and the real pregame DraftKings
--   lines were captured 11:49:02Z. 12:00Z is therefore strictly pre-kickoff for all six
--   AND after their line capture. The v1 epoch (17:00Z) was AFTER the 16:45Z kickoff of
--   401915422 and 401915444, which is the real reason those two had no staged row.
--   STAGE 6 asserts that a POST-kickoff epoch still excludes them (the universe filter is
--   not loosened; only the decision time was wrong).
--
-- EVIDENCE MODEL: every stage writes a row into v2.gate_run_log and records PASS/FAIL
-- WITHOUT raising, so the full evidence table survives a failure. The FINAL statement
-- raises if any row is not PASS. This also makes the proof readable over a SQL-only
-- channel (RAISE NOTICE output is dropped by the Supabase MCP/REST interface).
-- Read the evidence with:  select * from v2.gate_run_log order by seq;
-- ============================================================================

drop table if exists v2.gate_run_log;
create table v2.gate_run_log (
  seq serial primary key, stage text, status text, detail text, at timestamptz default now());

-- ── STAGE 1: SCHEMA_BOOTSTRAP ───────────────────────────────────────────────
do $S1$
declare miss text := null; n int;
begin
  if to_regprocedure('v2.fn_dist_from_lambda(numeric,numeric,numeric,numeric,integer)') is null then miss := concat_ws(', ',miss,'fn_dist_from_lambda'); end if;
  if to_regprocedure('v2.build_soccer_prediction_v2_staged(timestamptz,boolean,text)') is null then miss := concat_ws(', ',miss,'builder'); end if;
  if to_regprocedure('v2.fn_crossleague_lambda_asof(text,text,integer,integer,integer,timestamptz,text,integer,boolean)') is null then miss := concat_ws(', ',miss,'fn_crossleague_lambda_asof'); end if;
  if to_regprocedure('v2.fn_crossleague_features_asof(text,timestamptz,integer,boolean)') is null then miss := concat_ws(', ',miss,'fn_crossleague_features_asof'); end if;
  if to_regprocedure('v2.fn_soccer_model_route(text,integer,text,text,text,text,text)') is null then miss := concat_ws(', ',miss,'fn_soccer_model_route'); end if;
  if to_regprocedure('v2.fn_crossleague_phi_asof(integer,timestamptz,text)') is null then miss := concat_ws(', ',miss,'fn_crossleague_phi_asof'); end if;
  if to_regclass('v2.soccer_prediction_v2_staged') is null then miss := concat_ws(', ',miss,'staged table'); end if;
  if to_regclass('v2.feature_snapshot') is null then miss := concat_ws(', ',miss,'feature_snapshot'); end if;
  if to_regclass('v2.liga_fuerza_snapshot_seal') is null then miss := concat_ws(', ',miss,'liga_fuerza_snapshot_seal'); end if;
  if to_regclass('v2.v_soccer_event_gate') is null then miss := concat_ws(', ',miss,'v_soccer_event_gate'); end if;
  if to_regclass('v2.v_soccer_daily_candidates') is null then miss := concat_ws(', ',miss,'v_soccer_daily_candidates'); end if;
  if to_regclass('v2.v_soccer_staged_identity_violations') is null then miss := concat_ws(', ',miss,'v_soccer_staged_identity_violations'); end if;
  if to_regprocedure('v2.fn_soccer_dossier_manifest(text,timestamptz)') is null then miss := concat_ws(', ',miss,'dossier manifest'); end if;
  select count(*) into n from pg_proc p join pg_namespace np on np.oid=p.pronamespace
   where np.nspname='v2' and p.proname='fn_event_gate_status';
  if n <> 1 then miss := concat_ws(', ',miss,'fn_event_gate_status signatures='||n||' (want 1)'); end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('1_SCHEMA_BOOTSTRAP', case when miss is null then 'PASS' else 'FAIL' end,
     coalesce('missing/wrong: '||miss, 'all core objects present; exactly 1 fn_event_gate_status signature'));
end $S1$;

-- ── STAGE 2: GOVERNANCE_SEED (reproducible config, no silent bypass) ────────
do $S2$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  n_cat int; n_sup int; n_map int; n_xl_appr int; n_xl_reg int; v_cut timestamptz;
  b_integ boolean; n_ambig int; fails text := null; v_guard boolean;
begin
  select count(*) into n_cat from v2.competition_catalog where sport='soccer';
  if n_cat < 29 then fails := concat_ws('; ',fails,'competition_catalog soccer rows='||n_cat||' (<29)'); end if;
  select count(*) into n_sup from v2.competition_catalog where sport='soccer' and model_supported;
  select count(*) into n_map from v2.competition_provider_map where mapping_version='compmap_v1';
  if n_map < 1 then fails := concat_ws('; ',fails,'competition_provider_map empty'); end if;
  -- UCL must be model_supported=FALSE in the catalog: crossleague support is a SEPARATE
  -- authority. If this ever flips to true, someone faked domestic approval for UCL.
  if exists (select 1 from v2.competition_catalog
             where competition_id='uefa_champions_league' and model_supported is true) then
    fails := concat_ws('; ',fails,'UCL catalog.model_supported=true (domestic approval faked for UCL)');
  end if;
  select count(*) into n_xl_appr from v2.crossleague_competencias where aprobada is true;
  if n_xl_appr <> 2 then fails := concat_ws('; ',fails,'crossleague aprobada='||n_xl_appr||' (want exactly 2: UCL+UEL)'); end if;
  select count(*) into n_xl_reg from v2.model_registry
   where sport='soccer' and model_name='crossleague' and model_version='crossleague_v1' and approved is true;
  if n_xl_reg <> 2 then fails := concat_ws('; ',fails,'crossleague model_registry approvals='||n_xl_reg||' (want 2)'); end if;
  -- sealed phi must exist, be integral, and be STRICTLY BEFORE the decision epoch
  v_cut := v2.fn_crossleague_active_cutoff(T_DEC,'crossleague_v1');
  if v_cut is null then fails := concat_ws('; ',fails,'no sealed phi snapshot with cutoff<=decision');
  else
    b_integ := v2.fn_crossleague_snapshot_integrity('crossleague_v1', v_cut);
    if not b_integ then fails := concat_ws('; ',fails,'phi snapshot integrity FALSE at '||v_cut); end if;
    if v_cut > T_DEC then fails := concat_ws('; ',fails,'phi cutoff '||v_cut||' > decision'); end if;
  end if;
  begin v_guard := v2.fn_crossleague_config_guard('crossleague_v1');
  exception when others then fails := concat_ws('; ',fails,'config guard raised: '||SQLERRM); end;
  -- DISJOINTNESS: no competition may be approved for both models (two P_RETO authorities)
  select count(*) into n_ambig from (
    select r1.liga_id from v2.model_registry r1
    where r1.sport='soccer' and r1.model_name='reto_dc_v2' and r1.approved is true
    intersect
    select r2.liga_id from v2.model_registry r2
    where r2.sport='soccer' and r2.model_name='crossleague' and r2.approved is true) z;
  if n_ambig <> 0 then fails := concat_ws('; ',fails,n_ambig||' competitions approved for BOTH models'); end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('2_GOVERNANCE_SEED', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('catalog=%s soccer rows (%s domestic model_supported; UCL stays false) · provider_map=%s · crossleague approved=%s (registry %s) · phi sealed cutoff=%s integrity=true · config guard ok · both-model competitions=0',
       n_cat, n_sup, n_map, n_xl_appr, n_xl_reg, v_cut)));
end $S2$;

-- ── STAGE 3: DATA_BUILDER (real builder over the real universe) ─────────────
do $S3$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  n_src int; n_proc int; n_ready int; n_rej int; n_ident int; fails text := null;
  n_dom_ready int; n_xl_ready int;
begin
  select count(*) into n_src from public.agenda_espn where deporte='soccer' and fecha > T_DEC;
  delete from v2.soccer_prediction_v2_staged where decision_time = T_DEC;
  delete from v2.feature_snapshot where decision_time = T_DEC;
  select v2.build_soccer_prediction_v2_staged(T_DEC) into n_proc;
  select count(*) into n_ready from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_status='READY_UNVALIDATED';
  select count(*) into n_rej   from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_status<>'READY_UNVALIDATED';
  select count(*) into n_dom_ready from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_status='READY_UNVALIDATED' and model_route='DOMESTIC';
  select count(*) into n_xl_ready  from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_status='READY_UNVALIDATED' and model_route='CROSSLEAGUE';
  select count(*) into n_ident from v2.v_soccer_staged_identity_violations;
  if n_proc <> n_src then fails := concat_ws('; ',fails,'processed '||n_proc||' != universe '||n_src); end if;
  if n_ready + n_rej <> n_proc then fails := concat_ws('; ',fails,'ready('||n_ready||')+rejected('||n_rej||') != processed('||n_proc||')'); end if;
  if n_ident <> 0 then fails := concat_ws('; ',fails,n_ident||' events with >1 staged row (parallel P_RETO)'); end if;
  -- the whole point of iss051: the crossleague route must actually PRODUCE predictions
  if n_xl_ready < 1 then fails := concat_ws('; ',fails,'0 CROSSLEAGUE READY rows — crossleague model still not wired into the real path'); end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('3_DATA_BUILDER', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('universe=%s processed=%s READY=%s (domestic %s + crossleague %s) fail-closed=%s · identity violations=0',
       n_src, n_proc, n_ready, n_dom_ready, n_xl_ready, n_rej)));
end $S3$;

-- rejection-reason census (evidence, not an assertion)
do $S3b$
declare r record;
begin
  for r in select model_route, model_status, model_status_reason, count(*) c
           from v2.soccer_prediction_v2_staged
           where decision_time = timestamptz '2026-09-10 12:00:00+00' and model_status<>'READY_UNVALIDATED'
           group by 1,2,3 order by 4 desc loop
    insert into v2.gate_run_log(stage,status,detail) values
      ('3b_REJECTION_CENSUS','INFO', format('%s/%s x%s :: %s', r.model_route, r.model_status, r.c, r.model_status_reason));
  end loop;
end $S3b$;

-- ── STAGE 4: OWNER_REALPATH — EXACT-SET e2e assertion over the six fixtures ──
-- This is the release proof the auditor demanded. For EACH of the six ids the runner
-- walks agenda -> staged -> v_soccer_event_gate -> v_soccer_daily_candidates and requires
-- either a full READY contract, or a fail-close whose reason is a DATA reason. A fail-close
-- caused by config/mapping/seed/approval is an explicit FAIL.
do $S4$
declare
  T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  OWNER constant text[] := array['401915422','401915440','401915441','401915442','401915443','401915444'];
  CONFIG_RX constant text := '(no aprobada para el modelo|no mapeada|CATALOG_MISSING|CATALOG_DISABLED|MAPPING_NOT_END_TO_END|PARAMS_MISSING|CONFIG_MISSING|CONFIG_DRIFT|PHI_SNAPSHOT_UNAVAILABLE|MAPPING_UNSET|no aprobada OOS)';
  id text; s record; g record; n_rows int; n_cand int; n_ag int; fails text := null; det text := null;
  n_ready int := 0; n_failclose int := 0;
begin
  foreach id in array OWNER loop
    select count(*) into n_ag from public.agenda_espn where espn_event_id=id and deporte='soccer' and fecha > T_DEC;
    if n_ag = 0 then
      fails := concat_ws('; ',fails,id||': NOT in the builder universe at decision (agenda row missing or kickoff<=decision)');
      continue;
    end if;
    select count(*) into n_rows from v2.soccer_prediction_v2_staged where espn_event_id=id and decision_time=T_DEC;
    if n_rows <> 1 then
      fails := concat_ws('; ',fails,id||': '||n_rows||' staged rows (want exactly 1)');
      continue;
    end if;
    select * into s from v2.soccer_prediction_v2_staged where espn_event_id=id and decision_time=T_DEC;
    select * into g from v2.v_soccer_event_gate where canonical_event_id=id and decision_time=T_DEC and model_version=s.model_version;
    select count(*) into n_cand from v2.v_soccer_daily_candidates where canonical_event_id=id and decision_time=T_DEC;

    -- the six are UCL: routing must resolve to the approved crossleague model, never NONE
    if s.model_route is distinct from 'CROSSLEAGUE' then
      fails := concat_ws('; ',fails,id||': model_route='||coalesce(s.model_route,'NULL')||' (want CROSSLEAGUE; UCL is crossleague-approved)');
    end if;

    if s.model_status = 'READY_UNVALIDATED' then
      n_ready := n_ready + 1;
      if s.score_dist is null then fails := concat_ws('; ',fails,id||': READY without score_dist'); end if;
      if s.top_scores is null or jsonb_array_length(s.top_scores) <> 5 then fails := concat_ws('; ',fails,id||': top_scores not len 5'); end if;
      if s.p_home is null or s.p_draw is null or s.p_away is null then fails := concat_ws('; ',fails,id||': 1X2 incomplete'); end if;
      if abs((coalesce(s.p_home,0)+coalesce(s.p_draw,0)+coalesce(s.p_away,0))-100) > 0.2 then fails := concat_ws('; ',fails,id||': 1X2 sum off by >0.2pp'); end if;
      -- 0.2pp is the GATE's tolerance: btts_yes/btts_no are each rounded to 1dp from a matrix that
      -- sums to exactly 100, so the pair can legitimately read 100.1 (e.g. 56.2+43.9). Asserting
      -- exact equality here would be stricter than the contract the gate enforces.
      if abs((coalesce(s.btts_yes,0)+coalesce(s.btts_no,0))-100) > 0.2 then fails := concat_ws('; ',fails,id||': BTTS sum off by >0.2pp'); end if;
      if s.over_line is null then fails := concat_ws('; ',fails,id||': READY without a real provider total line'); end if;
      if s.over_line is not null and s.ou_supported then
        if abs((coalesce(s.p_over,0)+coalesce(s.p_push,0)+coalesce(s.p_under,0))-100) > 0.2 then fails := concat_ws('; ',fails,id||': over+push+under off by >0.2pp'); end if;
      end if;
      if s.feature_snapshot_id is null then fails := concat_ws('; ',fails,id||': READY without feature_snapshot_id'); end if;
      if not coalesce(s.temporal_safe,false) then fails := concat_ws('; ',fails,id||': READY but temporal_safe false'); end if;
      if s.provenance->'phi'->>'phi_training_cutoff' is null then fails := concat_ws('; ',fails,id||': crossleague READY without sealed phi provenance'); end if;
      -- after a REAL prediction exists, the gate decides: eligible OR suppressed-with-reason
      if g.coherence_ok is not true then fails := concat_ws('; ',fails,id||': READY but coherence_ok not true ('||coalesce(g.gate_reason,'')||')'); end if;
      if g.top_only_eligible then
        if n_cand = 0 then fails := concat_ws('; ',fails,id||': eligible but 0 candidates'); end if;
      else
        if n_cand <> 0 then fails := concat_ws('; ',fails,id||': suppressed but '||n_cand||' candidates leaked'); end if;
        if g.disc_flag is null or g.disc_flag in ('OK','NO_MARKET_DIAGNOSTIC') then
          fails := concat_ws('; ',fails,id||': not eligible yet disc_flag='||coalesce(g.disc_flag,'NULL'));
        end if;
      end if;
      det := concat_ws(E'\n', det, format('%s %s vs %s :: READY %s · P(H/D/A)=%s/%s/%s · BTTS %s/%s · line %s (%s) O/P/U=%s/%s/%s · samples %s/%s · phi_cut=%s · gate=%s suppress=%s cand=%s%s',
        id, s.home_team, s.away_team, s.model_version, s.p_home, s.p_draw, s.p_away, s.btts_yes, s.btts_no,
        s.over_line, s.ou_line_type, s.p_over, s.p_push, s.p_under, s.sample_home, s.sample_away,
        s.provenance->'phi'->>'phi_training_cutoff', coalesce(g.disc_flag,'-'), g.suppress, n_cand,
        case when g.gate_reason is not null then ' · reason='||g.gate_reason else '' end));
    else
      n_failclose := n_failclose + 1;
      -- a fail-close is only legitimate if the reason is about DATA, never about config
      if coalesce(s.model_status_reason,'') ~* CONFIG_RX then
        fails := concat_ws('; ',fails,id||': fail-closed for a CONFIG reason ("'||s.model_status_reason||'") — must be a real data reason');
      end if;
      if s.p_home is not null or s.p_over is not null or s.score_dist is not null then
        fails := concat_ws('; ',fails,id||': fail-closed but still published probabilities');
      end if;
      if n_cand <> 0 then fails := concat_ws('; ',fails,id||': fail-closed but '||n_cand||' candidates leaked'); end if;
      det := concat_ws(E'\n', det, format('%s %s vs %s :: %s (%s) · samples %s/%s · reason=%s · candidates=%s',
        id, s.home_team, s.away_team, s.model_status, s.model_route, s.sample_home, s.sample_away, s.model_status_reason, n_cand));
    end if;
  end loop;
  insert into v2.gate_run_log(stage,status,detail) values
    ('4_OWNER_REALPATH', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce('FAILURES: '||fails, format('6/6 owner fixtures traversed the REAL path (READY=%s, legitimate data fail-close=%s); no config-caused fail-close',n_ready,n_failclose))
       || coalesce(E'\n'||det,''));
end $S4$;

-- ── STAGE 5: COHERENCE — every READY scalar derives from the persisted matrix ─
do $S5$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  r record; fails text := null; n int := 0; n_line_ne int := 0;
begin
  for r in select * from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_status='READY_UNVALIDATED' loop
    n := n + 1;
    if abs(r.p_home - v2.fn_matrix_market(r.score_dist,'1X2','HOME')) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' p_home'); end if;
    if abs(r.p_draw - v2.fn_matrix_market(r.score_dist,'1X2','DRAW')) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' p_draw'); end if;
    if abs(r.p_away - v2.fn_matrix_market(r.score_dist,'1X2','AWAY')) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' p_away'); end if;
    if abs(r.btts_yes - v2.fn_matrix_market(r.score_dist,'BTTS','YES')) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' btts_yes'); end if;
    if abs(r.btts_no  - v2.fn_matrix_market(r.score_dist,'BTTS','NO'))  > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' btts_no'); end if;
    if jsonb_array_length(r.top_scores) <> 5 then fails := concat_ws('; ',fails,r.espn_event_id||' top_scores len'); end if;
    if r.over_line is not null and r.ou_supported then
      if abs(r.p_over  - v2.fn_matrix_market(r.score_dist,'OU','OVER', r.over_line)) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' p_over'); end if;
      if abs(r.p_under - v2.fn_matrix_market(r.score_dist,'OU','UNDER',r.over_line)) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' p_under'); end if;
      if abs(r.p_push  - v2.fn_matrix_market(r.score_dist,'OU','PUSH', r.over_line)) > 0.2 then fails := concat_ws('; ',fails,r.espn_event_id||' p_push'); end if;
    end if;
    -- ANTI-HARDCODE: the persisted line must be the REAL provider line at decision time
    if r.over_line is distinct from (select provider_total_line from v2.fn_real_total_line(r.espn_event_id, T_DEC)) then
      n_line_ne := n_line_ne + 1;
      fails := concat_ws('; ',fails,r.espn_event_id||' over_line != provider line');
    end if;
  end loop;
  -- gate must independently agree for every READY row
  if exists (select 1 from v2.v_soccer_event_gate g
             join v2.soccer_prediction_v2_staged s on s.espn_event_id=g.canonical_event_id
               and s.decision_time=g.decision_time and s.model_version=g.model_version
             where g.decision_time=T_DEC and s.model_status='READY_UNVALIDATED' and g.coherence_ok is not true) then
    fails := concat_ws('; ',fails,'some READY rows are not coherence_ok');
  end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('5_COHERENCE', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('%s READY rows: all 1X2/BTTS/O-U/push scalars derive from the persisted score_dist (<=0.2pp), top_scores=5, over_line == real provider line for all %s', n, n)));
end $S5$;

-- ── STAGE 6: TEMPORAL (post-decision odds, wrong line, post-kickoff, sealed phi) ──
do $S6$
declare
  T_DEC  constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  T_POST constant timestamptz := timestamptz '2026-09-10 17:00:00+00';
  e_id text; b0 boolean; b1 boolean; df text; fails text := null;
  h_before text; h_after text; n_post int; ln numeric;
begin
  -- (a) post-decision odds must not change eligibility
  select g.canonical_event_id into e_id
  from v2.v_soccer_event_gate g
  join v2.soccer_prediction_v2_staged s on s.espn_event_id=g.canonical_event_id
    and s.decision_time=g.decision_time and s.model_version=g.model_version
  where g.decision_time=T_DEC and g.top_only_eligible and s.over_line is not null
  order by g.canonical_event_id limit 1;
  if e_id is null then
    fails := concat_ws('; ',fails,'no eligible event with a line to probe');
  else
    select top_only_eligible into b0 from v2.v_soccer_event_gate where canonical_event_id=e_id and decision_time=T_DEC;
    select over_line into ln from v2.soccer_prediction_v2_staged where espn_event_id=e_id and decision_time=T_DEC;
    insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
      values (e_id, 9.00,7.00,1.05,8.00,1.05, ln, T_DEC + interval '2 hours','ADV_POST',true);
    select top_only_eligible into b1 from v2.v_soccer_event_gate where canonical_event_id=e_id and decision_time=T_DEC;
    if b1 is distinct from b0 then fails := concat_ws('; ',fails,'post-decision odds changed eligibility of '||e_id); end if;
    -- (b) a pregame row on a DIFFERENT line must not drive the totals diagnostic
    insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
      values (e_id, 2.0,3.4,3.6, 8.00,1.05, 9.5, T_DEC - interval '2 hours','ADV_WRONGLINE',true);
    select disc_flag into df from v2.v_soccer_event_gate where canonical_event_id=e_id and decision_time=T_DEC;
    if df = 'QUALITY_DOWNGRADE' then fails := concat_ws('; ',fails,'wrong-line (9.5) forced a false QUALITY_DOWNGRADE on '||e_id); end if;
    delete from public.v_momios_confiables where bookmaker in ('ADV_POST','ADV_WRONGLINE');
  end if;

  -- (c) POST-KICKOFF epoch must still EXCLUDE the two 16:45Z fixtures. This proves the
  --     12:00Z epoch is a correct pre-kickoff decision time, not a loosened universe filter.
  delete from v2.soccer_prediction_v2_staged where decision_time = T_POST;
  delete from v2.feature_snapshot where decision_time = T_POST;
  perform v2.build_soccer_prediction_v2_staged(T_POST);
  select count(*) into n_post from v2.soccer_prediction_v2_staged
   where decision_time=T_POST and espn_event_id in ('401915422','401915444');
  if n_post <> 0 then fails := concat_ws('; ',fails,'post-kickoff epoch still staged '||n_post||' of the 16:45Z fixtures (universe filter broken)'); end if;
  delete from v2.soccer_prediction_v2_staged where decision_time = T_POST;
  delete from v2.feature_snapshot where decision_time = T_POST;

  -- (d) SEALED phi immunity: mutating the LIVE v2.liga_fuerza must not move any output.
  select md5(string_agg(espn_event_id||':'||coalesce(p_home::text,'')||':'||coalesce(score_dist::text,''), '|' order by espn_event_id))
    into h_before from v2.soccer_prediction_v2_staged where decision_time=T_DEC;
  update v2.liga_fuerza set phi = phi + 5.0 where liga_id = 78;
  delete from v2.soccer_prediction_v2_staged where decision_time = T_DEC;
  delete from v2.feature_snapshot where decision_time = T_DEC;
  perform v2.build_soccer_prediction_v2_staged(T_DEC);
  select md5(string_agg(espn_event_id||':'||coalesce(p_home::text,'')||':'||coalesce(score_dist::text,''), '|' order by espn_event_id))
    into h_after from v2.soccer_prediction_v2_staged where decision_time=T_DEC;
  update v2.liga_fuerza set phi = phi - 5.0 where liga_id = 78;
  if h_before is distinct from h_after then
    fails := concat_ws('; ',fails,'mutating LIVE liga_fuerza changed staged output — builder is reading live phi, not the sealed snapshot');
  end if;

  insert into v2.gate_run_log(stage,status,detail) values
    ('6_TEMPORAL', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('post-decision odds ignored (event %s); wrong-line 9.5 ignored; post-kickoff 17:00Z epoch excludes both 16:45Z fixtures; live liga_fuerza phi+5 did NOT change output (sealed phi honoured, md5 %s)', e_id, h_before)));
end $S6$;

-- ── STAGE 7: SELECTOR ───────────────────────────────────────────────────────
do $S7$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  n_ready int; n_analysis int; m int; n_dupgate int; n_ev int; n_bad int; fails text := null;
begin
  select count(*) into n_ready from v2.soccer_prediction_v2_staged where decision_time=T_DEC and model_status='READY_UNVALIDATED';
  select count(*) into n_analysis from v2.v_soccer_analysis_all where decision_time=T_DEC;
  if n_analysis <> n_ready then fails := concat_ws('; ',fails,'analysis surface '||n_analysis||' != READY '||n_ready); end if;
  select coalesce(max(c),0) into m from (select canonical_event_id, count(*) c from v2.v_soccer_daily_candidates
     where decision_time=T_DEC group by canonical_event_id) z;
  if m > 7 then fails := concat_ws('; ',fails,'NxM duplication: '||m||' candidates for one event'); end if;
  select count(*) into n_dupgate from (select canonical_event_id, decision_time, model_version, count(*) c
     from v2.v_soccer_event_gate where decision_time=T_DEC group by 1,2,3 having count(*)>1) z;
  if n_dupgate <> 0 then fails := concat_ws('; ',fails,n_dupgate||' staged PKs with >1 gate row'); end if;
  select count(distinct canonical_event_id) into n_ev from v2.v_soccer_daily_candidates where decision_time=T_DEC;
  -- no candidate may come from an ineligible or non-READY row
  select count(*) into n_bad from v2.v_soccer_daily_candidates d
   join v2.soccer_prediction_v2_staged s on s.espn_event_id=d.canonical_event_id and s.decision_time=d.decision_time and s.model_version=d.model_version
   left join v2.v_soccer_event_gate g on g.canonical_event_id=d.canonical_event_id and g.decision_time=d.decision_time and g.model_version=d.model_version
   where d.decision_time=T_DEC and (s.model_status<>'READY_UNVALIDATED' or g.top_only_eligible is not true or d.canonical_probability is null);
  if n_bad <> 0 then fails := concat_ws('; ',fails,n_bad||' candidates from ineligible/non-READY rows'); end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('7_SELECTOR', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('analysis keeps %s READY visible; %s eligible event(s) in candidates; max %s candidates/event (no NxM); 1 gate row per PK; 0 candidates from ineligible rows', n_ready, n_ev, m)));
end $S7$;

-- ── STAGE 8: DOSSIER_TRACEABILITY (crossleague row anchored + phi provenance) ─
do $S8$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  e_id text; v_snap uuid; n int; fs record; fails text := null; v_eff numeric;
begin
  select s.espn_event_id, s.feature_snapshot_id into e_id, v_snap
  from v2.soccer_prediction_v2_staged s
  where s.decision_time=T_DEC and s.model_status='READY_UNVALIDATED' and s.model_route='CROSSLEAGUE'
  order by s.espn_event_id limit 1;
  if e_id is null then
    fails := 'no crossleague READY row to trace';
  else
    select count(*) into n from v2.fn_soccer_dossier_manifest(e_id, T_DEC)
     where role='MODEL_ACTIVE' and used_in_p_reto and feature_snapshot_id = v_snap;
    if n < 1 then fails := concat_ws('; ',fails,'no MODEL_ACTIVE row anchored to feature_snapshot_id '||v_snap||' for '||e_id); end if;
    select * into fs from v2.feature_snapshot where feature_snapshot_id=v_snap;
    if fs.phi_training_cutoff is null or fs.phi_config_hash is null then
      fails := concat_ws('; ',fails,'crossleague feature_snapshot lacks sealed phi provenance');
    end if;
    select effective_value into v_eff from v2.fn_soccer_dossier_manifest(e_id,T_DEC) where source_name='feat_goal_rate_home' limit 1;
  end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('8_DOSSIER_TRACEABILITY', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('%s: MODEL_ACTIVE anchored to snapshot %s; sealed phi provenance present (cutoff %s, hash %s); feat_goal_rate_home=%s',
       e_id, v_snap, fs.phi_training_cutoff, left(fs.phi_config_hash,12), v_eff)));
end $S8$;

-- ── STAGE 9: REPLAY_IDEMPOTENCE ─────────────────────────────────────────────
do $S9$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  h1 text; h2 text; fails text := null;
begin
  select md5(string_agg(espn_event_id||':'||coalesce(model_status,'')||':'||coalesce(model_route,'')||':'
             ||coalesce(p_home::text,'')||':'||coalesce(p_over::text,'')||':'||coalesce(score_dist::text,''), '|' order by espn_event_id))
    into h1 from v2.soccer_prediction_v2_staged where decision_time=T_DEC;
  delete from v2.soccer_prediction_v2_staged where decision_time=T_DEC;
  delete from v2.feature_snapshot where decision_time=T_DEC;
  perform v2.build_soccer_prediction_v2_staged(T_DEC);
  select md5(string_agg(espn_event_id||':'||coalesce(model_status,'')||':'||coalesce(model_route,'')||':'
             ||coalesce(p_home::text,'')||':'||coalesce(p_over::text,'')||':'||coalesce(score_dist::text,''), '|' order by espn_event_id))
    into h2 from v2.soccer_prediction_v2_staged where decision_time=T_DEC;
  if h1 is distinct from h2 then fails := 'rebuild differs: '||h1||' vs '||h2; end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('9_REPLAY_IDEMPOTENCE', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, 'build twice -> identical staged output (md5 '||h1||')'));
end $S9$;

-- ── STAGE 10: GATE_REASON cleanliness (owner item E/6) ──────────────────────
do $S10$
declare n_dirty int; n_dup int; fails text := null; samples text;
begin
  select count(*) into n_dirty from v2.v_soccer_event_gate
   where gate_reason is not null and (gate_reason like '%; ;%' or gate_reason like '; %' or gate_reason like '%;' or gate_reason = '');
  if n_dirty <> 0 then fails := concat_ws('; ',fails,n_dirty||' gate_reason values with empty/leading/trailing separators'); end if;
  select count(*) into n_dup from (
    select canonical_event_id from v2.v_soccer_event_gate g
    where g.gate_reason is not null
      and (select count(*) from (select trim(t) tt from unnest(string_to_array(g.gate_reason,';')) t) z) <>
          (select count(distinct trim(t)) from unnest(string_to_array(g.gate_reason,';')) t)) z;
  if n_dup <> 0 then fails := concat_ws('; ',fails,n_dup||' gate_reason values with duplicate tokens'); end if;
  select count(*) into n_dirty from v2.soccer_prediction_v2_staged
   where model_status_reason is not null and (model_status_reason like '%; ;%' or model_status_reason like '; %' or model_status_reason = '');
  if n_dirty <> 0 then fails := concat_ws('; ',fails,n_dirty||' model_status_reason values with empty/leading separators'); end if;
  select string_agg(distinct left(gate_reason,90),' || ') into samples from v2.v_soccer_event_gate where gate_reason is not null;
  insert into v2.gate_run_log(stage,status,detail) values
    ('10_REASON_CLEANLINESS', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, 'no "; ;", no leading/trailing separator, no duplicate tokens in gate_reason or model_status_reason. samples: '||coalesce(samples,'(none)')));
end $S10$;

-- ── STAGE 11: ADVERSARIAL BATTERY (every case must FAIL-CLOSE) ──────────────
do $S11$
declare
  d jsonb; dist jsonb; ph numeric; pd numeric; pa numeric; byy numeric; bn numeric;
  po numeric; pu numeric; ts jsonb; pp numeric; olt text; osup boolean; ok boolean;
  NN numeric := null; fails text := null; nfail int; failclosed boolean;
begin
  d := v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10);
  dist:=d->'dist'; ph:=(d->>'p_home')::numeric; pd:=(d->>'p_draw')::numeric; pa:=(d->>'p_away')::numeric;
  byy:=(d->>'btts_yes')::numeric; bn:=(d->>'btts_no')::numeric; po:=(d->>'p_over')::numeric; pu:=(d->>'p_under')::numeric;
  ts:=d->'top_scores'; pp:=(d->>'p_push')::numeric; olt:=(d->>'ou_line_type'); osup:=(d->>'ou_supported')::boolean;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if not ok then fails := concat_ws('; ',fails,'baseline not coherent'); end if;

  -- MATRIX
  select coherence_ok into ok from v2.fn_event_gate_status((select jsonb_agg(jsonb_build_object('s',c->>'s','p',round((c->>'p')::numeric*0.9,2))) from jsonb_array_elements(dist) c),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'matrix sum 90 not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status((select jsonb_agg(jsonb_build_object('s',c->>'s','p',round((c->>'p')::numeric*1.1,2))) from jsonb_array_elements(dist) c),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'matrix sum >100 not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist||jsonb_build_array(jsonb_build_object('s','7-7','p',-5.0)),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'negative cell not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist||jsonb_build_array(jsonb_build_object('s',(ts->0->>'s'),'p',10.0)),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'duplicate score not fail-closed'); end if;
  failclosed := false;
  begin
    select coherence_ok into ok from v2.fn_event_gate_status(dist||jsonb_build_array(jsonb_build_object('s','x-y','p',1.0)),ph,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
    failclosed := not ok;
  exception when others then failclosed := true; end;
  if not failclosed then fails := concat_ws('; ',fails,'invalid score key not fail-closed'); end if;

  -- SCALARS
  select coherence_ok into ok from v2.fn_event_gate_status(dist,NN,pd,pa,po,pu,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'p_home NULL not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,NN,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'btts_no NULL not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,NN,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'p_under NULL not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn+15,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'btts_no +15pp not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu+15,4.5,byy,bn,ts,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'p_under +15pp not fail-closed'); end if;

  -- PUSH / LINE TYPES
  if (v2.fn_dist_from_lambda(2.697,1.266,3.5,0.0705,10)->>'ou_line_type')<>'HALF' then fails := concat_ws('; ',fails,'3.5 not HALF'); end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10)->>'ou_line_type')<>'WHOLE' then fails := concat_ws('; ',fails,'4.0 not WHOLE'); end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10)->>'p_push')::numeric<=0 then fails := concat_ws('; ',fails,'4.0 has no push'); end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,2.25,-0.05,10)->>'ou_line_type')<>'QUARTER' then fails := concat_ws('; ',fails,'2.25 not QUARTER'); end if;
  if (v2.fn_dist_from_lambda(3.2,1.1,2.75,-0.05,10)->>'ou_line_type')<>'QUARTER' then fails := concat_ws('; ',fails,'2.75 not QUARTER'); end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,3.1,-0.05,10);
  if (d->>'ou_supported')::boolean or (d->>'p_over') is not null then fails := concat_ws('; ',fails,'3.1 not fail-closed'); end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10);
  if round(coalesce((d->>'p_over')::numeric,0)+coalesce((d->>'p_push')::numeric,0)+coalesce((d->>'p_under')::numeric,0),1)<>100.0 then
    fails := concat_ws('; ',fails,'whole-line over+push+under != 100'); end if;
  select count(*) filter (where not g.ok) into nfail from v2.fn_soccer_coherence_gate(jsonb_set(d,'{p_push}',to_jsonb(((d->>'p_push')::numeric+15))),4.0) g;
  if nfail=0 then fails := concat_ws('; ',fails,'p_push +15pp not fail-closed'); end if;

  -- TOP_SCORES
  d := v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10);
  dist:=d->'dist'; ts:=d->'top_scores'; ph:=(d->>'p_home')::numeric; pd:=(d->>'p_draw')::numeric; pa:=(d->>'p_away')::numeric;
  byy:=(d->>'btts_yes')::numeric; bn:=(d->>'btts_no')::numeric; po:=(d->>'p_over')::numeric; pu:=(d->>'p_under')::numeric;
  pp:=(d->>'p_push')::numeric; olt:=(d->>'ou_line_type'); osup:=(d->>'ou_supported')::boolean;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,null::jsonb,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'top_scores NULL not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,'[]'::jsonb,pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'top_scores [] not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->0),pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'top_scores len1 not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->0,ts->0,ts->2,ts->3,ts->4),pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'top_scores duplicate not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(ts->1,ts->0,ts->2,ts->3,ts->4),pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'top_scores wrong order not fail-closed'); end if;
  select coherence_ok into ok from v2.fn_event_gate_status(dist,ph,pd,pa,po,pu,4.5,byy,bn,jsonb_build_array(jsonb_build_object('s',ts->0->>'s','p',((ts->0->>'p')::numeric+15)),ts->1,ts->2,ts->3,ts->4),pp,olt,osup,NN,NN,NN,NN,NN);
  if ok then fails := concat_ws('; ',fails,'top_scores wrong prob not fail-closed'); end if;

  insert into v2.gate_run_log(stage,status,detail) values
    ('11_ADVERSARIAL', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, 'MATRIX (sum90 / sum>100 / negative / duplicate / bad-key), SCALARS (p_home/btts_no/p_under NULL, btts_no/p_under +15pp), PUSH (3.5=HALF, 4.0=WHOLE with push>0, 2.25/2.75=QUARTER, 3.1=UNSUPPORTED, over+push+under=100, p_push+15pp), TOP_SCORES (NULL/[]/len1/duplicate/wrong-order/wrong-prob) — all FAIL-CLOSED as specified'));
end $S11$;

-- ── STAGE 12: crossleague model has NO parallel probability authority ───────
-- fn_crossleague_p_reto used to build its own matrix and hardcode Over 2.5. It must now
-- agree EXACTLY with the canonical emitter at the real line, i.e. be a thin delegate.
do $S12$
declare T_DEC constant timestamptz := timestamptz '2026-09-10 12:00:00+00';
  s record; p record; fails text := null; n int := 0;
begin
  for s in select * from v2.soccer_prediction_v2_staged
           where decision_time=T_DEC and model_route='CROSSLEAGUE' and model_status='READY_UNVALIDATED' loop
    n := n + 1;
    select * into p from v2.fn_crossleague_p_reto(
      (select home_espn_id from public.agenda_espn where espn_event_id=s.espn_event_id limit 1),
      (select away_espn_id from public.agenda_espn where espn_event_id=s.espn_event_id limit 1),
      s.competition_id, s.competition_id, T_DEC, s.competition_id, s.over_line);
    if p.p_reto_home is distinct from s.p_home or p.p_reto_draw is distinct from s.p_draw
       or p.p_reto_away is distinct from s.p_away or p.btts_yes is distinct from s.btts_yes
       or p.p_over is distinct from s.p_over or p.p_under is distinct from s.p_under
       or p.p_push is distinct from s.p_push then
      fails := concat_ws('; ',fails,s.espn_event_id||': fn_crossleague_p_reto disagrees with the staged row (parallel authority)');
    end if;
    if s.over_line <> 2.5 and p.p_over is not null and p.p_over = (select (v2.fn_dist_from_lambda(
         (s.provenance->'lambda'->>'lambda_home')::numeric,(s.provenance->'lambda'->>'lambda_away')::numeric,2.5,
         (s.provenance->'lambda'->>'rho')::numeric,10)->>'p_over')::numeric) then
      fails := concat_ws('; ',fails,s.espn_event_id||': p_over equals the Over-2.5 value despite a '||s.over_line||' line (hardcode suspected)');
    end if;
  end loop;
  insert into v2.gate_run_log(stage,status,detail) values
    ('12_NO_PARALLEL_AUTHORITY', case when fails is null then 'PASS' else 'FAIL' end,
     coalesce(fails, format('%s crossleague READY rows: fn_crossleague_p_reto reproduces the staged row EXACTLY at the real line (thin delegate of fn_dist_from_lambda); no Over-2.5 hardcode', n)));
end $S12$;

-- ── FINAL VERDICT ───────────────────────────────────────────────────────────
do $FIN$
declare n_fail int; lst text;
begin
  select count(*), string_agg(stage,', ' order by seq) into n_fail, lst
  from v2.gate_run_log where status = 'FAIL';
  if n_fail > 0 then
    insert into v2.gate_run_log(stage,status,detail) values ('ZZ_VERDICT','FAIL', n_fail||' stage(s) FAILED: '||lst);
    raise exception 'SOCCER FINAL BRANCH GATE: % stage(s) FAILED: %. Read v2.gate_run_log for detail.', n_fail, lst;
  end if;
  insert into v2.gate_run_log(stage,status,detail) values
    ('ZZ_VERDICT','PASS','==== SOCCER FINAL BRANCH GATE: ALL STAGES PASS (real path) ====');
end $FIN$;

select seq, stage, status, detail from v2.gate_run_log order by seq;
