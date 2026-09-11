-- iss081 — SOCCER release gate contract.
-- Owner lock: sportsbook disagreement is diagnostic context only. It MUST NOT
-- suppress, authorize, rank, score or select a RETO prediction.
-- Totals release contract: only WHOLE/HALF provider lines have canonical scalar
-- settlement probabilities. QUARTER/other lines fail closed for TOP_ONLY.

create or replace function v2.fn_event_gate_status(
  p_dist jsonb, p_home numeric, p_draw numeric, p_away numeric,
  p_over numeric, p_under numeric, p_over_line numeric,
  p_btts_yes numeric, p_btts_no numeric, p_top_scores jsonb,
  p_push numeric, p_ou_line_type text, p_ou_supported boolean,
  p_odds_home numeric, p_odds_draw numeric, p_odds_away numeric,
  p_odds_over numeric, p_odds_under numeric, p_tol numeric default 0.2)
returns table(coherence_ok boolean, disc_flag text, suppress boolean, top_only_eligible boolean, gate_reason text)
language plpgsql immutable as $$
declare
  d record; coh boolean := true; reasons text := ''; e jsonb; s text; pv numeric;
  dist_sum numeric := 0; dist_n int := 0; dist_unique int := 0; dist_struct_ok boolean := true;
  gi int; gj int; true_top jsonb; top_keys jsonb; top_n int := 0;
  expected_line_type text; expected_supported boolean; frac numeric; scalar_sum numeric;
