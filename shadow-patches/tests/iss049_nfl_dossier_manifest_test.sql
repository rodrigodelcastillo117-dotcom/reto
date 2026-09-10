-- ============================================================================
-- iss049 TEST — NFL DOSSIER MANIFEST PARITY (issue #4 comment 5620196530)
-- Self-contained adversarial test: RAISE EXCEPTION on ANY leak.
-- Asserts, mirroring the soccer contract but for the NFL NO_OWN_MODEL brain:
--   * modelo_p_reto => role NO_OWN_MODEL, available=false, effective_value NULL,
--     used_in_p_reto=false, missing_reason explains NO_OWN_MODEL.
--   * NO row has used_in_p_reto=true (no own model exists to feed P_RETO).
--   * market / FPI never role=MODEL_ACTIVE (roles restricted to the NFL set).
--   * temporal rule: a post-decision capture (FPI/lesiones/odds refreshed AFTER the
--     decision) is excluded (temporally_safe=false, post_decision_capture=true) and
--     the valid earlier capture is NOT deleted; an as_of<=decision source is included.
--   * NO_ASOF sources fail-closed (data_asof NULL, freshness NO_ASOF, not used).
--   * event 401872657 renders FULL team names "San Francisco 49ers @ Los Angeles Rams"
--     (never "SF @ LAR").
--   * neutral-site handling: the LA Rams home stadium (SoFi) is NEVER substituted.
--   * decision_time is the real capture, never kickoff; no capture => NO_DECISION_TIME.
-- Branch-only. Requires iss049 prepared (v2.fn_nfl_dossier_manifest) applied first.
-- ============================================================================

create schema if not exists v2;

-- ── minimal table skeletons (real prod columns the function touches) ──
create table if not exists public.nfl_partidos(
  espn_event_id text primary key, temporada int, semana int,
  home_team text, away_team text, home_id text, away_id text,
  home_abrev text, away_abrev text, home_record text, away_record text,
  p_home numeric, p_away numeric, estadio text, techado boolean,
  temperatura int, clima_cond text, actualizado timestamptz, fecha timestamptz);
create table if not exists public.nfl_predicciones_historial(
  id bigserial, espn_event_id text, capturado_at timestamptz, saque timestamptz);
create table if not exists public.nfl_odds_snapshots(
  id bigserial, espn_event_id text, casa text, snapshot_at timestamptz);
create table if not exists public.nfl_fpi(
  espn_team_id text, temporada int, actualizado timestamptz);
create table if not exists public.nfl_lesiones_semana(
  temporada int, semana int, equipo text, cargado_at timestamptz);
create table if not exists public.nfl_depth_chart(
  temporada int, equipo text, cargado_at timestamptz);
create table if not exists public.nfl_h2h(
  team_a text, team_b text, actualizado timestamptz);
create table if not exists public.nfl_bye_weeks(
  temporada int, equipo_abrev text);
create table if not exists public.nfl_standings(
  temporada int, equipo text);

-- ── seed: REAL event 401872657 (values read from prod, SELECT-only) ──
delete from public.nfl_partidos where espn_event_id in ('401872657','NODEC');
delete from public.nfl_predicciones_historial where espn_event_id in ('401872657','NODEC');
delete from public.nfl_odds_snapshots where espn_event_id in ('401872657','NODEC');
delete from public.nfl_fpi where espn_team_id in ('14','25');
delete from public.nfl_lesiones_semana where temporada=2026 and semana=1 and equipo in ('LAR','SF');
delete from public.nfl_depth_chart where temporada=2026 and equipo in ('LAR','SF');
delete from public.nfl_bye_weeks where temporada=2026 and equipo_abrev in ('LAR','SF');
delete from public.nfl_standings where temporada=2026 and equipo in ('Los Angeles Rams','San Francisco 49ers');
delete from public.nfl_h2h where (team_a,team_b) in (('14','25'),('25','14'));

-- FULL names as stored in prod; estadio/techado NULL exactly as in prod (Melbourne neutral site not captured).
insert into public.nfl_partidos(espn_event_id,temporada,semana,home_team,away_team,home_id,away_id,
  home_abrev,away_abrev,home_record,away_record,p_home,p_away,estadio,techado,temperatura,clima_cond,actualizado,fecha)
values('401872657',2026,1,'Los Angeles Rams','San Francisco 49ers','14','25','LAR','SF','0-0','0-0',
  0.6369,0.3631,null,null,null,null, timestamptz '2026-09-08 20:00+00', timestamptz '2026-09-11 00:35+00');
-- event with NO historial and no arg => NO_DECISION_TIME fail-closed
insert into public.nfl_partidos(espn_event_id,temporada,semana,home_team,away_team,home_id,away_id,home_abrev,away_abrev,fecha)
values('NODEC',2026,1,'Team H','Team A','99','98','TH','TA', timestamptz '2026-12-01 18:00+00');

-- immutable per-run captures (real capturado_at from prod). Latest = decision authority.
insert into public.nfl_predicciones_historial(espn_event_id,capturado_at,saque) values
 ('401872657', timestamptz '2026-09-01 00:47:00.19+00', timestamptz '2026-09-11 00:35+00'),
 ('401872657', timestamptz '2026-09-04 15:47:00.36+00', timestamptz '2026-09-11 00:35+00'),
 ('401872657', timestamptz '2026-09-06 00:47:00.31+00', timestamptz '2026-09-11 00:35+00'),
 ('401872657', timestamptz '2026-09-07 00:47:00.34+00', timestamptz '2026-09-11 00:35+00'),
 ('401872657', timestamptz '2026-09-09 00:47:00.47+00', timestamptz '2026-09-11 00:35+00');  -- <= this is decision_time

-- odds snapshots: one prematch (<=dec) and one post-decision (>dec)
insert into public.nfl_odds_snapshots(espn_event_id,casa,snapshot_at) values
 ('401872657','DraftKings', timestamptz '2026-09-08 10:00+00'),   -- prematch
 ('401872657','DraftKings', timestamptz '2026-09-10 10:00+00');   -- post-decision drift

-- FPI overwrite: only a POST-decision refresh exists (real prod actualizado)
insert into public.nfl_fpi(espn_team_id,temporada,actualizado) values
 ('14',2026, timestamptz '2026-09-10 12:31:01.51+00'),
 ('25',2026, timestamptz '2026-09-10 12:31:01.51+00');
-- injuries: post-decision as_of (real prod cargado_at)
insert into public.nfl_lesiones_semana(temporada,semana,equipo,cargado_at) values
 (2026,1,'LAR', timestamptz '2026-09-09 17:07:05.81+00'),
 (2026,1,'SF',  timestamptz '2026-09-09 17:07:05.81+00');
-- depth chart: pre-decision as_of (real prod cargado_at) -> valid prematch context
insert into public.nfl_depth_chart(temporada,equipo,cargado_at) values
 (2026,'LAR', timestamptz '2026-08-31 21:10:20.04+00'),
 (2026,'SF',  timestamptz '2026-08-31 21:10:20.04+00');
-- NO_ASOF context that merely exists
insert into public.nfl_bye_weeks(temporada,equipo_abrev) values (2026,'LAR'),(2026,'SF');
insert into public.nfl_standings(temporada,equipo) values (2026,'Los Angeles Rams'),(2026,'San Francisco 49ers');
-- nfl_h2h intentionally has NO row for 14/25 (matches prod: h2h unavailable)

-- ============================================================================
-- A) REAL EVENT 401872657, decision = latest capture (no arg)
-- ============================================================================
do $$
declare
  r record; m record;
  n_used int:=0; n_bad_role int:=0; n_rows int:=0;
  v_dec timestamptz; v_saque timestamptz := timestamptz '2026-09-11 00:35+00';
