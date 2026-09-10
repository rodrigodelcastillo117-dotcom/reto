-- ============================================================================
-- iss045 — GATE STATUS WIRED INTO THE CANONICAL CANDIDATE CONTRACT (P0)
-- ============================================================================
-- Resolves AUDIT_NO_PASS 5619542059 finding 1 (+2): the coherence gate (iss042) and
-- the model-market discrepancy gate (iss043) were only RETURNING status; nothing
-- excluded flagged events from TOP_ONLY_GLOBAL / Reto13M. This file makes the gate
-- status a first-class per-event contract and EXCLUDES ineligible events from the
-- candidate/daily selector while keeping them visible in normal analysis.
-- STAGED · branch-only · NO PROD MUTATION · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
--
-- top_only_eligible := coherence_ok AND NOT suppress
--   coherence_ok : every published market sums the stored matrix within 0.2pp (iss042).
--   suppress     : discrepancy gate (iss043) QUALITY_DOWNGRADE or REVIEW_REQUIRED
--                  (a real >=12pp model-vs-market breach). NO_MARKET_DIAGNOSTIC and OK
--                  do NOT suppress (market absence never fabricates a discrepancy).
-- Ineligible events remain fully visible in the analysis surface (v_*_analysis_all);
-- they are only removed from the TOP_ONLY candidate/daily surface.
-- ============================================================================
create schema if not exists v2;

-- ── BOOTSTRAP FIX (clean-chain reproducibility) ──────────────────────────────
-- The proof views below (v_gate_fixture_*) and the gate test suites read the
-- adversarial owner-card fixture table v2.gate_fixture_soccer_cards. On a clean
-- empty branch that table does not yet exist, so CREATE VIEW v_gate_fixture_status
-- fails (missing relation) and the whole migration chain breaks here. The 6-owner
-- fixture SEED (`iss041_fixtures`) was never committed to the repo; this DDL creates
-- the table structure (idempotent, empty => proof views are valid and return 0 rows)
-- so the chain reproduces from scratch with ZERO errors. The fixture ROWS are seeded
-- separately by the gate test setup (execute_sql), never fabricated into the chain.
-- Column set = union of every in-scope consumer (iss045 views, iss042/043/036/048 tests).
create table if not exists v2.gate_fixture_soccer_cards (
  espn_event_id text primary key,
  home_team text, away_team text, competition text,
  over_line numeric, lambda_home numeric, lambda_away numeric, rho numeric, maxg int,
  odds_home numeric, odds_draw numeric, odds_away numeric, odds_over numeric, odds_under numeric,
  disp_p_home numeric, disp_p_draw numeric, disp_p_away numeric, disp_p_over numeric,
  bookmaker text
);

