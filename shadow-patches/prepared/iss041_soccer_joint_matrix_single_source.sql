-- ============================================================================
-- iss041 v2 — SOCCER JOINT MATRIX = SINGLE AUTHORITATIVE SOURCE (P0 COHERENCE FIX)
-- ============================================================================
-- Issue #4 mandate 5618913334 · DELIVERABLE 1. Resolves AUDIT_NO_PASS 5619542059
-- findings 3 (totals push/split), 4 (handicap push), 5 (top-k), 7 (wording).
-- STAGED · branch-only · NO PROD MUTATION · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
--
-- CONFIRMED ROOT CAUSE (v1, read-only from prod): fn_dist_from_lambda emitted only
-- cells >=1%, rounded, never renormalized, while scalars accumulated at full precision
-- over the complete grid -> stored matrix summed 91.5-95.4, every market deflated.
--
-- v1 FIX kept: emit EVERY cell (2-dec >0), fold rounding residual into the modal cell
-- so the matrix sums to EXACTLY 100.00, and DERIVE every scalar by summing the SAME
-- emitted cells (matrix-sum == scalar by construction). DC math (rho/lambda) UNCHANGED.
--
-- v2 ADDITIONS (this file), all still DERIVED from the single emitted matrix:
--   F3 TOTALS: proper win/PUSH/loss settlement. Half line (x.5) -> no push. Whole line
--      (x.0) -> exact-total==line is a PUSH (not UNDER). Quarter line (x.25/x.75) ->
--      split into the two adjacent lines (half-win/half-push). Any other fractional
--      line -> FAIL-CLOSE (p_over/p_under/p_push NULL + ou_supported=false + reason).
--      Never publish a fake binary P_OVER/P_UNDER for a push-bearing line.
--   F4 HANDICAP: whole handicaps (+/-1) get explicit win/PUSH/loss (margin==1 is a PUSH
--      on -1, not a win). Half handicaps (+/-1.5) unchanged (no push). Every user-visible
--      handicap field is emitted with its push companion so the gate can check it.
--   F5 TOP-K: emit a canonical `top_scores` array sorted by probability DESC with a
--      DETERMINISTIC tie-break (p desc, then lower total, then lower home goals). The
--      frontend consumes top_scores (no recompute / no re-sort). predicted_score is
--      defined as top_scores[0] so display order and modal cell agree deterministically.
--
-- SETTLEMENT PRIMITIVE: v2.fn_total_weights(total,line) returns [w_over,w_push,w_under].
--   A home handicap h is settled as an "over" bet on the margin with line = -h, so the
--   SAME primitive powers totals AND handicaps -> the gate and the emitter cannot drift.
-- ============================================================================

create schema if not exists v2;

-- ── shared settlement primitive: over/push/under weights for a line ──────────
-- Standard Asian settlement. `total` is an integer (goal total, or a goal margin for
-- handicaps). Returns numeric[3] = [w_over, w_push, w_under] summing to 1, or NULL for
-- an unsupported fractional line (caller fail-closes).
create or replace function v2.fn_total_weights(total int, line numeric)
returns numeric[] language plpgsql immutable as $$
declare frac numeric; lw numeric; lh numeric;
        ow numeric; pw numeric; uw numeric; oh numeric; uh numeric;
begin
  if line is null then return null; end if;
  frac := line - floor(line);
  if frac = 0.5 then                                   -- half line: no push
    if total > line then return array[1,0,0]::numeric[]; else return array[0,0,1]::numeric[]; end if;
  elsif frac = 0 then                                  -- whole line: exact == push
    if total > line then return array[1,0,0]::numeric[];
    elsif total = line then return array[0,1,0]::numeric[];
    else return array[0,0,1]::numeric[]; end if;
  elsif frac = 0.25 then                               -- quarter: whole(L-.25) + half(L+.25)
    lw := line - 0.25; lh := line + 0.25;
    if total > lw then ow:=1; pw:=0; uw:=0; elsif total = lw then ow:=0; pw:=1; uw:=0; else ow:=0; pw:=0; uw:=1; end if;
    if total > lh then oh:=1; uh:=0; else oh:=0; uh:=1; end if;
    return array[0.5*ow+0.5*oh, 0.5*pw, 0.5*uw+0.5*uh]::numeric[];
  elsif frac = 0.75 then                               -- quarter: half(L-.25) + whole(L+.25)
    lh := line - 0.25; lw := line + 0.25;
    if total > lh then oh:=1; uh:=0; else oh:=0; uh:=1; end if;
    if total > lw then ow:=1; pw:=0; uw:=0; elsif total = lw then ow:=0; pw:=1; uw:=0; else ow:=0; pw:=0; uw:=1; end if;
    return array[0.5*oh+0.5*ow, 0.5*pw, 0.5*uh+0.5*uw]::numeric[];
  else
    return null;                                       -- unsupported line fraction -> fail-close
  end if;
