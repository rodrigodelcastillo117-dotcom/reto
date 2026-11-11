-- ============================================================================
-- iss047 — NFL FANTASY "EQUIPO" START/SIT BACKEND SQL CONTRACT · STAGED · v2
-- ============================================================================
-- Owner contract: GitHub issue #4 — comment 5620342324 (scoring names),
--   comment 5620314120 (full roster / bench), and the v2 STOP-SHIP audit
--   comment 5620923816 (7 Fantasy findings F1..F7 against v1 @ 16eae5d).
--   Owner-authorized NFL/Fantasy PARALLEL PREP (comment 5619005803),
--   BACKEND ONLY. This builds the STRUCTURE + the GLOBAL LEGAL optimizer now,
--   and FAIL-CLOSES the numeric projections (no Fantasy projection brain exists
--   yet → floor/median/ceiling stay NULL, projection_status='NO_FANTASY_BRAIN').
--
-- GATES IN FORCE (do not violate): P0=SOCCER · RELEASE_GATE=HOLD ·
--   PROD_FREEZE=ON · LOVABLE_FREEZE=ON.
-- This file is STAGED and applied ONLY to the disposable branch project
--   kmasawoljjyfmxadbvou. It does NOT go in supabase/migrations, is NOT
--   deployed, touches NO Lovable, mutates NO production. All objects live under
--   schema v2 with the fq_ prefix so they never collide with the concurrent
--   parlay/soccer agents' v2 objects on the same branch.
--
-- NO FABRICATED DATA: projections are NULL until a real Fantasy projection brain
--   exists. Deltas are NEVER invented. Coverage is quality-aware.
--
-- ---- v2 CHANGES (resolve the 7 STOP-SHIP findings) -------------------------
-- F1  Exact owner Yahoo config: PPR 1.0, starters QB/WR/WR/RB/RB/TE/FLEX/K/DEF,
--     BN×6, IR×2. NO Superflex slot, NO TE-premium (v1 wrongly claimed both).
--     eligible_slots derived: QB->{QB}; RB->{RB,FLEX}; WR->{WR,FLEX};
--     TE->{TE,FLEX}; K->{K}; DEF->{DEF}.
-- F2  First-class snapshot keys on both contracts: rosters keyed by league_id,
--     fantasy_team_id, season, week, roster_snapshot_id, as_of,
--     scoring_profile_version; projections keyed by projection_snapshot_id,
--     feature_snapshot_id, model_version, as_of, provenance. Snapshots immutable.
-- F3  fq_fn_roster_status validates LEGAL SLOT OCCUPANCY (exact per-slot counts,
--     eligibility of each starter, unique player_ids, no over-filled slots,
--     bench/IR counts, cardinality) — 9 QB starters => ROSTER_INVALID, not
--     COMPLETE.
-- F4  Server-DERIVED eligibility on EVERY input path; client-supplied
--     eligible_slots and client-supplied projection_status are IGNORED.
-- F5  fq_fn_optimize_lineup: whole-roster global legal optimizer (bipartite
--     max-cardinality matching, Kuhn augmenting paths) — each player used at
--     most once, respects FLEX, supports chained reassignments, honors locks
--     (started games can't move / late-swap). Current vs optimal + moves.
-- F6  fq_fn_projection_status: floor/median/ceiling flip to PROJECTED only on a
--     COMPLETE immutable tuple; a PARTIAL tuple fails closed (NO_FANTASY_BRAIN).
-- F7  Scoring name is a pure function of reception points (0/0.5/1.0 =>
--     STANDARD/HALF PPR/PPR); modifiers (DST, kicker, TE bonus, ...) live as
--     SEPARATE rule metadata and NEVER rename an otherwise-PPR league to CUSTOM.
--
-- Column mapping note: floor/median/ceiling are stored as proj_floor /
--   proj_median / proj_ceiling (avoids the floor()/ceiling() builtin names).
-- ============================================================================

create schema if not exists v2;

-- ---- clean recreate (branch-only, fq_* is fantasy-only; no cross-agent risk)
drop function if exists v2.fq_fn_optimize_lineup(text, jsonb);
drop function if exists v2.fq_fn__lineup_aug(int, boolean[], int, int, boolean[], int[], boolean[]);
drop function if exists v2.fq_fn_start_sit(text, jsonb);
drop function if exists v2.fq_fn_roster_status(text, jsonb);
drop function if exists v2.fq_fn_sync_roster_slots(text);
drop trigger  if exists fq_tg_roster_player_immutable on v2.fq_roster_player;
drop function if exists v2.fq_tg_roster_player_immutable();
drop trigger  if exists fq_tg_roster_player_derive on v2.fq_roster_player;
drop function if exists v2.fq_tg_roster_player_derive();
drop function if exists v2.fq_fn_projection_status(numeric,numeric,numeric,text,text,text,timestamptz,text);
drop function if exists v2.fq_fn_eligible_slots(text, boolean);
drop function if exists v2.fq_fn_canonical_scoring_name(numeric, boolean);
drop function if exists v2.fq_fn_canonical_scoring_name(numeric);
drop table if exists v2.fq_scoring_modifier;
drop table if exists v2.fq_roster_player;
drop table if exists v2.fq_roster_slots;
drop table if exists v2.fq_scoring_profile;

-- ----------------------------------------------------------------------------
-- 1) SCORING PROFILES  (F2 keys, F7 naming)
--    Primary label is a PURE function of reception points:
--       0.0 => STANDARD | 0.5 => HALF PPR | 1.0 => PPR
--    Any OTHER reception value => CUSTOM (internal/advanced). Extra scoring
--    modifiers (DST, kicker, TE bonus, superflex-as-a-setting) are metadata and
--    do NOT rename the league. The owner's league is PPR (1.0) with modifiers
--    and stays labelled PPR.
-- ----------------------------------------------------------------------------
create table v2.fq_scoring_profile (
  scoring_profile_id       text primary key,
  -- F2 first-class scope/version keys (snapshot-safe, multi-league):
  league_id                text not null default 'default_league',
  season                   integer not null default 2025,
  scoring_profile_version  integer not null default 1,
  as_of                    timestamptz not null default now(),
  name                     text not null,
  ppr_per_reception        numeric not null,          -- reception points; the ONLY driver of `name`
  -- league settings (metadata; do NOT drive the primary label):
  te_premium_bonus         numeric not null default 0,
  superflex                boolean not null default false,
  -- roster slot counts (starter slot counts + bench/IR):
  qb_slots                 integer not null default 1,
  rb_slots                 integer not null default 2,
  wr_slots                 integer not null default 2,
  te_slots                 integer not null default 1,
  flex_slots               integer not null default 1,
  superflex_slots          integer not null default 0,
  k_slots                  integer not null default 1,
  def_slots                integer not null default 1,
  bench_count              integer not null default 6,
  ir_count                 integer not null default 2,
  created_at               timestamptz not null default now(),
  constraint fq_scoring_profile_name_ck check (name in ('STANDARD','HALF PPR','PPR','CUSTOM')),
  -- F7: name is bound to reception points ONLY. CUSTOM is reserved for a truly
  --     nonstandard reception value; it is NEVER forced by modifiers.
  constraint fq_scoring_profile_name_invariant_ck check (
        (name = 'STANDARD' and ppr_per_reception = 0)
     or (name = 'HALF PPR' and ppr_per_reception = 0.5)
     or (name = 'PPR'      and ppr_per_reception = 1.0)
     or (name = 'CUSTOM'   and ppr_per_reception not in (0, 0.5, 1.0))
  ),
  constraint fq_scoring_profile_slots_nonneg_ck check (
    qb_slots>=0 and rb_slots>=0 and wr_slots>=0 and te_slots>=0 and flex_slots>=0
    and superflex_slots>=0 and k_slots>=0 and def_slots>=0 and bench_count>=0 and ir_count>=0
  ),
  constraint fq_scoring_profile_superflex_ck check (superflex_slots = 0 or superflex = true),
  constraint fq_scoring_profile_scope_uk unique (league_id, season, scoring_profile_version, scoring_profile_id)
);