begin
  for r in select * from v2.fn_nfl_dossier_manifest('401872657') loop
    n_rows := n_rows+1;
    v_dec := r.decision_time;
    -- role must be from the NFL set; MODEL_ACTIVE must NEVER appear
    if r.role not in ('NO_OWN_MODEL','MARKET','CONTEXT_ONLY','AVAILABLE_NOT_USED') then
      n_bad_role := n_bad_role+1; end if;
    if r.role like 'MODEL_ACTIVE%' then raise exception 'FAIL A: % tiene role MODEL_ACTIVE (prohibido en NFL)', r.source_name; end if;
    -- nothing may feed P_RETO (no own model)
    if r.used_in_p_reto then n_used := n_used+1; end if;
    -- NFL never carries own-model traceability
    if r.effective_value is not null or r.feature_snapshot_id is not null
       or r.feature_version is not null or r.max_source_event_time is not null then
      raise exception 'FAIL A: % lleva rastro de modelo propio (eff/snapshot) inexistente en NFL', r.source_name; end if;
    -- temporal invariants
    if r.temporally_safe and (r.data_asof is null or r.data_asof>r.decision_time) then
      raise exception 'FAIL A: % temporally_safe con as_of inválido', r.source_name; end if;
    if r.post_decision_capture is null then raise exception 'FAIL A: % post_decision_capture NULL', r.source_name; end if;
    -- decision_time is a real capture, NEVER kickoff
    if r.decision_time = v_saque then raise exception 'FAIL A: decision_time == kickoff (prohibido)'; end if;
    -- neutral-site: the LA Rams home stadium must NEVER be substituted anywhere
    if r.provenance ilike '%SoFi%' or r.missing_reason ilike '%SoFi%' then
      raise exception 'FAIL A: % sustituye el estadio local (SoFi) en sede neutral', r.source_name; end if;
  end loop;
  if n_rows=0 then raise exception 'FAIL A: manifest vacío'; end if;
  if n_bad_role>0 then raise exception 'FAIL A: % roles inválidos', n_bad_role; end if;
  if n_used>0 then raise exception 'FAIL A: % filas con used_in_p_reto=true (NFL no tiene modelo propio)', n_used; end if;
  if v_dec <> timestamptz '2026-09-09 00:47:00.47+00' then
    raise exception 'FAIL A: decision_time=% (esperaba la última captura 2026-09-09 00:47)', v_dec; end if;

  -- A.model row
  select * into m from v2.fn_nfl_dossier_manifest('401872657') where source_name='modelo_p_reto';
  if m.role<>'NO_OWN_MODEL' then raise exception 'FAIL A: model role=% (esperaba NO_OWN_MODEL)', m.role; end if;
  if m.available then raise exception 'FAIL A: model available=true'; end if;
  if m.used_in_p_reto then raise exception 'FAIL A: model used_in_p_reto=true'; end if;
  if m.effective_value is not null then raise exception 'FAIL A: model effective_value no es NULL'; end if;
  if m.freshness_status<>'NO_OWN_MODEL' then raise exception 'FAIL A: model freshness=%', m.freshness_status; end if;
  if m.missing_reason not ilike '%no tiene modelo%' then raise exception 'FAIL A: model missing_reason no explica NO_OWN_MODEL: %', m.missing_reason; end if;
  -- FULL team names surfaced, NOT abbreviations
  if m.provenance not like '%San Francisco 49ers @ Los Angeles Rams%' then
    raise exception 'FAIL A: model no muestra nombres completos: %', m.provenance; end if;
  if m.provenance like '%SF @ LAR%' then raise exception 'FAIL A: model usa abreviaturas SF @ LAR'; end if;

  raise notice 'PASS A: % filas, 0 used_in_p_reto, model NO_OWN_MODEL, decision=% (no kickoff), nombres completos', n_rows, v_dec;
