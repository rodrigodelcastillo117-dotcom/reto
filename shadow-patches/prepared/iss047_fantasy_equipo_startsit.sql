-- ============================================================================
-- iss047 — NFL FANTASY "EQUIPO" START/SIT BACKEND SQL CONTRACT · STAGED
-- ============================================================================
-- Owner contract: GitHub issue #4, comment 5620342324 (owner-authorized NFL /
-- Fantasy PARALLEL PREP, comment 5619005803). Backend-only structure + legal
-- Start/Sit optimizer. This builds the STRUCTURE and the LEGAL optimizer now,
-- and FAIL-CLOSES the numeric projections (no Fantasy projection brain exists
-- yet → floor/median/ceiling stay NULL, projection_status='NO_FANTASY_BRAIN').
--
-- GATES IN FORCE (do not violate): P0=SOCCER · RELEASE_GATE=HOLD ·
--   PROD_FREEZE=ON · LOVABLE_FREEZE=ON.
-- This file is STAGED and applied ONLY to the disposable branch project
--   kmasawoljjyfmxadbvou. It does NOT go in supabase/migrations, is NOT
--   deployed, touches NO Lovable, mutates NO production. All objects live under
--   schema v2 with the fq_ prefix so they never collide with other agents'
--   v2 parlay objects on the same branch.
--
-- NO FABRICATED DATA: projections are NULL until a real Fantasy projection brain
--   exists. Deltas are NEVER invented. Coverage is quality-aware: an empty /
--   placeholder field does NOT count as covered (mirrors the NFL dossier rule).
--
-- Objects (all v2.fq_*):
--   TABLE     v2.fq_scoring_profile      scoring profiles + roster slot counts
--   TABLE     v2.fq_roster_slots         enumerated starter slots per profile
--   TABLE     v2.fq_roster_player        canonical player records
--   FUNCTION  v2.fq_fn_canonical_scoring_name(numeric, boolean) -> text
--   FUNCTION  v2.fq_fn_eligible_slots(text, boolean) -> text[]
--   FUNCTION  v2.fq_tg_roster_player_derive()  (BEFORE INS/UPD trigger)
--   FUNCTION  v2.fq_fn_roster_status(text, jsonb) -> table (ROSTER_INCOMPLETE gate)
--   FUNCTION  v2.fq_fn_start_sit(text, jsonb) -> table (legal Start/Sit optimizer)
--
-- Column mapping note: floor/median/ceiling are stored as proj_floor /
--   proj_median / proj_ceiling (avoids the floor()/ceiling() builtin names).
-- ============================================================================

create schema if not exists v2;

-- ----------------------------------------------------------------------------
-- 1) SCORING PROFILES
--    Exact display names only: STANDARD | HALF PPR | PPR | CUSTOM.
--    Invariant: STANDARD=0.0, HALF PPR=0.5, PPR=1.0. If ppr not in {0,0.5,1.0}
--    OR the league carries extra non-standard rules (has_custom_rules) => the
--    name MUST be CUSTOM. superflex / te_premium_bonus are league settings and
--    do NOT by themselves force CUSTOM (the owner's league is PPR + Superflex +
--    TE Premium and is still named 'PPR').
-- ----------------------------------------------------------------------------
create table if not exists v2.fq_scoring_profile (
  scoring_profile_id  text primary key,
  name                text not null,
  ppr_per_reception   numeric not null,
  te_premium_bonus    numeric not null default 0,
  superflex           boolean not null default false,
  has_custom_rules    boolean not null default false,   -- extra non-standard scoring rules
  -- roster slot counts (starter slot counts + bench/IR)
  qb_slots            integer not null default 1,
  rb_slots            integer not null default 2,
  wr_slots            integer not null default 2,
  te_slots            integer not null default 1,
  flex_slots          integer not null default 1,
  superflex_slots     integer not null default 0,
  k_slots             integer not null default 1,
  def_slots           integer not null default 1,
  bench_count         integer not null default 6,
  ir_count            integer not null default 2,
  created_at          timestamptz not null default now(),
  constraint fq_scoring_profile_name_ck check (name in ('STANDARD','HALF PPR','PPR','CUSTOM')),
  -- canonical-name invariant enforced structurally:
  constraint fq_scoring_profile_name_invariant_ck check (
        (name = 'STANDARD' and ppr_per_reception = 0   and not has_custom_rules)
     or (name = 'HALF PPR' and ppr_per_reception = 0.5 and not has_custom_rules)
     or (name = 'PPR'      and ppr_per_reception = 1.0 and not has_custom_rules)
     or (name = 'CUSTOM')
  ),
  constraint fq_scoring_profile_slots_nonneg_ck check (
    qb_slots>=0 and rb_slots>=0 and wr_slots>=0 and te_slots>=0 and flex_slots>=0
    and superflex_slots>=0 and k_slots>=0 and def_slots>=0 and bench_count>=0 and ir_count>=0
  ),
  -- if the profile declares superflex starter slots, superflex must be on:
  constraint fq_scoring_profile_superflex_ck check (superflex_slots = 0 or superflex = true)
);

