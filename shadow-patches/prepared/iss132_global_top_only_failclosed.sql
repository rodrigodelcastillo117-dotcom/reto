-- ============================================================================
-- ISS132 — GLOBAL TOP_ONLY · CROSS-SPORT FILTER/RANKER · FAIL CLOSED
-- Staged/disposable only. NO production cutover.
-- ============================================================================
-- Contract:
--   * Consumes ONLY already-canonical sport candidate surfaces.
--   * NEVER creates, calibrates, blends or replaces P_RETO.
--   * Market / no-vig / EV / CLV are absent from the selector and cannot rank/authorize.
--   * No sport quota. No filler. 0 rows is valid.
--   * One candidate per event, then one global ranking across sports/day.
--   * Conservative model-only floor while RETO_SCORE weights are not empirically proven:
--       P_RETO >= 0.55 AND P_RETO - arithmetic random-base >= 0.10.
--     Binary markets therefore require >=0.60; soccer 1X2 requires >=0.55.
--   * RETO_SCORE_V1 is explicitly UNVALIDATED and equals model-only probability
--     advantage after ALL hard upstream gates; it is ranking metadata, never P_RETO.
-- ============================================================================

create schema if not exists v2;

create or replace view v2.v_global_top_only_universe
with (security_invoker = true) as
select
  'SOCCER'::text as sport,
  'v2.v_soccer_daily_candidates'::text as canonical_source,
  c.canonical_event_id::text as canonical_event_id,
  c.kickoff::timestamptz as event_time,
  c.decision_time::timestamptz as decision_time,
  c.model_version::text as model_version,
  c.model_snapshot_id::text as model_snapshot_id,
  c.canonical_market::text as canonical_market,
  c.canonical_side::text as canonical_side,
  c.canonical_line::numeric as canonical_line,
  c.canonical_probability::numeric as p_reto,
  c.canonical_push::numeric as canonical_push,
  c.canonical_line_type::text as canonical_line_type,
  case when c.canonical_market='1X2' then 3 else 2 end::int as outcome_count
from v2.v_soccer_daily_candidates c

union all

select
  'MLB'::text,
  'v2.v_mlb_daily_candidates'::text,
  c.canonical_event_id::text,
  c.scheduled_at::timestamptz,
  c.decision_time::timestamptz,
  c.model_version::text,
  c.model_snapshot_id::text,
  c.canonical_market::text,
  c.canonical_side::text,
  c.canonical_line::numeric,
  c.canonical_probability::numeric,
  c.canonical_push::numeric,
  c.canonical_line_type::text,
  2::int
from v2.v_mlb_daily_candidates c

union all

select
  'NFL'::text,
  'v2.v_nfl_daily_candidates'::text,
  c.espn_event_id::text,
  c.kickoff::timestamptz,
  c.decision_time::timestamptz,
  c.model_version::text,
  ('NFL:'||c.model_version||':'||c.decision_time::text)::text,
  c.market::text,
  c.side::text,
  c.line::numeric,
  c.p_reto::numeric,
  c.push::numeric,
  null::text,
  2::int
from v2.v_nfl_daily_candidates c;

create or replace view v2.v_global_top_only_ranked
with (security_invoker = true) as
with clean as (
  select u.*,
         (u.event_time at time zone 'America/Mexico_City')::date as dia_mx,
         (1.0 / u.outcome_count::numeric) as random_base,
         (u.p_reto - (1.0 / u.outcome_count::numeric)) as model_advantage_over_random,
         case
           when u.p_reto is null then 'NULL_P_RETO'
           when u.p_reto < 0 or u.p_reto > 1 then 'INVALID_P_RETO'
           when u.decision_time is null or u.event_time is null then 'MISSING_TEMPORAL_IDENTITY'
           when u.decision_time > u.event_time then 'TEMPORAL_VIOLATION'
           when u.model_version is null or u.model_snapshot_id is null then 'MISSING_MODEL_IDENTITY'
           when u.p_reto < 0.55 then 'GLOBAL_PROBABILITY_FLOOR'
           when u.p_reto - (1.0 / u.outcome_count::numeric) < 0.10 then 'GLOBAL_RANDOM_ADVANTAGE_FLOOR'
           else 'ELIGIBLE'
         end as global_gate_reason
  from v2.v_global_top_only_universe u
), eligible as (
  select c.*,
         round((100.0 * c.model_advantage_over_random)::numeric,6) as reto_score_v1,
         'UNVALIDATED_V1_MODEL_ONLY_AFTER_HARD_GATES'::text as score_status
  from clean c
  where c.global_gate_reason='ELIGIBLE'
), one_per_event as (
  select e.*,
         row_number() over (
           partition by e.sport,e.canonical_event_id,e.dia_mx
           order by e.model_advantage_over_random desc,
                    e.p_reto desc,
                    e.decision_time desc,
                    e.canonical_market,e.canonical_side,
                    e.canonical_line nulls last
         ) as rn_event
  from eligible e
), ranked as (
  select e.*,
         row_number() over (
           partition by e.dia_mx
           order by e.model_advantage_over_random desc,
                    e.p_reto desc,
                    e.event_time,
                    e.sport,e.canonical_event_id,
                    e.canonical_market,e.canonical_side,
                    e.canonical_line nulls last
         ) as global_rank
  from one_per_event e
  where e.rn_event=1
)
select r.*,
       (r.global_rank=1) as top_only_selected
from ranked r;

-- Canonical RETO13M surface. Strictest conservative interpretation while score
-- weighting is UNVALIDATED: exactly the global top-1, or zero when no row passes.
create or replace view v2.v_reto13m_top_only
with (security_invoker = true) as
select *
from v2.v_global_top_only_ranked
where top_only_selected;

-- Pick del Día is an exact alias of RETO13M top-1; no second ranking brain.
create or replace view v2.v_pick_del_dia_canonical
with (security_invoker = true) as
select * from v2.v_reto13m_top_only;

-- Audit: P_RETO appears once, copied verbatim from approved canonical candidate sources.
-- The selector contains no sportsbook/no-vig/EV/CLV columns and therefore cannot use
-- them as probability, gate or ranking input.
comment on view v2.v_reto13m_top_only is
  'GLOBAL TOP_ONLY v1: no quotas/filler; P_RETO copied verbatim from canonical sport candidates; market/no-vig/EV excluded; score UNVALIDATED_V1.';