end $$;

-- ============================================================================
-- A2) matchup + neutral-site venue/weather rows
-- ============================================================================
do $$
declare mm record; vr record; cl record;
begin
  select * into mm from v2.fn_nfl_dossier_manifest('401872657') where source_name='matchup';
  if mm.provenance not like '%San Francisco 49ers @ Los Angeles Rams%' then
    raise exception 'FAIL A2: matchup sin nombres completos: %', mm.provenance; end if;
  if mm.provenance like '%SF @ LAR%' then raise exception 'FAIL A2: matchup abreviado'; end if;

  select * into vr from v2.fn_nfl_dossier_manifest('401872657') where source_name='venue_roof';
  if vr.role<>'AVAILABLE_NOT_USED' then raise exception 'FAIL A2: venue_roof role=% (esperaba AVAILABLE_NOT_USED)', vr.role; end if;
  if vr.available then raise exception 'FAIL A2: venue_roof available=true (estadio es NULL en sede neutral)'; end if;
  if vr.data_asof is not null then raise exception 'FAIL A2: venue_roof inventó as_of'; end if;
  if vr.freshness_status<>'NO_ASOF' then raise exception 'FAIL A2: venue_roof freshness=%', vr.freshness_status; end if;
  if vr.missing_reason not ilike '%neutral%' then raise exception 'FAIL A2: venue_roof no marca sede neutral: %', vr.missing_reason; end if;

  select * into cl from v2.fn_nfl_dossier_manifest('401872657') where source_name='clima';
  if cl.available then raise exception 'FAIL A2: clima available=true (no debe usar clima de ciudad local en sede neutral)'; end if;
  if cl.data_asof is not null then raise exception 'FAIL A2: clima inventó as_of'; end if;
  if cl.role<>'AVAILABLE_NOT_USED' then raise exception 'FAIL A2: clima role=%', cl.role; end if;

  raise notice 'PASS A2: matchup nombres completos; venue/clima neutral-safe (no sustituye SoFi/ciudad local)';
