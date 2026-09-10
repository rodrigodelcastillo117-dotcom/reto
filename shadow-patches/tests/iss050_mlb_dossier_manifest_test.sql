-- ============================================================================
-- iss050 TEST — MLB DOSSIER MANIFEST PARITY (issue #4 comment 5620196530)
-- Self-contained adversarial test: RAISE EXCEPTION on ANY leak.
-- Asserts, mirroring the SOCCER contract (MLB has a REAL own model, unlike NFL):
--   * modelo_p_reto => role MODEL_ACTIVE with the REAL internal P (prob_home) as
--     effective_value READ FROM the frozen immutable snapshot, feature_snapshot_id +
--     feature_version populated, used_in_p_reto=true; canonical selection picks the
--     prod-mirror version, NOT the shadow challenger.
--   * λ run-rates + exponent (feat_lambda_home/away, feat_exponent) are MODEL_ACTIVE,
--     byte-copies of the frozen snapshot, used_in_p_reto=true.
--   * NO-RECOMPUTE proof: emitted P/λ == persisted mlb_shadow_predicciones values and
--     are invariant to post-seal mutation of the live feature cache (mlb_stats_cache).
--   * MODEL_ACTIVE_TEMPORAL_UNPROVEN fail-close: a served prediction (mlb_modelo_snapshot)
--     with NO immutable snapshot linked => role UNPROVEN, effective_value NULL, used=false.
--   * MARKET (momios_novig/total_line) labelled MARKET, never P_RETO, used=false.
--   * a post-decision capture excluded (post_decision_capture=true) + earlier valid
--     capture kept; a pre-decision context capture included (CONTEXT_ONLY).
--   * NO_ASOF context (clima per-city forecast; season form w/o as_of) fail-closed.
--   * NO_DECISION_TIME fail-closed — decision_time is the immutable prediction capture,
--     NEVER the first pitch (game_date).
-- Real prod values (SELECT-only) for event 401816509 (Toronto Blue Jays vs Boston Red Sox):
--   frozen prod-mirror: prob_home 0.4169, λ 3.585/5.015, exp 0.5, version prod_espejo_0.5,
--     features_hash f7ad37290a57b7730cfe0a031cb46bfe, prediction_timestamp 2026-09-05
--     07:43:10.574349+00, game_date 2026-08-13 19:07 (first pitch);
--   shadow challenger: prob_home 0.4666, version shadow_0.2;
--   market momios_mercado: DraftKings, actualizado 2026-08-13 18:34:01.146+00, ml 128/-138,
--     total 8, p_home 0.4307.
-- Branch-only. Requires iss050 prepared (v2.fn_mlb_dossier_manifest) applied first.
-- ============================================================================

create schema if not exists v2;

-- ── minimal table skeletons (subset of real prod columns the function touches) ──
create table if not exists public.mlb_shadow_predicciones(
  id uuid, espn_event_id text, prediction_timestamp timestamptz, model_version text,
  home_team text, away_team text, prob_home numeric, prob_away numeric,
  lambda_home numeric, lambda_away numeric, exponent numeric,
  features_hash text, game_date timestamptz);
create table if not exists public.mlb_modelo_snapshot(
  espn_event_id text, mod_home numeric, mod_away numeric, mod_over numeric, actualizado timestamptz);
create table if not exists public.mlb_stats_cache(
  id uuid, espn_event_id text, mlb_game_pk text, home_team text, away_team text,
  home_pitcher_name text, away_pitcher_name text,
  home_bullpen_fatigue numeric, away_bullpen_fatigue numeric,
  park_factor_runs numeric, park_factor_hr numeric, park_name text,
  home_team_vs_lhp jsonb, home_team_vs_rhp jsonb, away_team_vs_lhp jsonb, away_team_vs_rhp jsonb,
  home_team_last10 jsonb, away_team_last10 jsonb, cached_at timestamptz);
create table if not exists public.mlb_umpire_juego(
  mlb_game_pk text, umpire_home text, cargado_at timestamptz);
create table if not exists public.mlb_alineacion(
  mlb_game_pk text, lado text, cargado_at timestamptz);
create table if not exists public.mlb_forma_temporada(
  temporada int, equipo text, rpg numeric, permitidas_pg numeric);
create table if not exists public.momios_mercado(
  espn_event_id text, fecha timestamptz, casa text, ml_home int, ml_away int,
  total_linea numeric, over_odds int, under_odds int, p_home numeric, p_away numeric,
  vig numeric, actualizado timestamptz);
create table if not exists public.odds_pro_snapshots(
  id bigint, espn_event_id text, created_at timestamptz, is_opening boolean, is_closing boolean, clv_percentage numeric);

-- ── clean the specific test keys (branch is disposable; delete-then-insert is safe) ──
delete from public.mlb_shadow_predicciones where espn_event_id in ('401816509','UNPROVEN1','NODEC');
delete from public.mlb_modelo_snapshot     where espn_event_id in ('401816509','UNPROVEN1','NODEC');
delete from public.mlb_stats_cache         where espn_event_id in ('401816509','UNPROVEN1','NODEC');
delete from public.mlb_umpire_juego        where mlb_game_pk = '777001';
delete from public.mlb_alineacion          where mlb_game_pk = '777001';
delete from public.mlb_forma_temporada     where equipo in ('Toronto Blue Jays','Boston Red Sox');
delete from public.momios_mercado          where espn_event_id in ('401816509','UNPROVEN1','NODEC');
delete from public.odds_pro_snapshots      where espn_event_id in ('401816509','UNPROVEN1','NODEC');

-- ── seed: frozen immutable snapshot — prod mirror (canonical) + shadow challenger ──
insert into public.mlb_shadow_predicciones(id,espn_event_id,prediction_timestamp,model_version,home_team,away_team,prob_home,prob_away,lambda_home,lambda_away,exponent,features_hash,game_date) values
 ('ee13552d-f527-4d2b-9965-2689d5bd5359','401816509', timestamptz '2026-09-05 07:43:10.574349+00','prod_espejo_0.5','Toronto Blue Jays','Boston Red Sox',0.4169,0.5831,3.585,5.015,0.5,'f7ad37290a57b7730cfe0a031cb46bfe', timestamptz '2026-08-13 19:07:00+00'),
 ('6ee913d8-7568-4100-8702-c5e23be0c9d8','401816509', timestamptz '2026-09-05 07:43:10.574349+00','shadow_0.2','Toronto Blue Jays','Boston Red Sox',0.4666,0.5334,4.146,4.739,0.2,'f7ad37290a57b7730cfe0a031cb46bfe', timestamptz '2026-08-13 19:07:00+00');

-- serving surface row (thin overwrite; NOT a traceability source)
insert into public.mlb_modelo_snapshot(espn_event_id,mod_home,mod_away,mod_over,actualizado)
 values('401816509',0.4169,0.5831,0.52, timestamptz '2026-09-05 23:03:00.401203+00');

-- per-event context cache: PRE-decision cached_at (valid prematch context)
insert into public.mlb_stats_cache(id,espn_event_id,mlb_game_pk,home_team,away_team,
  home_pitcher_name,away_pitcher_name,home_bullpen_fatigue,away_bullpen_fatigue,
  park_factor_runs,park_factor_hr,park_name,home_team_vs_lhp,away_team_vs_rhp,
  home_team_last10,away_team_last10,cached_at)
 values(gen_random_uuid(),'401816509','777001','Toronto Blue Jays','Boston Red Sox',
  'Kevin Gausman','Brayan Bello',0.31,0.44,1.02,1.08,'Rogers Centre','{"ops":0.71}','{"ops":0.69}',
  '{"w":6,"l":4}','{"w":5,"l":5}', timestamptz '2026-09-04 12:00:00+00');

-- umpire: POST-decision cargado_at (must be excluded, flagged post_decision_capture)
insert into public.mlb_umpire_juego(mlb_game_pk,umpire_home,cargado_at)
 values('777001','Angel Hernandez', timestamptz '2026-09-06 10:00:00+00');
-- lineups: PRE-decision cargado_at (valid prematch context)
insert into public.mlb_alineacion(mlb_game_pk,lado,cargado_at)
 values('777001','home', timestamptz '2026-09-04 18:00:00+00');

-- season form (NO as_of column => NO_ASOF fail-closed even though rows exist)
insert into public.mlb_forma_temporada(temporada,equipo,rpg,permitidas_pg)
 values(2026,'Toronto Blue Jays',4.6,4.1),(2026,'Boston Red Sox',4.9,4.7);

-- market: PRE-decision no-vig line + a POST-decision drift row (earlier must be kept)
insert into public.momios_mercado(espn_event_id,fecha,casa,ml_home,ml_away,total_linea,over_odds,under_odds,p_home,p_away,vig,actualizado) values
 ('401816509', timestamptz '2026-08-13 19:07:00+00','DraftKings',128,-138,8,-102,-118,0.4307,0.5693,1.84, timestamptz '2026-08-13 18:34:01.146+00'),
 ('401816509', timestamptz '2026-08-13 19:07:00+00','DraftKings',131,-142,8,-104,-116,0.4290,0.5710,1.85, timestamptz '2026-09-06 09:00:00+00');
-- odds_pro_snapshots intentionally EMPTY for this event (matches prod: MLB CLV coverage 0)

-- UNPROVEN event: served (mlb_modelo_snapshot) but NO immutable snapshot row
insert into public.mlb_modelo_snapshot(espn_event_id,mod_home,mod_away,mod_over,actualizado)
 values('UNPROVEN1',0.55,0.45,0.50, timestamptz '2026-09-05 12:00:00+00');

-- ============================================================================
-- A) REAL EVENT 401816509 — MODEL_ACTIVE, canonical = prod mirror, real P honestly shown
-- ============================================================================
do $$
declare
  r record; m record; lh2 record; ex record; n_rows int:=0; n_bad_role int:=0;
  v_saque timestamptz := timestamptz '2026-08-13 19:07:00+00';
  v_persisted_p numeric; v_persisted_lh numeric;