-- F7: separate rule metadata. DST scoring, kicker distance rules, TE bonuses,
--     etc. live HERE and never change the league's primary label.
create table v2.fq_scoring_modifier (
  scoring_profile_id  text not null references v2.fq_scoring_profile(scoring_profile_id) on delete cascade,
  modifier_code       text not null,   -- e.g. DST_SACK, K_50PLUS, TE_BONUS, PASS_TD_6PT
  modifier_value      numeric,
  description         text,
  primary key (scoring_profile_id, modifier_code)
);

-- F7: canonical scoring-name resolver. PURELY reception-point driven. No custom
--     flag, no modifier can rename an otherwise-standard league.
create or replace function v2.fq_fn_canonical_scoring_name(p_reception_points numeric)
returns text language sql immutable as $$
  select case
    when p_reception_points = 0    then 'STANDARD'
    when p_reception_points = 0.5  then 'HALF PPR'
    when p_reception_points = 1.0  then 'PPR'
    else 'CUSTOM'
  end;
$$;

-- ----------------------------------------------------------------------------
-- 2) ROSTER SLOTS / LEAGUE CONFIG (enumerated starter slots per profile)
-- ----------------------------------------------------------------------------
create table v2.fq_roster_slots (
  scoring_profile_id  text not null references v2.fq_scoring_profile(scoring_profile_id) on delete cascade,
  slot_code           text not null,     -- QB|RB|WR|TE|FLEX|SUPERFLEX|K|DEF
  slot_count          integer not null,
  slot_order          integer not null default 0,
  primary key (scoring_profile_id, slot_code),
  constraint fq_roster_slots_code_ck check (slot_code in ('QB','RB','WR','TE','FLEX','SUPERFLEX','K','DEF')),
  constraint fq_roster_slots_count_ck check (slot_count >= 0)
);

