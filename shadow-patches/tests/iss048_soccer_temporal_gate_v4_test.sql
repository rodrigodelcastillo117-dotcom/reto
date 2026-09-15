-- ============================================================================
-- iss048 — SOCCER COHERENCE / TEMPORAL GATE v4 · branch-only, self-contained
-- ============================================================================
-- Resolves issue #4 comment 5620477307 (5 STOP-SHIP findings on the REAL staged ->
-- Reto13M path) + comment 5620997108 (A: single fn_event_gate_status signature;
-- B: NULL/empty bypass in coherence; C: p_push/ou_line_type/ou_supported persisted).
--
-- Reproduces the auditor's 5 adversarials + the 4 NULL adversarials + the 6-fixture
-- regression and RAISES EXCEPTION on any leak. Self-contained: rebuilds
-- v2.soccer_prediction_v2_staged (with the new columns), public.v_momios_confiables,
-- and the iss036 gate/candidate/analysis views inline, then seeds real staged rows.
--
-- PREREQUISITES (branch-global functions, applied via iss041/iss042/iss043/iss045):
--   v2.fn_dist_from_lambda, v2.fn_matrix_market, v2.fn_total_weights,
--   v2.fn_model_market_discrepancy, v2.fn_event_gate_status (NEW 16-arg signature),
--   and v2.gate_fixture_soccer_cards (the 6 owner fixtures).
-- NO PROD MUTATION · disposable branch only · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
-- Timeline: T0 = 2026-09-01 12:00Z (decision). pregame odds 09:00Z (<=T0, valid).
--   F1 poisoned snapshot 13:00Z. F3 post-decision odds 14:00Z (>T0, must be ignored).
-- ============================================================================

-- ── (0) clean rebuild of the contract surface ───────────────────────────────
drop view if exists v2.v_soccer_daily_canonical  cascade;
drop view if exists v2.v_soccer_daily_candidates cascade;
drop view if exists v2.v_soccer_analysis_all     cascade;
drop view if exists v2.v_soccer_event_gate       cascade;
drop table if exists v2.soccer_prediction_v2_staged cascade;
drop table if exists public.v_momios_confiables      cascade;

create table v2.soccer_prediction_v2_staged (
  espn_event_id text, competition_id int, home_team text, away_team text,
  kickoff timestamptz, decision_time timestamptz, sample_home int, sample_away int, temporal_safe boolean,
  feature_version text, model_version text, calibration_status text,
  p_home numeric, p_draw numeric, p_away numeric, btts_yes numeric, btts_no numeric,
  over_line numeric, p_over numeric, p_under numeric,
  p_push numeric, ou_line_type text, ou_supported boolean,          -- C: persisted O/U settlement
  line_source text, model_status text, model_status_reason text, provenance jsonb,
  score_dist jsonb, top_scores jsonb, feature_snapshot_id uuid, built_at timestamptz default now(),
  primary key (espn_event_id, decision_time, model_version));

create table public.v_momios_confiables (
  espn_event_id text, home_ml numeric, away_ml numeric, draw_ml numeric,
  over_odds numeric, under_odds numeric, over_line numeric,
  snapshot_at timestamptz default now(), bookmaker text, confiable boolean default true);

-- ── (0b) iss036 views recreated inline (mirror of prepared/iss036) ──────────
create or replace view v2.v_soccer_event_gate as
select c.espn_event_id as canonical_event_id, c.decision_time, c.model_version,     -- F1: FULL PK
       g.coherence_ok, g.disc_flag, coalesce(g.suppress,false) as suppress,
       (c.model_status='READY_UNVALIDATED' and coalesce(g.coherence_ok,false) and not coalesce(g.suppress,false)) as top_only_eligible,
       g.gate_reason
