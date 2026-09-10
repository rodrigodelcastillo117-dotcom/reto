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

-- Per-event gate status from the stored matrix + stored scalars + real odds context.
-- Works on any surface that persists score_dist + scalars + odds (prod staged rows or
-- the branch fixture rows), so the exclusion logic is identical everywhere.
create or replace function v2.fn_event_gate_status(
  p_dist jsonb, p_home numeric, p_draw numeric, p_away numeric,
  p_over numeric, p_over_line numeric, p_btts_yes numeric,
  p_odds_home numeric, p_odds_draw numeric, p_odds_away numeric,
  p_odds_over numeric, p_odds_under numeric, p_tol numeric default 0.2
) returns table(coherence_ok boolean, disc_flag text, suppress boolean, top_only_eligible boolean, gate_reason text)
language plpgsql immutable as $$
declare d record; coh boolean := true; reasons text := '';
begin
  -- (a) coherence: stored scalars must sum the stored matrix (defense-in-depth; the
  --     emitter guarantees this by construction, but a rogue/legacy row is caught here).
  if p_dist is null or jsonb_array_length(p_dist)=0 then
    coherence_ok:=false; disc_flag:='NO_MATRIX'; suppress:=true; top_only_eligible:=false;
    gate_reason:='missing/empty score_dist'; return next; return;
  end if;
  if abs(p_home - v2.fn_matrix_market(p_dist,'1X2','HOME')) > p_tol
     or abs(p_draw - v2.fn_matrix_market(p_dist,'1X2','DRAW')) > p_tol
     or abs(p_away - v2.fn_matrix_market(p_dist,'1X2','AWAY')) > p_tol
     or (p_btts_yes is not null and abs(p_btts_yes - v2.fn_matrix_market(p_dist,'BTTS','YES')) > p_tol)
     or (p_over is not null and p_over_line is not null and abs(p_over - v2.fn_matrix_market(p_dist,'OU','OVER',p_over_line)) > p_tol)
  then coh:=false; reasons:=concat_ws('; ',reasons,'COHERENCE_FAIL: displayed market != matrix sum'); end if;
  coherence_ok := coh;
  -- (b) discrepancy (model vs no-vig market). suppress from iss043.
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
cross join lateral v2.fn_event_gate_status(
  d.jd->'dist',
  (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
  (d.jd->>'p_over')::numeric, f.over_line, (d.jd->>'btts_yes')::numeric,
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