create or replace function v2.fq_fn_sync_roster_slots(p_scoring_profile_id text)
returns void language plpgsql as $$
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
-- F1: eligible_slots resolver. base slot = own position; FLEX = RB/WR/TE;
--     SUPERFLEX = QB/RB/WR/TE (only when the league actually runs superflex);
--     K->{K}; DEF->{DEF}. TE-premium is SCORING, never eligibility.
--     For the owner's league (superflex=false): QB->{QB}, RB->{RB,FLEX},
--     WR->{WR,FLEX}, TE->{TE,FLEX}, K->{K}, DEF->{DEF}.
-- ----------------------------------------------------------------------------
create or replace function v2.fq_fn_eligible_slots(p_position text, p_superflex boolean)
returns text[] language sql immutable as $$
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

-- ----------------------------------------------------------------------------
-- F6: immutable projection contract. floor/median/ceiling become PROJECTED only
--     when the WHOLE tuple is present: proj_floor + proj_median + proj_ceiling +
--     projection_snapshot_id + feature_snapshot_id + model_version + as_of +
--     provenance. Any missing element => fail closed (NO_FANTASY_BRAIN).
-- ----------------------------------------------------------------------------
create or replace function v2.fq_fn_projection_status(
  p_floor numeric, p_median numeric, p_ceiling numeric,
  p_projection_snapshot_id text, p_feature_snapshot_id text,
  p_model_version text, p_as_of timestamptz, p_provenance text
) returns text language sql immutable as $$
  select case
    when p_floor is not null and p_median is not null and p_ceiling is not null
     and p_projection_snapshot_id is not null and btrim(p_projection_snapshot_id) <> ''
     and p_feature_snapshot_id    is not null and btrim(p_feature_snapshot_id)    <> ''
     and p_model_version          is not null and btrim(p_model_version)          <> ''
     and p_as_of                  is not null
     and p_provenance             is not null and btrim(p_provenance)             <> ''
    then 'PROJECTED'
    else 'NO_FANTASY_BRAIN'
  end;
$$;

-- ----------------------------------------------------------------------------
-- 3) ROSTER / WEEKLY SNAPSHOT ROW (F2 keys, F4 derivation, F6 fail-close)
-- ----------------------------------------------------------------------------
create table v2.fq_roster_player (
  roster_player_id    bigint generated always as identity primary key,
  scoring_profile_id  text not null references v2.fq_scoring_profile(scoring_profile_id) on delete cascade,
  -- F2 first-class snapshot keys (immutable weekly roster, multi-league/team):
  league_id                text not null default 'default_league',
  fantasy_team_id          text not null default 'owner_team',
  season                   integer not null default 2025,
  week                     integer not null default 1,
  roster_snapshot_id       text not null default 'snap_0',
  as_of                    timestamptz not null default now(),
  scoring_profile_version  integer not null default 1,
  -- player identity (canonical id, NEVER display-name identity):
  player_id           text not null,
  display_name        text,
  position            text not null,                 -- QB|RB|WR|TE|K|DEF
  lineup_state        text not null,                 -- STARTER|BENCH|IR|RESERVE
  roster_slot         text,                          -- starter slot occupied (null if not STARTER)
  eligible_slots      text[] not null default '{}',  -- DERIVED server-side (client input ignored)
  locked              boolean not null default false,-- F5 late-swap: game started => cannot move
  lock_at             timestamptz,
  rival               text,
  kickoff             timestamptz,
  injury_status       text,
  -- F6 immutable projection tuple (all NULL until a real Fantasy brain exists):
  proj_floor               numeric,
  proj_median              numeric,
  proj_ceiling             numeric,
  projection_snapshot_id   text,
  feature_snapshot_id      text,
  model_version            text,
  proj_as_of               timestamptz,
  provenance               text,
  projection_status        text not null default 'NO_FANTASY_BRAIN',
  created_at          timestamptz not null default now(),
  constraint fq_roster_player_pos_ck check (position in ('QB','RB','WR','TE','K','DEF')),
  constraint fq_roster_player_state_ck check (lineup_state in ('STARTER','BENCH','IR','RESERVE')),
  -- F2: a player is unique WITHIN a weekly snapshot scope, not globally:
  constraint fq_roster_player_snapshot_uk
    unique (league_id, fantasy_team_id, season, week, roster_snapshot_id, player_id)
);