end $$;

-- ============================================================================
-- A3) temporal drift on REAL event: post-decision captures excluded, earlier kept
-- ============================================================================
do $$
declare fpi record; les record; dep record; odd record;
begin
  select * into fpi from v2.fn_nfl_dossier_manifest('401872657') where source_name='fpi_opinion';
  if fpi.available then raise exception 'FAIL A3: fpi_opinion available (sólo hay refresh post-decisión)'; end if;
  if fpi.temporally_safe then raise exception 'FAIL A3: fpi_opinion temporally_safe con captura post-decisión'; end if;
  if not fpi.post_decision_capture then raise exception 'FAIL A3: fpi_opinion no marca post_decision_capture'; end if;
  if fpi.used_in_p_reto then raise exception 'FAIL A3: fpi_opinion used_in_p_reto (FPI nunca es P_RETO)'; end if;
  if fpi.role='CONTEXT_ONLY' then raise exception 'FAIL A3: fpi_opinion CONTEXT_ONLY con captura post-decisión'; end if;

  select * into les from v2.fn_nfl_dossier_manifest('401872657') where source_name='lesiones';
  if les.temporally_safe or not les.post_decision_capture then
    raise exception 'FAIL A3: lesiones (cargado post-decisión) no excluidas'; end if;

  -- depth chart as_of is PRE-decision -> included as valid prematch context
  select * into dep from v2.fn_nfl_dossier_manifest('401872657') where source_name='depth_chart';
  if not dep.temporally_safe then raise exception 'FAIL A3: depth_chart pre-decisión no incluido'; end if;
  if dep.role<>'CONTEXT_ONLY' then raise exception 'FAIL A3: depth_chart role=% (esperaba CONTEXT_ONLY)', dep.role; end if;
  if dep.post_decision_capture then raise exception 'FAIL A3: depth_chart marcado post_decision erróneamente'; end if;
  if dep.used_in_p_reto then raise exception 'FAIL A3: depth_chart used_in_p_reto (nada alimenta P_RETO en NFL)'; end if;

  -- odds: earlier prematch snapshot present + as_of, later one flagged post-decision (drift)
  select * into odd from v2.fn_nfl_dossier_manifest('401872657') where source_name='odds_snapshot';
  if odd.data_asof<>timestamptz '2026-09-08 10:00+00' then
    raise exception 'FAIL A3: odds as_of=% (esperaba captura prematch 09-08)', odd.data_asof; end if;
  if not odd.post_decision_capture then raise exception 'FAIL A3: odds no marca drift post-decisión'; end if;

  raise notice 'PASS A3: FPI/lesiones/odds post-decisión excluidas; depth prematch incluido; captura prematch preservada';
end $$;

-- ============================================================================
-- A4) NO_ASOF sources fail-closed
-- ============================================================================
do $$
declare r record; n int:=0;
begin
  for r in select * from v2.fn_nfl_dossier_manifest('401872657')
           where source_name in ('puntos_espn','clima','venue_roof','h2h','descanso_bye','standings','record') loop
    n := n+1;
    if r.data_asof is not null then raise exception 'FAIL A4: % inventó as_of', r.source_name; end if;
    if r.freshness_status<>'NO_ASOF' then raise exception 'FAIL A4: % freshness=% (esperaba NO_ASOF)', r.source_name, r.freshness_status; end if;
    if r.temporally_safe then raise exception 'FAIL A4: % temporally_safe sin as_of', r.source_name; end if;
    if r.used_in_p_reto then raise exception 'FAIL A4: % used_in_p_reto', r.source_name; end if;
    if r.role<>'AVAILABLE_NOT_USED' then raise exception 'FAIL A4: % role=% (esperaba AVAILABLE_NOT_USED)', r.source_name, r.role; end if;
  end loop;
  if n<7 then raise exception 'FAIL A4: sólo % de 7 fuentes NO_ASOF presentes', n; end if;
  raise notice 'PASS A4: % fuentes NO_ASOF fail-closed', n;
end $$;