begin
  -- capture the persisted values straight from the frozen snapshot (no-recompute baseline)
  select prob_home, lambda_home into v_persisted_p, v_persisted_lh
    from public.mlb_shadow_predicciones where espn_event_id='401816509' and model_version='prod_espejo_0.5';

  for r in select * from v2.fn_mlb_dossier_manifest('401816509') loop
    n_rows := n_rows+1;
    if r.role not in ('MODEL_ACTIVE','MODEL_ACTIVE_TEMPORAL_UNPROVEN','MARKET','CONTEXT_ONLY','AVAILABLE_NOT_USED') then
      n_bad_role := n_bad_role+1; end if;
    -- decision_time is the frozen capture, NEVER first pitch
    if r.decision_time = v_saque then raise exception 'FAIL A: decision_time == first pitch (prohibido)'; end if;
    if r.decision_time <> timestamptz '2026-09-05 07:43:10.574349+00' then
      raise exception 'FAIL A: decision_time=% (esperaba la captura congelada)', r.decision_time; end if;
    -- MODEL_ACTIVE must carry snapshot traceability + valid as_of
    if r.role='MODEL_ACTIVE' then
      if r.data_asof is null or r.data_asof>r.decision_time then raise exception 'FAIL A: % MODEL_ACTIVE as_of inválido', r.source_name; end if;
      if r.feature_snapshot_id is null then raise exception 'FAIL A: % MODEL_ACTIVE sin feature_snapshot_id', r.source_name; end if;
      if r.feature_version is null then raise exception 'FAIL A: % MODEL_ACTIVE sin feature_version', r.source_name; end if;
    end if;
    -- used_in_p_reto only when MODEL_ACTIVE
    if r.used_in_p_reto and r.role<>'MODEL_ACTIVE' then raise exception 'FAIL A: % used_in_p_reto sin MODEL_ACTIVE (role=%)', r.source_name, r.role; end if;
    -- MARKET / CONTEXT must never feed P_RETO
    if r.role in ('MARKET','CONTEXT_ONLY','AVAILABLE_NOT_USED') and r.used_in_p_reto then
      raise exception 'FAIL A: % (role %) alimenta P_RETO', r.source_name, r.role; end if;
    if r.post_decision_capture is null then raise exception 'FAIL A: % post_decision_capture NULL', r.source_name; end if;
  end loop;
  if n_rows=0 then raise exception 'FAIL A: manifest vacío'; end if;
  if n_bad_role>0 then raise exception 'FAIL A: % roles inválidos', n_bad_role; end if;

  -- A.model row: real internal P from the FROZEN prod-mirror snapshot, used_in_p_reto=true
  select * into m from v2.fn_mlb_dossier_manifest('401816509') where source_name='modelo_p_reto';
  if m.role<>'MODEL_ACTIVE' then raise exception 'FAIL A: model role=% (esperaba MODEL_ACTIVE)', m.role; end if;
  if not m.available then raise exception 'FAIL A: model available=false'; end if;
  if not m.used_in_p_reto then raise exception 'FAIL A: model used_in_p_reto=false'; end if;
  if m.effective_value is distinct from 0.4169 then raise exception 'FAIL A: model P=% (esperaba 0.4169 prod mirror, no 0.4666 challenger)', m.effective_value; end if;
  if m.effective_value is distinct from v_persisted_p then raise exception 'FAIL A: emitted P % <> persisted snapshot P %', m.effective_value, v_persisted_p; end if;
  if m.feature_snapshot_id is distinct from 'ee13552d-f527-4d2b-9965-2689d5bd5359'::uuid then raise exception 'FAIL A: snapshot_id=% (esperaba prod mirror)', m.feature_snapshot_id; end if;
  if m.feature_version<>'prod_espejo_0.5' then raise exception 'FAIL A: feature_version=% (esperaba prod_espejo_0.5)', m.feature_version; end if;
  if m.provenance not like '%mlb_shadow_predicciones%' then raise exception 'FAIL A: model provenance prestada: %', m.provenance; end if;
  if m.provenance not like '%NOT_VALIDATED%' and m.provider not like '%UNVALIDATED%' then raise exception 'FAIL A: model no marca UNVALIDATED/NOT_VALIDATED'; end if;
  if m.data_asof is distinct from timestamptz '2026-09-05 07:43:10.574349+00' then raise exception 'FAIL A: model as_of=%', m.data_asof; end if;
  if not m.temporally_safe then raise exception 'FAIL A: model no temporally_safe'; end if;
  if m.max_source_event_time is not null then raise exception 'FAIL A: model fabricó max_source_event_time (debe ser NULL)'; end if;

  -- A.feature rows: λ from the exact frozen snapshot, used_in_p_reto=true
  select * into lh2 from v2.fn_mlb_dossier_manifest('401816509') where source_name='feat_lambda_home';
  if lh2.role<>'MODEL_ACTIVE' then raise exception 'FAIL A: feat_lambda_home role=%', lh2.role; end if;
  if lh2.effective_value is distinct from 3.585 then raise exception 'FAIL A: λ_home=% (esperaba 3.585)', lh2.effective_value; end if;
  if lh2.effective_value is distinct from v_persisted_lh then raise exception 'FAIL A: emitted λ_home % <> persisted %', lh2.effective_value, v_persisted_lh; end if;
  if not lh2.used_in_p_reto then raise exception 'FAIL A: feat_lambda_home no used_in_p_reto'; end if;
  if lh2.feature_snapshot_id is distinct from 'ee13552d-f527-4d2b-9965-2689d5bd5359'::uuid then raise exception 'FAIL A: feat_lambda_home snapshot_id incorrecto'; end if;

  select * into ex from v2.fn_mlb_dossier_manifest('401816509') where source_name='feat_exponent';
  if ex.effective_value is distinct from 0.5 then raise exception 'FAIL A: exponent=% (esperaba 0.5)', ex.effective_value; end if;
  if not ex.used_in_p_reto then raise exception 'FAIL A: feat_exponent no used_in_p_reto'; end if;

  raise notice 'PASS A: MODEL_ACTIVE real P=0.4169 (prod mirror) trazable al snapshot congelado, λ/exponente used_in_p_reto, decision=captura (no first pitch)';