from v2.soccer_prediction_v2_staged c
left join lateral (                                                                 -- F3: ML AS-OF decision
  select mc.home_ml, mc.draw_ml, mc.away_ml
  from public.v_momios_confiables mc
  where mc.espn_event_id = c.espn_event_id and mc.confiable is true
    and mc.snapshot_at <= c.decision_time
  order by mc.snapshot_at desc limit 1
) oml on true
left join lateral (                                                                 -- F4: OU AS-OF + EXACT line
  select mc.over_odds, mc.under_odds
  from public.v_momios_confiables mc
  where mc.espn_event_id = c.espn_event_id and mc.confiable is true
    and mc.snapshot_at <= c.decision_time
    and mc.over_line = c.over_line
  order by mc.snapshot_at desc limit 1
) oou on true
left join lateral v2.fn_event_gate_status(                                          -- F2/B: every field checked
  c.score_dist, c.p_home, c.p_draw, c.p_away, c.p_over, c.p_under, c.over_line,
  c.btts_yes, c.btts_no, c.top_scores,
  oml.home_ml, oml.draw_ml, oml.away_ml, oou.over_odds, oou.under_odds
) g on true;

create or replace view v2.v_soccer_analysis_all as
select c.*, gt.coherence_ok, gt.disc_flag, gt.suppress, gt.top_only_eligible, gt.gate_reason
from v2.soccer_prediction_v2_staged c
left join v2.v_soccer_event_gate gt
  on gt.canonical_event_id = c.espn_event_id
 and gt.decision_time    = c.decision_time
 and gt.model_version    = c.model_version
where c.model_status = 'READY_UNVALIDATED';

create or replace view v2.v_soccer_daily_candidates as
select c.espn_event_id as canonical_event_id,
       c.home_team, c.away_team, c.competition_id, c.kickoff, c.decision_time,
       c.model_version, c.feature_snapshot_id as model_snapshot_id,
       cand.canonical_market, cand.canonical_side, cand.canonical_line, cand.canonical_probability,
       cand.canonical_push, cand.canonical_line_type,                               -- F5: OU settlement (NULL for non-OU)
       c.sample_home, c.sample_away
from v2.soccer_prediction_v2_staged c
join v2.v_soccer_event_gate gt
  on gt.canonical_event_id = c.espn_event_id
 and gt.decision_time    = c.decision_time
 and gt.model_version    = c.model_version                                          -- F1: FULL-PK join (no cross-snapshot leak, 1:1)
 and gt.top_only_eligible
cross join lateral (
  values
    ('1X2'::text, 'HOME'::text, null::numeric, c.p_home,    null::numeric, null::text),
    ('1X2',       'DRAW',        null,          c.p_draw,    null,          null),
    ('1X2',       'AWAY',        null,          c.p_away,    null,          null),
    ('BTTS',      'YES',         null,          c.btts_yes,  null,          null),
    ('BTTS',      'NO',          null,          c.btts_no,   null,          null),
    ('OU',        'OVER',        c.over_line,   case when c.over_line is not null then c.p_over end,  c.p_push, c.ou_line_type),
    ('OU',        'UNDER',       c.over_line,   case when c.over_line is not null then c.p_under end, c.p_push, c.ou_line_type)
) cand(canonical_market, canonical_side, canonical_line, canonical_probability, canonical_push, canonical_line_type)
where c.model_status = 'READY_UNVALIDATED'
  and cand.canonical_probability is not null;

-- ── (1) seed the 6 owner fixtures as REAL staged rows (decision_time=T0) ─────
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select f.espn_event_id,2,f.home_team,f.away_team,
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,
   f.over_line,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:'||f.bookmaker,'READY_UNVALIDATED','DC V2 owner fixture',
   jsonb_build_object('odds_is_context_not_preto',true),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from v2.gate_fixture_soccer_cards f
cross join lateral (select v2.fn_dist_from_lambda(f.lambda_home,f.lambda_away,f.over_line,f.rho,coalesce(f.maxg,10)) jd) d;

-- pregame (09:00Z <= T0) real odds for the 6 fixtures, at the EXACT canonical over_line
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
select espn_event_id,odds_home,odds_draw,odds_away,odds_over,odds_under,over_line,
       timestamptz '2026-09-01 09:00:00+00',bookmaker,true
from v2.gate_fixture_soccer_cards;

-- ── (2) adversarial seeds ───────────────────────────────────────────────────

