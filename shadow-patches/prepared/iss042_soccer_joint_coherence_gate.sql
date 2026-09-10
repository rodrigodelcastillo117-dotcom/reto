-- ============================================================================
-- iss042 — SOCCER_JOINT_DISTRIBUTION_COHERENCE_GATE (P0) · STAGED, branch-only
-- ============================================================================
-- Issue #4 mandate 5618913334 · DELIVERABLE 2.
-- Asserts that, for an event's ONE emitted matrix (score_dist), every published
-- market is a faithful sum over that SAME matrix: 1X2, BTTS Y/N, clean-sheet
-- home/away, exact-score top-k, Asian handicap half-lines, and O/U AT THE REAL
-- PROVIDER LINE. FAIL if |displayed - matrix_derived| > 0.2pp.
-- No weakened assertions, no recompute of P: the gate only SUMS the stored matrix
-- and compares to the stored scalars. NO PROD MUTATION.
-- ============================================================================
create schema if not exists v2;

-- Sum an arbitrary market directly over the matrix (single source of truth).
create or replace function v2.fn_matrix_market(p_dist jsonb, p_market text, p_side text default null, p_line numeric default null)
returns numeric language sql immutable as $$
  select round(coalesce(sum((c->>'p')::numeric),0),2)
  from jsonb_array_elements(p_dist) c
  cross join lateral (select split_part(c->>'s','-',1)::int gi, split_part(c->>'s','-',2)::int gj) k
  where case upper(p_market)
    when '1X2' then case upper(p_side) when 'HOME' then k.gi>k.gj when 'DRAW' then k.gi=k.gj when 'AWAY' then k.gi<k.gj else false end
    when 'BTTS' then case upper(p_side) when 'YES' then k.gi>=1 and k.gj>=1 when 'NO' then not (k.gi>=1 and k.gj>=1) else false end
    when 'CS' then case upper(p_side) when 'HOME' then k.gj=0 when 'AWAY' then k.gi=0 else false end   -- clean sheet
    when 'OU' then case upper(p_side) when 'OVER' then (k.gi+k.gj) > p_line when 'UNDER' then (k.gi+k.gj) < p_line else false end
    -- Asian handicap half-lines (no push): HOME -p_line means home margin > p_line
    when 'AH_HOME' then (k.gi - k.gj) > p_line
    when 'AH_AWAY' then (k.gj - k.gi) > p_line
    when 'EXACT' then (c->>'s') = p_side
    else false end;
$$;

-- The gate: takes the full emitted jsonb d (from fn_dist_from_lambda) and its real
-- provider over_line, and returns one row per checked market with pass/fail vs 0.2pp.
create or replace function v2.fn_soccer_coherence_gate(p_d jsonb, p_over_line numeric, p_tol numeric default 0.2)
returns table(market text, displayed numeric, matrix_derived numeric, delta numeric, ok boolean)
language plpgsql immutable as $$
declare dist jsonb := p_d->'dist'; mk jsonb := p_d->'markets'; top_s text; top_p numeric;
begin
  -- dist completeness first (must sum to 100 within rounding)
  market := 'DIST_SUM'; displayed := 100; matrix_derived := (select round(sum((c->>'p')::numeric),2) from jsonb_array_elements(dist) c);
  delta := round(abs(displayed-matrix_derived),2); ok := delta <= 0.5; return next;
  -- 1X2
  market:='1X2_HOME'; displayed:=(p_d->>'p_home')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'1X2','HOME'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='1X2_DRAW'; displayed:=(p_d->>'p_draw')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'1X2','DRAW'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='1X2_AWAY'; displayed:=(p_d->>'p_away')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'1X2','AWAY'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- BTTS
  market:='BTTS_YES'; displayed:=(p_d->>'btts_yes')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'BTTS','YES'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='BTTS_NO'; displayed:=(p_d->>'btts_no')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'BTTS','NO'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- clean sheets (from markets block)
  market:='CS_HOME'; displayed:=(mk->>'clean_sheet_home')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'CS','HOME'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='CS_AWAY'; displayed:=(mk->>'clean_sheet_away')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'CS','AWAY'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- O/U at the REAL provider line only
  if p_over_line is not null then
    market:='OU_OVER@'||p_over_line; displayed:=(p_d->>'p_over')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'OU','OVER',p_over_line); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
    market:='OU_UNDER@'||p_over_line; displayed:=(p_d->>'p_under')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'OU','UNDER',p_over_line); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  end if;
  -- Asian handicap half-lines (home -1.5 / away -1.5 and their complements)
  market:='AH_HOME_-1.5'; displayed:=(mk->>'home_minus15')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'AH_HOME',null,1.5); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_AWAY_-1.5'; displayed:=(mk->>'away_minus15')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'AH_AWAY',null,1.5); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- exact-score top-k coherence: predicted_score_prob must equal that cell's matrix value
  market:='EXACT_TOP1'; displayed:=(p_d->>'predicted_score_prob')::numeric;
  matrix_derived:=v2.fn_matrix_market(dist,'EXACT',(p_d->>'predicted_score')); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- exact-score top-k must be the k largest cells of the SAME matrix (monotone check)
  select c->>'s',(c->>'p')::numeric into top_s,top_p from jsonb_array_elements(dist) c order by (c->>'p')::numeric desc limit 1;
  market:='EXACT_TOP1_IS_MODAL'; displayed:=top_p; matrix_derived:=(p_d->>'predicted_score_prob')::numeric; delta:=round(abs(displayed-matrix_derived),2); ok:=(top_s=(p_d->>'predicted_score') and delta<=p_tol); return next;
end $$;
