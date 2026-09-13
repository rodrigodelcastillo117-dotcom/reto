-- RETO 13M FINAL CLOSEOUT — READ-ONLY PREFLIGHT
-- 2026-09-13
-- DO NOT use this file to mutate production. It contains SELECT/DO-read assertions only.
-- Run against the intended target immediately before any independently-authorized cutover.
-- Any exception => ABORT CUTOVER. No partial deployment.

begin transaction read only;

-- 1) Server / transaction identity
select current_database() as database_name,
       current_user as current_user_name,
       now() as preflight_at,
       current_setting('transaction_read_only') as transaction_read_only;

-- 2) Required final closeout contracts. Missing rows are blockers.
with required(schema_name, object_name, expected_kind) as (values
  ('v2','v_soccer_daily_candidates','v'),
  ('v2','v_mlb_daily_candidates','v'),
  ('v2','v_nfl_daily_candidates','v')
), found as (
  select n.nspname schema_name,c.relname object_name,c.relkind
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
)
select r.*, f.relkind as actual_kind,
       (f.object_name is not null and f.relkind=r.expected_kind::"char") as ok
from required r left join found f using(schema_name,object_name)
order by 1,2;

-- 3) Capture current definitions BEFORE cutover. Persist this query output externally
--    as the rollback snapshot; this SQL deliberately does not write it anywhere.
select n.nspname as schema_name,
       c.relname as view_name,
       pg_get_viewdef(c.oid,true) as definition
from pg_class c
join pg_namespace n on n.oid=c.relnamespace
where c.relkind in ('v','m')
  and n.nspname in ('public','v2')
  and c.relname in (
    'v_soccer_daily_candidates','v_mlb_daily_candidates','v_nfl_daily_candidates',
    'v_global_top_only_universe','v_global_top_only_ranked',
    'v_reto13m_top_only','v_pick_del_dia_canonical'
  )
order by 1,2;

-- 4) Temporal / probability sanity on upstream canonical candidate surfaces.
--    These queries are intentionally independent of sportsbook price.
select 'SOCCER' sport,
       count(*) rows_total,
       count(*) filter (where canonical_probability is null or canonical_probability < 0 or canonical_probability > 1) invalid_probability,
       count(*) filter (where decision_time is null or kickoff is null or decision_time > kickoff) temporal_violations
from v2.v_soccer_daily_candidates
union all
select 'MLB',
       count(*),
       count(*) filter (where canonical_probability is null or canonical_probability < 0 or canonical_probability > 1),
       count(*) filter (where decision_time is null or scheduled_at is null or decision_time > scheduled_at)
from v2.v_mlb_daily_candidates
union all
select 'NFL',
       count(*),
       count(*) filter (where p_reto is null or p_reto < 0 or p_reto > 1),
       count(*) filter (where decision_time is null or kickoff is null or decision_time > kickoff)
from v2.v_nfl_daily_candidates;

-- 5) If final GLOBAL objects already exist, expose their definitions for drift review.
select n.nspname as schema_name,c.relname as object_name,c.relkind,
       case when c.relkind='v' then pg_get_viewdef(c.oid,true) else null end as view_definition
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='v2'
  and c.relname in ('v_global_top_only_universe','v_global_top_only_ranked','v_reto13m_top_only','v_pick_del_dia_canonical')
order by c.relname;

-- 6) Pre-existing public exposure/security inventory. This is evidence, not a mutation.
select n.nspname schema_name,c.relname object_name,c.relkind,
       c.relrowsecurity as rls_enabled
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname in ('public','v2')
  and c.relkind in ('r','p')
  and c.relname in (
    'picks','nfl_predicciones','nfl_lesiones_semana','nfl_depth_chart',
    'nfl_fantasy_projection_snapshot'
  )
order by 1,2;

-- 7) Hard fail if upstream candidate contracts are absent or malformed.
do $$
declare
  missing_count int;
  bad_count bigint;
begin
  select count(*) into missing_count
  from (values
    ('v2'::text,'v_soccer_daily_candidates'::text),
    ('v2','v_mlb_daily_candidates'),
    ('v2','v_nfl_daily_candidates')
  ) r(schema_name,object_name)
  where to_regclass(format('%I.%I',schema_name,object_name)) is null;
  if missing_count <> 0 then
    raise exception 'PREFLIGHT_FAIL: % required canonical candidate surfaces missing', missing_count;
  end if;

  select count(*) into bad_count from v2.v_soccer_daily_candidates
   where canonical_probability is null or canonical_probability not between 0 and 1
      or decision_time is null or kickoff is null or decision_time > kickoff;
  if bad_count <> 0 then raise exception 'PREFLIGHT_FAIL: SOCCER canonical violations=%',bad_count; end if;

  select count(*) into bad_count from v2.v_mlb_daily_candidates
   where canonical_probability is null or canonical_probability not between 0 and 1
      or decision_time is null or scheduled_at is null or decision_time > scheduled_at;
  if bad_count <> 0 then raise exception 'PREFLIGHT_FAIL: MLB canonical violations=%',bad_count; end if;

  select count(*) into bad_count from v2.v_nfl_daily_candidates
   where p_reto is null or p_reto not between 0 and 1
      or decision_time is null or kickoff is null or decision_time > kickoff;
  if bad_count <> 0 then raise exception 'PREFLIGHT_FAIL: NFL canonical violations=%',bad_count; end if;
end $$;

rollback;