end $$;

-- ============================================================================
-- A2) NO-RECOMPUTE: mutating the live feature cache AFTER the seal does NOT change P/λ
-- ============================================================================
do $$
declare m1 record; m2 record; lh1 record; lh3 record;
begin
  select * into m1 from v2.fn_mlb_dossier_manifest('401816509') where source_name='modelo_p_reto';
  select * into lh1 from v2.fn_mlb_dossier_manifest('401816509') where source_name='feat_lambda_home';

  -- mutate the live feature source (mlb_stats_cache) with wildly different values
  update public.mlb_stats_cache
     set home_pitcher_name='REPLACED', home_bullpen_fatigue=9.99, park_factor_runs=9.99,
         cached_at = timestamptz '2026-09-04 23:59:00+00'
   where espn_event_id='401816509';

  select * into m2 from v2.fn_mlb_dossier_manifest('401816509') where source_name='modelo_p_reto';
  select * into lh3 from v2.fn_mlb_dossier_manifest('401816509') where source_name='feat_lambda_home';

  if m2.effective_value is distinct from m1.effective_value then
    raise exception 'FAIL A2: P cambió tras mutar feature cache: % -> % (recompute-on-read)', m1.effective_value, m2.effective_value; end if;
  if lh3.effective_value is distinct from lh1.effective_value then
    raise exception 'FAIL A2: λ_home cambió tras mutar feature cache: % -> %', lh1.effective_value, lh3.effective_value; end if;
  if m2.feature_snapshot_id is distinct from m1.feature_snapshot_id then raise exception 'FAIL A2: snapshot_id cambió'; end if;

  raise notice 'PASS A2: no-recompute — P/λ byte-estables ante mutación del cache de features vivo';
