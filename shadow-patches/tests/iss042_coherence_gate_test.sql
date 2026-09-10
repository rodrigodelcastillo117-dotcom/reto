-- ============================================================================
-- iss042 TEST — SOCCER_JOINT_DISTRIBUTION_COHERENCE_GATE · tx ROLLBACK · branch-only
-- Adversarial fixtures = the SIX owner UCL cards (exact prod inputs; rho=0.0705 xleague).
-- POST-FIX (iss041 applied): every card must PASS all 14 coherence checks (<=0.2pp).
-- Also demonstrates PRE-FIX FAIL by restoring the prod-verbatim fn inside the tx.
-- Requires: iss000 baseline, iss041 fix, iss042 gate, iss041_fixtures loaded.
-- ============================================================================
begin;
do $$
declare bad int; worst numeric;
begin
  -- POST-FIX assertion: 0 failing checks across all 6 fixtures
  select count(*) filter (where not ok), max(delta) into bad, worst
  from v2.gate_fixture_soccer_cards f,
       lateral v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,f.maxg) d,
       lateral v2.fn_soccer_coherence_gate(d, f.over_line, 0.2) g;
  if bad <> 0 then raise exception 'FAIL post-fix coherence: % failing checks (worst %pp)', bad, worst; end if;
  raise notice 'PASS iss042 post-fix: 6/6 cards coherent, worst delta %pp (<=0.2)', worst;
end $$;
rollback;

-- PRE-FIX demonstration (separate tx): restore prod-verbatim fn, expect failures.
begin;
CREATE OR REPLACE FUNCTION v2.fn_dist_from_lambda(lh numeric, la numeric, over_line numeric DEFAULT NULL::numeric, rho numeric DEFAULT '-0.05'::numeric, maxg integer DEFAULT 8)
 RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $f$
declare fact numeric[] := array[1,1,2,6,24,120,720,5040,40320,362880,3628800];
 i int; j int; ph numeric; pa numeric; tau numeric; pij numeric; tot numeric:=0;
 p_home numeric:=0;p_draw numeric:=0;p_away numeric:=0;btts numeric:=0;p_over numeric:=0;
 best numeric:=-1;best_i int:=0;best_j int:=0; dist jsonb:='[]'::jsonb;
 hm2 numeric:=0;am2 numeric:=0;cs_h numeric:=0;cs_a numeric:=0;
begin
 if lh is null or la is null or lh<=0 or la<=0 or lh>8 or la>8 then return null; end if;
 for i in 0..maxg loop for j in 0..maxg loop
   ph:=exp(-lh)*power(lh,i)/fact[i+1];pa:=exp(-la)*power(la,j)/fact[j+1];
   tau:=case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
   tot:=tot+greatest(tau,0)*ph*pa; end loop; end loop;
 if tot<=0 then return null; end if;
 for i in 0..maxg loop for j in 0..maxg loop
   ph:=exp(-lh)*power(lh,i)/fact[i+1];pa:=exp(-la)*power(la,j)/fact[j+1];
   tau:=case when i=0 and j=0 then 1-lh*la*rho when i=0 and j=1 then 1+lh*rho when i=1 and j=0 then 1+la*rho when i=1 and j=1 then 1-rho else 1 end;
   pij:=greatest(tau,0)*ph*pa/tot;
   if i>j then p_home:=p_home+pij; elsif i=j then p_draw:=p_draw+pij; else p_away:=p_away+pij; end if;
   if i>=1 and j>=1 then btts:=btts+pij; end if;
   if over_line is not null and (i+j)>over_line then p_over:=p_over+pij; end if;
   if (i-j)>=2 then hm2:=hm2+pij; end if; if (j-i)>=2 then am2:=am2+pij; end if;
   if j=0 then cs_h:=cs_h+pij; end if; if i=0 then cs_a:=cs_a+pij; end if;
   if pij>best then best:=pij;best_i:=i;best_j:=j; end if;
   if pij>=0.01 then dist:=dist||jsonb_build_object('s',i||'-'||j,'p',round(pij*100,1)); end if;
 end loop; end loop;
 return jsonb_build_object('lambda_home',round(lh,3),'lambda_away',round(la,3),'rho',rho,'exp_goals_total',round(lh+la,2),
   'p_home',round(p_home*100,1),'p_draw',round(p_draw*100,1),'p_away',round(p_away*100,1),
   'btts_yes',round(btts*100,1),'btts_no',round((1-btts)*100,1),'over_line',over_line,
   'p_over',case when over_line is null then null else round(p_over*100,1) end,
   'p_under',case when over_line is null then null else round((1-p_over)*100,1) end,
   'predicted_score',best_i||'-'||best_j,'predicted_score_prob',round(best*100,1),'dist',dist,'max_goals',maxg,
   'markets',jsonb_build_object('home_minus15',round(hm2*100,1),'away_minus15',round(am2*100,1),
     'clean_sheet_home',round(cs_h*100,1),'clean_sheet_away',round(cs_a*100,1)));
end $f$;
do $$
declare bad int;
begin
  select count(*) filter (where not ok) into bad
  from v2.gate_fixture_soccer_cards f,
       lateral v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,f.maxg) d,
       lateral v2.fn_soccer_coherence_gate(d, f.over_line, 0.2) g;
  if bad = 0 then raise exception 'UNEXPECTED: pre-fix should FAIL coherence but produced 0 failures'; end if;
  raise notice 'PASS iss042 pre-fix demo: gate correctly FAILS pre-fix (% failing checks across 6 cards)', bad;
end $$;
rollback;