begin
  if p_dist is null or jsonb_typeof(p_dist) <> 'array' or jsonb_array_length(p_dist)=0 then
    coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_MISSING_OR_EMPTY');
  else
    for e in select value from jsonb_array_elements(p_dist) loop
      dist_n := dist_n + 1;
      if jsonb_typeof(e) <> 'object' then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_CELL_NOT_OBJECT'); continue; end if;
      s := e->>'s';
      if s is null or s !~ '^[0-9]+-[0-9]+$' then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_BAD_SCORE_KEY'); continue; end if;
      begin gi := split_part(s,'-',1)::int; gj := split_part(s,'-',2)::int;
      exception when others then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_BAD_SCORE_KEY'); continue; end;
      if gi < 0 or gj < 0 or gi > 12 or gj > 12 then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_SCORE_OUT_OF_RANGE'); end if;
      begin pv := (e->>'p')::numeric;
      exception when others then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_BAD_PROB'); continue; end;
      if pv is null or pv::text='NaN' or pv<0 or pv>100 then coh := false; dist_struct_ok := false; reasons := concat_ws('; ', reasons, 'MATRIX_PROB_OUT_OF_RANGE'); else dist_sum := dist_sum + pv; end if;
    end loop;
    if dist_struct_ok then
      select count(distinct x->>'s') into dist_unique from jsonb_array_elements(p_dist) x;
      if dist_unique <> dist_n then coh := false; reasons := concat_ws('; ', reasons, 'MATRIX_DUPLICATE_SCORE'); end if;
      if abs(dist_sum-100)>p_tol then coh := false; reasons := concat_ws('; ', reasons, 'MATRIX_SUM_NOT_100'); end if;
    end if;
  end if;

  if p_home is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_home'); elsif p_home::text='NaN' or p_home<0 or p_home>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_home'); end if;
  if p_draw is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_draw'); elsif p_draw::text='NaN' or p_draw<0 or p_draw>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_draw'); end if;
  if p_away is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_away'); elsif p_away::text='NaN' or p_away<0 or p_away>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_away'); end if;
  if p_btts_yes is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:btts_yes'); elsif p_btts_yes::text='NaN' or p_btts_yes<0 or p_btts_yes>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:btts_yes'); end if;
  if p_btts_no is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:btts_no'); elsif p_btts_no::text='NaN' or p_btts_no<0 or p_btts_no>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:btts_no'); end if;
  if p_home is not null and p_draw is not null and p_away is not null and abs((p_home+p_draw+p_away)-100)>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'SUM_1X2_NOT_100'); end if;
  if p_btts_yes is not null and p_btts_no is not null and abs((p_btts_yes+p_btts_no)-100)>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'SUM_BTTS_NOT_100'); end if;

  if p_top_scores is null or jsonb_typeof(p_top_scores)<>'array' then
    coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:top_scores');
  else
    top_n:=jsonb_array_length(p_top_scores);
    if top_n<>5 then coh:=false; reasons:=concat_ws('; ',reasons,'TOPK_LEN_NOT_5'); end if;
    if exists(select 1 from jsonb_array_elements(p_top_scores) t where t->>'s' is null or t->>'s' !~ '^[0-9]+-[0-9]+$') then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_BAD_KEY'); end if;
    if (select count(distinct t->>'s') from jsonb_array_elements(p_top_scores) t)<>top_n then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_DUPLICATE'); end if;
    if dist_struct_ok and top_n>0 then
      select jsonb_agg(z.s) into true_top from (
        select c->>'s' s from jsonb_array_elements(p_dist) c
        order by (c->>'p')::numeric desc,(split_part(c->>'s','-',1)::int+split_part(c->>'s','-',2)::int) asc,split_part(c->>'s','-',1)::int asc limit 5) z;
      select jsonb_agg(t->>'s') into top_keys from jsonb_array_elements(p_top_scores) t;
      if top_keys is distinct from true_top then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_ORDER'); end if;
      begin
        if exists(select 1 from jsonb_array_elements(p_top_scores) t where (t->>'p') is null or (t->>'p')::numeric::text='NaN' or (t->>'p')::numeric<0 or abs((t->>'p')::numeric-v2.fn_matrix_market(p_dist,'EXACT',t->>'s'))>p_tol) then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_PROB'); end if;
      exception when others then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_BAD_PROB'); end;
    end if;
  end if;

  if dist_struct_ok then
    if p_home is not null and abs(p_home-v2.fn_matrix_market(p_dist,'1X2','HOME'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_HOME'); end if;
    if p_draw is not null and abs(p_draw-v2.fn_matrix_market(p_dist,'1X2','DRAW'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_DRAW'); end if;
    if p_away is not null and abs(p_away-v2.fn_matrix_market(p_dist,'1X2','AWAY'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'1X2_AWAY'); end if;
    if p_btts_yes is not null and abs(p_btts_yes-v2.fn_matrix_market(p_dist,'BTTS','YES'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'BTTS_YES'); end if;
    if p_btts_no is not null and abs(p_btts_no-v2.fn_matrix_market(p_dist,'BTTS','NO'))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'BTTS_NO'); end if;
  end if;

  if p_over_line is null then
    coh:=false; reasons:=concat_ws('; ',reasons,'OU_PROVIDER_LINE_MISSING');
  else
    frac:=p_over_line-floor(p_over_line);
    expected_line_type:=case when frac=0 then 'WHOLE' when frac=0.5 then 'HALF' when frac in (0.25,0.75) then 'QUARTER' else 'UNSUPPORTED' end;
    expected_supported:=expected_line_type in ('WHOLE','HALF');
    if p_ou_line_type is distinct from expected_line_type then coh:=false; reasons:=concat_ws('; ',reasons,'OU_LINE_TYPE_MISMATCH'); end if;
    if p_ou_supported is distinct from expected_supported then coh:=false; reasons:=concat_ws('; ',reasons,'OU_SUPPORTED_MISMATCH'); end if;
    if expected_supported then
      if p_over is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_over'); elsif p_over::text='NaN' or p_over<0 or p_over>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_over'); end if;
      if p_under is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_under'); elsif p_under::text='NaN' or p_under<0 or p_under>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_under'); end if;
      if p_push is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_push'); elsif p_push::text='NaN' or p_push<0 or p_push>100 then coh:=false; reasons:=concat_ws('; ',reasons,'RANGE_FIELD:p_push'); end if;
      if p_over is not null and p_push is not null and p_under is not null then scalar_sum:=p_over+p_push+p_under; if abs(scalar_sum-100)>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_SUM_NOT_100'); end if; end if;
      if dist_struct_ok then
        if p_over is not null and abs(p_over-v2.fn_matrix_market(p_dist,'OU','OVER',p_over_line))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_OVER'); end if;
        if p_push is not null and abs(p_push-v2.fn_matrix_market(p_dist,'OU','PUSH',p_over_line))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_PUSH'); end if;
        if p_under is not null and abs(p_under-v2.fn_matrix_market(p_dist,'OU','UNDER',p_over_line))>p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNDER'); end if;
      end if;
    else
      if p_over is not null or p_push is not null or p_under is not null then coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNSUPPORTED_MUST_BE_NULL'); end if;
    end if;
  end if;

  coherence_ok:=coh;
  if not coh then reasons:=concat_ws('; ','COHERENCE_FAIL',reasons); end if;

  -- Market-derived comparison is retained only as a diagnostic flag.
  select * into d from v2.fn_model_market_discrepancy(p_home,p_draw,p_away,p_over,p_odds_home,p_odds_draw,p_odds_away,p_odds_over,p_odds_under);
  disc_flag:=coalesce(d.flag,'NO_MARKET_DIAGNOSTIC');
  suppress:=false;

  -- The full canonical soccer matrix is required; unsupported/missing O/U fails closed.
  top_only_eligible:=coherence_ok and coalesce(p_ou_supported,false);
  if coherence_ok and not coalesce(p_ou_supported,false) then reasons:=concat_ws('; ',reasons,'OU_LINE_UNSUPPORTED_FOR_RELEASE:'||coalesce(p_ou_line_type,'UNKNOWN')); end if;
  gate_reason:=nullif(reasons,'');
  return next;
end $$;

create or replace view v2.v_soccer_event_gate as
select c.espn_event_id canonical_event_id,c.decision_time,c.model_version,
       g.coherence_ok,g.disc_flag,g.suppress,g.top_only_eligible,g.gate_reason
from v2.soccer_prediction_v2_staged c
left join lateral (
  select mc.home_ml,mc.draw_ml,mc.away_ml from public.v_momios_confiables mc
  where mc.espn_event_id=c.espn_event_id and mc.confiable is true and mc.snapshot_at<=c.decision_time
  order by mc.snapshot_at desc limit 1) oml on true
left join lateral (
  select mc.over_odds,mc.under_odds from public.v_momios_confiables mc
  where mc.espn_event_id=c.espn_event_id and mc.confiable is true and mc.snapshot_at<=c.decision_time and mc.over_line=c.over_line
  order by mc.snapshot_at desc limit 1) oou on true
left join lateral v2.fn_event_gate_status(
  c.score_dist,c.p_home,c.p_draw,c.p_away,c.p_over,c.p_under,c.over_line,
  c.btts_yes,c.btts_no,c.top_scores,c.p_push,c.ou_line_type,c.ou_supported,
  oml.home_ml,oml.draw_ml,oml.away_ml,oou.over_odds,oou.under_odds
) g(coherence_ok,disc_flag,suppress,top_only_eligible,gate_reason) on true;