end $$;

-- ── fn_dist_from_lambda: authoritative matrix emitter (crossleague path) ─────
CREATE OR REPLACE FUNCTION v2.fn_dist_from_lambda(lh numeric, la numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
declare
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800,39916800,479001600];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  css text[] := array[]::text[]; cpp numeric[] := array[]::numeric[];
  cp numeric; dist_sum numeric := 0; residual numeric; modal_idx int := 1; k int;
  gi int; gj int; g numeric; m int; w numeric[];
  p_home numeric:=0; p_draw numeric:=0; p_away numeric:=0; btts numeric:=0; btts_no numeric:=0;
  p_over numeric:=0; p_under numeric:=0; p_push numeric:=0; ou_supported boolean := true;
  ou_line_type text; ou_reason text;
  hm2 numeric:=0; am2 numeric:=0; mrg_p1 numeric:=0; mrg_n1 numeric:=0; mle0 numeric:=0; mge0 numeric:=0;
  o05 numeric:=0; o15 numeric:=0; o25 numeric:=0; o35 numeric:=0;
  cs_h numeric:=0; cs_a numeric:=0; dist jsonb := '[]'::jsonb; top_scores jsonb; frac numeric;
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
  -- pass 2: build the COMPLETE rounded matrix (every cell >0, no >=1% drop), track modal
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
    end if;
  end loop; end loop;
  -- fold rounding residual into the modal cell so the matrix sums to EXACTLY 100.00
  for k in 1..array_length(css,1) loop
    if css[k] = best_i||'-'||best_j then modal_idx := k; end if;
  end loop;
  residual := round(100 - dist_sum, 2);
  cpp[modal_idx] := cpp[modal_idx] + residual;
  dist_sum := 100;
  -- totals line-type classification (fail-close unsupported fractional lines)
  if over_line is not null then
    frac := over_line - floor(over_line);
    ou_line_type := case frac when 0 then 'WHOLE' when 0.5 then 'HALF' when 0.25 then 'QUARTER' when 0.75 then 'QUARTER' else 'UNSUPPORTED' end;
    if ou_line_type = 'UNSUPPORTED' then ou_supported := false; ou_reason := 'unsupported total line fraction '||frac; end if;
  end if;
  -- pass 3: DERIVE every market by summing the SAME emitted cells (single source)
  for k in 1..array_length(css,1) loop
    gi := split_part(css[k],'-',1)::int; gj := split_part(css[k],'-',2)::int; g := cpp[k]; m := gi-gj;
    if gi>gj then p_home:=p_home+g; elsif gi=gj then p_draw:=p_draw+g; else p_away:=p_away+g; end if;
    if gi>=1 and gj>=1 then btts:=btts+g; else btts_no:=btts_no+g; end if;
    -- totals with proper push/split settlement at the REAL provider line
    if over_line is not null and ou_supported then
      w := v2.fn_total_weights(gi+gj, over_line);
      if w is null then ou_supported := false; ou_reason := 'settlement undefined for line '||over_line;
      else p_over := p_over + g*w[1]; p_push := p_push + g*w[2]; p_under := p_under + g*w[3]; end if;
    end if;
    -- handicap margin buckets (whole handicaps carry a push at |margin|==1)
    if m>=2 then hm2:=hm2+g; end if;
    if m<=-2 then am2:=am2+g; end if;
    if m=1 then mrg_p1:=mrg_p1+g; end if;
    if m=-1 then mrg_n1:=mrg_n1+g; end if;
    if m<=0 then mle0:=mle0+g; end if;
    if m>=0 then mge0:=mge0+g; end if;
    -- fixed-reference over ladder (half lines, no push)
    if (gi+gj)>=1 then o05:=o05+g; end if;
    if (gi+gj)>=2 then o15:=o15+g; end if;
    if (gi+gj)>=3 then o25:=o25+g; end if;
    if (gi+gj)>=4 then o35:=o35+g; end if;
    if gj=0 then cs_h:=cs_h+g; end if;
    if gi=0 then cs_a:=cs_a+g; end if;
    dist := dist || jsonb_build_object('s', css[k], 'p', cpp[k]);
  end loop;
  -- canonical top-k exact scores: DESC by prob, deterministic tie-break, take 5
  select jsonb_agg(jsonb_build_object('s', s, 'p', p))
    into top_scores
  from (
    select s, p from (
      select (e->>'s') s, (e->>'p')::numeric p,
             split_part(e->>'s','-',1)::int gi2, split_part(e->>'s','-',2)::int gj2
      from jsonb_array_elements(dist) e
    ) z order by p desc, (gi2+gj2) asc, gi2 asc limit 5
  ) t;
  return jsonb_build_object(
    'lambda_home', round(lh,3), 'lambda_away', round(la,3), 'rho', rho, 'exp_goals_total', round(lh+la,2),
    'p_home', round(p_home,1), 'p_draw', round(p_draw,1), 'p_away', round(p_away,1),
    'btts_yes', round(btts,1), 'btts_no', round(btts_no,1),
    'over_line', over_line, 'ou_line_type', ou_line_type, 'ou_supported', ou_supported, 'ou_reason', ou_reason,
    'p_over',  case when over_line is null or not ou_supported then null else round(p_over,1) end,
    'p_under', case when over_line is null or not ou_supported then null else round(p_under,1) end,
    'p_push',  case when over_line is null or not ou_supported then null else round(p_push,1) end,
    'predicted_score', (top_scores->0->>'s'), 'predicted_score_prob', (top_scores->0->>'p')::numeric,
    'dist', dist, 'top_scores', top_scores, 'dist_sum_pct', round(dist_sum,1), 'max_goals', maxg, 'dist_complete', true,
    'markets', jsonb_build_object(
      'dc_1x', round(p_home+p_draw,1), 'dc_12', round(p_home+p_away,1), 'dc_x2', round(p_draw+p_away,1),
      -- half handicaps (no push)
      'home_minus15', round(hm2,1), 'away_plus15', round(100-hm2,1),
      'away_minus15', round(am2,1), 'home_plus15', round(100-am2,1),
      -- whole handicaps (explicit win + push; loss implied)
      'home_minus1', round(hm2,1), 'home_minus1_push', round(mrg_p1,1),
      'away_plus1', round(mle0,1), 'away_plus1_push', round(mrg_p1,1),
      'home_plus1', round(mge0,1), 'home_plus1_push', round(mrg_n1,1),
      'away_minus1', round(am2,1), 'away_minus1_push', round(mrg_n1,1),
      -- fixed-reference over ladder
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
  d := v2.fn_dist_from_lambda(lh, la, over_line, rho, greatest(coalesce(maxg,8),8));
  if d is null then return null; end if;
  -- fn_score_dist contract: same top-level scalars + dist + top_scores, no 'markets' block.
  return jsonb_build_object(
    'lambda_home', d->'lambda_home', 'lambda_away', d->'lambda_away', 'rho', rho,
    'exp_goals_total', d->'exp_goals_total',
    'p_home', d->'p_home', 'p_draw', d->'p_draw', 'p_away', d->'p_away',
    'btts_yes', d->'btts_yes', 'btts_no', d->'btts_no',
    'over_line', over_line, 'ou_line_type', d->'ou_line_type', 'ou_supported', d->'ou_supported',
    'p_over', d->'p_over', 'p_under', d->'p_under', 'p_push', d->'p_push',
    'predicted_score', d->'predicted_score', 'predicted_score_prob', d->'predicted_score_prob',
    'dist', d->'dist', 'top_scores', d->'top_scores', 'dist_sum_pct', d->'dist_sum_pct',
    'max_goals', d->'max_goals', 'dist_complete', true);
end $function$;