-- Per-event gate status from the stored matrix + stored scalars + real odds context.
-- Works on any surface that persists score_dist + scalars + odds (prod staged rows or
-- the branch fixture rows), so the exclusion logic is identical everywhere.
--
-- 5620997108 A: RETIRE the OLD v3 signature. A CREATE OR REPLACE with the new 16-arg
-- signature would leave the old signature as a coexisting OVERLOAD; a caller matching the
-- old arg list would then silently run incomplete v3 logic. Drop it explicitly (CASCADE
-- drops dependent views — the fixture views below and iss036's staged views recreate them)
-- so EXACTLY ONE fn_event_gate_status signature exists after bootstrap. Idempotent on a
-- clean bootstrap (no-op when the old signature is absent).
drop function if exists v2.fn_event_gate_status(
  jsonb, numeric, numeric, numeric, numeric, numeric, numeric,
  numeric, numeric, numeric, numeric, numeric, numeric) cascade;

create or replace function v2.fn_event_gate_status(
  p_dist jsonb, p_home numeric, p_draw numeric, p_away numeric,
  p_over numeric, p_under numeric, p_over_line numeric,
  p_btts_yes numeric, p_btts_no numeric, p_top_scores jsonb,
  p_odds_home numeric, p_odds_draw numeric, p_odds_away numeric,
  p_odds_over numeric, p_odds_under numeric, p_tol numeric default 0.2
) returns table(coherence_ok boolean, disc_flag text, suppress boolean, top_only_eligible boolean, gate_reason text)
language plpgsql immutable as $$
declare d record; coh boolean := true; reasons text := ''; n int; true_top jsonb;
begin
  -- (a) coherence: EVERY published/candidate field must sum the stored matrix within tol
  --     (5620477307 F2: btts_no + p_under + top_scores were unchecked -> complements leaked).
  if p_dist is null or jsonb_array_length(p_dist)=0 then
    coherence_ok:=false; disc_flag:='NO_MATRIX'; suppress:=true; top_only_eligible:=false;
    gate_reason:='missing/empty score_dist'; return next; return;
  end if;
  -- 5620997108 B: NULL/EMPTY BYPASS GUARD. `abs(field - derived) > p_tol` yields NULL
  --   (not TRUE) when `field` IS NULL, so an UNPUBLISHED candidate field would otherwise
  --   pass coherence and leak into TOP_ONLY. A published/candidate field that is NULL (or
  --   an empty top_scores) is a coherence FAIL with reason NULL_FIELD:<name>. The row stays
  --   visible in analysis but is EXCLUDED from candidates/TOP_ONLY.
  if p_home is null     then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_home'); end if;
  if p_draw is null     then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_draw'); end if;
  if p_away is null     then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_away'); end if;
  if p_btts_yes is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:btts_yes'); end if;
  if p_btts_no is null  then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:btts_no'); end if;
  if p_top_scores is null or jsonb_typeof(p_top_scores) <> 'array' or jsonb_array_length(p_top_scores)=0
     then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:top_scores'); end if;
  -- O/U is required ONLY when the provider line is a SUPPORTED fraction. An UNSUPPORTED
  --   line legitimately fail-closes p_over/p_under to NULL (ou_supported=false, iss041 F3),
  --   so a NULL there is expected, not a bug. fn_total_weights(...) returns NULL exactly
  --   for unsupported fractions, so it classifies the line without a new parameter.
  if p_over_line is not null and v2.fn_total_weights(0, p_over_line) is not null then
    if p_over is null  then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_over'); end if;
    if p_under is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_under'); end if;
  end if;
  if p_home is not null     and abs(p_home - v2.fn_matrix_market(p_dist,'1X2','HOME')) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_HOME'); end if;
  if p_draw is not null and abs(p_draw - v2.fn_matrix_market(p_dist,'1X2','DRAW')) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_DRAW'); end if;
  if p_away is not null and abs(p_away - v2.fn_matrix_market(p_dist,'1X2','AWAY')) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_AWAY'); end if;
  if p_btts_yes is not null and abs(p_btts_yes - v2.fn_matrix_market(p_dist,'BTTS','YES')) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'BTTS_YES'); end if;
  if p_btts_no  is not null and abs(p_btts_no  - v2.fn_matrix_market(p_dist,'BTTS','NO'))  > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'BTTS_NO'); end if;
  if p_over_line is not null then
    if p_over  is not null and abs(p_over  - v2.fn_matrix_market(p_dist,'OU','OVER', p_over_line)) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_OVER'); end if;
    if p_under is not null and abs(p_under - v2.fn_matrix_market(p_dist,'OU','UNDER',p_over_line)) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNDER'); end if;
  end if;
  -- top_scores must be the deterministic top-k of the SAME persisted matrix (order + per-cell prob)
  if p_top_scores is not null and jsonb_array_length(p_top_scores) > 0 then
    n := jsonb_array_length(p_top_scores);
    select jsonb_agg(s) into true_top from (
      select (c->>'s') s from jsonb_array_elements(p_dist) c
      order by (c->>'p')::numeric desc, (split_part(c->>'s','-',1)::int+split_part(c->>'s','-',2)::int) asc, split_part(c->>'s','-',1)::int asc
      limit n) z;
    if (select jsonb_agg(e->>'s') from jsonb_array_elements(p_top_scores) e) is distinct from true_top then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_ORDER'); end if;
    if exists (select 1 from jsonb_array_elements(p_top_scores) e where abs((e->>'p')::numeric - v2.fn_matrix_market(p_dist,'EXACT',(e->>'s'))) > p_tol) then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_PROB'); end if;
  end if;
  coherence_ok := coh;
  if not coh then reasons := concat_ws('; ','COHERENCE_FAIL',reasons); end if;
  -- (b) discrepancy (model vs no-vig market). Caller MUST pass AS-OF<=decision odds and
  --     over/under only for the EXACT canonical line (5620477307 F3/F4); this fn does not
  --     read odds itself, so temporal/line safety is enforced at the view boundary.
  select * into d from v2.fn_model_market_discrepancy(
    p_home,p_draw,p_away,p_over, p_odds_home,p_odds_draw,p_odds_away,p_odds_over,p_odds_under);
  disc_flag := d.flag; suppress := coalesce(d.suppress,false);
  if suppress then reasons := concat_ws('; ',reasons, d.flag||': '||d.reason); end if;
  top_only_eligible := coherence_ok and not suppress;
  gate_reason := nullif(reasons,'');
  return next;