-- Canonical scoring-name resolver. Given ppr and whether extra rules exist,
-- returns exactly one of STANDARD|HALF PPR|PPR|CUSTOM. Never returns Spanish /
-- informal labels ("Estándar", "medio", "un punto").
create or replace function v2.fq_fn_canonical_scoring_name(
  p_ppr numeric, p_has_custom_rules boolean default false
) returns text
language sql immutable as $$
  select case
    when p_has_custom_rules then 'CUSTOM'
    when p_ppr = 0    then 'STANDARD'
    when p_ppr = 0.5  then 'HALF PPR'
    when p_ppr = 1.0  then 'PPR'
    else 'CUSTOM'
  end;
$$;

-- ----------------------------------------------------------------------------
-- 2) ROSTER SLOTS / LEAGUE CONFIG
--    Enumerated starter slots per profile (QB, RB, WR, TE, FLEX, SUPERFLEX,
--    K, DEF as the league defines). bench_count / ir_count live on the profile.
-- ----------------------------------------------------------------------------
create table if not exists v2.fq_roster_slots (
  scoring_profile_id  text not null references v2.fq_scoring_profile(scoring_profile_id) on delete cascade,
  slot_code           text not null,     -- QB|RB|WR|TE|FLEX|SUPERFLEX|K|DEF
  slot_count          integer not null,
  slot_order          integer not null default 0,
  primary key (scoring_profile_id, slot_code),
  constraint fq_roster_slots_code_ck check (slot_code in ('QB','RB','WR','TE','FLEX','SUPERFLEX','K','DEF')),
  constraint fq_roster_slots_count_ck check (slot_count >= 0)
);

-- Populate/refresh the enumerated starter slots from a profile's slot counts.
create or replace function v2.fq_fn_sync_roster_slots(p_scoring_profile_id text)
returns void
language plpgsql as $$
declare p record;
begin
  select * into p from v2.fq_scoring_profile where scoring_profile_id = p_scoring_profile_id;
  if not found then
    raise exception 'fq_fn_sync_roster_slots: unknown scoring_profile_id %', p_scoring_profile_id;
  end if;
  delete from v2.fq_roster_slots where scoring_profile_id = p_scoring_profile_id;
  insert into v2.fq_roster_slots(scoring_profile_id, slot_code, slot_count, slot_order)
  select p_scoring_profile_id, x.slot_code, x.slot_count, x.slot_order
  from (values
    ('QB',        p.qb_slots,        1),
    ('RB',        p.rb_slots,        2),
    ('WR',        p.wr_slots,        3),
    ('TE',        p.te_slots,        4),
    ('FLEX',      p.flex_slots,      5),
    ('SUPERFLEX', p.superflex_slots, 6),
    ('K',         p.k_slots,         7),
    ('DEF',       p.def_slots,       8)
  ) as x(slot_code, slot_count, slot_order)
  where x.slot_count > 0;
end;
$$;

