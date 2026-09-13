-- ISS132 GLOBAL TOP_ONLY acceptance gate. Read-only.
select
  (select count(*) from v2.v_global_top_only_universe) universe,
  (select count(*) from v2.v_global_top_only_ranked) ranked,
  (select count(*) from v2.v_reto13m_top_only) selected,
  (select count(*) from ((select * from v2.v_reto13m_top_only except all select * from v2.v_pick_del_dia_canonical) union all (select * from v2.v_pick_del_dia_canonical except all select * from v2.v_reto13m_top_only)) d) alias_diff,
  (select count(*) from (select sport,canonical_event_id,dia_mx,count(*) n from v2.v_global_top_only_ranked group by 1,2,3 having count(*)>1) x) duplicate_events,
  (select count(*) from v2.v_global_top_only_ranked where p_reto<0 or p_reto>1 or decision_time>event_time) invariant_violations;
-- Acceptance: selected in [0,1] per day; alias_diff=0; duplicate_events=0; invariant_violations=0.

select
  (pg_get_viewdef('v2.v_global_top_only_ranked'::regclass,true) ~* '(momio|odds|no.?vig|ev_pct|kelly|clv)') as forbidden_selector_input,
  (pg_get_viewdef('v2.v_global_top_only_ranked'::regclass,true) ~* '(quota|filler)') as quota_or_filler_logic;
-- Acceptance: both false.

select count(*) as p_reto_mismatches
from (
  select u.sport,u.canonical_event_id,u.canonical_market,u.canonical_side,u.canonical_line,u.p_reto,
    case
      when u.sport='SOCCER' then (select c.canonical_probability from v2.v_soccer_daily_candidates c where c.canonical_event_id::text=u.canonical_event_id and c.canonical_market=u.canonical_market and c.canonical_side=u.canonical_side and c.canonical_line is not distinct from u.canonical_line limit 1)
      when u.sport='MLB' then (select c.canonical_probability from v2.v_mlb_daily_candidates c where c.canonical_event_id::text=u.canonical_event_id and c.canonical_market=u.canonical_market and c.canonical_side=u.canonical_side and c.canonical_line is not distinct from u.canonical_line limit 1)
      else null
    end as source_p
  from v2.v_global_top_only_universe u
) q
where p_reto is distinct from source_p;
-- Acceptance on currently seeded SOCCER/MLB universe: 0 mismatches. NFL may legally contribute 0 rows while fail-closed.