end $$;

-- ============================================================================
-- A3) MARKET never P_RETO; post-decision drift excluded + earlier capture kept
-- ============================================================================
do $$
declare mk record; tl record;
begin
  select * into mk from v2.fn_mlb_dossier_manifest('401816509') where source_name='momios_novig';
  if mk.role<>'MARKET' then raise exception 'FAIL A3: momios_novig role=% (esperaba MARKET)', mk.role; end if;
  if mk.used_in_p_reto then raise exception 'FAIL A3: momios_novig alimenta P_RETO (prohibido)'; end if;
  if mk.data_asof is distinct from timestamptz '2026-08-13 18:34:01.146+00' then
    raise exception 'FAIL A3: momios as_of=% (esperaba captura prematch 08-13 18:34)', mk.data_asof; end if;
  if not mk.temporally_safe then raise exception 'FAIL A3: momios prematch no temporally_safe'; end if;
  if not mk.post_decision_capture then raise exception 'FAIL A3: momios no marca drift post-decisión (fila 09-06)'; end if;

  select * into tl from v2.fn_mlb_dossier_manifest('401816509') where source_name='total_line';
  if tl.role<>'MARKET' then raise exception 'FAIL A3: total_line role=%', tl.role; end if;
  if tl.used_in_p_reto then raise exception 'FAIL A3: total_line alimenta P_RETO'; end if;

  -- earlier prematch momios capture never deleted
  if not exists(select 1 from public.momios_mercado where espn_event_id='401816509' and actualizado=timestamptz '2026-08-13 18:34:01.146+00') then
    raise exception 'FAIL A3: captura prematch de momios borrada'; end if;

  raise notice 'PASS A3: MARKET etiquetado MARKET nunca P_RETO; captura post-decisión excluida, prematch preservada';
