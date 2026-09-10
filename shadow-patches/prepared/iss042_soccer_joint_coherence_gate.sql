-- ============================================================================
-- iss042 v2 — SOCCER_JOINT_DISTRIBUTION_COHERENCE_GATE (P0) · STAGED, branch-only
-- ============================================================================
-- Issue #4 mandate 5618913334 · DELIVERABLE 2. Resolves AUDIT_NO_PASS 5619542059
-- findings 3/4/5 on the GATE side: it now checks totals with PUSH semantics, whole
-- AND half handicaps (every user-visible handicap field, incl. push companions), and
-- the canonical top-k exact scores (order + membership). It SUMS the stored matrix and
-- compares to the stored scalars via the SAME settlement primitive the emitter uses
-- (v2.fn_total_weights) so gate and emitter cannot drift. FAIL if |displayed-matrix|>0.2pp.
-- No weakened assertions, no recompute of P. NO PROD MUTATION.
-- ============================================================================
create schema if not exists v2;

-- Sum an arbitrary market directly over the matrix (single source of truth).
-- OU/AH use v2.fn_total_weights so PUSH and whole/quarter lines settle identically to
-- the emitter. AH: p_line is the HOME handicap h; settled as an over-bet on margin @ -h.
create or replace function v2.fn_matrix_market(p_dist jsonb, p_market text, p_side text default null, p_line numeric default null)
returns numeric language sql immutable as $$
  select round(coalesce(sum(
    (c->>'p')::numeric * (
      case upper(p_market)
        when '1X2'  then case upper(p_side) when 'HOME' then (k.gi>k.gj)::int when 'DRAW' then (k.gi=k.gj)::int when 'AWAY' then (k.gi<k.gj)::int else 0 end::numeric
        when 'BTTS' then case upper(p_side) when 'YES' then (k.gi>=1 and k.gj>=1)::int when 'NO' then (not(k.gi>=1 and k.gj>=1))::int else 0 end::numeric
        when 'CS'   then case upper(p_side) when 'HOME' then (k.gj=0)::int when 'AWAY' then (k.gi=0)::int else 0 end::numeric
        when 'OU'   then case upper(p_side) when 'OVER' then wou.wt[1] when 'PUSH' then wou.wt[2] when 'UNDER' then wou.wt[3] else 0 end
        when 'AH'   then case upper(p_side) when 'HOME' then wah.wt[1] when 'PUSH' then wah.wt[2] when 'AWAY' then wah.wt[3] else 0 end
        when 'EXACT' then ((c->>'s')=p_side)::int::numeric
        else 0::numeric end
    )
  ),0),2)
  from jsonb_array_elements(p_dist) c
  cross join lateral (select split_part(c->>'s','-',1)::int gi, split_part(c->>'s','-',2)::int gj) k
  left join lateral (select v2.fn_total_weights(k.gi+k.gj, p_line) wt) wou on upper(p_market)='OU'
  left join lateral (select v2.fn_total_weights(k.gi-k.gj, -p_line) wt) wah on upper(p_market)='AH';
$$;

-- The gate: takes the full emitted jsonb d and its real provider over_line, returns one
-- row per checked market with pass/fail vs 0.2pp (dist-sum tolerance 0.5pp).
create or replace function v2.fn_soccer_coherence_gate(p_d jsonb, p_over_line numeric, p_tol numeric default 0.2)
returns table(market text, displayed numeric, matrix_derived numeric, delta numeric, ok boolean)
language plpgsql immutable as $$
declare dist jsonb := p_d->'dist'; mk jsonb := p_d->'markets'; ts jsonb := p_d->'top_scores';
        ou_ok boolean := coalesce((p_d->>'ou_supported')::boolean, true);
        true_top jsonb; n int; a text; b numeric;
