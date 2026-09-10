-- ============================================================================
-- iss051_soccer_gate_v5_adversarial_test.sql
-- Independent ChatGPT adversarial gate. Branch-only; transaction rolls back fixtures.
-- ============================================================================
begin;

do $t$
declare
  d jsonb;
  du jsonb;
  bad jsonb;
  g record;
  n int;
  first_p numeric;
  ts jsonb;
  revts jsonb;
begin
  d := v2.fn_dist_from_lambda(2.697,1.266,4.0,0.0705,10);
  if d is null then raise exception 'BASE emitter returned NULL'; end if;

  -- valid baseline
  select * into g from v2.fn_event_gate_status(
    d->'dist',(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,d->>'ou_line_type',(d->>'ou_supported')::boolean,
    null,null,null,null,null
  );
  if g.coherence_ok is not true or g.top_only_eligible is not true then
    raise exception 'BASELINE should be eligible: %',g.gate_reason;
  end if;

  -- 90% matrix (recomputed scalars still cannot authorize an incomplete distribution)
  select jsonb_agg(jsonb_build_object('s',e->>'s','p',round((e->>'p')::numeric*0.9,2)) order by ord)
    into bad from jsonb_array_elements(d->'dist') with ordinality a(e,ord);
  select jsonb_agg(jsonb_build_object('s',s,'p',p)) into ts from (
    select e->>'s' s,(e->>'p')::numeric p from jsonb_array_elements(bad) e
    order by (e->>'p')::numeric desc,
             (split_part(e->>'s','-',1)::int+split_part(e->>'s','-',2)::int) asc,
             split_part(e->>'s','-',1)::int asc limit 5
  ) q;
  select * into g from v2.fn_event_gate_status(
    bad,
    v2.fn_matrix_market(bad,'1X2','HOME'),v2.fn_matrix_market(bad,'1X2','DRAW'),v2.fn_matrix_market(bad,'1X2','AWAY'),
    v2.fn_matrix_market(bad,'OU','OVER',4.0),v2.fn_matrix_market(bad,'OU','UNDER',4.0),4.0,
    v2.fn_matrix_market(bad,'BTTS','YES'),v2.fn_matrix_market(bad,'BTTS','NO'),ts,
    v2.fn_matrix_market(bad,'OU','PUSH',4.0),'WHOLE',true,
    null,null,null,null,null
  );
  if g.coherence_ok or position('MATRIX_SUM_NOT_100' in coalesce(g.gate_reason,''))=0 then
    raise exception '90%% matrix leaked: %',g.gate_reason;
  end if;

  -- >100 matrix
  first_p := (d->'dist'->0->>'p')::numeric;
  bad := jsonb_set(d->'dist','{0,p}',to_jsonb(first_p+10));
  select * into g from v2.fn_event_gate_status(
    bad,(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('MATRIX_SUM_NOT_100' in coalesce(g.gate_reason,''))=0 then raise exception '>100 matrix leaked'; end if;

  -- negative probability
  bad := jsonb_set(d->'dist','{0,p}',to_jsonb(-1::numeric));
  select * into g from v2.fn_event_gate_status(
    bad,(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('MATRIX_PROB_OUT_OF_RANGE' in coalesce(g.gate_reason,''))=0 then raise exception 'negative matrix prob leaked'; end if;

  -- duplicate score
  bad := (d->'dist') || jsonb_build_array(d->'dist'->0);
  select * into g from v2.fn_event_gate_status(
    bad,(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('MATRIX_DUPLICATE_SCORE' in coalesce(g.gate_reason,''))=0 then raise exception 'duplicate score leaked'; end if;

  -- invalid score key
  bad := jsonb_set(d->'dist','{0,s}',to_jsonb('BAD'::text));
  select * into g from v2.fn_event_gate_status(
    bad,(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('MATRIX_BAD_SCORE_KEY' in coalesce(g.gate_reason,''))=0 then raise exception 'invalid score key leaked'; end if;

  -- NULL scalar bypass
  select * into g from v2.fn_event_gate_status(
    d->'dist',null,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('NULL_FIELD:p_home' in coalesce(g.gate_reason,''))=0 then raise exception 'NULL p_home leaked'; end if;

  -- poison only push
  select * into g from v2.fn_event_gate_status(
    d->'dist',(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric+15,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('OU_PUSH' in coalesce(g.gate_reason,''))=0 then raise exception 'p_push poison leaked'; end if;

  -- wrong O/U metadata
  select * into g from v2.fn_event_gate_status(
    d->'dist',(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,d->'top_scores',
    (d->>'p_push')::numeric,'HALF',true,null,null,null,null,null
  );
  if g.coherence_ok or position('OU_LINE_TYPE_MISMATCH' in coalesce(g.gate_reason,''))=0 then raise exception 'line type mismatch leaked'; end if;

  -- unsupported 3.1 must be explicit and fail-neutral for analysis but never create OU scalars
  du := v2.fn_dist_from_lambda(2.2,1.1,3.1,0.0705,10);
  select * into g from v2.fn_event_gate_status(
    du->'dist',(du->>'p_home')::numeric,(du->>'p_draw')::numeric,(du->>'p_away')::numeric,
    (du->>'p_over')::numeric,(du->>'p_under')::numeric,3.1,
    (du->>'btts_yes')::numeric,(du->>'btts_no')::numeric,du->'top_scores',
    (du->>'p_push')::numeric,du->>'ou_line_type',(du->>'ou_supported')::boolean,
    null,null,null,null,null
  );
  if g.coherence_ok is not true then raise exception 'valid unsupported-line representation should keep event coherence: %',g.gate_reason; end if;
  if (du->>'ou_supported')::boolean is not false or du->>'ou_line_type'<>'UNSUPPORTED'
     or du->>'p_over' is not null or du->>'p_push' is not null or du->>'p_under' is not null then
    raise exception 'unsupported line emitter contract broken';
  end if;

  -- top_scores strictness
  select * into g from v2.fn_event_gate_status(
    d->'dist',(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,jsonb_build_array(d->'top_scores'->0),
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('TOPK_LEN_NOT_5' in coalesce(g.gate_reason,''))=0 then raise exception 'top1 leaked'; end if;

  ts := d->'top_scores';
  revts := jsonb_build_array(ts->1,ts->0,ts->2,ts->3,ts->4);
  select * into g from v2.fn_event_gate_status(
    d->'dist',(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,revts,
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('TOP_SCORES_ORDER' in coalesce(g.gate_reason,''))=0 then raise exception 'wrong top_scores order leaked'; end if;

  ts := jsonb_build_array(d->'top_scores'->0,d->'top_scores'->0,d->'top_scores'->2,d->'top_scores'->3,d->'top_scores'->4);
  select * into g from v2.fn_event_gate_status(
    d->'dist',(d->>'p_home')::numeric,(d->>'p_draw')::numeric,(d->>'p_away')::numeric,
    (d->>'p_over')::numeric,(d->>'p_under')::numeric,4.0,
    (d->>'btts_yes')::numeric,(d->>'btts_no')::numeric,ts,
    (d->>'p_push')::numeric,'WHOLE',true,null,null,null,null,null
  );
  if g.coherence_ok or position('TOP_SCORES_DUPLICATE' in coalesce(g.gate_reason,''))=0 then raise exception 'duplicate top score leaked'; end if;

  -- single surviving signature
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid=p.pronamespace
   where ns.nspname='v2' and p.proname='fn_event_gate_status';
  if n<>1 then raise exception 'signature count %',n; end if;
end
$t$;

-- Analysis surface must retain a fail-closed non-READY event with NULL P_RETO.
insert into v2.soccer_prediction_v2_staged(
  espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,model_version,model_status,model_status_reason
) values (
  'CHATGPT_ANALYSIS_VIS',2,'A','B',timestamptz '2099-01-02 00:00+00',timestamptz '2099-01-01 00:00+00',
  'dc-2026.09.1','DATA_INCOMPLETE','adversarial visibility test'
);

do $v$
declare n int; e boolean;
begin
  select count(*),bool_and(coalesce(top_only_eligible,false)=false) into n,e
  from v2.v_soccer_analysis_all where espn_event_id='CHATGPT_ANALYSIS_VIS';
  if n<>1 or e is not true then raise exception 'analysis visibility contract failed'; end if;
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id='CHATGPT_ANALYSIS_VIS';
  if n<>0 then raise exception 'DATA_INCOMPLETE leaked to candidates'; end if;
end
$v$;

rollback;

select 'SOCCER_GATE_V5_ADVERSARIAL_PASS' as result;
