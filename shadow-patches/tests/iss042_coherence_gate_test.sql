-- ============================================================================
-- iss042/043/045 v2 GATE TEST — branch-only (soccer-coherence-gate). Reproduces
-- AUDIT_NO_PASS 5619542059 required rerun: 6 fixtures coherent, TOP_ONLY exclusion,
-- top-k, adversarial totals (4.5/4.0/2.25/2.75/unsupported), whole-handicap push.
-- Requires iss041 v2 + iss042 v2 + iss043 v2 + iss045 installed and the fixture table.
-- RAISE EXCEPTION on any failure; a clean run = all assertions passed.
-- ============================================================================
do $$
declare r record; n int; s text; d jsonb;
begin
  -- 1) six owner fixtures: 0 failing markets each
  for r in
    select f.espn_event_id, f.home_team,
           (select count(*) filter (where not g.ok)
              from v2.fn_soccer_coherence_gate(
                v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,coalesce(f.maxg,10)),
                f.over_line) g) fails
    from v2.gate_fixture_soccer_cards f
  loop
    if r.fails <> 0 then raise exception 'FAIL C1: % has % failing markets', r.home_team, r.fails; end if;
  end loop;
  raise notice 'PASS C1: 6/6 fixtures coherent (0 failing markets each)';

  -- 2) TOP_ONLY exclusion: Bayern 401915443 + ManU 401915442 excluded from candidates, present in analysis
  select count(*) into n from v2.v_gate_fixture_candidates where canonical_event_id in ('401915442','401915443');
  if n <> 0 then raise exception 'FAIL C2a: suppressed events leaked into TOP_ONLY candidates (n=%)', n; end if;
  select count(distinct espn_event_id) into n from v2.v_gate_fixture_analysis_all where espn_event_id in ('401915442','401915443');
  if n <> 2 then raise exception 'FAIL C2b: suppressed events not visible in analysis (n=%)', n; end if;
  select count(distinct canonical_event_id) into n from v2.v_gate_fixture_candidates;
  if n <> 4 then raise exception 'FAIL C2c: expected 4 eligible events in candidates, got %', n; end if;
  raise notice 'PASS C2: Bayern/ManU excluded from TOP_ONLY, present in analysis (4 eligible)';

  -- 3) top-k: Bayern true top-1 = 2-1 (was 0-0 under the old dist.slice bug)
  d := v2.fn_dist_from_lambda(2.697,1.266,4.5,0.0705,10);
  if (d->>'predicted_score') <> '2-1' then raise exception 'FAIL C3: Bayern top1 % (expected 2-1)', d->>'predicted_score'; end if;
  if (d->'top_scores'->0->>'s') <> '2-1' then raise exception 'FAIL C3: top_scores[0] mismatch'; end if;
  raise notice 'PASS C3: top-k sorted by prob (Bayern top1=2-1)';

  -- 4) adversarial totals
  d := v2.fn_dist_from_lambda(3.2,1.1,4.0,-0.05,10);   -- WHOLE line: exact-total push
  if (d->>'ou_line_type') <> 'WHOLE' or (d->>'p_push')::numeric <= 0 then raise exception 'FAIL C4a: whole line 4.0 no push (%)', d->>'p_push'; end if;
  if round(coalesce((d->>'p_over')::numeric,0)+coalesce((d->>'p_push')::numeric,0)+coalesce((d->>'p_under')::numeric,0),1) <> 100.0
     then raise exception 'FAIL C4a: whole 4.0 over+push+under != 100'; end if;
  select count(*) filter (where not ok) into n from v2.fn_soccer_coherence_gate(d,4.0); if n<>0 then raise exception 'FAIL C4a: whole 4.0 gate fails=%',n; end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,2.25,-0.05,10); if (d->>'ou_line_type')<>'QUARTER' then raise exception 'FAIL C4b: 2.25 not QUARTER'; end if;
  select count(*) filter (where not ok) into n from v2.fn_soccer_coherence_gate(d,2.25); if n<>0 then raise exception 'FAIL C4b: quarter 2.25 gate fails=%',n; end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,2.75,-0.05,10);
  select count(*) filter (where not ok) into n from v2.fn_soccer_coherence_gate(d,2.75); if n<>0 then raise exception 'FAIL C4c: quarter 2.75 gate fails=%',n; end if;
  d := v2.fn_dist_from_lambda(3.2,1.1,3.1,-0.05,10);   -- unsupported fraction: fail-closed
  if (d->>'ou_supported')::boolean or (d->>'p_over') is not null then raise exception 'FAIL C4d: unsupported line 3.1 not fail-closed'; end if;
  raise notice 'PASS C4: totals push (4.0)+split (2.25/2.75)+fail-close (3.1)';

  -- 5) whole handicap -1 push semantics: win=P(m>=2), push=P(m=1), win+push+lose=100
  d := v2.fn_dist_from_lambda(2.289,1.308,3.5,0.0705,10);
  if abs((d->'markets'->>'home_minus1')::numeric - v2.fn_matrix_market(d->'dist','AH','HOME',-1)) > 0.2
     then raise exception 'FAIL C5: home_minus1 win != P(margin>=2)'; end if;
  if abs((d->'markets'->>'home_minus1_push')::numeric - v2.fn_matrix_market(d->'dist','AH','PUSH',-1)) > 0.2
     then raise exception 'FAIL C5: home_minus1 push != P(margin==1)'; end if;
  if round((d->'markets'->>'home_minus1')::numeric+(d->'markets'->>'home_minus1_push')::numeric+(d->'markets'->>'away_plus1')::numeric,1) <> 100.0
     then raise exception 'FAIL C5: home-1 win+push+lose != 100'; end if;
  raise notice 'PASS C5: whole handicap -1 win/push/lose settlement complete';

  raise notice 'ALL COHERENCE-GATE v2 ASSERTIONS PASSED';
end $$;
