-- ISS131a acceptance gate. Read-only. Expected on seeded owner roster.
with x as (
  select * from v2.fn_fantasy_optimal_lineup_v2('rodelcast',2026,1,'2026-09-13 10:00:00+00')
), y as (
  select * from v2.fn_fantasy_optimal_lineup_v2('rodelcast',2026,1,'2026-09-13 10:00:00+00')
)
select
  count(*) as rows,
  count(*) filter (where locked and current_player is distinct from recommended_player) as locked_changed,
  count(*) filter (where slot_code in ('K','DST') and (not locked or action <> 'KEEP_UNMODELED')) as k_dst_violations,
  count(*) filter (where recommended_player is null) as null_recommendations,
  (select count(*) from ((select * from x except all select * from y) union all (select * from y except all select * from x)) d) as replay_diff
from x;

-- Acceptance: rows=9, locked_changed=0, k_dst_violations=0, null_recommendations=0, replay_diff=0.

select season,week,decision_time,count(*) n,
  count(*) filter (where model_status='READY') ready,
  count(*) filter (where feature_data_asof > decision_time) temporal_violations,
  count(*) filter (where model_status='READY' and (cold_start or position not in ('QB','RB','WR','TE'))) scope_violations,
  count(distinct model_version) model_versions
from v2.fantasy_projection_snapshot_v2
group by season,week,decision_time order by decision_time;
-- Acceptance: temporal_violations=0, scope_violations=0, one model_version per decision snapshot.