-- F1: SECOND snapshot of PSV (401915422) at decision_time=T0+1h, SAME model_version,
--     p_home poisoned +15 (same score_dist) -> coherence fails on the corrupt snapshot.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select '401915422',2,'PSV Eindhoven','Shakhtar Donetsk',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 13:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric+15,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,
   3.5,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:DraftKings','READY_UNVALIDATED','F1 cross-snapshot poison (+15 p_home, same matrix)',
   jsonb_build_object('adversarial','F1'),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from (select v2.fn_dist_from_lambda(2.289,1.308,3.5,0.0705,10) jd) d;

-- F2: p_home coherent but btts_no +15 AND p_under +15 -> both unchecked-in-v3 fields fail.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select 'F2_UNCHECKED',2,'Unchecked FC','Complement Utd',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric+15,
   2.5,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric+15,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:Test','READY_UNVALIDATED','F2 unchecked poison (btts_no+15, p_under+15)',
   jsonb_build_object('adversarial','F2'),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from (select v2.fn_dist_from_lambda(1.35,1.606,2.5,0.0705,10) jd) d;
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
select 'F2_UNCHECKED',                                                     -- fair (OK) odds: coherence, not disc, must exclude
   round(100.0/(d.jd->>'p_home')::numeric,3), round(100.0/(d.jd->>'p_draw')::numeric,3), round(100.0/(d.jd->>'p_away')::numeric,3),
   round(100.0/(d.jd->>'p_over')::numeric,3), round(100.0/(d.jd->>'p_under')::numeric,3),
   2.5, timestamptz '2026-09-01 09:00:00+00','Test',true
from (select v2.fn_dist_from_lambda(1.35,1.606,2.5,0.0705,10) jd) d;

-- F3: coherent event OK at T0; a POST-decision odds row (14:00Z) would flip it to
--     QUALITY_DOWNGRADE, but the AS-OF cutoff must ignore it.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select 'F3_TIMEDRIFT',2,'Timedrift FC','Asof Roma',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,
   2.5,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:Test','READY_UNVALIDATED','F3 temporal drift probe',
   jsonb_build_object('adversarial','F3'),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from (select v2.fn_dist_from_lambda(1.37,1.444,2.5,0.0705,10) jd) d;
-- valid PREGAME odds (09:00Z): fair -> disc OK at T0
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
select 'F3_TIMEDRIFT',
   round(100.0/(d.jd->>'p_home')::numeric,3), round(100.0/(d.jd->>'p_draw')::numeric,3), round(100.0/(d.jd->>'p_away')::numeric,3),
   round(100.0/(d.jd->>'p_over')::numeric,3), round(100.0/(d.jd->>'p_under')::numeric,3),
   2.5, timestamptz '2026-09-01 09:00:00+00','Test',true
from (select v2.fn_dist_from_lambda(1.37,1.444,2.5,0.0705,10) jd) d;
-- POST-decision odds (14:00Z > T0): extreme (would force QUALITY_DOWNGRADE if read)
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
values ('F3_TIMEDRIFT',9.00,7.00,1.20,8.00,1.10,2.5, timestamptz '2026-09-01 14:00:00+00','Test',true);

-- F4: canonical over_line 3.5; the latest valid (<=T0) OU odds exist ONLY at over_line 5.5.
--     The EXACT-line lateral must find NO 3.5 OU odds -> total diagnostic unavailable.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select 'F4_WRONGLINE',2,'Wrongline FC','Fivefive Leipzig',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,
   3.5,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:Test','READY_UNVALIDATED','F4 wrong-line probe',
   jsonb_build_object('adversarial','F4'),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from (select v2.fn_dist_from_lambda(1.879,1.034,3.5,0.0705,10) jd) d;
-- valid pregame row: fair ML (OK winner) but OU quoted at the WRONG line 5.5 (over unlikely)
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
select 'F4_WRONGLINE',
   round(100.0/(d.jd->>'p_home')::numeric,3), round(100.0/(d.jd->>'p_draw')::numeric,3), round(100.0/(d.jd->>'p_away')::numeric,3),
   8.00, 1.10, 5.5, timestamptz '2026-09-01 09:00:00+00','Test',true
from (select v2.fn_dist_from_lambda(1.879,1.034,3.5,0.0705,10) jd) d;