begin
  -- dist completeness
  market:='DIST_SUM'; displayed:=100; matrix_derived:=(select round(sum((c->>'p')::numeric),2) from jsonb_array_elements(dist) c);
  delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=0.5; return next;
  -- 1X2
  market:='1X2_HOME'; displayed:=(p_d->>'p_home')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'1X2','HOME'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='1X2_DRAW'; displayed:=(p_d->>'p_draw')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'1X2','DRAW'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='1X2_AWAY'; displayed:=(p_d->>'p_away')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'1X2','AWAY'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- BTTS
  market:='BTTS_YES'; displayed:=(p_d->>'btts_yes')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'BTTS','YES'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='BTTS_NO';  displayed:=(p_d->>'btts_no')::numeric;  matrix_derived:=v2.fn_matrix_market(dist,'BTTS','NO');  delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- clean sheets
  market:='CS_HOME'; displayed:=(mk->>'clean_sheet_home')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'CS','HOME'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='CS_AWAY'; displayed:=(mk->>'clean_sheet_away')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'CS','AWAY'); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- O/U at the REAL provider line only, WITH push
  if p_over_line is not null then
    if not ou_ok then
      -- unsupported line must fail-closed: displayed over/under/push all NULL
      market:='OU_UNSUPPORTED@'||p_over_line;
      displayed := case when p_d->>'p_over' is null and p_d->>'p_under' is null and p_d->>'p_push' is null then 0 else 1 end;
      matrix_derived := 0; delta := displayed; ok := (displayed = 0); return next;
    else
      market:='OU_OVER@'||p_over_line;  displayed:=(p_d->>'p_over')::numeric;  matrix_derived:=v2.fn_matrix_market(dist,'OU','OVER', p_over_line); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
      market:='OU_UNDER@'||p_over_line; displayed:=(p_d->>'p_under')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'OU','UNDER',p_over_line); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
      market:='OU_PUSH@'||p_over_line;  displayed:=(p_d->>'p_push')::numeric;  matrix_derived:=v2.fn_matrix_market(dist,'OU','PUSH', p_over_line); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
      -- over+push+under must sum to 100 (settlement completeness)
      market:='OU_SUM'; displayed:=100; matrix_derived:=round(coalesce((p_d->>'p_over')::numeric,0)+coalesce((p_d->>'p_push')::numeric,0)+coalesce((p_d->>'p_under')::numeric,0),2); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=0.5; return next;
    end if;
  end if;
  -- Asian handicap HALF lines (no push): +/-1.5
  market:='AH_HOME_-1.5'; displayed:=(mk->>'home_minus15')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'AH','HOME',-1.5); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_AWAY_+1.5'; displayed:=(mk->>'away_plus15')::numeric;  matrix_derived:=v2.fn_matrix_market(dist,'AH','AWAY',-1.5); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_AWAY_-1.5'; displayed:=(mk->>'away_minus15')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'AH','AWAY', 1.5); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_HOME_+1.5'; displayed:=(mk->>'home_plus15')::numeric;  matrix_derived:=v2.fn_matrix_market(dist,'AH','HOME', 1.5); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- Asian handicap WHOLE lines (+/-1) WITH push
  market:='AH_HOME_-1';      displayed:=(mk->>'home_minus1')::numeric;      matrix_derived:=v2.fn_matrix_market(dist,'AH','HOME',-1); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_HOME_-1_PUSH'; displayed:=(mk->>'home_minus1_push')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'AH','PUSH',-1); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_AWAY_+1';      displayed:=(mk->>'away_plus1')::numeric;       matrix_derived:=v2.fn_matrix_market(dist,'AH','AWAY',-1); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_HOME_+1';      displayed:=(mk->>'home_plus1')::numeric;       matrix_derived:=v2.fn_matrix_market(dist,'AH','HOME', 1); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_HOME_+1_PUSH'; displayed:=(mk->>'home_plus1_push')::numeric;  matrix_derived:=v2.fn_matrix_market(dist,'AH','PUSH', 1); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  market:='AH_AWAY_-1';      displayed:=(mk->>'away_minus1')::numeric;      matrix_derived:=v2.fn_matrix_market(dist,'AH','AWAY', 1); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- exact-score TOP1 coherence: predicted_score_prob equals that cell's matrix value
  market:='EXACT_TOP1'; displayed:=(p_d->>'predicted_score_prob')::numeric; matrix_derived:=v2.fn_matrix_market(dist,'EXACT',(p_d->>'predicted_score')); delta:=round(abs(displayed-matrix_derived),2); ok:=delta<=p_tol; return next;
  -- top1 must be the modal (max) cell of the SAME matrix
  select c->>'s' into a from jsonb_array_elements(dist) c order by (c->>'p')::numeric desc, (split_part(c->>'s','-',1)::int+split_part(c->>'s','-',2)::int) asc, split_part(c->>'s','-',1)::int asc limit 1;
  market:='EXACT_TOP1_IS_MODAL'; displayed:=1; matrix_derived:=case when a=(p_d->>'predicted_score') then 1 else 0 end; delta:=abs(displayed-matrix_derived); ok:=(matrix_derived=1); return next;
  -- top_scores must equal the k largest cells in the deterministic order, each p == matrix cell
  n := jsonb_array_length(ts);
  select jsonb_agg(s) into true_top from (
    select (c->>'s') s from jsonb_array_elements(dist) c
    order by (c->>'p')::numeric desc, (split_part(c->>'s','-',1)::int+split_part(c->>'s','-',2)::int) asc, split_part(c->>'s','-',1)::int asc
    limit n
  ) z;
  market:='TOP_SCORES_ORDER'; displayed:=1;
  matrix_derived:=case when (select jsonb_agg(e->>'s') from jsonb_array_elements(ts) e) = true_top then 1 else 0 end;
  delta:=abs(displayed-matrix_derived); ok:=(matrix_derived=1); return next;
  -- each top_scores probability equals its matrix cell probability
  market:='TOP_SCORES_PROB'; displayed:=0;
  matrix_derived:=(select coalesce(max(round(abs((e->>'p')::numeric - v2.fn_matrix_market(dist,'EXACT',(e->>'s'))),2)),0) from jsonb_array_elements(ts) e);
  delta:=matrix_derived; ok:=(matrix_derived<=p_tol); return next;
end $$;