end $$;

-- ============================================================================
-- A4) CONTEXT: pre-decision included (CONTEXT_ONLY); post-decision excluded; NO_ASOF fail-closed
-- ============================================================================
do $$
declare pit record; ali record; ump record; cl record; st record;
begin
  -- pitchers cache PRE-decision -> CONTEXT_ONLY, not used
  select * into pit from v2.fn_mlb_dossier_manifest('401816509') where source_name='pitchers_abridores';
  if not pit.temporally_safe then raise exception 'FAIL A4: pitchers pre-decisión no incluidos'; end if;
  if pit.role<>'CONTEXT_ONLY' then raise exception 'FAIL A4: pitchers role=% (esperaba CONTEXT_ONLY)', pit.role; end if;
  if pit.used_in_p_reto then raise exception 'FAIL A4: pitchers alimentan P_RETO (contexto, no feature del modelo)'; end if;

  -- lineups PRE-decision via game_pk bridge -> CONTEXT_ONLY
  select * into ali from v2.fn_mlb_dossier_manifest('401816509') where source_name='alineaciones';
  if not ali.temporally_safe then raise exception 'FAIL A4: alineaciones pre-decisión no incluidas'; end if;
  if ali.role<>'CONTEXT_ONLY' then raise exception 'FAIL A4: alineaciones role=%', ali.role; end if;

  -- umpire POST-decision via bridge -> excluded, flagged
  select * into ump from v2.fn_mlb_dossier_manifest('401816509') where source_name='umpire';
  if ump.temporally_safe then raise exception 'FAIL A4: umpire post-decisión marcado temporally_safe'; end if;
  if not ump.post_decision_capture then raise exception 'FAIL A4: umpire post-decisión no marcado'; end if;
  if ump.role<>'AVAILABLE_NOT_USED' then raise exception 'FAIL A4: umpire role=% (esperaba AVAILABLE_NOT_USED)', ump.role; end if;

  -- clima NO_ASOF fail-closed
  select * into cl from v2.fn_mlb_dossier_manifest('401816509') where source_name='clima';
  if cl.available then raise exception 'FAIL A4: clima available (per-ciudad forecast, sin as_of)'; end if;
  if cl.data_asof is not null then raise exception 'FAIL A4: clima inventó as_of'; end if;
  if cl.freshness_status<>'NO_ASOF' then raise exception 'FAIL A4: clima freshness=%', cl.freshness_status; end if;
  if cl.role<>'AVAILABLE_NOT_USED' then raise exception 'FAIL A4: clima role=%', cl.role; end if;

  -- season form NO_ASOF fail-closed (rows exist, but no as_of column)
  select * into st from v2.fn_mlb_dossier_manifest('401816509') where source_name='standings_temporada';
  if st.data_asof is not null then raise exception 'FAIL A4: standings inventó as_of'; end if;
  if st.freshness_status<>'NO_ASOF' then raise exception 'FAIL A4: standings freshness=%', st.freshness_status; end if;
  if st.temporally_safe then raise exception 'FAIL A4: standings temporally_safe sin as_of'; end if;
  if st.used_in_p_reto then raise exception 'FAIL A4: standings alimenta P_RETO'; end if;

  raise notice 'PASS A4: contexto pre-decisión CONTEXT_ONLY; umpire post-decisión excluido; clima/standings NO_ASOF fail-closed';