-- ----------------------------------------------------------------------------
-- 3) PLAYER RECORD
--    Canonical player_id identity (NEVER display-name identity).
--    eligible_slots derived from position + league rules by trigger.
-- ----------------------------------------------------------------------------
create table if not exists v2.fq_roster_player (
  roster_player_id    bigint generated always as identity primary key,
  scoring_profile_id  text not null references v2.fq_scoring_profile(scoring_profile_id) on delete cascade,
  player_id           text not null,                 -- canonical id (e.g. espn_player_id)
  display_name        text,
  position            text not null,                 -- QB|RB|WR|TE|K|DEF
  lineup_state        text not null,                 -- STARTER|BENCH|IR|RESERVE
  roster_slot         text,                          -- starter slot occupied (null if not STARTER)
  eligible_slots      text[] not null default '{}',  -- derived: which starter slots this player may fill
  rival               text,                          -- next opponent
  kickoff             timestamptz,
  injury_status       text,
  proj_floor          numeric,                       -- "floor"   (NULL until Fantasy brain)
  proj_median         numeric,                       -- "median"  (NULL until Fantasy brain)
  proj_ceiling        numeric,                       -- "ceiling" (NULL until Fantasy brain)
  projection_status   text not null default 'NO_FANTASY_BRAIN',
  created_at          timestamptz not null default now(),
  constraint fq_roster_player_pos_ck check (position in ('QB','RB','WR','TE','K','DEF')),
  constraint fq_roster_player_state_ck check (lineup_state in ('STARTER','BENCH','IR','RESERVE')),
  constraint fq_roster_player_uk unique (scoring_profile_id, player_id)
);

-- eligible_slots resolver: base slot = own position; FLEX = RB/WR/TE;
-- SUPERFLEX = QB/RB/WR/TE (only when league is superflex); K->K only; DEF->DEF
-- only. TE premium affects SCORING, not eligibility.
create or replace function v2.fq_fn_eligible_slots(
  p_position text, p_superflex boolean
) returns text[]
language sql immutable as $$
  select case upper(p_position)
    when 'QB'  then case when p_superflex then array['QB','SUPERFLEX'] else array['QB'] end
    when 'RB'  then case when p_superflex then array['RB','FLEX','SUPERFLEX'] else array['RB','FLEX'] end
    when 'WR'  then case when p_superflex then array['WR','FLEX','SUPERFLEX'] else array['WR','FLEX'] end
    when 'TE'  then case when p_superflex then array['TE','FLEX','SUPERFLEX'] else array['TE','FLEX'] end
    when 'K'   then array['K']
    when 'DEF' then array['DEF']
    else array[]::text[]
  end;
$$;

-- Trigger: derive eligible_slots from position + profile.superflex; fail-close
-- projection_status; enforce roster_slot legality; null roster_slot off the bench.
create or replace function v2.fq_tg_roster_player_derive()
returns trigger
language plpgsql as $$
declare v_superflex boolean;
begin
  select superflex into v_superflex from v2.fq_scoring_profile
   where scoring_profile_id = new.scoring_profile_id;
  if v_superflex is null then
    raise exception 'fq_roster_player: unknown scoring_profile_id %', new.scoring_profile_id;
  end if;

  -- always derive eligible_slots canonically from position + league rules
  new.eligible_slots := v2.fq_fn_eligible_slots(new.position, v_superflex);

  -- only STARTERs occupy a roster_slot
  if new.lineup_state <> 'STARTER' then
    new.roster_slot := null;
  end if;

  -- a STARTER's occupied slot must be one the player is eligible for (fail-closed)
  if new.lineup_state = 'STARTER' then
    if new.roster_slot is null then
      raise exception 'fq_roster_player: STARTER % (%) has no roster_slot', new.player_id, new.position;
    end if;
    if not (new.roster_slot = any(new.eligible_slots)) then
      raise exception 'fq_roster_player: illegal starter placement — % (%) not eligible for slot % (eligible: %)',
        new.player_id, new.position, new.roster_slot, new.eligible_slots;
    end if;
  end if;

  -- fail-close projections: no numbers => NO_FANTASY_BRAIN
  if new.proj_floor is null and new.proj_median is null and new.proj_ceiling is null then
    new.projection_status := 'NO_FANTASY_BRAIN';
  elsif new.projection_status is null or new.projection_status = 'NO_FANTASY_BRAIN' then
    new.projection_status := 'PROJECTED';
  end if;

  return new;
end;
$$;

drop trigger if exists fq_tg_roster_player_derive on v2.fq_roster_player;
create trigger fq_tg_roster_player_derive
  before insert or update on v2.fq_roster_player
  for each row execute function v2.fq_tg_roster_player_derive();

