-- ============================================================================
-- iss046 — PARLAY SCANNER v2: IDENTITY + CORRELATION + PERFORMANCE  (schema v2)
-- STAGED, branch-only (project kmasawoljjyfmxadbvou). NO PROD MUTATION.
-- Resolves GitHub issue #4 comment 5620229977 (RETO 13M PARLAY SCANNER v2).
-- Gates honored: P0=SOCCER · RELEASE_GATE=HOLD · PROD_FREEZE=ON · LOVABLE_FREEZE=ON.
-- NO va en supabase/migrations. NO deploy de edge functions. NO Lovable.
-- ----------------------------------------------------------------------------
-- Builds ON:
--   iss038 (per-leg canonical resolution; joint_probability=NULL discipline; the
--           LLM ai_prob_combinada is NON-AUTHORITY) — KEPT: joint=NULL always.
--   iss040 (SGP grouping: one price per canonical event; the filler 1.01 ignored;
--           coherence vs ticket total).
--   iss031 / iss022 (canonical leg identity by teams+date; never guess).
--
-- 14 findings covered (see issue #4 c5620229977):
--   1  team-name normalization (accent-fold + club-token strip + munich unify)
--   2  canonical alias registry (persist/display the backend canonical name)
--   3  event resolver (id-first, else teams+date; OCR league SUPPORTING only,
--      never rejects an otherwise-unique match; ambiguous => AMBIGUOUS, no guess)
--   4  market canonicalization: BTTS / 1X2 / ASIAN_HANDICAP / MATCH_TOTAL /
--      TEAM_TOTAL — team totals NEVER merged with match O/U
--   5  leg odds contract: grouped price makes a leg VALID even w/o individual
--      price; NEVER fabricate 1.0 as an individual price then flag it invalid
--   6  correlation: same-event legs are correlated by definition; emit
--      correlated_groups[]; joint_probability=NULL; EV_REAL=NULL;
--      CORRELATION_STATUS='UNMODELED_REQUIRES_JOINT_MODEL'; never 1/ticket_odds;
--      never "Sin correlación detectada" when same-event legs exist
--   7  house_edge=NULL + reason (no documented fair-price baseline yet)
--   8  single bankroll snapshot -> one snapshot id + one percentage
--   9  bono/payout invariant: bonus only if the ticket EXPLICITLY carries one
--   10 persistence status: any unresolved leg / invalid market / unknown joint
--      => NEEDS_REVIEW and is_canonical_reto13m=false
--   11 performance: ONE set-based resolution query (no per-leg serial lookups)
--   (edge-layer OCR/parse parallelization is out of this repo — noted at end)
-- ============================================================================

create schema if not exists v2;

-- ----------------------------------------------------------------------------
-- FINDING 1 — Team-name normalization -> canonical key.
-- Explicit NFD-style accent fold via translate() (self-contained & IMMUTABLE;
-- does not depend on the unaccent extension being present on the branch),
-- lowercase, punctuation stripped, club-type tokens dropped, munich unified.
-- ----------------------------------------------------------------------------
create or replace function v2.fn_norm_team(p_raw text)
returns text language sql immutable as $$
  select nullif(
    trim(
      regexp_replace(                                             -- 5) collapse ws
        regexp_replace(                                           -- 4) drop club tokens
          regexp_replace(                                         -- 3) punctuation -> space
            regexp_replace(                                       -- 2) unify munich
              translate(lower(coalesce(p_raw,'')),                -- 1) accent fold
                'áàâäãåéèêëíìîïóòôöõúùûüñçø',
                'aaaaaaeeeeiiiiooooouuuunco'),
              '\ymunchen\y','munich','g'),                        -- \y = word boundary
            '[^a-z0-9 ]',' ','g'),
          '\y(fc|fk|fa|cf|rc|sc|as|rb|afc|cd)\y','','g'),         -- PG uses \y not \b
        '\s+',' ','g')
    ), '');
$$;
comment on function v2.fn_norm_team(text) is
  'iss046: canonical team key. Fenerbahçe/Fenerbahce, Bayern München/Munich, '
  'Sabah FC/FK/FA, RC Lens/Lens, RB Leipzig->leipzig all fold to one key.';