-- F4: derive eligible_slots + projection_status on EVERY write path. Client
--     supplied eligible_slots / projection_status are OVERWRITTEN (ignored).
create or replace function v2.fq_tg_roster_player_derive()
returns trigger language plpgsql as $$
declare v_superflex boolean;
begin
  select superflex into v_superflex from v2.fq_scoring_profile
   where scoring_profile_id = new.scoring_profile_id;
  if v_superflex is null then
    raise exception 'fq_roster_player: unknown scoring_profile_id %', new.scoring_profile_id;
  end if;

  -- F4: ALWAYS derive eligible_slots canonically (never trust client input)
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

  -- F6 + F4: derive projection_status from the COMPLETE tuple; a client-supplied
  --          projection_status is IGNORED. Partial tuple => fail closed.
  new.projection_status := v2.fq_fn_projection_status(
    new.proj_floor, new.proj_median, new.proj_ceiling,
    new.projection_snapshot_id, new.feature_snapshot_id, new.model_version,
    new.proj_as_of, new.provenance
  );

  return new;
end;
$$;

create trigger fq_tg_roster_player_derive
  before insert or update on v2.fq_roster_player
  for each row execute function v2.fq_tg_roster_player_derive();

-- F2: weekly snapshot immutability. Once a row exists, its snapshot identity and
--     its projection tuple cannot be mutated in place — a change is a NEW
--     snapshot. Operational fields (lineup_state/roster_slot/locked) may change.
create or replace function v2.fq_tg_roster_player_immutable()
returns trigger language plpgsql as $$
begin
  if new.league_id <> old.league_id
     or new.fantasy_team_id <> old.fantasy_team_id
     or new.season <> old.season
     or new.week <> old.week
     or new.roster_snapshot_id <> old.roster_snapshot_id
     or new.player_id <> old.player_id
     or new.position <> old.position
     or new.proj_floor is distinct from old.proj_floor
     or new.proj_median is distinct from old.proj_median
     or new.proj_ceiling is distinct from old.proj_ceiling
     or new.projection_snapshot_id is distinct from old.projection_snapshot_id
     or new.feature_snapshot_id is distinct from old.feature_snapshot_id
     or new.model_version is distinct from old.model_version
     or new.proj_as_of is distinct from old.proj_as_of
     or new.provenance is distinct from old.provenance
  then
    raise exception 'fq_roster_player: snapshot % (player %) is immutable — write a new roster_snapshot_id instead',
      old.roster_snapshot_id, old.player_id;
  end if;
  return new;
end;
$$;

create trigger fq_tg_roster_player_immutable
  before update on v2.fq_roster_player
  for each row execute function v2.fq_tg_roster_player_immutable();

-- ----------------------------------------------------------------------------
-- 4) ROSTER STATUS GATE  (F3: legal slot occupancy, not headcount; F4 derived)
--    Validates, against the league config:
--      * exact per-slot starter counts (no over/under-filled slots),
--      * each starter legally eligible for its slot,
--      * UNIQUE player_ids (no duplicate player),
--      * exact bench and IR counts,
--      * total starter cardinality.
--    status: COMPLETE | ROSTER_INCOMPLETE (something missing/under)
--          | ROSTER_INVALID (illegal: over-filled slot, illegal placement,
--            duplicate player, too many starters, over bench/IR).
--    9 QB starters => ROSTER_INVALID (QB slot over-filled 9>1), never COMPLETE.
-- ----------------------------------------------------------------------------
create or replace function v2.fq_fn_roster_status(
  p_scoring_profile_id text, p_roster jsonb default null
) returns table (
  status               text,
  required_starters    integer,
  present_starters     integer,
  required_bench       integer,
  present_bench        integer,
  required_ir          integer,
  present_ir           integer,
  duplicate_players    integer,
  violation_count      integer,
  violations           text[],
  slot_report          jsonb
)
language plpgsql stable as $$
declare
  p record;
  v_norm jsonb;
  v_req_starters int;
  v_present_starters int; v_present_bench int; v_present_ir int; v_dupe int;
  v_invalid boolean := false; v_incomplete boolean := false;
  v_viol text[] := '{}';
  v_slot_report jsonb := '[]'::jsonb;
  v_present int; v_illegal int;
  rec record;