end $$;

-- ============================================================================
-- B) MODEL_ACTIVE_TEMPORAL_UNPROVEN — served but NO immutable snapshot linked
-- ============================================================================
do $$
declare m record; n_used int:=0; r record;
  v_dec timestamptz := timestamptz '2026-09-05 12:00:00+00';
begin
  select * into m from v2.fn_mlb_dossier_manifest('UNPROVEN1', v_dec) where source_name='modelo_p_reto';
  if m.role<>'MODEL_ACTIVE_TEMPORAL_UNPROVEN' then raise exception 'FAIL B: role=% (esperaba MODEL_ACTIVE_TEMPORAL_UNPROVEN)', m.role; end if;
  if m.used_in_p_reto then raise exception 'FAIL B: UNPROVEN usado en P_RETO'; end if;
  if m.effective_value is not null then raise exception 'FAIL B: UNPROVEN emitió P (debe ser NULL, no se presta del serving)'; end if;
  if m.feature_snapshot_id is not null then raise exception 'FAIL B: UNPROVEN con feature_snapshot_id'; end if;
  if m.freshness_status<>'MODEL_ACTIVE_TEMPORAL_UNPROVEN' then raise exception 'FAIL B: freshness=%', m.freshness_status; end if;
  if m.missing_reason not like '%SIN snapshot inmutable%' then raise exception 'FAIL B: missing_reason no explica UNPROVEN: %', m.missing_reason; end if;
  for r in select * from v2.fn_mlb_dossier_manifest('UNPROVEN1', v_dec) loop
    if r.used_in_p_reto then n_used:=n_used+1; end if;
  end loop;
  if n_used>0 then raise exception 'FAIL B: % filas used_in_p_reto en evento UNPROVEN', n_used; end if;
  raise notice 'PASS B: MODEL_ACTIVE_TEMPORAL_UNPROVEN fail-closed (servido sin snapshot inmutable), P NULL, 0 used';
end $$;

-- ============================================================================
-- C) NO_DECISION_TIME fail-closed — no frozen capture, no arg; NEVER first pitch
-- ============================================================================
do $$
declare r record; n int:=0;
begin
  for r in select * from v2.fn_mlb_dossier_manifest('NODEC') loop
    n := n+1;
    if r.freshness_status<>'NO_DECISION_TIME' then raise exception 'FAIL C: freshness=% (esperaba NO_DECISION_TIME)', r.freshness_status; end if;
    if r.used_in_p_reto then raise exception 'FAIL C: used_in_p_reto en fail-closed'; end if;
    if r.decision_time is not null then raise exception 'FAIL C: decision_time no NULL en fail-closed'; end if;
    if r.missing_reason not ilike '%game_date%' then raise exception 'FAIL C: no aclara que NO se usa first pitch: %', r.missing_reason; end if;
  end loop;
  if n<>1 then raise exception 'FAIL C: esperaba 1 fila NO_DECISION_TIME, hubo %', n; end if;
  raise notice 'PASS C: NO_DECISION_TIME fail-closed (no cae al primer pitcheo)';
end $$;

do $$ begin raise notice 'iss050 MLB DOSSIER MANIFEST: ALL ASSERTIONS PASSED (verified on branch)'; end $$;