-- ----------------------------------------------------------------------------
-- FINDING 2 — Canonical alias registry (persist/display the backend name).
-- ----------------------------------------------------------------------------
create table if not exists v2.team_alias_registry (
  alias_norm     text primary key,
  canonical_name text not null,
  espn_team_hint text
);
comment on table v2.team_alias_registry is
  'iss046: normalized alias key -> canonical backend display name (+ event hint).';

-- ----------------------------------------------------------------------------
-- Canonical agenda used by the resolver (seeded from gate_fixture_soccer_cards).
-- One row per canonical event; teams pre-normalized for a set-based join.
-- ----------------------------------------------------------------------------
create table if not exists v2.parlay_canonical_agenda (
  canonical_event_id text primary key,
  home_canonical     text not null,
  away_canonical     text not null,
  home_norm          text not null,
  away_norm          text not null,
  kickoff            timestamptz not null,
  competition_id     text
);
comment on table v2.parlay_canonical_agenda is
  'iss046: canonical resolution agenda (id, normalized teams, kickoff, competition).';

-- Registry-backed canonical team key: an alias (incl. OCR garble) is mapped to
-- the canonical name, then to its canonical key. Falls back to plain fn_norm_team
-- for teams already canonical. This is how finding 2's registry drives resolution.
create or replace function v2.fn_canon_team_key(p_raw text)
returns text language sql stable as $$
  select coalesce(
    (select v2.fn_norm_team(r.canonical_name)
       from v2.team_alias_registry r
      where r.alias_norm = v2.fn_norm_team(p_raw) limit 1),
    v2.fn_norm_team(p_raw));
$$;

-- Seed registry + agenda from the 6 real UCL fixture cards + observed OCR variants.
create or replace function v2.fn_seed_parlay_scanner_agenda(p_kickoff timestamptz)
returns void language plpgsql as $$
begin
  -- agenda: rebuild deterministically from the fixture cards
  delete from v2.parlay_canonical_agenda;
  insert into v2.parlay_canonical_agenda
    (canonical_event_id, home_canonical, away_canonical, home_norm, away_norm, kickoff, competition_id)
  select c.espn_event_id, c.home_team, c.away_team,
         v2.fn_norm_team(c.home_team), v2.fn_norm_team(c.away_team),
         p_kickoff, c.competition
  from v2.gate_fixture_soccer_cards c;

  -- registry: canonical names straight from the cards ...
  insert into v2.team_alias_registry (alias_norm, canonical_name, espn_team_hint)
  select v2.fn_norm_team(c.home_team), c.home_team, c.espn_event_id
    from v2.gate_fixture_soccer_cards c
  on conflict (alias_norm) do nothing;
  insert into v2.team_alias_registry (alias_norm, canonical_name, espn_team_hint)
  select v2.fn_norm_team(c.away_team), c.away_team, c.espn_event_id
    from v2.gate_fixture_soccer_cards c
  on conflict (alias_norm) do nothing;

  -- ... plus the OCR variants observed on the owner ticket (all collapse to the
  -- same alias_norm, proving the fold; canonical_name kept from the card).
  insert into v2.team_alias_registry (alias_norm, canonical_name, espn_team_hint) values
    (v2.fn_norm_team('Fenerbahçe'),               'Fenerbahce',   '401915444'),
    (v2.fn_norm_team('Fenerb'||chr(233)||'çe'),   'Fenerbahce',   '401915444'), -- L1 OCR garble
    (v2.fn_norm_team('AS Roma'),         'AS Roma',           '401915444'),
    (v2.fn_norm_team('Roma'),            'AS Roma',           '401915444'),
    (v2.fn_norm_team('Bayern München'),  'Bayern Munich',     '401915443'),
    (v2.fn_norm_team('Bayern Munich'),   'Bayern Munich',     '401915443'),
    (v2.fn_norm_team('Bodø/Glimt'),      'Bodo/Glimt',        '401915443'),
    (v2.fn_norm_team('RB Leipzig'),      'RB Leipzig',        '401915441'),
    (v2.fn_norm_team('Leipzig'),         'RB Leipzig',        '401915441'),
    (v2.fn_norm_team('RC Lens'),         'Lens',              '401915440'),
    (v2.fn_norm_team('Lens'),            'Lens',              '401915440'),
    (v2.fn_norm_team('Sabah FC'),        'Sabah FK',          '401915442'),
    (v2.fn_norm_team('Sabah FK'),        'Sabah FK',          '401915442'),
    (v2.fn_norm_team('Sabah FA'),        'Sabah FK',          '401915442')
  on conflict (alias_norm) do nothing;
