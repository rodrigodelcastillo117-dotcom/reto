-- ============================================================================
-- iss045b — GATE v5 HARDENING (fn_event_gate_status full-structural coherence) · STAGED
-- ============================================================================
-- Supersedes the iss045 fn_event_gate_status. Applied to the branch gate as the
-- authoritative hardened coherence gate (recorded on branch rotbmkcqvaeqmfdormfp as
-- migration `chatgpt_soccer_gate_v5_hardening`, captured here VERBATIM from the live
-- object so the committed chain reproduces the branch). Apply AFTER iss036 (it replaces
-- fn_event_gate_status and v_soccer_event_gate, which iss036 created).
--
-- v5 adds, over the iss045 gate: full matrix-cell structural validation (bad score key,
-- score out of range, bad/out-of-range prob, dist_sum==100, duplicate score), 1X2/BTTS
-- range + sum==100, top_scores EXACTLY 5 + bad-key + duplicate + true-top-5 order +
-- per-cell prob, and O/U line-type/supported MATCH + p_over/p_push/p_under range + sum==100
-- + per-market matrix agreement, with UNSUPPORTED lines required NULL. Every branch is
-- fail-closed (coherence_ok=false) — including malformed input, which returns false rather
-- than throwing. NO PROD MUTATION. Branch-only. RELEASE_GATE=HOLD, PROD_FREEZE=ON.
-- The new signature adds p_push numeric, p_ou_line_type text, p_ou_supported boolean after
-- p_top_scores so the gate validates the persisted O/U settlement columns (iss033/iss041 C).
-- ============================================================================

-- Drop the iss045 gate (16 input args, p_tol defaulted) CASCADE — removes the old fn and
-- the views that depend on it (v_soccer_event_gate + v_gate_fixture_*); all are recreated
-- below and by iss036's re-run order, so exactly ONE fn_event_gate_status signature remains.
drop function if exists v2.fn_event_gate_status(
  jsonb, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, jsonb, numeric, numeric, numeric, numeric, numeric, numeric) cascade;

CREATE OR REPLACE FUNCTION v2.fn_event_gate_status(p_dist jsonb, p_home numeric, p_draw numeric, p_away numeric, p_over numeric, p_under numeric, p_over_line numeric, p_btts_yes numeric, p_btts_no numeric, p_top_scores jsonb, p_push numeric, p_ou_line_type text, p_ou_supported boolean, p_odds_home numeric, p_odds_draw numeric, p_odds_away numeric, p_odds_over numeric, p_odds_under numeric, p_tol numeric DEFAULT 0.2)
 RETURNS TABLE(coherence_ok boolean, disc_flag text, suppress boolean, top_only_eligible boolean, gate_reason text)
 LANGUAGE plpgsql IMMUTABLE
AS $function$
declare
  d record; coh boolean := true; reasons text := null; e jsonb; s text; pv numeric;  -- null (not '') so concat_ws skips the seed -> no leading '; ' / '; ;' in gate_reason
  dist_sum numeric := 0; dist_n int := 0; dist_unique int := 0; dist_struct_ok boolean := true;
  gi int; gj int; true_top jsonb; top_keys jsonb; top_n int := 0;
  expected_line_type text; expected_supported boolean; frac numeric; scalar_sum numeric;
