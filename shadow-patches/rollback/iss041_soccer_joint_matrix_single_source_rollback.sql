-- ============================================================================
-- ROLLBACK for iss041 — restores PROD-VERBATIM v2.fn_dist_from_lambda + v2.fn_score_dist
-- Captured READ-ONLY from prod wpiztubmmmzclhlprgpd on 2026-09-10 via pg_get_functiondef.
-- Apply only to undo iss041 (branch or, post-cutover, prod). No data change.
-- NOTE: rolling back does NOT re-truncate already-rebuilt score_dist rows.
-- ============================================================================

-- prod-verbatim fn_dist_from_lambda (>=0.01 cell drop, 1-dec, no renorm)
CREATE OR REPLACE FUNCTION v2.fn_dist_from_lambda(lh numeric, la numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
declare
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; p_home numeric := 0; p_draw numeric := 0; p_away numeric := 0;
  btts numeric := 0; p_over numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  dist jsonb := '[]'::jsonb;
  hm2 numeric:=0; hm1 numeric:=0; am2 numeric:=0; am1 numeric:=0;
  o05 numeric:=0; o15 numeric:=0; o25 numeric:=0; o35 numeric:=0;
  cs_h numeric:=0; cs_a numeric:=0;
begin
  if lh is null or la is null or lh<=0 or la<=0 or lh>8 or la>8 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1]; pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    tot := tot + greatest(tau,0)*ph*pa;
  end loop; end loop;
  if tot<=0 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1]; pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    pij := greatest(tau,0)*ph*pa/tot;
    if i>j then p_home:=p_home+pij; elsif i=j then p_draw:=p_draw+pij; else p_away:=p_away+pij; end if;
    if i>=1 and j>=1 then btts:=btts+pij; end if;
    if over_line is not null and (i+j) > over_line then p_over:=p_over+pij; end if;
    if (i-j)>=2 then hm2:=hm2+pij; end if;
    if (i-j)>=1 then hm1:=hm1+pij; end if;
    if (j-i)>=2 then am2:=am2+pij; end if;
    if (j-i)>=1 then am1:=am1+pij; end if;
    if (i+j)>=1 then o05:=o05+pij; end if;
    if (i+j)>=2 then o15:=o15+pij; end if;
    if (i+j)>=3 then o25:=o25+pij; end if;
    if (i+j)>=4 then o35:=o35+pij; end if;
    if j=0 then cs_h:=cs_h+pij; end if;
    if i=0 then cs_a:=cs_a+pij; end if;
    if pij>best then best:=pij; best_i:=i; best_j:=j; end if;
    if pij>=0.01 then dist := dist || jsonb_build_object('s', i||'-'||j, 'p', round(pij*100,1)); end if;
  end loop; end loop;
  return jsonb_build_object(
    'lambda_home', round(lh,3), 'lambda_away', round(la,3), 'rho', rho, 'exp_goals_total', round(lh+la,2),
    'p_home', round(p_home*100,1), 'p_draw', round(p_draw*100,1), 'p_away', round(p_away*100,1),
    'btts_yes', round(btts*100,1), 'btts_no', round((1-btts)*100,1),
    'over_line', over_line,
    'p_over', case when over_line is null then null else round(p_over*100,1) end,
    'p_under', case when over_line is null then null else round((1-p_over)*100,1) end,
    'predicted_score', best_i||'-'||best_j, 'predicted_score_prob', round(best*100,1),
    'dist', dist, 'max_goals', maxg,
    'markets', jsonb_build_object(
      'dc_1x', round((p_home+p_draw)*100,1), 'dc_12', round((p_home+p_away)*100,1), 'dc_x2', round((p_draw+p_away)*100,1),
      'hand_home_minus15', round(hm2*100,1), 'hand_home_minus25', round((case when true then 0 else 0 end)*100,1),
      'hand_home_minus1', round(hm2*100,1), 'hand_home_ah_minus1_win', round(hm2*100,1),
      'home_minus15', round(hm2*100,1), 'away_plus15', round((1-hm2)*100,1),
      'home_minus1', round(hm1*100,1), 'away_plus1', round(am1*100,1),
      'away_minus15', round(am2*100,1), 'home_plus15', round((1-am2)*100,1),
      'over05', round(o05*100,1), 'over15', round(o15*100,1), 'over25', round(o25*100,1), 'over35', round(o35*100,1),
      'under15', round((1-o15)*100,1), 'under25', round((1-o25)*100,1), 'under35', round((1-o35)*100,1),
      'clean_sheet_home', round(cs_h*100,1), 'clean_sheet_away', round(cs_a*100,1)
    ));
end $function$;

-- prod-verbatim fn_score_dist (parallel full-precision scalars; all cells 2-dec; sums ~100)
CREATE OR REPLACE FUNCTION v2.fn_score_dist(atk_h numeric, def_h numeric, atk_a numeric, def_a numeric, mgl numeric, mgv numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $function$
declare
  lh numeric; la numeric;
  fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800];
  i int; j int; ph numeric; pa numeric; tau numeric; pij numeric;
  tot numeric := 0; p_home numeric := 0; p_draw numeric := 0; p_away numeric := 0;
  btts numeric := 0; p_over numeric := 0; best numeric := -1; best_i int := 0; best_j int := 0;
  dist jsonb := '[]'::jsonb; dist_sum numeric := 0;
begin
  if atk_h is null or def_h is null or atk_a is null or def_a is null
     or mgl is null or mgv is null or mgl<=0 or mgv<=0 then return null; end if;
  lh := atk_h * def_a / mgv;
  la := atk_a * def_h / mgl;
  if lh is null or la is null or lh<=0 or la<=0 or lh>8 or la>8 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1];
    pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    tot := tot + greatest(tau,0)*ph*pa;
  end loop; end loop;
  if tot<=0 then return null; end if;
  for i in 0..maxg loop for j in 0..maxg loop
    ph := exp(-lh)*power(lh,i)/fact[i+1];
    pa := exp(-la)*power(la,j)/fact[j+1];
    tau := case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho
                when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
    pij := greatest(tau,0)*ph*pa/tot;
    if i>j then p_home:=p_home+pij; elsif i=j then p_draw:=p_draw+pij; else p_away:=p_away+pij; end if;
    if i>=1 and j>=1 then btts:=btts+pij; end if;
    if over_line is not null and (i+j) > over_line then p_over:=p_over+pij; end if;
    if pij>best then best:=pij; best_i:=i; best_j:=j; end if;
    dist := dist || jsonb_build_object('s', i||'-'||j, 'p', round(pij*100,2));
    dist_sum := dist_sum + round(pij*100,2);
  end loop; end loop;
  return jsonb_build_object(
    'lambda_home', round(lh,3), 'lambda_away', round(la,3), 'rho', rho,
    'exp_goals_total', round(lh+la,2),
    'p_home', round(p_home*100,1), 'p_draw', round(p_draw*100,1), 'p_away', round(p_away*100,1),
    'btts_yes', round(btts*100,1), 'btts_no', round((1-btts)*100,1),
    'over_line', over_line,
    'p_over', case when over_line is null then null else round(p_over*100,1) end,
    'p_under', case when over_line is null then null else round((1-p_over)*100,1) end,
    'predicted_score', best_i||'-'||best_j, 'predicted_score_prob', round(best*100,1),
    'dist', dist, 'dist_sum_pct', round(dist_sum,1), 'max_goals', maxg, 'dist_complete', true);
end $function$;