end $$;

-- ----------------------------------------------------------------------------
-- FINDING 4 — Market canonicalization.
-- Distinguishes BTTS / 1X2(ML) / ASIAN_HANDICAP / MATCH_TOTAL / TEAM_TOTAL.
-- Team totals ("Como Total Más de 1.5") carry team_norm => NEVER match totals.
-- HOME/AWAY side for ML/AH/TEAM_TOTAL is finalized later against the resolved
-- event (this function only extracts the team token referenced).
-- ----------------------------------------------------------------------------
create or replace function v2.fn_canon_market(p_raw text)
returns jsonb language plpgsql immutable as $$
declare
  t        text := regexp_replace(
                     translate(lower(coalesce(p_raw,'')),
                       'áàâäãåéèêëíìîïóòôöõúùûüñçø',
                       'aaaaaaeeeeiiiiooooouuuunco'),
                     '\s+',' ','g');
  v_market text := 'UNRESOLVED';
  v_side   text := null;
  v_line   numeric := null;
  v_team_raw  text := null;
  v_team_norm text := null;
begin
  if t ~ 'btts|ambos anotan|ambos marcan|both teams' then
    v_market := 'BTTS';
    v_side := case when t ~ '(^| )no( |$)' then 'NO' else 'YES' end;

  elsif t ~ 'asian handicap|handicap asiatico|hcap|handicap' then
    v_market := 'ASIAN_HANDICAP';
    v_line := nullif(substring(t from '[-+]?[0-9]+\.?[0-9]*'),'')::numeric;
    v_team_raw := trim(regexp_replace(t,'(asian handicap|handicap asiatico|hcap|handicap).*$',''));
    v_team_norm := v2.fn_norm_team(v_team_raw);

  elsif t ~ 'total|over|under|mas de|menos de|mayor|menor|goles' then
    v_side := case when t ~ 'over|mas de|mayor' then 'OVER'
                   when t ~ 'under|menos|menor' then 'UNDER' end;
    v_line := nullif(substring(t from '[0-9]+\.?[0-9]*'),'')::numeric;
    v_team_raw := trim(regexp_replace(t,'(total|over|under|mas de|menos de|mayor|menor|goles).*$',''));
    if v_team_raw is null or v_team_raw = '' then
      v_market := 'MATCH_TOTAL'; v_team_norm := null;
    else
      v_market := 'TEAM_TOTAL'; v_team_norm := v2.fn_norm_team(v_team_raw);
    end if;

  elsif t ~ '(^| )ml( |$)|moneyline|money line|1x2|gana|resultado' then
    v_market := '1X2';
    v_team_raw := trim(regexp_replace(t,'( ml|moneyline|money line|1x2|gana|resultado).*$',''));
    v_team_norm := v2.fn_norm_team(v_team_raw);
  end if;

  return jsonb_build_object(
    'market', v_market, 'side', v_side, 'line', v_line,
    'team_norm', v_team_norm, 'team_raw', v_team_raw, 'raw', p_raw);
end $$;
comment on function v2.fn_canon_market(text) is
  'iss046: market canon. TEAM_TOTAL carries team_norm and is never merged with '
  'MATCH_TOTAL. HOME/AWAY finalized against the resolved event.';

-- ----------------------------------------------------------------------------
-- FINDING 3 — Event resolver (per-leg convenience API; the ticket structure
-- resolves the whole ticket set-based, see below).
-- Priority: (a) explicit canonical/provider event id; else (b) normalized
-- home+away keys (order-insensitive) + intended date within a kickoff window.
-- OCR league is SUPPORTING evidence ONLY and must NEVER reject a unique match.
-- Distinct real events never merge; >1 candidate => AMBIGUOUS (no guess).
-- ----------------------------------------------------------------------------
create or replace function v2.fn_resolve_event(
  p_home_raw text, p_away_raw text, p_intended_date date, p_ocr_league text,
  p_explicit_event_id text default null, p_window_days int default 1)
returns jsonb language plpgsql stable as $$
declare
  lh text := v2.fn_canon_team_key(p_home_raw);
  la text := v2.fn_canon_team_key(p_away_raw);
  v_cand jsonb;
  v_n int;
  r record;
