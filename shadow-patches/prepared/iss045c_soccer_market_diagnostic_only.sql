-- ISS045c — SOCCER market/no-vig diagnostic-only authority repair
-- Reversible staged patch. Production cutover remains frozen.
--
-- Contract:
--   * ONE BRAIN / ONE P_RETO remains the model distribution.
--   * sportsbook/no-vig may remain visible as diagnostic/economic context.
--   * market discrepancy MUST NOT veto canonical candidate publication.
--   * canonical eligibility = model READY + internal distribution coherence.

create or replace view v2.v_soccer_event_gate as
select c.espn_event_id as canonical_event_id,
       c.decision_time,
       c.model_version,
       g.coherence_ok,
       g.disc_flag,
       coalesce(g.suppress,false) as suppress,
       (c.model_status='READY_UNVALIDATED'::text
        and coalesce(g.coherence_ok,false)) as top_only_eligible,
       g.gate_reason
from v2.soccer_prediction_v2_staged c
left join lateral (
  select mc.home_ml,mc.draw_ml,mc.away_ml
  from public.v_momios_confiables mc
  where mc.espn_event_id=c.espn_event_id
    and mc.confiable is true
    and mc.snapshot_at<=c.decision_time
  order by mc.snapshot_at desc
  limit 1
) oml on true
left join lateral (
  select mc.over_odds,mc.under_odds
  from public.v_momios_confiables mc
  where mc.espn_event_id=c.espn_event_id
    and mc.confiable is true
    and mc.snapshot_at<=c.decision_time
    and mc.over_line=c.over_line
  order by mc.snapshot_at desc
  limit 1
) oou on true
left join lateral v2.fn_event_gate_status(
  c.score_dist,
  c.p_home,c.p_draw,c.p_away,
  c.p_over,c.p_under,c.over_line,
  c.btts_yes,c.btts_no,c.top_scores,
  c.p_push,c.ou_line_type,c.ou_supported,
  oml.home_ml,oml.draw_ml,oml.away_ml,
  oou.over_odds,oou.under_odds
) g on true;

comment on view v2.v_soccer_event_gate is
'Canonical SOCCER gate: model readiness + internal matrix coherence authorize candidates. disc_flag/suppress/gate_reason retain market/no-vig diagnostics only and MUST NOT veto canonical P_RETO/candidate publication.';