-- F5: whole (4.0), quarter (2.25), unsupported (3.1) lines. Fair (OK) odds each.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select v.eid,2,v.eid,'Opponent',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,
   v.ol,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:Test','READY_UNVALIDATED','F5 line-type probe',
   jsonb_build_object('adversarial','F5'),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from (values ('F5_WHOLE',1.9,1.5,4.0),('F5_QUARTER',1.4,1.3,2.25),('F5_UNSUP',1.6,1.3,3.1)) v(eid,lh,la,ol)
cross join lateral (select v2.fn_dist_from_lambda(v.lh::numeric,v.la::numeric,v.ol::numeric,-0.05,10) jd) d;
-- fair odds for F5 events (ML always; OU at the exact line only when supported)
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
select v.eid,
   round(100.0/(d.jd->>'p_home')::numeric,3), round(100.0/(d.jd->>'p_draw')::numeric,3), round(100.0/(d.jd->>'p_away')::numeric,3),
   case when (d.jd->>'p_over') is not null then round(100.0/(d.jd->>'p_over')::numeric,3) end,
   case when (d.jd->>'p_under') is not null then round(100.0/(d.jd->>'p_under')::numeric,3) end,
   v.ol, timestamptz '2026-09-01 09:00:00+00','Test',true
from (values ('F5_WHOLE',1.9,1.5,4.0),('F5_QUARTER',1.4,1.3,2.25),('F5_UNSUP',1.6,1.3,3.1)) v(eid,lh,la,ol)
cross join lateral (select v2.fn_dist_from_lambda(v.lh::numeric,v.la::numeric,v.ol::numeric,-0.05,10) jd) d;