begin
  -- (a) explicit id wins outright
  if nullif(p_explicit_event_id,'') is not null then
    select * into r from v2.parlay_canonical_agenda a
      where a.canonical_event_id = p_explicit_event_id;
    if found then
      return jsonb_build_object(
        'status','RESOLVED','canonical_event_id',r.canonical_event_id,
        'home_canonical',r.home_canonical,'away_canonical',r.away_canonical,
        'kickoff',r.kickoff,'competition_id',r.competition_id,
        'identity_confidence',1.0,
        'evidence',jsonb_build_object('rule','EXPLICIT_EVENT_ID',
          'ocr_league',p_ocr_league,'ocr_league_role','SUPPORTING_ONLY'),
        'candidates', jsonb_build_array(r.canonical_event_id));
    end if;
  end if;

  -- (b) order-insensitive team keys + intended date within kickoff window
  select jsonb_agg(a.canonical_event_id order by a.canonical_event_id), count(*)
    into v_cand, v_n
  from v2.parlay_canonical_agenda a
  where ((a.home_norm = lh and a.away_norm = la)
      or (a.home_norm = la and a.away_norm = lh))
    and a.kickoff::date between coalesce(p_intended_date, a.kickoff::date) - p_window_days
                           and coalesce(p_intended_date, a.kickoff::date) + p_window_days;

  if coalesce(v_n,0) = 0 then
    return jsonb_build_object('status','UNRESOLVED','canonical_event_id',null,
      'identity_confidence',0,
      'evidence',jsonb_build_object('rule','NO_TEAM_DATE_MATCH','home_norm',lh,
        'away_norm',la,'ocr_league',p_ocr_league,'ocr_league_role','SUPPORTING_ONLY'),
      'candidates','[]'::jsonb);
  elsif v_n > 1 then
    return jsonb_build_object('status','AMBIGUOUS','canonical_event_id',null,
      'identity_confidence',0,
      'evidence',jsonb_build_object('rule','MULTIPLE_TEAM_DATE_CANDIDATES',
        'ocr_league',p_ocr_league,'ocr_league_role','SUPPORTING_ONLY'),
      'candidates',v_cand);
  end if;

  select * into r from v2.parlay_canonical_agenda a
   where a.canonical_event_id = (v_cand->>0);
  return jsonb_build_object(
    'status','RESOLVED','canonical_event_id',r.canonical_event_id,
    'home_canonical',r.home_canonical,'away_canonical',r.away_canonical,
    'kickoff',r.kickoff,'competition_id',r.competition_id,
    'identity_confidence',1.0,
    'evidence',jsonb_build_object('rule','TEAMS_PLUS_DATE_UNIQUE',
      'ocr_league',p_ocr_league,'ocr_league_role','SUPPORTING_ONLY',
      'ocr_vs_canonical_competition',
        case when p_ocr_league is not null and lower(p_ocr_league) not like '%champ%'
                  and r.competition_id ilike '%champions%'
             then 'OCR_LEAGUE_DIFFERS_IGNORED_AS_SUPPORTING' else 'CONSISTENT_OR_NA' end),
    'candidates',v_cand);
end $$;
comment on function v2.fn_resolve_event(text,text,date,text,text,int) is
  'iss046: id-first else teams+date resolver. OCR league supporting only; '
  'never rejects a unique match; ambiguous => AMBIGUOUS with candidates.';

-- ----------------------------------------------------------------------------
-- FINDING 8 — Single bankroll snapshot -> one snapshot id + one percentage.
-- ----------------------------------------------------------------------------
create or replace function v2.fn_parlay_bankroll_pct(
  p_stake numeric, p_bankroll_snapshot numeric)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'snapshot_id',
      md5(coalesce(p_stake,0)::text || ':' || coalesce(p_bankroll_snapshot,0)::text),
    'stake', p_stake,
    'bankroll_snapshot', p_bankroll_snapshot,
    'bankroll_pct',
      case when p_bankroll_snapshot is null or p_bankroll_snapshot = 0 or p_stake is null
           then null
           else round(p_stake / p_bankroll_snapshot * 100, 4) end,
    'bankroll_pct_count', 1);
$$;
comment on function v2.fn_parlay_bankroll_pct(numeric,numeric) is
  'iss046: exactly one snapshot id + one percentage. No two different percentages.';