begin
  if p_dist is null or jsonb_typeof(p_dist) <> 'array' or jsonb_array_length(p_dist)=0 then
    coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_MISSING_OR_EMPTY');
  else
    for e in select value from jsonb_array_elements(p_dist) loop
      dist_n := dist_n + 1;
      if jsonb_typeof(e) <> 'object' then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_CELL_NOT_OBJECT'); continue; end if;
      s := e->>'s';
      if s is null or s !~ '^[0-9]+-[0-9]+$' then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_BAD_SCORE_KEY'); continue; end if;
      begin gi := split_part(s,'-',1)::int; gj := split_part(s,'-',2)::int;
      exception when others then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_BAD_SCORE_KEY'); continue; end;
      if gi < 0 or gj < 0 or gi > 12 or gj > 12 then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_SCORE_OUT_OF_RANGE'); end if;
      begin pv := (e->>'p')::numeric;
      exception when others then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_BAD_PROB'); continue; end;
      if pv is null or pv::text = 'NaN' or pv < 0 or pv > 100 then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_PROB_OUT_OF_RANGE');
      else dist_sum := dist_sum + pv; end if;
    end loop;
    if dist_struct_ok then
      select count(distinct x->>'s') into dist_unique from jsonb_array_elements(p_dist) x;
      if dist_unique <> dist_n then coh := false; reasons := concat_ws('; ', reasons, 'MATRIX_DUPLICATE_SCORE'); end if;
      if abs(dist_sum - 100) > p_tol then coh := false; reasons := concat_ws('; ', reasons, 'MATRIX_SUM_NOT_100'); end if;
    end if;
  end if;

  if p_home is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_home');
  elsif p_home::text='NaN' or p_home<0 or p_home>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_home'); end if;
  if p_draw is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_draw');
  elsif p_draw::text='NaN' or p_draw<0 or p_draw>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_draw'); end if;
  if p_away is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_away');
  elsif p_away::text='NaN' or p_away<0 or p_away>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_away'); end if;
  if p_btts_yes is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:btts_yes');
  elsif p_btts_yes::text='NaN' or p_btts_yes<0 or p_btts_yes>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:btts_yes'); end if;
  if p_btts_no is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:btts_no');
  elsif p_btts_no::text='NaN' or p_btts_no<0 or p_btts_no>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:btts_no'); end if;

  if p_home is not null and p_draw is not null and p_away is not null and abs((p_home+p_draw+p_away)-100) > p_tol then
    coh:=false; reasons:=concat_ws('; ',reasons,'SUM_1X2_NOT_100'); end if;
  if p_btts_yes is not null and p_btts_no is not null and abs((p_btts_yes+p_btts_no)-100) > p_tol then
    coh:=false; reasons:=concat_ws('; ',reasons,'SUM_BTTS_NOT_100'); end if;

  if p_top_scores is null or jsonb_typeof(p_top_scores) <> 'array' then
    coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:top_scores');
  else
    top_n := jsonb_array_length(p_top_scores);
    if top_n <> 5 then coh:=false; reasons:=concat_ws('; ',reasons,'TOPK_LEN_NOT_5'); end if;
    if exists (select 1 from jsonb_array_elements(p_top_scores) t where t->>'s' is null or t->>'s' !~ '^[0-9]+-[0-9]+$') then
      coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_BAD_KEY'); end if;
    if (select count(distinct t->>'s') from jsonb_array_elements(p_top_scores) t) <> top_n then
      coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_DUPLICATE'); end if;
    if dist_struct_ok and top_n > 0 then
      select jsonb_agg(z.s) into true_top from (
        select c->>'s' as s from jsonb_array_elements(p_dist) c
        order by (c->>'p')::numeric desc, (split_part(c->>'s','-',1)::int + split_part(c->>'s','-',2)::int) asc, split_part(c->>'s','-',1)::int asc
        limit 5) z;
      select jsonb_agg(t->>'s') into top_keys from jsonb_array_elements(p_top_scores) t;
      if top_keys is distinct from true_top then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_ORDER'); end if;
      begin
        if exists (select 1 from jsonb_array_elements(p_top_scores) t
          where (t->>'p') is null or (t->>'p')::numeric::text='NaN' or (t->>'p')::numeric < 0
             or abs((t->>'p')::numeric - v2.fn_matrix_market(p_dist,'EXACT',t->>'s')) > p_tol) then
          coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_PROB'); end if;
      exception when others then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_BAD_PROB'); end;
    end if;
  end if;

  if dist_struct_ok then
    if p_home is not null and abs(p_home-v2.fn_matrix_market(p_dist,'1X2','HOME'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_HOME'); end if;
    if p_draw is not null and abs(p_draw-v2.fn_matrix_market(p_dist,'1X2','DRAW'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_DRAW'); end if;
    if p_away is not null and abs(p_away-v2.fn_matrix_market(p_dist,'1X2','AWAY'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_AWAY'); end if;
    if p_btts_yes is not null and abs(p_btts_yes-v2.fn_matrix_market(p_dist,'BTTS','YES'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'BTTS_YES'); end if;
    if p_btts_no is not null and abs(p_btts_no-v2.fn_matrix_market(p_dist,'BTTS','NO'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'BTTS_NO'); end if;
  end if;

  if p_over_line is not null then
    frac := p_over_line - floor(p_over_line);
    expected_line_type := case when frac=0 then 'WHOLE' when frac=0.5 then 'HALF' when frac in (0.25,0.75) then 'QUARTER' else 'UNSUPPORTED' end;
    expected_supported := expected_line_type <> 'UNSUPPORTED';
    if p_ou_line_type is distinct from expected_line_type then coh:=false; reasons:=concat_ws('; ',reasons,'OU_LINE_TYPE_MISMATCH'); end if;
    if p_ou_supported is distinct from expected_supported then coh:=false; reasons:=concat_ws('; ',reasons,'OU_SUPPORTED_MISMATCH'); end if;
    if expected_supported then
      if p_over is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_over');
      elsif p_over::text='NaN' or p_over<0 or p_over>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_over'); end if;
      if p_under is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_under');
      elsif p_under::text='NaN' or p_under<0 or p_under>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_under'); end if;
      if p_push is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_push');
      elsif p_push::text='NaN' or p_push<0 or p_push>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_push'); end if;
      if p_over is not null and p_push is not null and p_under is not null then
        scalar_sum := p_over+p_push+p_under;
        if abs(scalar_sum-100)>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_SUM_NOT_100'); end if;
      end if;
      if dist_struct_ok then
        if p_over is not null and abs(p_over-v2.fn_matrix_market(p_dist,'OU','OVER',p_over_line))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_OVER'); end if;
        if p_push is not null and abs(p_push-v2.fn_matrix_market(p_dist,'OU','PUSH',p_over_line))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_PUSH'); end if;
        if p_under is not null and abs(p_under-v2.fn_matrix_market(p_dist,'OU','UNDER',p_over_line))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNDER'); end if;
      end if;
    else
      if p_over is not null or p_push is not null or p_under is not null then coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNSUPPORTED_MUST_BE_NULL'); end if;
    end if;
  end if;

  coherence_ok := coh;
  if not coh then reasons := concat_ws('; ', 'COHERENCE_FAIL', reasons); end if;
  select * into d from v2.fn_model_market_discrepancy(p_home,p_draw,p_away,p_over,p_odds_home,p_odds_draw,p_odds_away,p_odds_over,p_odds_under);
  disc_flag := d.flag; suppress := coalesce(d.suppress,false);
  if suppress then reasons := concat_ws('; ',reasons,d.flag||': '||d.reason); end if;
  top_only_eligible := coherence_ok and not suppress;
  gate_reason := nullif(reasons,'');
  return next;
end
$function$;

-- v_soccer_event_gate rewired to pass the persisted O/U settlement columns to the v5 gate.
create or replace view v2.v_soccer_event_gate as
 select c.espn_event_id as canonical_event_id, c.decision_time, c.model_version,
    g.coherence_ok, g.disc_flag, coalesce(g.suppress, false) as suppress,
    (c.model_status = 'READY_UNVALIDATED'::text and coalesce(g.coherence_ok, false) and not coalesce(g.suppress, false)) as top_only_eligible,
    g.gate_reason
   from v2.soccer_prediction_v2_staged c
     left join lateral ( select mc.home_ml, mc.draw_ml, mc.away_ml from public.v_momios_confiables mc
          where mc.espn_event_id = c.espn_event_id and mc.confiable is true and mc.snapshot_at <= c.decision_time
          order by mc.snapshot_at desc limit 1) oml on true
     left join lateral ( select mc.over_odds, mc.under_odds from public.v_momios_confiables mc
          where mc.espn_event_id = c.espn_event_id and mc.confiable is true and mc.snapshot_at <= c.decision_time and mc.over_line = c.over_line
          order by mc.snapshot_at desc limit 1) oou on true
     left join lateral v2.fn_event_gate_status(c.score_dist, c.p_home, c.p_draw, c.p_away, c.p_over, c.p_under, c.over_line, c.btts_yes, c.btts_no, c.top_scores, c.p_push, c.ou_line_type, c.ou_supported, oml.home_ml, oml.draw_ml, oml.away_ml, oou.over_odds, oou.under_odds) g on true;

-- Fixture proof-views recreated to pass the persisted O/U settlement columns to the v5 gate.
create or replace view v2.v_gate_fixture_status as
select f.espn_event_id, f.home_team, f.away_team, f.competition, f.over_line, d.jd,
       gs.coherence_ok, gs.disc_flag, gs.suppress, gs.top_only_eligible, gs.gate_reason
from v2.gate_fixture_soccer_cards f
cross join lateral (select v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,coalesce(f.maxg,10)) jd) d
cross join lateral v2.fn_event_gate_status(
  d.jd->'dist', (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
  (d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric, f.over_line,
  (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric, d.jd->'top_scores',
  (d.jd->>'p_push')::numeric, d.jd->>'ou_line_type', (d.jd->>'ou_supported')::boolean,
  f.odds_home,f.odds_draw,f.odds_away,f.odds_over,f.odds_under) gs;
create or replace view v2.v_gate_fixture_analysis_all as
select espn_event_id, home_team, away_team, competition, over_line,
       (jd->>'p_home')::numeric p_home, (jd->>'p_away')::numeric p_away, (jd->>'p_over')::numeric p_over,
       disc_flag, suppress, top_only_eligible, gate_reason from v2.v_gate_fixture_status;
create or replace view v2.v_gate_fixture_candidates as
select s.espn_event_id as canonical_event_id, s.home_team, s.away_team, s.competition,
       cand.canonical_market, cand.canonical_side, cand.canonical_line, cand.canonical_probability
from v2.v_gate_fixture_status s
cross join lateral (values
    ('1X2'::text,'HOME'::text,null::numeric,(s.jd->>'p_home')::numeric),
    ('1X2','DRAW',null,(s.jd->>'p_draw')::numeric),
    ('1X2','AWAY',null,(s.jd->>'p_away')::numeric),
    ('BTTS','YES',null,(s.jd->>'btts_yes')::numeric),
    ('BTTS','NO', null,(s.jd->>'btts_no')::numeric),
    ('OU','OVER', s.over_line, case when s.over_line is not null then (s.jd->>'p_over')::numeric end),
    ('OU','UNDER',s.over_line, case when s.over_line is not null then (s.jd->>'p_under')::numeric end)
) cand(canonical_market,canonical_side,canonical_line,canonical_probability)
where s.top_only_eligible and cand.canonical_probability is not null;

-- iss036 selector views recreated (the DROP ... CASCADE above removes them since they
-- depend on v_soccer_event_gate). Definitions identical to iss036; re-stated here so
-- iss045b is a self-contained replacement applied after iss036.
create or replace view v2.v_soccer_analysis_all as
select c.*, gt.coherence_ok, gt.disc_flag, gt.suppress, gt.top_only_eligible, gt.gate_reason
from v2.soccer_prediction_v2_staged c
left join v2.v_soccer_event_gate gt on gt.canonical_event_id = c.espn_event_id and gt.decision_time = c.decision_time and gt.model_version = c.model_version
where c.model_status = 'READY_UNVALIDATED';
create or replace view v2.v_soccer_daily_candidates as
select c.espn_event_id as canonical_event_id, c.home_team, c.away_team, c.competition_id, c.kickoff, c.decision_time,
       c.model_version, c.feature_snapshot_id as model_snapshot_id,
       cand.canonical_market, cand.canonical_side, cand.canonical_line, cand.canonical_probability, cand.canonical_push, cand.canonical_line_type, c.sample_home, c.sample_away
from v2.soccer_prediction_v2_staged c
join v2.v_soccer_event_gate gt on gt.canonical_event_id = c.espn_event_id and gt.decision_time = c.decision_time and gt.model_version = c.model_version and gt.top_only_eligible
cross join lateral (values
    ('1X2'::text, 'HOME'::text, null::numeric, c.p_home, null::numeric, null::text),
    ('1X2','DRAW', null, c.p_draw, null, null),
    ('1X2','AWAY', null, c.p_away, null, null),
    ('BTTS','YES', null, c.btts_yes, null, null),
    ('BTTS','NO', null, c.btts_no, null, null),
    ('OU','OVER', c.over_line, case when c.over_line is not null then c.p_over end, c.p_push, c.ou_line_type),
    ('OU','UNDER', c.over_line, case when c.over_line is not null then c.p_under end, c.p_push, c.ou_line_type)
) cand(canonical_market, canonical_side, canonical_line, canonical_probability, canonical_push, canonical_line_type)
where c.model_status = 'READY_UNVALIDATED' and cand.canonical_probability is not null;
create or replace view v2.v_soccer_daily_canonical as
with cand as (select d.*, (d.kickoff at time zone 'America/Mexico_City')::date as dia_mx, least(coalesce(d.sample_home,0), coalesce(d.sample_away,0)) as muestra_min from v2.v_soccer_daily_candidates d),
best_per_event as (select *, row_number() over (partition by canonical_event_id order by canonical_probability desc, muestra_min desc, canonical_market) as rn_event from cand),
ranked as (select b.*, row_number() over (partition by dia_mx order by canonical_probability desc, muestra_min desc, kickoff, canonical_event_id) as rank_dia from best_per_event b where rn_event = 1)
select 'FUT'::text as deporte, canonical_event_id, home_team, away_team, competition_id, kickoff, dia_mx, decision_time, model_version, model_snapshot_id,
       canonical_market, canonical_side, canonical_line, canonical_probability, muestra_min, rank_dia, (rank_dia = 1) as es_mejor_del_dia from ranked;