end $$;

-- ── BRANCH EXECUTABLE PROOF over the 6 owner fixtures (real lambdas + real odds) ──
-- Each fixture -> its ONE emitted matrix -> gate status. The candidate view excludes
-- ineligible events; the analysis view keeps them. Proves Bayern (401915443) and
-- Man United (401915442) are absent from TOP_ONLY yet present in analysis.
create or replace view v2.v_gate_fixture_status as
select f.espn_event_id, f.home_team, f.away_team, f.competition, f.over_line,
       d.jd,
       gs.coherence_ok, gs.disc_flag, gs.suppress, gs.top_only_eligible, gs.gate_reason
from v2.gate_fixture_soccer_cards f
cross join lateral (select v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,coalesce(f.maxg,10)) jd) d
-- 5620477307 F2: new fn_event_gate_status signature — checks EVERY candidate field.
-- Arg order: p_dist, p_home, p_draw, p_away, p_over, p_under, p_over_line, p_btts_yes,
--            p_btts_no, p_top_scores, then the 5 context odds.
cross join lateral v2.fn_event_gate_status(
  d.jd->'dist',
  (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
  (d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric, f.over_line,
  (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric, d.jd->'top_scores',
  f.odds_home,f.odds_draw,f.odds_away,f.odds_over,f.odds_under) gs;

-- ANALYSIS surface: ALL events (incl. suppressed) remain visible.
create or replace view v2.v_gate_fixture_analysis_all as
select espn_event_id, home_team, away_team, competition, over_line,
       (jd->>'p_home')::numeric p_home, (jd->>'p_away')::numeric p_away,
       (jd->>'p_over')::numeric p_over, disc_flag, suppress, top_only_eligible, gate_reason
from v2.v_gate_fixture_status;

-- TOP_ONLY candidate surface: only eligible events, expanded into canonical candidates.
create or replace view v2.v_gate_fixture_candidates as
select s.espn_event_id as canonical_event_id, s.home_team, s.away_team, s.competition,
       cand.canonical_market, cand.canonical_side, cand.canonical_line, cand.canonical_probability
from v2.v_gate_fixture_status s
cross join lateral (
  values
    ('1X2'::text,'HOME'::text,null::numeric,(s.jd->>'p_home')::numeric),
    ('1X2','DRAW',null,(s.jd->>'p_draw')::numeric),
    ('1X2','AWAY',null,(s.jd->>'p_away')::numeric),
    ('BTTS','YES',null,(s.jd->>'btts_yes')::numeric),
    ('BTTS','NO', null,(s.jd->>'btts_no')::numeric),
    ('OU','OVER', s.over_line, case when s.over_line is not null then (s.jd->>'p_over')::numeric end),
    ('OU','UNDER',s.over_line, case when s.over_line is not null then (s.jd->>'p_under')::numeric end)
) cand(canonical_market,canonical_side,canonical_line,canonical_probability)
where s.top_only_eligible                              -- <-- the exclusion
  and cand.canonical_probability is not null;
