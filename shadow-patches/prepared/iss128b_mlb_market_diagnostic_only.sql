-- ISS128b — MLB market/no-vig diagnostic-only authority repair
-- Staged / reversible. Production remains frozen.
--
-- Contract:
--   * ONE BRAIN / ONE P_RETO remains v2.mlb_prediction_snapshot.
--   * market/no-vig discrepancy is diagnostic/economic context only.
--   * canonical publication eligibility is internal coherence + exact-model validation.
--   * market discrepancy MUST NOT promote, calibrate, replace, or veto P_RETO.

create or replace view v2.v_mlb_event_gate as
select s.espn_event_id as canonical_event_id,
       s.decision_time,
       s.model_version,
       g.coherence_ok,
       g.disc_flag,
       (not coalesce(v.publish_authorized,false)) as suppress,
       (s.model_status='READY_UNVALIDATED'
        and coalesce(g.coherence_ok,false)
        and coalesce(v.publish_authorized,false)) as top_only_eligible,
       nullif(concat_ws('; ',
          case when g.disc_flag is not null and g.disc_flag <> 'OK'
               then 'MARKET_DIAGNOSTIC:'||g.disc_flag||coalesce(': '||md.reason,'') end,
          case when not coalesce(v.publish_authorized,false)
               then 'MODEL_VALIDATION_FAIL_CLOSE:'||coalesce(v.verdict,'NO_VALIDATION_SEAL') end
       ),'') as gate_reason
from v2.mlb_prediction_snapshot s
left join lateral (
  select mc.home_ml,mc.away_ml
  from public.v_momios_confiables mc
  where mc.espn_event_id=s.espn_event_id
    and mc.confiable is true
    and mc.snapshot_at<=s.decision_time
  order by mc.snapshot_at desc limit 1
) oml on true
left join lateral (
  select mc.over_odds,mc.under_odds
  from public.v_momios_confiables mc
  where mc.espn_event_id=s.espn_event_id
    and mc.confiable is true
    and mc.snapshot_at<=s.decision_time
    and mc.over_line=s.total_line
  order by mc.snapshot_at desc limit 1
) oou on true
left join lateral v2.fn_mlb_event_gate_status(
  s.run_dist,s.p_home_ml,s.p_away_ml,s.total_line,s.p_over,s.p_under,s.p_push,
  s.ou_line_type,s.ou_supported,s.top_scores,
  oml.home_ml,oml.away_ml,oou.over_odds,oou.under_odds
) g on true
left join lateral (
  select ms.suppress as market_suppress, ms.reason
  from v2.fn_mlb_market_discrepancy(
    s.p_home_ml,s.p_over,oml.home_ml,oml.away_ml,oou.over_odds,oou.under_odds
  ) ms
) md on true
left join v2.mlb_validation_seal v on v.model_version=s.model_version;

comment on view v2.v_mlb_event_gate is
'MLB canonical gate: internal distribution coherence + exact-model validation only. Sportsbook/no-vig discrepancy remains diagnostic/economic context and cannot alter P_RETO or canonical eligibility.';