-- ============================================================================
-- A5) motor_nfl quarantine marker present and inert
-- ============================================================================
do $$
declare q record;
begin
  select * into q from v2.fn_nfl_dossier_manifest('401872657') where source_name='motor_nfl_quarantine';
  if q.source_name is null then raise exception 'FAIL A5: falta marcador de cuarentena motor_nfl'; end if;
  if q.used_in_p_reto or q.temporally_safe then raise exception 'FAIL A5: motor_nfl no está inerte'; end if;
  if q.role<>'AVAILABLE_NOT_USED' then raise exception 'FAIL A5: motor_nfl role=%', q.role; end if;
  raise notice 'PASS A5: motor_nfl en cuarentena, no alimenta el dossier';
end $$;

-- ============================================================================
-- B) NO_DECISION_TIME fail-closed (no historial, no arg) — never kickoff
-- ============================================================================
do $$
declare r record; n int:=0;
begin
  for r in select * from v2.fn_nfl_dossier_manifest('NODEC') loop
    n := n+1;
    if r.freshness_status<>'NO_DECISION_TIME' then raise exception 'FAIL B: freshness=% (esperaba NO_DECISION_TIME)', r.freshness_status; end if;
    if r.used_in_p_reto then raise exception 'FAIL B: used_in_p_reto en fail-closed'; end if;
    if r.decision_time is not null then raise exception 'FAIL B: decision_time no NULL en fail-closed'; end if;
  end loop;
  if n<>1 then raise exception 'FAIL B: esperaba 1 fila NO_DECISION_TIME, hubo %', n; end if;
  raise notice 'PASS B: NO_DECISION_TIME fail-closed (no cae a kickoff)';
end $$;

-- ============================================================================
-- C) explicit later decision_time: prematch coverage grows but P_RETO still NULL,
--    earlier captures preserved, and a strictly-later capture still excluded
-- ============================================================================
do $$
declare les record; fpi record; odd record; n_used int:=0; r record;
  v_dec timestamptz := timestamptz '2026-09-10 18:00+00';
begin
  -- add a capture strictly AFTER this later decision to prove ongoing drift handling
  insert into public.nfl_odds_snapshots(espn_event_id,casa,snapshot_at)
    values('401872657','DraftKings', timestamptz '2026-09-11 09:00+00');

  -- with a later decision, lesiones (09-09 17:07) and FPI (09-10 12:31) are now prematch
  select * into les from v2.fn_nfl_dossier_manifest('401872657', v_dec) where source_name='lesiones';
  if not les.temporally_safe then raise exception 'FAIL C: lesiones no incluida con decision posterior'; end if;
  if les.role<>'CONTEXT_ONLY' then raise exception 'FAIL C: lesiones role=%', les.role; end if;
  if les.used_in_p_reto then raise exception 'FAIL C: lesiones used_in_p_reto (sigue sin modelo propio)'; end if;

  select * into fpi from v2.fn_nfl_dossier_manifest('401872657', v_dec) where source_name='fpi_opinion';
  if not fpi.temporally_safe then raise exception 'FAIL C: FPI no incluida con decision posterior'; end if;
  if fpi.used_in_p_reto then raise exception 'FAIL C: FPI used_in_p_reto (FPI nunca es P_RETO)'; end if;

  -- the strictly-later capture (09-11) must still be excluded and flagged as drift
  select * into odd from v2.fn_nfl_dossier_manifest('401872657', v_dec) where source_name='odds_snapshot';
  if odd.data_asof>v_dec then raise exception 'FAIL C: odds as_of posterior a decision'; end if;
  if not odd.post_decision_capture then raise exception 'FAIL C: captura 09-11 no marcada post-decisión'; end if;

  -- still nothing feeds P_RETO
  for r in select * from v2.fn_nfl_dossier_manifest('401872657', v_dec) loop
    if r.used_in_p_reto then n_used := n_used+1; end if;
  end loop;
  if n_used>0 then raise exception 'FAIL C: % used_in_p_reto con decision posterior', n_used; end if;

  -- earlier prematch odds capture still present (never deleted)
  if not exists(select 1 from public.nfl_odds_snapshots where espn_event_id='401872657' and snapshot_at=timestamptz '2026-09-08 10:00+00') then
    raise exception 'FAIL C: captura prematch anterior borrada'; end if;

  raise notice 'PASS C: cobertura prematch crece con decision posterior, P_RETO sigue NULL, captura tardía excluida, anterior preservada';
end $$;

-- Cleanup the C-block drift insert so the test is re-runnable.
delete from public.nfl_odds_snapshots where espn_event_id='401872657' and snapshot_at=timestamptz '2026-09-11 09:00+00';

do $$ begin raise notice 'iss049 NFL DOSSIER MANIFEST: ALL ASSERTIONS PASSED (verified on branch)'; end $$;