-- ----------------------------------------------------------------------------
-- FINDINGS 3+4+5+6+7+9+10+11 — Ticket structure + correlation.
-- ONE set-based CTE resolves ALL legs (no per-leg serial DB lookups).
-- Groups by canonical_event_id; same-event legs are CORRELATED by definition.
-- joint_probability=NULL, EV_REAL=NULL, CORRELATION_STATUS unmodeled.
-- house_edge=NULL (no fair-price baseline). bonus only if EXPLICIT.
-- Core signature (p_legs, p_decision) per spec; optional ticket-level params
-- (stake/bankroll/bonus) support findings 8 & 9 without a second call surface.
-- ----------------------------------------------------------------------------
create or replace function v2.fn_parlay_ticket_structure(
  p_legs jsonb, p_decision timestamptz,
  p_stake numeric default null, p_bankroll_snapshot numeric default null,
  p_bonus numeric default null, p_window_days int default 1)
returns jsonb language plpgsql stable as $$
declare
  v_legs        jsonb;
  v_groups      jsonb;
  v_n_groups    int;
  v_n_corr      int;
  v_any_bad     boolean;
  v_ticket_odds numeric;
  v_bankroll    jsonb;
  v_bonus       numeric;
  v_bonus_rsn   text;
  v_payout      numeric;
  v_status      text;
  v_is_canon    boolean;
  v_canon_rsn   text;