-- Regression: single-row corrupt p_home (+15) with balanced odds -> excluded, visible.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select 'CORRUPT_ROW',2,'Corrupt FC','Poison United',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   (d.jd->>'p_home')::numeric+15,(d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,(d.jd->>'btts_no')::numeric,
   2.5,(d.jd->>'p_over')::numeric,(d.jd->>'p_under')::numeric,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:Test','READY_UNVALIDATED','regression: poisoned p_home',
   jsonb_build_object('adversarial','regression'),d.jd->'dist',d.jd->'top_scores',gen_random_uuid()
from (select v2.fn_dist_from_lambda(1.35,1.606,2.5,0.0705,10) jd) d;
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
values ('CORRUPT_ROW',2.70,3.55,2.55,1.645,2.25,2.5, timestamptz '2026-09-01 09:00:00+00','Test',true);

-- B: NULL/empty bypass adversarials — one field NULL each, everything else coherent.
--    Each must be visible in analysis (READY) but EXCLUDED from candidates/TOP_ONLY.
insert into v2.soccer_prediction_v2_staged
  (espn_event_id,competition_id,home_team,away_team,kickoff,decision_time,sample_home,sample_away,temporal_safe,
   feature_version,model_version,calibration_status,p_home,p_draw,p_away,btts_yes,btts_no,
   over_line,p_over,p_under,p_push,ou_line_type,ou_supported,line_source,model_status,model_status_reason,provenance,
   score_dist,top_scores,feature_snapshot_id)
select v.eid,2,v.eid,'NullOpp',
   timestamptz '2026-09-02 12:00:00+00', timestamptz '2026-09-01 12:00:00+00',30,30,true,
   'fv1','dc_v2','UNVALIDATED',
   case when v.eid='NULL_PHOME'     then null else (d.jd->>'p_home')::numeric end,
   (d.jd->>'p_draw')::numeric,(d.jd->>'p_away')::numeric,
   (d.jd->>'btts_yes')::numeric,
   case when v.eid='NULL_BTTSNO'    then null else (d.jd->>'btts_no')::numeric end,
   2.5,(d.jd->>'p_over')::numeric,
   case when v.eid='NULL_PUNDER'    then null else (d.jd->>'p_under')::numeric end,
   (d.jd->>'p_push')::numeric,(d.jd->>'ou_line_type'),(d.jd->>'ou_supported')::boolean,
   'v_momios_confiables:Test','READY_UNVALIDATED','B NULL bypass probe',
   jsonb_build_object('adversarial','B_null'),
   d.jd->'dist',
   case when v.eid='NULL_TOPSCORES' then null else d.jd->'top_scores' end,
   gen_random_uuid()
from (values ('NULL_PHOME'),('NULL_BTTSNO'),('NULL_PUNDER'),('NULL_TOPSCORES')) v(eid)
cross join lateral (select v2.fn_dist_from_lambda(1.37,1.444,2.5,0.0705,10) jd) d;
insert into public.v_momios_confiables (espn_event_id,home_ml,draw_ml,away_ml,over_odds,under_odds,over_line,snapshot_at,bookmaker,confiable)
select v.eid,
   round(100.0/(d.jd->>'p_home')::numeric,3), round(100.0/(d.jd->>'p_draw')::numeric,3), round(100.0/(d.jd->>'p_away')::numeric,3),
   round(100.0/(d.jd->>'p_over')::numeric,3), round(100.0/(d.jd->>'p_under')::numeric,3),
   2.5, timestamptz '2026-09-01 09:00:00+00','Test',true
from (values ('NULL_PHOME'),('NULL_BTTSNO'),('NULL_PUNDER'),('NULL_TOPSCORES')) v(eid)
cross join lateral (select v2.fn_dist_from_lambda(1.37,1.444,2.5,0.0705,10) jd) d;

-- ── (3) ASSERTIONS (RAISE EXCEPTION on any leak) ────────────────────────────
do $$
declare n int; m int; b boolean; t text; r record;
  T0 constant timestamptz := timestamptz '2026-09-01 12:00:00+00';
  Tc constant timestamptz := timestamptz '2026-09-01 13:00:00+00';
begin
  ----------------------------------------------------------------------------
  -- A: exactly ONE fn_event_gate_status signature (no v3 overload survives).
  ----------------------------------------------------------------------------
  select count(*) into n from pg_proc p join pg_namespace np on np.oid=p.pronamespace
   where np.nspname='v2' and p.proname='fn_event_gate_status';
  if n <> 1 then raise exception 'FAIL A: fn_event_gate_status has % signatures (expected exactly 1)', n; end if;
  raise notice 'PASS A: exactly one fn_event_gate_status signature';

  ----------------------------------------------------------------------------
  -- F1: cross-snapshot poison must NOT leak; eligible snapshot appears once.
  ----------------------------------------------------------------------------
  select count(*) into n from v2.v_soccer_daily_candidates
    where canonical_event_id='401915422' and decision_time = Tc;               -- cross_snapshot_poison_leaked_count
  if n <> 0 then raise exception 'FAIL F1: cross_snapshot_poison_leaked_count=% (expected 0)', n; end if;
  select count(*) into m from v2.v_soccer_daily_candidates
    where canonical_event_id='401915422' and decision_time = T0;
  if m <> 7 then raise exception 'FAIL F1: eligible T0 PSV snapshot candidate rows=% (expected 7)', m; end if;
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id='401915422';
  if n <> 7 then raise exception 'FAIL F1: PSV total candidate rows=% (N×M duplication? expected 7)', n; end if;
  if not exists (select 1 from v2.v_soccer_analysis_all
                 where espn_event_id='401915422' and decision_time=Tc and coherence_ok=false) then
    raise exception 'FAIL F1: corrupt PSV snapshot not visible/flagged in analysis';
  end if;
  raise notice 'PASS F1: cross_snapshot_poison_leaked_count=0; eligible T0 snapshot present once (7 rows, no N×M dup); corrupt snapshot visible in analysis';

  ----------------------------------------------------------------------------
  -- F2: btts_no + p_under poison both caught -> excluded, both reasons present.
  ----------------------------------------------------------------------------
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id='F2_UNCHECKED';
  if n <> 0 then raise exception 'FAIL F2: unchecked_poison_leaked_count=% (expected 0)', n; end if;
  select coherence_ok, gate_reason into b, t from v2.v_soccer_analysis_all where espn_event_id='F2_UNCHECKED';
  if b is not false then raise exception 'FAIL F2: coherence_ok=% (expected false)', b; end if;
  if position('BTTS_NO' in coalesce(t,'')) = 0 or position('OU_UNDER' in coalesce(t,'')) = 0 then
    raise exception 'FAIL F2: reasons missing BTTS_NO/OU_UNDER (got %)', t; end if;
  raise notice 'PASS F2: unchecked_poison leaked btts_no=0 / p_under=0; both flagged (%)', t;

  ----------------------------------------------------------------------------
  -- F3: post-decision odds must NOT change eligibility (AS-OF cutoff).
  ----------------------------------------------------------------------------
  select top_only_eligible, disc_flag into b, t from v2.v_soccer_event_gate where canonical_event_id='F3_TIMEDRIFT';
  if b is not true then raise exception 'FAIL F3: F3 not eligible (top_only_eligible=%, disc_flag=%)', b, t; end if;
  if t <> 'OK' then raise exception 'FAIL F3: disc_flag=% (expected OK; post-decision odds leaked into diagnostic)', t; end if;
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id='F3_TIMEDRIFT';
  if n = 0 then raise exception 'FAIL F3: F3 absent from candidates'; end if;
  -- prove the ignored 14:00Z row IS genuinely adverse (would suppress if it had been read)
  select suppress into b from v2.fn_model_market_discrepancy(36.6,23.5,39.9,53.4, 9.00,7.00,1.20, 8.00,1.10);
  if b is not true then raise exception 'FAIL F3: control probe — post-decision odds are not adverse (suppress=%)', b; end if;
  raise notice 'PASS F3: market_time_drift eligibility UNCHANGED (eligible, disc OK) though post-decision odds would suppress';

  ----------------------------------------------------------------------------
  -- F4: wrong-line (5.5) odds must NOT be used for the 3.5 total diagnostic.
  ----------------------------------------------------------------------------
  select top_only_eligible, disc_flag into b, t from v2.v_soccer_event_gate where canonical_event_id='F4_WRONGLINE';
  if b is not true then raise exception 'FAIL F4: F4 not eligible (top_only_eligible=%, disc_flag=%)', b, t; end if;
  if t = 'QUALITY_DOWNGRADE' then raise exception 'FAIL F4: false QUALITY_DOWNGRADE from a wrong-line price'; end if;
  select count(*) into n from public.v_momios_confiables
    where espn_event_id='F4_WRONGLINE' and confiable and snapshot_at<=T0 and over_line=3.5;
  if n <> 0 then raise exception 'FAIL F4: unexpected exact-line 3.5 odds exist (n=%)', n; end if;
  -- prove the 5.5 price WOULD suppress if compared to the model P_OVER@3.5
  select suppress into b from v2.fn_model_market_discrepancy(57.9,20.9,21.3,33.3, 1.73,4.78,4.69, 8.00,1.10);
  if b is not true then raise exception 'FAIL F4: control probe — 5.5 price not adverse to P_OVER@3.5 (suppress=%)', b; end if;
  raise notice 'PASS F4: wrong-line (5.5) price ignored; F4 eligible, total diagnostic unavailable, no false QUALITY_DOWNGRADE';

  ----------------------------------------------------------------------------
  -- F5: push mass persisted; line types; unsupported fail-close; candidate cols.
  ----------------------------------------------------------------------------
  select p_push, ou_line_type into m, t from v2.soccer_prediction_v2_staged where espn_event_id='F5_WHOLE';
  if not (m > 0 and t = 'WHOLE') then raise exception 'FAIL F5 whole: p_push=% ou_line_type=% (expected >0, WHOLE)', m, t; end if;
  select p_push, ou_line_type into m, t from v2.soccer_prediction_v2_staged where espn_event_id='F5_QUARTER';
  if not (m > 0 and t = 'QUARTER') then raise exception 'FAIL F5 quarter: p_push=% ou_line_type=% (expected >0, QUARTER)', m, t; end if;
  select count(*) into n from v2.soccer_prediction_v2_staged
    where espn_event_id='F5_UNSUP' and p_over is null and p_under is null and p_push is null
      and ou_line_type='UNSUPPORTED' and ou_supported=false;
  if n <> 1 then raise exception 'FAIL F5 unsupported: 3.1 line not fail-closed (n=%)', n; end if;
  -- candidate OU rows expose canonical_push + canonical_line_type (=staged values)
  select canonical_push, canonical_line_type into m, t from v2.v_soccer_daily_candidates
    where canonical_event_id='F5_WHOLE' and canonical_market='OU' and canonical_side='OVER';
  if not (m > 0 and t='WHOLE') then raise exception 'FAIL F5: candidate OU canonical_push=% canonical_line_type=% (expected >0, WHOLE)', m, t; end if;
  if exists (select 1 from v2.v_soccer_daily_candidates
             where canonical_event_id='F5_WHOLE' and canonical_market='1X2' and canonical_push is not null) then
    raise exception 'FAIL F5: non-OU candidate exposes canonical_push (must be NULL)'; end if;
  -- unsupported line: no OU candidate, but event still eligible for 1X2/BTTS
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id='F5_UNSUP' and canonical_market='OU';
  if n <> 0 then raise exception 'FAIL F5: unsupported line emitted an OU candidate (n=%)', n; end if;
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id='F5_UNSUP';
  if n = 0 then raise exception 'FAIL F5: unsupported-line event lost all candidates (1X2/BTTS should remain)'; end if;
  raise notice 'PASS F5: p_push persisted (WHOLE / QUARTER >0), 3.1 fail-closed (p_over/p_under/p_push NULL), candidate settlement columns exposed';

  ----------------------------------------------------------------------------
  -- B: NULL/empty bypass — each excluded from candidates, visible in analysis.
  ----------------------------------------------------------------------------
  for r in select * from (values
      ('NULL_PHOME','NULL_FIELD:p_home'),
      ('NULL_BTTSNO','NULL_FIELD:btts_no'),
      ('NULL_PUNDER','NULL_FIELD:p_under'),
      ('NULL_TOPSCORES','NULL_FIELD:top_scores')) v(eid, reason)
  loop
    select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id=r.eid;
    if n <> 0 then raise exception 'FAIL B: % leaked into candidates (n=%)', r.eid, n; end if;
    select coherence_ok, gate_reason into b, t from v2.v_soccer_analysis_all where espn_event_id=r.eid;
    if b is not false then raise exception 'FAIL B: % coherence_ok=% (expected false)', r.eid, b; end if;
    if position(r.reason in coalesce(t,'')) = 0 then raise exception 'FAIL B: % missing reason % (got %)', r.eid, r.reason, t; end if;
  end loop;
  raise notice 'PASS B: 4 NULL/empty adversarials excluded from TOP_ONLY, visible+flagged in analysis';

  ----------------------------------------------------------------------------
  -- Regression: 6 owner fixtures + single-row corrupt p_home.
  ----------------------------------------------------------------------------
  select count(*) into n from v2.v_soccer_daily_candidates where canonical_event_id in ('401915442','401915443');
  if n <> 0 then raise exception 'FAIL REG: ManU/Bayern leaked into candidates (n=%)', n; end if;
  select count(distinct espn_event_id) into n from v2.v_soccer_analysis_all where espn_event_id in ('401915442','401915443');
  if n <> 2 then raise exception 'FAIL REG: ManU/Bayern not both visible in analysis (n=%)', n; end if;
  select count(distinct canonical_event_id) into n from v2.v_soccer_daily_candidates
    where canonical_event_id in ('401915422','401915440','401915441','401915444');
  if n <> 4 then raise exception 'FAIL REG: eligible owner fixtures present=% (expected 4)', n; end if;
  if exists (select 1 from v2.v_soccer_daily_candidates where canonical_event_id='CORRUPT_ROW') then
    raise exception 'FAIL REG: single-row corrupt p_home reached candidates'; end if;
  if not exists (select 1 from v2.v_soccer_analysis_all where espn_event_id='CORRUPT_ROW' and coherence_ok=false) then
    raise exception 'FAIL REG: corrupt row not visible/flagged in analysis'; end if;
  raise notice 'PASS REG: ManU/Bayern suppressed + other 4 eligible; single-row corrupt p_home excluded, visible';

  raise notice '==== iss048 v4 — ALL ASSERTIONS PASSED (F1..F5 + A + B + regression) ====';
end $$;
