-- ============================================================================
-- iss041 — SOCCER JOINT MATRIX = SINGLE AUTHORITATIVE SOURCE (P0 COHERENCE FIX)
-- ============================================================================
-- Issue #4 mandate 5618913334 · DELIVERABLE 1.
-- STAGED · branch-only · NO PROD MUTATION · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
--
-- CONFIRMED ROOT CAUSE (read-only from prod wpiztubmmmzclhlprgpd):
--   The 6 UCL owner cards populate v2.soccer_prediction_v2.score_dist via
--   v2.fn_crossleague_predict_canonical, which does:
--       d := v2.fn_dist_from_lambda(lh, la, line, rho, 10);
--       ... score_dist := d->'dist'
--   In v2.fn_dist_from_lambda the emitted `dist` array KEEPS ONLY CELLS WITH
--   pij >= 0.01 (>=1%), each rounded to 1 decimal, and is NEVER renormalized:
--       if pij>=0.01 then dist := dist || jsonb_build_object('s',..., 'p', round(pij*100,1)); end if;
--   while the scalar outputs (p_home/btts_yes/p_over) are accumulated at FULL
--   precision over the COMPLETE 0..maxg grid. The stored matrix therefore sums to
--   91.5-95.4 (not 100) and every market summed over it is deflated vs the
--   displayed scalar by the dropped sub-1% tail (Bayern: matrix BTTS 59.5 vs
--   displayed 66.5; matrix O4.5 28.8 vs 36.4; matrix p_home 64.0 vs 68.1).
--   v2.fn_score_dist has the analogous defect in weaker form: it keeps all cells
--   (2-dec) so it sums ~100, but its scalars are still a PARALLEL full-precision
--   accumulation, not derived from the emitted cells -> not a single source.
--
-- FIX (both functions; DC math rho/lambda UNCHANGED):
--   (a) emit EVERY cell 0..maxg whose 2-decimal value > 0 (no >=1% drop);
--   (b) renormalize the emitted rounded array to sum to EXACTLY 100.00 by folding
--       the rounding residual into the modal cell (deterministic);
--   (c) DERIVE every scalar (1X2, BTTS Y/N, O/U, clean sheets, handicaps,
--       exact-score) by summing the SAME emitted cells -> matrix-sum == scalar
--       by construction (0.0pp), well within the 0.2pp gate tolerance.
--   Both remain IMMUTABLE / deterministic. maxg kept at the caller's grid (crossleague
--   already passes 10); tot is normalized over 0..maxg so full-precision mass over the
--   grid is exactly 1 and the residual fold is <0.5pp.
-- ============================================================================

create schema if not exists v2;

-- ── fn_dist_from_lambda: authoritative matrix emitter (used by crossleague path) ──
CREATE OR REPLACE FUNCTION v2.fn_dist_from_lambda(lh numeric, la numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
declare
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800,39916800,479001600];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  -- rounded emitted cells (single source)
  css text[] := array[]::text[]; cpp numeric[] := array[]::numeric[];
  cp numeric; dist_sum numeric := 0; residual numeric; modal_idx int := 1; k int;
  gi int; gj int; g numeric;
  p_home numeric:=0; p_draw numeric:=0; p_away numeric:=0; btts numeric:=0; btts_no numeric:=0;
  p_over numeric:=0; p_under numeric:=0;
  hm2 numeric:=0; hm1 numeric:=0; am2 numeric:=0; am1 numeric:=0;
  o05 numeric:=0; o15 numeric:=0; o25 numeric:=0; o35 numeric:=0;
  cs_h numeric:=0; cs_a numeric:=0; dist jsonb := '[]'::jsonb;