begin
  ------------------------------------------------------------------ set-based
  with legs as (
    select ord::int as leg_no, e.leg,
           nullif(e.leg->>'home_raw','')                                    as hr,
           nullif(e.leg->>'away_raw','')                                    as ar,
           nullif(e.leg->>'ocr_league','')                                  as ocr,
           coalesce(e.leg->>'market_raw','')                                as mkt,
           nullif(e.leg->>'explicit_event_id','')                          as xid,
           nullif(e.leg->>'individual_odds','')::numeric                    as ind,
           coalesce(nullif(e.leg->>'same_game_price','')::numeric,
                    nullif(e.leg->>'grouped_event_odds','')::numeric)       as grp,
           nullif(e.leg->>'ticket_total_odds','')::numeric                  as tto,
           nullif(e.leg->>'odds_source','')                                as src_in,
           nullif(e.leg->>'intended_date','')::date                        as idate
    from jsonb_array_elements(coalesce(p_legs,'[]'::jsonb)) with ordinality e(leg, ord)
  ),
  normed as (
    select l.*, v2.fn_canon_team_key(l.hr) as lh, v2.fn_canon_team_key(l.ar) as la,
           v2.fn_canon_market(l.mkt) as cm
    from legs l
  ),
  matched as (
    select n.*,
      m.canonical_event_id, m.home_canonical, m.away_canonical,
      m.home_norm, m.away_norm, m.kickoff, m.competition_id,
      ( select count(*) from v2.parlay_canonical_agenda a2
         where ( n.xid is not null and a2.canonical_event_id = n.xid )
            or ( n.xid is null and
                 ((a2.home_norm=n.lh and a2.away_norm=n.la) or
                  (a2.home_norm=n.la and a2.away_norm=n.lh)) and
                 a2.kickoff::date between coalesce(n.idate,a2.kickoff::date)-p_window_days
                                     and coalesce(n.idate,a2.kickoff::date)+p_window_days)
      ) as n_cand
    from normed n
    left join lateral (
      select * from v2.parlay_canonical_agenda a
       where ( n.xid is not null and a.canonical_event_id = n.xid )
          or ( n.xid is null and
               ((a.home_norm=n.lh and a.away_norm=n.la) or
                (a.home_norm=n.la and a.away_norm=n.lh)) and
               a.kickoff::date between coalesce(n.idate,a.kickoff::date)-p_window_days
                                   and coalesce(n.idate,a.kickoff::date)+p_window_days)
       order by a.canonical_event_id
       limit 1
    ) m on true
  ),
  finalized as (
    select mt.*,
      case when mt.canonical_event_id is null then 'UNRESOLVED'
           when mt.n_cand > 1 then 'AMBIGUOUS'
           else 'RESOLVED' end                                     as identity_status,
      (mt.cm->>'market')                                           as m0,
      (mt.cm->>'side')                                             as s0,
      nullif(mt.cm->>'line','')::numeric                           as ln,
      nullif(mt.cm->>'team_norm','')                               as tn,
      -- HOME/AWAY for the team referenced by the market (prefix-tolerant: "Bayern"~"bayern munich")
      case
        when nullif(mt.cm->>'team_norm','') is null then null
        when (mt.home_norm = mt.cm->>'team_norm'
              or mt.home_norm like (mt.cm->>'team_norm')||'%'
              or (mt.cm->>'team_norm') like mt.home_norm||'%')
         and not (mt.away_norm = mt.cm->>'team_norm'
              or mt.away_norm like (mt.cm->>'team_norm')||'%') then 'HOME'
        when (mt.away_norm = mt.cm->>'team_norm'
              or mt.away_norm like (mt.cm->>'team_norm')||'%'
              or (mt.cm->>'team_norm') like mt.away_norm||'%')
         and not (mt.home_norm = mt.cm->>'team_norm'
              or mt.home_norm like (mt.cm->>'team_norm')||'%') then 'AWAY'
        else null end                                              as team_side
    from matched mt
  ),
  legrows as (
    select f.leg_no, f.canonical_event_id, f.home_canonical, f.away_canonical,
           f.identity_status, f.m0, f.s0, f.ln, f.team_side, f.ind, f.grp, f.tto,
           f.src_in, f.competition_id,
      -- canonical market projection
      case f.m0
        when '1X2'            then f.team_side              -- HOME/AWAY
        when 'ASIAN_HANDICAP' then f.team_side
        else f.s0                                           -- YES/NO or OVER/UNDER
      end                                                        as canonical_side,
      case when f.m0 = 'ASIAN_HANDICAP' then f.team_side
           when f.m0 = 'TEAM_TOTAL'     then f.team_side
           else null end                                         as team_scope,
      case when f.m0 in ('MATCH_TOTAL','TEAM_TOTAL','ASIAN_HANDICAP') then f.ln
           else null end                                         as canonical_line,
      -- odds source (never fabricate): grouped price counts; missing individual is OK
      coalesce(f.src_in,
               case when f.grp is not null then 'grouped'
                    when f.ind is not null then 'OCR' else 'OCR' end) as odds_source,
      -- leg validity: identity + market only. A grouped/absent individual price
      -- NEVER invalidates the leg (finding 5). No fabricated 1.0 anywhere.
      (f.identity_status = 'RESOLVED' and f.m0 <> 'UNRESOLVED')      as leg_valid,
      (f.ind is not null)                                            as leg_ev_available
    from finalized f
  )
  select
    jsonb_agg(to_jsonb(lr) order by lr.leg_no)
  into v_legs
  from (
    select leg_no, canonical_event_id, home_canonical, away_canonical, competition_id,
           identity_status,
           m0 as canonical_market, canonical_side, canonical_line, team_scope,
           ind as individual_odds, grp as same_game_price, tto as ticket_total_odds,
           odds_source, leg_valid, leg_ev_available
    from legrows
  ) lr;

  ----------------------------------------------------- groups + correlation
  with lr as (select * from jsonb_array_elements(coalesce(v_legs,'[]'::jsonb)) x(leg))
  select
    jsonb_agg(g.grp order by g.canonical_event_id) filter (where g.leg_count > 1),
    count(*)::int,
    count(*) filter (where g.leg_count > 1)::int
  into v_groups, v_n_groups, v_n_corr
  from (
    select leg->>'canonical_event_id' as canonical_event_id,
           max(leg->>'home_canonical') as home_canonical,
           max(leg->>'away_canonical') as away_canonical,
           count(*)::int as leg_count,
           jsonb_build_object(
             'canonical_event_id', leg->>'canonical_event_id',
             'home_canonical', max(leg->>'home_canonical'),
             'away_canonical', max(leg->>'away_canonical'),
             'leg_count', count(*)::int,
             'legs', jsonb_agg((leg->>'leg_no')::int order by (leg->>'leg_no')::int)
           ) as grp
    from lr
    where leg->>'canonical_event_id' is not null
    group by leg->>'canonical_event_id'
  ) g;

  v_groups := coalesce(v_groups,'[]'::jsonb);
  v_n_corr := coalesce(v_n_corr,0);
  v_n_groups := coalesce(v_n_groups,0);

  ----------------------------------------------------------- ticket rollups
  select bool_or( not (leg->>'leg_valid')::boolean
                  or leg->>'identity_status' <> 'RESOLVED' )
    into v_any_bad
  from jsonb_array_elements(coalesce(v_legs,'[]'::jsonb)) leg;
  v_any_bad := coalesce(v_any_bad,true);

  select max((leg->>'ticket_total_odds')::numeric)
    into v_ticket_odds
  from jsonb_array_elements(coalesce(v_legs,'[]'::jsonb)) leg;

  -- FINDING 8: single snapshot / single percentage
  v_bankroll := v2.fn_parlay_bankroll_pct(p_stake, p_bankroll_snapshot);

  -- FINDING 9: bonus ONLY if explicitly provided; never inferred
  if p_bonus is not null then
    v_bonus := p_bonus; v_bonus_rsn := 'EXPLICIT_BONUS';
  else
    v_bonus := null;    v_bonus_rsn := 'NO_EXPLICIT_BONUS';
  end if;
  v_payout := case when p_stake is not null and v_ticket_odds is not null
                   then p_stake * v_ticket_odds + coalesce(v_bonus,0) end;

  -- FINDING 10: unresolved leg / invalid market / unknown joint => not canonical
  -- Joint probability is ALWAYS unknown (§25, iss038), so a fully-resolved ticket
  -- is still NOT a canonical RETO 13M parlay for EV; it is identity-resolved only.
  if v_any_bad then
    v_status := 'NEEDS_REVIEW'; v_is_canon := false;
    v_canon_rsn := 'UNRESOLVED_OR_INVALID_LEG';
  else
    v_status := 'RESOLVED_NO_JOINT_MODEL'; v_is_canon := false;
    v_canon_rsn := 'JOINT_MODEL_UNAVAILABLE_UNMODELED_CORRELATION';
  end if;

  return jsonb_build_object(
    'decision_time', p_decision,
    'n_legs', jsonb_array_length(coalesce(v_legs,'[]'::jsonb)),
    'legs', coalesce(v_legs,'[]'::jsonb),
    'n_event_groups', v_n_groups,
    'correlated_groups', v_groups,
    'n_correlated_groups', v_n_corr,
    -- FINDING 6: correlation emitted; NEVER "Sin correlación detectada"
    'CORRELATION_STATUS', 'UNMODELED_REQUIRES_JOINT_MODEL',
    'correlation_note',
      'Same-event legs are correlated by definition; joint model unavailable.',
    -- FINDING 6 + iss038 §25: joint NULL; EV_REAL NULL; never 1/ticket_odds
    'joint_probability', null,
    'joint_probability_reason', 'NO_VALIDATED_JOINT_MODEL',
    'EV_REAL', null,
    'EV_REAL_reason', 'REQUIRES_JOINT_PROBABILITY_MODEL',
    -- FINDING 7: no invented house edge
    'house_edge', null,
    'house_edge_reason', 'NO_FAIR_PRICE_BASELINE_REQUIRES_LEG_AND_JOINT_PROBS',
    -- FINDING 8
    'bankroll', v_bankroll,
    'bankroll_pct_count', 1,
    -- FINDING 9
    'ticket_total_odds', v_ticket_odds,
    'bonus', v_bonus,
    'bonus_reason', v_bonus_rsn,
    'payout', v_payout,
    'payout_formula', 'stake*ticket_odds + explicit_bonus (bonus only if present)',
    -- FINDING 10
    'status', v_status,
    'is_canonical_reto13m', v_is_canon,
    'is_canonical_reason', v_canon_rsn
  );
end $$;
comment on function v2.fn_parlay_ticket_structure(jsonb,timestamptz,numeric,numeric,numeric,int) is
  'iss046: set-based batch resolution + correlation tree. joint/EV NULL; single '
  'bankroll pct; explicit-only bonus; NEEDS_REVIEW + is_canonical_reto13m=false '
  'on any unresolved/invalid leg or unknown joint.';

-- ----------------------------------------------------------------------------
-- FINDING 11 (edge layer, OUT OF THIS REPO): the OCR/parse edge function must
-- parallelize per-image OCR and per-leg text parse and emit structured legs
-- (home_raw, away_raw, market_raw, ocr_league, individual/grouped odds,
-- odds_source, intended_date). This SQL resolver already does the DB side in a
-- single set-based pass (no per-leg serial lookups). See report note.
-- ============================================================================
