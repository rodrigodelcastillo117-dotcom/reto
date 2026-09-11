-- iss081a — clean release-gate reason formatting after iss081.
create or replace view v2.v_soccer_event_gate as
select c.espn_event_id as canonical_event_id,c.decision_time,c.model_version,
       g.coherence_ok,g.disc_flag,g.suppress,g.top_only_eligible,
       nullif(btrim(g.gate_reason,'; '),'') as gate_reason
from v2.soccer_prediction_v2_staged c
left join lateral (
  select mc.home_ml,mc.draw_ml,mc.away_ml from public.v_momios_confiables mc
  where mc.espn_event_id=c.espn_event_id and mc.confiable is true and mc.snapshot_at<=c.decision_time
  order by mc.snapshot_at desc limit 1
) oml on true
left join lateral (
  select mc.over_odds,mc.under_odds from public.v_momios_confiables mc
  where mc.espn_event_id=c.espn_event_id and mc.confiable is true and mc.snapshot_at<=c.decision_time and mc.over_line=c.over_line
  order by mc.snapshot_at desc limit 1
) oou on true
left join lateral v2.fn_event_gate_status(
  c.score_dist,c.p_home,c.p_draw,c.p_away,c.p_over,c.p_under,c.over_line,
  c.btts_yes,c.btts_no,c.top_scores,c.p_push,c.ou_line_type,c.ou_supported,
  oml.home_ml,oml.draw_ml,oml.away_ml,oou.over_odds,oou.under_odds
) g(coherence_ok,disc_flag,suppress,top_only_eligible,gate_reason) on true;