-- ----------------------------------------------------------------------------
-- 5) ROSTER_INCOMPLETE GATE
--    Coverage is QUALITY-AWARE: a player only counts if it has a real canonical
--    player_id and a real display_name (empty/placeholder => not covered).
--    Required minimum = required_starters + bench_count. IR is optional and does
--    NOT force incompleteness. status='COMPLETE' only when nothing is missing.
--    (Defined before fq_fn_start_sit because the optimizer consults it.)
-- ----------------------------------------------------------------------------
create or replace function v2.fq_fn_roster_status(
  p_scoring_profile_id text, p_roster jsonb default null
) returns table (
  status               text,
  required_starters    integer,
  present_starters     integer,
  required_bench       integer,
  present_bench        integer,
  missing_count        integer,
  missing_detail       text[]
)
language plpgsql stable as $$
declare
  p record;
  v_req_starters int;
  v_present_starters int;
  v_present_bench int;
  v_miss_starters int;
  v_miss_bench int;
  v_detail text[] := '{}';
begin
  select * into p from v2.fq_scoring_profile where scoring_profile_id = p_scoring_profile_id;
  if not found then
    raise exception 'fq_fn_roster_status: unknown scoring_profile_id %', p_scoring_profile_id;
  end if;
  v_req_starters := p.qb_slots + p.rb_slots + p.wr_slots + p.te_slots
                  + p.flex_slots + p.superflex_slots + p.k_slots + p.def_slots;

  with roster as (
    select r.player_id, r.display_name, r.lineup_state
    from v2.fq_roster_player r
    where r.scoring_profile_id = p_scoring_profile_id and p_roster is null
    union all
    select (x->>'player_id'), (x->>'display_name'), (x->>'lineup_state')
    from jsonb_array_elements(coalesce(p_roster,'[]'::jsonb)) x
    where p_roster is not null
  ),
  quality as (   -- quality-aware coverage: empty/placeholder does NOT count
    select lineup_state
    from roster
    where player_id is not null
      and btrim(player_id) <> ''
      and upper(btrim(coalesce(player_id,''))) not in ('TBD','PLACEHOLDER','NA','NULL','N/A')
      and display_name is not null
      and btrim(display_name) <> ''
      and upper(btrim(coalesce(display_name,''))) not in ('TBD','PLACEHOLDER','NA','NULL','N/A')
  )
  select count(*) filter (where lineup_state = 'STARTER'),
         count(*) filter (where lineup_state = 'BENCH')
    into v_present_starters, v_present_bench
    from quality;

  v_miss_starters := greatest(0, v_req_starters - v_present_starters);
  v_miss_bench    := greatest(0, p.bench_count  - v_present_bench);

  if v_miss_starters > 0 then
    v_detail := v_detail || format('STARTERS: need %s, have %s (missing %s)',
                  v_req_starters, v_present_starters, v_miss_starters);
  end if;
  if v_miss_bench > 0 then
    v_detail := v_detail || format('BENCH: need %s, have %s (missing %s)',
                  p.bench_count, v_present_bench, v_miss_bench);
  end if;

  status            := case when (v_miss_starters + v_miss_bench) = 0 then 'COMPLETE' else 'ROSTER_INCOMPLETE' end;
  required_starters := v_req_starters;
  present_starters  := v_present_starters;
  required_bench    := p.bench_count;
  present_bench     := v_present_bench;
  missing_count     := v_miss_starters + v_miss_bench;
  missing_detail    := v_detail;
  return next;
end;
$$;