begin
  select * into p from v2.fq_scoring_profile where scoring_profile_id = p_scoring_profile_id;
  if not found then
    raise exception 'fq_fn_roster_status: unknown scoring_profile_id %', p_scoring_profile_id;
  end if;
  v_req_starters := p.qb_slots + p.rb_slots + p.wr_slots + p.te_slots
                  + p.flex_slots + p.superflex_slots + p.k_slots + p.def_slots;

  -- F4: build the normalized roster ONCE, deriving eligibility server-side and
  --     IGNORING any client-supplied eligible_slots / projection_status.
  if p_roster is null then
    select jsonb_agg(jsonb_build_object(
      'player_id', r.player_id, 'display_name', r.display_name,
      'position', upper(r.position), 'lineup_state', upper(r.lineup_state),
      'roster_slot', nullif(upper(coalesce(r.roster_slot,'')),''),
      'eligible_slots', to_jsonb(v2.fq_fn_eligible_slots(r.position, p.superflex))
    ))
    into v_norm
    from v2.fq_roster_player r
    where r.scoring_profile_id = p_scoring_profile_id;
  else
    select jsonb_agg(jsonb_build_object(
      'player_id', x->>'player_id', 'display_name', x->>'display_name',
      'position', upper(x->>'position'), 'lineup_state', upper(x->>'lineup_state'),
      'roster_slot', nullif(upper(coalesce(x->>'roster_slot','')),''),
      'eligible_slots', to_jsonb(v2.fq_fn_eligible_slots(x->>'position', p.superflex))
    ))
    into v_norm
    from jsonb_array_elements(coalesce(p_roster,'[]'::jsonb)) x;
  end if;
  v_norm := coalesce(v_norm, '[]'::jsonb);

  -- headcounts (quality-aware: real player_id required to count)
  select
    count(*) filter (where e->>'lineup_state'='STARTER'),
    count(*) filter (where e->>'lineup_state'='BENCH'),
    count(*) filter (where e->>'lineup_state'='IR')
  into v_present_starters, v_present_bench, v_present_ir
  from jsonb_array_elements(v_norm) e
  where coalesce(btrim(e->>'player_id'),'') <> ''
    and upper(btrim(coalesce(e->>'player_id',''))) not in ('TBD','PLACEHOLDER','NA','NULL','N/A');

  -- duplicate player_ids (same canonical id twice) => illegal
  select count(*) into v_dupe from (
    select e->>'player_id' pid from jsonb_array_elements(v_norm) e
    where coalesce(btrim(e->>'player_id'),'') <> ''
    group by 1 having count(*) > 1
  ) d;
  if v_dupe > 0 then
    v_invalid := true;
    v_viol := v_viol || format('DUPLICATE_PLAYER_IDS: %s player_id(s) appear more than once', v_dupe);
  end if;

  -- exact per-slot occupancy vs league config
  for rec in
    select code, req, ord from (values
      ('QB',p.qb_slots,1),('RB',p.rb_slots,2),('WR',p.wr_slots,3),('TE',p.te_slots,4),
      ('FLEX',p.flex_slots,5),('SUPERFLEX',p.superflex_slots,6),('K',p.k_slots,7),('DEF',p.def_slots,8)
    ) v(code,req,ord)
    where req > 0
    order by ord
  loop
    select count(*) into v_present
      from jsonb_array_elements(v_norm) e
     where e->>'lineup_state'='STARTER' and e->>'roster_slot'=rec.code;
    if v_present > rec.req then
      v_invalid := true;
      v_viol := v_viol || format('SLOT_OVER_FILLED: %s has %s starters, allows %s', rec.code, v_present, rec.req);
    elsif v_present < rec.req then
      v_incomplete := true;
      v_viol := v_viol || format('SLOT_UNDER_FILLED: %s has %s starters, needs %s', rec.code, v_present, rec.req);
    end if;
    v_slot_report := v_slot_report || jsonb_build_object(
      'slot', rec.code, 'required', rec.req, 'present', v_present, 'ok', (v_present = rec.req));
  end loop;

  -- illegal placements: a STARTER whose occupied slot is not one it is eligible
  -- for (includes starters placed into a slot the league does not run, e.g. a QB
  -- forced into FLEX/SUPERFLEX, or any starter with no slot).
  select count(*) into v_illegal
    from jsonb_array_elements(v_norm) e
   where e->>'lineup_state'='STARTER'
     and ( e->>'roster_slot' is null
           or not (e->'eligible_slots' ? (e->>'roster_slot')) );
  if v_illegal > 0 then
    v_invalid := true;
    v_viol := v_viol || format('ILLEGAL_STARTER_PLACEMENT: %s starter(s) in an ineligible/absent slot', v_illegal);
  end if;

  -- total starter cardinality
  if v_present_starters > v_req_starters then
    v_invalid := true;
    v_viol := v_viol || format('TOO_MANY_STARTERS: %s starters, config allows %s', v_present_starters, v_req_starters);
  end if;

  -- bench / IR exact counts
  if v_present_bench > p.bench_count then
    v_invalid := true;
    v_viol := v_viol || format('BENCH_OVER: %s bench, config allows %s', v_present_bench, p.bench_count);
  elsif v_present_bench < p.bench_count then
    v_incomplete := true;
    v_viol := v_viol || format('BENCH_UNDER: %s bench, needs %s', v_present_bench, p.bench_count);
  end if;
  if v_present_ir > p.ir_count then
    v_invalid := true;
    v_viol := v_viol || format('IR_OVER: %s IR, config allows %s', v_present_ir, p.ir_count);
  elsif v_present_ir < p.ir_count then
    v_incomplete := true;
    v_viol := v_viol || format('IR_UNDER: %s IR, needs %s', v_present_ir, p.ir_count);
  end if;

  status            := case when v_invalid then 'ROSTER_INVALID'
                            when v_incomplete then 'ROSTER_INCOMPLETE'
                            else 'COMPLETE' end;
  required_starters := v_req_starters;
  present_starters  := v_present_starters;
  required_bench    := p.bench_count;
  present_bench     := v_present_bench;
  required_ir       := p.ir_count;
  present_ir        := v_present_ir;
  duplicate_players := v_dupe;
  violation_count   := coalesce(array_length(v_viol,1),0);
  violations        := v_viol;
  slot_report       := v_slot_report;
  return next;
