-- ============================================================================
-- iss043 — MODEL_MARKET_DISCREPANCY diagnostic / quality gate · STAGED, branch-only
-- ============================================================================
-- Issue #4 mandate 5618913334 · DELIVERABLE 3.
-- Computes no-vig (implied, overround-removed) market probabilities from the ODDS
-- columns only (odds_home/draw/away/over/under). The no-vig market is NEVER used as
-- P_RETO (odds_is_context_not_preto=true). It is a QUALITY DIAGNOSTIC: when the
-- model's winner prob or total prob diverges from the no-vig market beyond a
-- threshold, the event is flagged QUALITY_DOWNGRADE / REVIEW_REQUIRED and SUPPRESSED
-- from TOP_ONLY_GLOBAL / Reto13M eligibility. Market numbers are DERIVED from real
-- odds, never hardcoded. NO PROD MUTATION.
-- ============================================================================
create schema if not exists v2;

-- No-vig 1X2 from decimal odds (proportional overround removal).
create or replace function v2.fn_novig_1x2(oh numeric, od numeric, oa numeric)
returns table(nv_home numeric, nv_draw numeric, nv_away numeric, overround numeric)
language sql immutable as $$
  select round(100*(1/oh)/s,1), round(100*(1/od)/s,1), round(100*(1/oa)/s,1), round(100*(s-1),2)
  from (select (1/oh + 1/od + 1/oa) s) q
  where oh is not null and od is not null and oa is not null and oh>1 and od>1 and oa>1;
$$;

-- No-vig two-way (Over/Under, or BTTS Y/N) from decimal odds.
create or replace function v2.fn_novig_2way(o1 numeric, o2 numeric)
returns table(nv_1 numeric, nv_2 numeric, overround numeric)
language sql immutable as $$
  select round(100*(1/o1)/s,1), round(100*(1/o2)/s,1), round(100*(s-1),2)
  from (select (1/o1 + 1/o2) s) q
  where o1 is not null and o2 is not null and o1>1 and o2>1;
$$;

-- The discrepancy gate: model probs (from the canonical matrix) vs no-vig market.
-- winner_gap    = model favorite prob - no-vig favorite prob (same side as model fav)
-- total_gap     = model p_over - no-vig p_over (at the SAME provider line)
-- Thresholds (diagnostic, conservative): winner_gap <= -12pp (model far UNDER the
-- market on its own favorite) OR total_gap >= 12pp / <= -12pp => REVIEW_REQUIRED;
-- winner_gap <= -18pp OR |total_gap| >= 18pp => QUALITY_DOWNGRADE + SUPPRESS.
create or replace function v2.fn_model_market_discrepancy(
  p_p_home numeric, p_p_draw numeric, p_p_away numeric, p_p_over numeric,
  p_odds_home numeric, p_odds_draw numeric, p_odds_away numeric,
  p_odds_over numeric, p_odds_under numeric
) returns table(
  nv_home numeric, nv_draw numeric, nv_away numeric, nv_over numeric, ou_overround numeric, x12_overround numeric,
  model_fav_side text, model_fav_prob numeric, market_fav_prob numeric,
  winner_gap numeric, total_gap numeric, flag text, suppress boolean, reason text
) language plpgsql immutable as $$
declare v record; w record; fav text; favp numeric; mfavp numeric; wg numeric; tg numeric;
begin
  select * into v from v2.fn_novig_1x2(p_odds_home,p_odds_draw,p_odds_away);
  select * into w from v2.fn_novig_2way(p_odds_over,p_odds_under);
  nv_home:=v.nv_home; nv_draw:=v.nv_draw; nv_away:=v.nv_away; x12_overround:=v.overround;
  nv_over:=w.nv_1; ou_overround:=w.overround;
  -- model favorite among 1X2
  if p_p_home>=p_p_draw and p_p_home>=p_p_away then fav:='HOME'; favp:=p_p_home; mfavp:=v.nv_home;
  elsif p_p_away>=p_p_draw and p_p_away>=p_p_home then fav:='AWAY'; favp:=p_p_away; mfavp:=v.nv_away;
  else fav:='DRAW'; favp:=p_p_draw; mfavp:=v.nv_draw; end if;
  model_fav_side:=fav; model_fav_prob:=favp; market_fav_prob:=mfavp;
  wg := case when mfavp is null then null else round(favp - mfavp,1) end;   -- model minus market on model's fav
  tg := case when w.nv_1 is null or p_p_over is null then null else round(p_p_over - w.nv_1,1) end;
  winner_gap:=wg; total_gap:=tg;
  -- Market ABSENCE is NOT a discrepancy (5619542059 finding 2): it is a distinct
  -- NO_MARKET_DIAGNOSTIC state that does NOT suppress. Market absence must never
  -- fabricate a discrepancy or make an event TOP_ONLY-ineligible on its own.
  if wg is null and tg is null then
    flag:='NO_MARKET_DIAGNOSTIC'; suppress:=false; reason:='no market odds available for model-vs-market diagnostic'; return next; return;
  end if;
  -- QUALITY_DOWNGRADE: a single extreme breach (>=18pp) OR a DUAL breach (both winner
  -- and total adverse by >=12pp) -> the model is systematically off on this event.
  if (wg is not null and wg <= -18) or (tg is not null and abs(tg) >= 18)
     or (wg is not null and wg <= -12 and tg is not null and abs(tg) >= 12) then
    flag:='QUALITY_DOWNGRADE'; suppress:=true;
    reason:=concat_ws('; ',
      case when wg<=-12 then 'winner_gap '||wg||'pp (model '||favp||' vs no-vig '||mfavp||')' end,
      case when tg is not null and abs(tg)>=12 then 'total_gap '||tg||'pp (model over '||p_p_over||' vs no-vig '||w.nv_1||')' end);
    return next; return;
  end if;
  if (wg is not null and wg <= -12) or (tg is not null and abs(tg) >= 12) then
    -- A real threshold breach (>=12pp) is a discrepancy: TOP_ONLY-INELIGIBLE until
    -- reviewed/cleared (5619542059 finding 2). suppress=true, distinct from OK/NO_MARKET.
    flag:='REVIEW_REQUIRED'; suppress:=true;
    reason:=concat_ws('; ',
      case when wg<=-12 then 'winner_gap '||wg||'pp (model '||favp||' vs no-vig '||mfavp||')' end,
      case when tg is not null and abs(tg)>=12 then 'total_gap '||tg||'pp (model over '||p_p_over||' vs no-vig '||w.nv_1||')' end);
    return next; return;
  end if;
  flag:='OK'; suppress:=false; reason:='within tolerance'; return next;
end $$;