-- ----------------------------------------------------------------------------
-- 4) START/SIT OPTIMIZER over the WHOLE roster
--    For EACH current starter, the best LEGAL eligible bench alternative.
--    A swap is LEGAL only if the bench player is eligible for the starter's slot
--    (respecting FLEX/Superflex/TE-premium/scoring + the real slots). Illegal
--    swaps are NEVER offered. Only BENCH players are candidates — IR/RESERVE are
--    NEVER offered as a start candidate.
--    Projections NULL (no brain) => delta_median/delta_ceiling NULL and
--    recommendation='PROJECTION_UNAVAILABLE_NO_FANTASY_BRAIN', but the best LEGAL
--    candidate bench player is STILL emitted per starter. No invented edge.
--    Roster must be COMPLETE; otherwise recommendations are WITHHELD (0 rows) —
--    the caller uses fq_fn_roster_status for the missing list.
-- ----------------------------------------------------------------------------
create or replace function v2.fq_fn_start_sit(
  p_scoring_profile_id text, p_roster jsonb default null
) returns table (
  starter_player_id         text,
  starter_slot              text,
  best_bench_alternative_id text,
  delta_median              numeric,
  delta_ceiling             numeric,
  recommendation            text
)
language plpgsql stable as $$
declare v_status text;
begin
  -- ROSTER_INCOMPLETE gate: withhold recommendations on a half roster
  select s.status into v_status
    from v2.fq_fn_roster_status(p_scoring_profile_id, p_roster) s;
  if v_status <> 'COMPLETE' then
    return;  -- 0 rows: recommendations withheld
  end if;

  return query
  with roster as (
    select r.player_id, r.display_name, r.position, r.lineup_state, r.roster_slot,
           r.eligible_slots, r.proj_floor, r.proj_median, r.proj_ceiling
    from v2.fq_roster_player r
    where r.scoring_profile_id = p_scoring_profile_id and p_roster is null
    union all
    select (x->>'player_id'), (x->>'display_name'), (x->>'position'),
           (x->>'lineup_state'), (x->>'roster_slot'),
           coalesce((select array_agg(e) from jsonb_array_elements_text(x->'eligible_slots') e), '{}'),
           (x->>'proj_floor')::numeric, (x->>'proj_median')::numeric, (x->>'proj_ceiling')::numeric
    from jsonb_array_elements(coalesce(p_roster,'[]'::jsonb)) x
    where p_roster is not null
  ),
  starters as (
    select * from roster where lineup_state = 'STARTER' and roster_slot is not null
  ),
  bench as (   -- ONLY the bench is a start candidate (IR/RESERVE excluded here)
    select * from roster where lineup_state = 'BENCH'
  ),
  -- rank each legal bench alternative per starter: best = higher median, then
  -- higher ceiling, then exact-position match, then canonical id (deterministic).
  ranked as (
    select st.player_id  as starter_player_id,
           st.roster_slot as starter_slot,
           st.proj_median  as st_median,
           st.proj_ceiling as st_ceiling,
           bn.player_id   as bench_player_id,
           bn.proj_median  as bn_median,
           bn.proj_ceiling as bn_ceiling,
           row_number() over (
             partition by st.player_id, st.roster_slot
             order by bn.proj_median desc nulls last,
                      bn.proj_ceiling desc nulls last,
                      (bn.position = st.position) desc,
                      bn.player_id asc
           ) as rnk
    from starters st
    join bench bn
      on st.roster_slot = any(bn.eligible_slots)   -- LEGALITY: bench eligible for starter's slot
  ),
  best as (
    select * from ranked where rnk = 1
  )
  select
    st.player_id as starter_player_id,
    st.roster_slot as starter_slot,
    b.bench_player_id as best_bench_alternative_id,
    case when st.proj_median is not null and b.bn_median is not null
         then b.bn_median - st.proj_median else null end as delta_median,
    case when st.proj_ceiling is not null and b.bn_ceiling is not null
         then b.bn_ceiling - st.proj_ceiling else null end as delta_ceiling,
    case
      when b.bench_player_id is null then 'NO_LEGAL_BENCH_ALTERNATIVE'
      when st.proj_median is null or b.bn_median is null
        then 'PROJECTION_UNAVAILABLE_NO_FANTASY_BRAIN'
      else format('SIT %s / START %s (Δ mediana %s / Δ techo %s)',
             st.player_id, b.bench_player_id,
             to_char(b.bn_median - st.proj_median, 'SG990D0'),
             to_char(coalesce(b.bn_ceiling - st.proj_ceiling, 0), 'SG990D0'))
    end as recommendation
  from starters st
  left join best b
    on b.starter_player_id = st.player_id and b.starter_slot = st.roster_slot
  order by st.roster_slot, st.player_id;
end;
$$;

-- ============================================================================
-- ROLLBACK (branch cleanup):
--   drop function if exists v2.fq_fn_start_sit(text, jsonb);
--   drop function if exists v2.fq_fn_roster_status(text, jsonb);
--   drop function if exists v2.fq_fn_sync_roster_slots(text);
--   drop trigger  if exists fq_tg_roster_player_derive on v2.fq_roster_player;
--   drop function if exists v2.fq_tg_roster_player_derive();
--   drop function if exists v2.fq_fn_eligible_slots(text, boolean);
--   drop function if exists v2.fq_fn_canonical_scoring_name(numeric, boolean);
--   drop table if exists v2.fq_roster_player;
--   drop table if exists v2.fq_roster_slots;
--   drop table if exists v2.fq_scoring_profile;
-- ============================================================================