end;
$$;

-- ----------------------------------------------------------------------------
-- 5) GLOBAL LEGAL LINEUP OPTIMIZER  (F5)
--    Solves the COMPLETE legal lineup under the league slot constraints as a
--    bipartite maximum-cardinality matching (Kuhn augmenting paths):
--      * every player used at most once,
--      * eligibility respected (incl. FLEX / SUPERFLEX),
--      * chained reassignments supported (augmenting paths reseat starters to
--        make room — e.g. move a FLEX WR to WR and promote a bench RB to FLEX),
--      * LOCKED starters (game started) are pinned and NEVER moved (late-swap),
--      * IR/RESERVE are never eligible for a starting slot.
--    Returns current lineup vs optimal lineup per slot + the legal moves.
--    per-move delta is NULL until a real projection brain exists (no fabrication);
--    with no projections the optimum keeps the current lineup and only makes the
--    legal moves required to reach a complete legal lineup.
--    Eligibility is DERIVED server-side (F4) — client eligible_slots ignored.
-- ----------------------------------------------------------------------------

-- Kuhn augmenting-path helper (pure in-memory arrays; no temp tables).
-- adjacency is flattened S*P: edge(slot s, player pl) at index (s-1)*P + pl.
create or replace function v2.fq_fn__lineup_aug(
  in  p_pl int,
  in  p_adj boolean[],
  in  p_s int,
  in  p_p int,
  in  p_fixed boolean[],
  inout p_match_slot int[],
  inout p_visited boolean[],
  out p_ok boolean
) language plpgsql as $$
declare s int;
begin
  p_ok := false;
  for s in 1..p_s loop
    if not coalesce(p_fixed[s],false)
       and coalesce(p_adj[(s-1)*p_p + p_pl],false)
       and not coalesce(p_visited[s],false)
    then
      p_visited[s] := true;
      if coalesce(p_match_slot[s],0) = 0 then
        p_match_slot[s] := p_pl;
        p_ok := true;
        return;
      else
        select a.p_match_slot, a.p_visited, a.p_ok
          into p_match_slot, p_visited, p_ok
          from v2.fq_fn__lineup_aug(p_match_slot[s], p_adj, p_s, p_p, p_fixed, p_match_slot, p_visited) a;
        if p_ok then
          p_match_slot[s] := p_pl;
          return;
        end if;
      end if;
    end if;
  end loop;
  p_ok := false;
end;
$$;

create or replace function v2.fq_fn_optimize_lineup(
  p_scoring_profile_id text, p_roster jsonb default null
) returns table (
  slot_code          text,
  slot_seq           integer,
  current_player_id  text,
  optimal_player_id  text,
  is_move            boolean,
  move_note          text,
  delta_median       numeric,
  delta_ceiling      numeric
)
language plpgsql stable as $$
declare
  p record;
  v_norm jsonb;
  v_s int := 0; v_p int := 0;
  a_slot_code text[] := '{}'; a_slot_seq int[] := '{}'; a_slot_order int[] := '{}';
  a_pl_id text[] := '{}'; a_pl_state text[] := '{}'; a_pl_slot text[] := '{}';
  a_pl_locked boolean[] := '{}'; a_pl_elig jsonb[] := '{}';
  adj boolean[]; fixed boolean[]; match_slot int[]; cur_occ int[]; vis boolean[];
  s int; pidx int; c int; ok boolean; found_slot int;
  rec record;