begin
  if lh is null or la is null or lh<=0 or la<=0 or lh>8 or la>8 then return null; end if;
  if maxg is null or maxg < 6 then maxg := 8; end if;
  if maxg > 12 then maxg := 12; end if;
  -- pass 1: normalization total over the complete 0..maxg grid
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1]; pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    tot := tot + greatest(tau,0)*ph*pa;
  end loop; end loop;
  if tot<=0 then return null; end if;
  -- pass 2: build the COMPLETE rounded matrix (every cell, no >=1% drop), track modal
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1]; pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    pij := greatest(tau,0)*ph*pa/tot;
    cp := round(pij*100, 2);
    if pij>best then best:=pij; best_i:=i; best_j:=j; end if;
    if cp > 0 then
      css := array_append(css, i||'-'||j);
      cpp := array_append(cpp, cp);
      dist_sum := dist_sum + cp;
      if i=best_i and j=best_j then modal_idx := array_length(css,1); end if;
    end if;
  end loop; end loop;
  -- locate modal cell index (best_i-best_j) in emitted array and fold residual into it
  for k in 1..array_length(css,1) loop
    if css[k] = best_i||'-'||best_j then modal_idx := k; end if;
  end loop;
  residual := round(100 - dist_sum, 2);
  cpp[modal_idx] := cpp[modal_idx] + residual;
  dist_sum := 100;
  -- pass 3: DERIVE every market by summing the SAME emitted cells (single source)
  for k in 1..array_length(css,1) loop
    gi := split_part(css[k],'-',1)::int; gj := split_part(css[k],'-',2)::int; g := cpp[k];
    if gi>gj then p_home:=p_home+g; elsif gi=gj then p_draw:=p_draw+g; else p_away:=p_away+g; end if;
    if gi>=1 and gj>=1 then btts:=btts+g; else btts_no:=btts_no+g; end if;
    if over_line is not null then
      if (gi+gj) > over_line then p_over:=p_over+g; else p_under:=p_under+g; end if;
    end if;
    if (gi-gj)>=2 then hm2:=hm2+g; end if;
    if (gi-gj)>=1 then hm1:=hm1+g; end if;
    if (gj-gi)>=2 then am2:=am2+g; end if;
    if (gj-gi)>=1 then am1:=am1+g; end if;
    if (gi+gj)>=1 then o05:=o05+g; end if;
    if (gi+gj)>=2 then o15:=o15+g; end if;
    if (gi+gj)>=3 then o25:=o25+g; end if;
    if (gi+gj)>=4 then o35:=o35+g; end if;
    if gj=0 then cs_h:=cs_h+g; end if;
    if gi=0 then cs_a:=cs_a+g; end if;
    dist := dist || jsonb_build_object('s', css[k], 'p', cpp[k]);
  end loop;
  return jsonb_build_object(
    'lambda_home', round(lh,3), 'lambda_away', round(la,3), 'rho', rho, 'exp_goals_total', round(lh+la,2),
    'p_home', round(p_home,1), 'p_draw', round(p_draw,1), 'p_away', round(p_away,1),
    'btts_yes', round(btts,1), 'btts_no', round(btts_no,1),
    'over_line', over_line,
    'p_over', case when over_line is null then null else round(p_over,1) end,
    'p_under', case when over_line is null then null else round(p_under,1) end,
    'predicted_score', best_i||'-'||best_j, 'predicted_score_prob', round(cpp[modal_idx],1),
    'dist', dist, 'dist_sum_pct', round(dist_sum,1), 'max_goals', maxg, 'dist_complete', true,
    'markets', jsonb_build_object(
      'dc_1x', round(p_home+p_draw,1), 'dc_12', round(p_home+p_away,1), 'dc_x2', round(p_draw+p_away,1),
      'home_minus15', round(hm2,1), 'away_plus15', round(100-hm2,1),
      'home_minus1', round(hm1,1), 'away_plus1', round(am1,1),
      'away_minus15', round(am2,1), 'home_plus15', round(100-am2,1),
      'over05', round(o05,1), 'over15', round(o15,1), 'over25', round(o25,1), 'over35', round(o35,1),
      'under15', round(100-o15,1), 'under25', round(100-o25,1), 'under35', round(100-o35,1),
      'clean_sheet_home', round(cs_h,1), 'clean_sheet_away', round(cs_a,1)
    ));
end $function$;

-- ── fn_score_dist: same single-source discipline (domestic path) ─────────────
CREATE OR REPLACE FUNCTION v2.fn_score_dist(atk_h numeric, def_h numeric, atk_a numeric, def_a numeric, mgl numeric, mgv numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
declare
  lh numeric; la numeric; d jsonb;
begin
  if atk_h is null or def_h is null or atk_a is null or def_a is null
     or mgl is null or mgv is null or mgl<=0 or mgv<=0 then return null; end if;
  lh := atk_h * def_a / mgv;
  la := atk_a * def_h / mgl;
  -- Delegate to the authoritative matrix emitter so scalars are DERIVED from the
  -- single emitted matrix (DC math rho/lambda unchanged). Keep raise-maxg support.
  d := v2.fn_dist_from_lambda(lh, la, over_line, rho, greatest(coalesce(maxg,8),8));
  if d is null then return null; end if;
  -- fn_score_dist contract: same top-level scalars + dist, no 'markets' block.
  return jsonb_build_object(
    'lambda_home', d->'lambda_home', 'lambda_away', d->'lambda_away', 'rho', rho,
    'exp_goals_total', d->'exp_goals_total',
    'p_home', d->'p_home', 'p_draw', d->'p_draw', 'p_away', d->'p_away',
    'btts_yes', d->'btts_yes', 'btts_no', d->'btts_no',
    'over_line', over_line, 'p_over', d->'p_over', 'p_under', d->'p_under',
    'predicted_score', d->'predicted_score', 'predicted_score_prob', d->'predicted_score_prob',
    'dist', d->'dist', 'dist_sum_pct', d->'dist_sum_pct', 'max_goals', d->'max_goals',
    'dist_complete', true);
end $function$;