begin
  select * into p from v2.fq_scoring_profile where scoring_profile_id = p_scoring_profile_id;
  if not found then
    raise exception 'fq_fn_optimize_lineup: unknown scoring_profile_id %', p_scoring_profile_id;
  end if;

  -- F4: normalized pool (STARTER + BENCH only; IR/RESERVE excluded), eligibility
  --     derived server-side, client eligible_slots ignored.
  if p_roster is null then
    select jsonb_agg(jsonb_build_object(
      'player_id', r.player_id, 'position', upper(r.position), 'lineup_state', upper(r.lineup_state),
      'roster_slot', nullif(upper(coalesce(r.roster_slot,'')),''),
      'locked', coalesce(r.locked,false),
      'eligible_slots', to_jsonb(v2.fq_fn_eligible_slots(r.position, p.superflex))
    ))
    into v_norm
    from v2.fq_roster_player r
    where r.scoring_profile_id = p_scoring_profile_id
      and upper(r.lineup_state) in ('STARTER','BENCH');
  else
    select jsonb_agg(jsonb_build_object(
      'player_id', x->>'player_id', 'position', upper(x->>'position'), 'lineup_state', upper(x->>'lineup_state'),
      'roster_slot', nullif(upper(coalesce(x->>'roster_slot','')),''),
      'locked', coalesce((x->>'locked')::boolean, false),
      'eligible_slots', to_jsonb(v2.fq_fn_eligible_slots(x->>'position', p.superflex))
    ))
    into v_norm
    from jsonb_array_elements(coalesce(p_roster,'[]'::jsonb)) x
    where upper(x->>'lineup_state') in ('STARTER','BENCH');
  end if;
  v_norm := coalesce(v_norm, '[]'::jsonb);

  -- build slot instances (QB1, RB1, RB2, WR1, WR2, TE1, FLEX1, K1, DEF1, ...)
  for rec in
    select code, req, ord from (values
      ('QB',p.qb_slots,1),('RB',p.rb_slots,2),('WR',p.wr_slots,3),('TE',p.te_slots,4),
      ('FLEX',p.flex_slots,5),('SUPERFLEX',p.superflex_slots,6),('K',p.k_slots,7),('DEF',p.def_slots,8)
    ) v(code,req,ord)
    where req > 0
    order by ord
  loop
    for c in 1..rec.req loop
      v_s := v_s + 1;
      a_slot_code[v_s] := rec.code;
      a_slot_seq[v_s]  := c;
      a_slot_order[v_s]:= rec.ord;
    end loop;
  end loop;

  -- build player pool
  for rec in
    select e.value as v from jsonb_array_elements(v_norm) e
  loop
    v_p := v_p + 1;
    a_pl_id[v_p]     := rec.v->>'player_id';
    a_pl_state[v_p]  := rec.v->>'lineup_state';
    a_pl_slot[v_p]   := nullif(rec.v->>'roster_slot','');
    a_pl_locked[v_p] := coalesce((rec.v->>'locked')::boolean,false);
    a_pl_elig[v_p]   := rec.v->'eligible_slots';
  end loop;

  if v_s = 0 or v_p = 0 then
    return;   -- nothing to optimize
  end if;

  -- adjacency
  adj := array_fill(false, ARRAY[v_s * v_p]);
  for s in 1..v_s loop
    for pidx in 1..v_p loop
      if a_pl_elig[pidx] ? a_slot_code[s] then
        adj[(s-1)*v_p + pidx] := true;
      end if;
    end loop;
  end loop;

  match_slot := array_fill(0, ARRAY[v_s]);
  fixed      := array_fill(false, ARRAY[v_s]);

  -- Pre-assign current STARTERs to an instance of their current slot (keep the
  -- current lineup). Locked starters pin their instance (fixed => never moved).
  for rec in
    select gs as idx from generate_series(1, v_p) gs
     where a_pl_state[gs] = 'STARTER' order by a_pl_id[gs]
  loop
    pidx := rec.idx;
    found_slot := 0;
    for s in 1..v_s loop
      if match_slot[s] = 0
         and a_slot_code[s] = a_pl_slot[pidx]
         and coalesce(adj[(s-1)*v_p + pidx],false)
      then
        found_slot := s; exit;
      end if;
    end loop;
    if found_slot > 0 then
      match_slot[found_slot] := pidx;
      if a_pl_locked[pidx] then
        fixed[found_slot] := true;
      end if;
    end if;
    -- if not placeable legally, the starter stays unmatched and (if unlocked)
    -- may be reseated legally by augmentation below.
  end loop;

  -- snapshot the CURRENT lineup (per slot) before optimizing
  cur_occ := match_slot;

  -- Augment the remaining (unmatched) players — bench first, then any current
  -- starter that could not be legally kept — filling empty slots, chaining
  -- reassignments through non-locked starters as needed.
  for rec in
    select gs as idx from generate_series(1, v_p) gs
     where not exists (select 1 from generate_series(1,v_s) g where match_slot[g] = gs)
     order by (case when a_pl_state[gs]='BENCH' then 0 else 1 end), a_pl_id[gs]
  loop
    pidx := rec.idx;
    vis := array_fill(false, ARRAY[v_s]);
    select a.p_match_slot, a.p_ok
      into match_slot, ok
      from v2.fq_fn__lineup_aug(pidx, adj, v_s, v_p, fixed, match_slot, vis) a;
  end loop;

  -- emit per-slot: current vs optimal + move classification (delta NULL: no brain)
  return query
  select
    a_slot_code[g],
    a_slot_seq[g],
    case when cur_occ[g] > 0 then a_pl_id[cur_occ[g]] end,
    case when match_slot[g] > 0 then a_pl_id[match_slot[g]] end,
    (coalesce(cur_occ[g],0) <> coalesce(match_slot[g],0)),
    case
      when match_slot[g] = 0 then 'EMPTY_UNFILLABLE'
      when coalesce(fixed[g],false) and match_slot[g] = cur_occ[g] then 'LOCKED_KEEP'
      when match_slot[g] = cur_occ[g] then 'KEEP'
      when cur_occ[g] = 0 then 'MOVE_IN'
      else 'CHAIN_MOVE'
    end,
    null::numeric,
    null::numeric
  from generate_series(1, v_s) g
  order by a_slot_order[g], a_slot_seq[g];
end;
$$;

-- ----------------------------------------------------------------------------
-- 6) START/SIT ADVISORY (per-starter best LEGAL bench alternative)
--    Retained as a lightweight advisory over the SAME server-derived eligibility
--    (F4). The authoritative whole-roster answer is fq_fn_optimize_lineup (F5).
--    Withholds when the roster is not COMPLETE (uses fq_fn_roster_status).
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
declare
  v_status text;
  v_superflex boolean;
begin
  select s.status into v_status from v2.fq_fn_roster_status(p_scoring_profile_id, p_roster) s;
  if v_status <> 'COMPLETE' then
    return;   -- recommendations withheld on a non-legal/incomplete roster
  end if;
  select superflex into v_superflex from v2.fq_scoring_profile where scoring_profile_id = p_scoring_profile_id;

  return query
  with roster as (
    select r.player_id, r.position, r.lineup_state, r.roster_slot,
           v2.fq_fn_eligible_slots(r.position, v_superflex) as eligible_slots,
           r.proj_median, r.proj_ceiling
    from v2.fq_roster_player r
    where r.scoring_profile_id = p_scoring_profile_id and p_roster is null
    union all
    select (x->>'player_id'), upper(x->>'position'), upper(x->>'lineup_state'),
           nullif(upper(coalesce(x->>'roster_slot','')),''),
           v2.fq_fn_eligible_slots(x->>'position', v_superflex),  -- F4: derived, client ignored
           (x->>'proj_median')::numeric, (x->>'proj_ceiling')::numeric
    from jsonb_array_elements(coalesce(p_roster,'[]'::jsonb)) x
    where p_roster is not null
  ),
  starters as (select * from roster where lineup_state='STARTER' and roster_slot is not null),
  bench as (select * from roster where lineup_state='BENCH'),
  ranked as (
    select st.player_id as starter_player_id, st.roster_slot as starter_slot,
           st.proj_median as st_median, st.proj_ceiling as st_ceiling,
           bn.player_id as bench_player_id, bn.proj_median as bn_median, bn.proj_ceiling as bn_ceiling,
           row_number() over (
             partition by st.player_id, st.roster_slot
             order by bn.proj_median desc nulls last, bn.proj_ceiling desc nulls last,
                      (bn.position = st.position) desc, bn.player_id asc
           ) as rnk
    from starters st
    join bench bn on st.roster_slot = any(bn.eligible_slots)   -- legality
  ),
  best as (select * from ranked where rnk = 1)
  select
    st.player_id, st.roster_slot, b.bench_player_id,
    case when st.proj_median is not null and b.bn_median is not null then b.bn_median - st.proj_median end,
    case when st.proj_ceiling is not null and b.bn_ceiling is not null then b.bn_ceiling - st.proj_ceiling end,
    case
      when b.bench_player_id is null then 'NO_LEGAL_BENCH_ALTERNATIVE'
      when st.proj_median is null or b.bn_median is null then 'PROJECTION_UNAVAILABLE_NO_FANTASY_BRAIN'
      else format('SIT %s / START %s', st.player_id, b.bench_player_id)
    end
  from starters st
  left join best b on b.starter_player_id = st.player_id and b.starter_slot = st.roster_slot
  order by st.roster_slot, st.player_id;
end;
$$;

-- ============================================================================
-- ROLLBACK (branch cleanup):
--   drop function if exists v2.fq_fn_optimize_lineup(text, jsonb);
--   drop function if exists v2.fq_fn__lineup_aug(int, boolean[], int, int, boolean[], int[], boolean[]);
--   drop function if exists v2.fq_fn_start_sit(text, jsonb);
--   drop function if exists v2.fq_fn_roster_status(text, jsonb);
--   drop function if exists v2.fq_fn_sync_roster_slots(text);
--   drop trigger  if exists fq_tg_roster_player_immutable on v2.fq_roster_player;
--   drop function if exists v2.fq_tg_roster_player_immutable();
--   drop trigger  if exists fq_tg_roster_player_derive on v2.fq_roster_player;
--   drop function if exists v2.fq_tg_roster_player_derive();
--   drop function if exists v2.fq_fn_projection_status(numeric,numeric,numeric,text,text,text,timestamptz,text);
--   drop function if exists v2.fq_fn_eligible_slots(text, boolean);
--   drop function if exists v2.fq_fn_canonical_scoring_name(numeric);
--   drop table if exists v2.fq_scoring_modifier;
--   drop table if exists v2.fq_roster_player;
--   drop table if exists v2.fq_roster_slots;
--   drop table if exists v2.fq_scoring_profile;
-- ============================================================================
