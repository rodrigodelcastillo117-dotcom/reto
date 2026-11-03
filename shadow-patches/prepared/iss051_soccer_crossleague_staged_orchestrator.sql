-- ============================================================================
-- iss051 — SOCCER UNIFIED STAGED ORCHESTRATOR (domestic + crossleague) · STAGED
-- ============================================================================
-- Fixes the REAL-PATH stop-ship in issue #4 comments 5623863543 / 5623894301 /
-- 5624210107. NO PROD MUTATION · branch-only · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
--
-- ROOT CAUSE (traced end-to-end, confirmed against prod READ-ONLY):
--   The six owner fixtures are UEFA Champions League (provider liga_id=2). The staged
--   builder (iss033) computed approval ONLY as
--       reg_ok = (v2.model_registry.approved is true)  for model_name='reto_dc_v2'
--   and v2.model_registry holds DOMESTIC ligas only. UCL approval lives in a SEPARATE
--   authority (v2.crossleague_competencias, iss027: UCL id 2 aprobada=true) and the
--   crossleague model (fn_crossleague_features / fn_crossleague_p_reto) was NEVER wired
--   into the staged builder. So every UCL event fail-closed with
--   "Competencia no aprobada para el modelo" — a CONFIG/WIRING reason, not a data reason.
--   Compounding it, v2.competition_catalog was never seeded by the chain.
--
--   SECOND, INDEPENDENT CAUSE of the two "NO ROW staged" fixtures (401915422 PSV-Shakhtar
--   and 401915444 Fenerbahce-Roma): both kick off 2026-09-10 16:45:00+00, and the old
--   runner's decision epoch was 17:00:00+00. The builder universe is
--   `agenda_espn.fecha > decision_time`, so those two were CORRECTLY excluded — the
--   builder was right and the decision_time was wrong. Fixed in the runner by moving the
--   epoch to 12:00:00+00 (genuinely pre-kickoff for all six). The universe filter is NOT
--   loosened; a post-kickoff decision must keep excluding the event.
--
-- WHAT THIS FILE DOES (no guard weakened, no event-id hardcode anywhere):
--   1. Adds a registry-driven model_config row for the crossleague model and a guard that
--      fail-closes if model_config and crossleague_params disagree (one governance truth).
--   2. v2.fn_crossleague_features_asof — domestic form with the SAME frozen competition
--      exclusion set as the validated iss027 feature, PLUS epoch-availability enforcement
--      (cargado_at <= decision), so the crossleague path can legitimately claim
--      temporal_safe instead of asserting it.
--   3. v2.fn_crossleague_lambda_asof — lambdas from the SEALED phi snapshot
--      (iss037 fn_crossleague_phi_asof / fn_crossleague_active_cutoff), never the live
--      mutable v2.liga_fuerza. Fail-closes with an explicit reason at every step.
--   4. v2.fn_crossleague_p_reto REWRITTEN to delegate to v2.fn_dist_from_lambda. The old
--      body summed `i+j>=3` internally — a HARDCODED Over 2.5 that ignored the real
--      provider line and was a second, divergent probability authority. Now every market
--      (1X2 / BTTS / O-U at the REAL line with push/line_type) comes from the ONE emitter.
--   5. v2.fn_soccer_model_route — reproducible per-competition routing from
--      competition_provider_map + competition_catalog + model_registry +
--      crossleague_competencias. Domestic and crossleague approval are asserted DISJOINT.
--   6. v2.build_soccer_prediction_v2_staged REPLACED by a unified orchestrator: domestic
--      comps -> reto_dc_v2, approved crossleague comps -> crossleague_v1, BOTH writing the
--      SAME staged contract (score_dist + top_scores + 1X2 + BTTS + real-line O/U with
--      push/line_type/supported + provenance + feature_snapshot). Exactly ONE staged row
--      per (event, decision_time): each event routes to exactly one model. ONE P_RETO.
--
-- Apply AFTER iss033 (it replaces the builder) and AFTER iss027/iss037/iss039/iss041.
-- ============================================================================

create schema if not exists v2;

-- ── 0) staged contract: additive provenance columns (route/model identity) ───
alter table v2.soccer_prediction_v2_staged add column if not exists model_name text;
alter table v2.soccer_prediction_v2_staged add column if not exists model_route text;

-- feature_snapshot: additive phi provenance so a crossleague P_RETO is replayable.
alter table v2.feature_snapshot add column if not exists phi_home numeric;
alter table v2.feature_snapshot add column if not exists phi_away numeric;
alter table v2.feature_snapshot add column if not exists phi_model_version text;
alter table v2.feature_snapshot add column if not exists phi_training_cutoff timestamptz;
alter table v2.feature_snapshot add column if not exists phi_config_hash text;

-- Immutability trigger EXTENDED to the phi columns: without this, phi could drift
-- in-place under the same (event, decision_time, feature_version) and silently rewrite a
-- historical crossleague belief.
create or replace function v2.fn_feature_snapshot_immutable() returns trigger language plpgsql as $$
begin
  if row(new.home_gf,new.home_gc,new.away_gf,new.away_gc,new.sample_home,new.sample_away,
         new.feature_data_asof,new.max_source_event_time,
         new.phi_home,new.phi_away,new.phi_model_version,new.phi_training_cutoff,new.phi_config_hash) is distinct from
     row(old.home_gf,old.home_gc,old.away_gf,old.away_gc,old.sample_home,old.sample_away,
         old.feature_data_asof,old.max_source_event_time,
         old.phi_home,old.phi_away,old.phi_model_version,old.phi_training_cutoff,old.phi_config_hash) then
    raise exception 'FEATURE_SNAPSHOT_DRIFT: (%,%,%) ya sellado con features distintas; usa un feature_version nuevo',
      new.espn_event_id, new.decision_time, new.feature_version;
  end if;
  return new;
end $$;
drop trigger if exists trg_feature_snapshot_immutable on v2.feature_snapshot;
create trigger trg_feature_snapshot_immutable before update on v2.feature_snapshot
  for each row execute function v2.fn_feature_snapshot_immutable();

-- ── 1) registry-driven config for the crossleague model ─────────────────────
-- max_goals is part of the belief: iss027 validated on a 0..10 grid, so the crossleague
-- row pins 10. The domestic row is left untouched (changing its grid would mutate an
-- already-sealed belief under the same model_version).
alter table v2.model_config add column if not exists max_goals int;
alter table v2.model_config add column if not exists model_kind text;

-- Append-only (iss033 whole-row immutability trigger applies). Re-seed identical = no-op.
insert into v2.model_config
  (sport, model_name, model_version, feature_version, calibration_status,
   sample_floor, window_days, publish_authorized, max_goals, model_kind)
values
  ('soccer','crossleague','crossleague_v1','crossleague_domestic_form_asof_v1','UNVALIDATED',
   15, 540, true, 10, 'CROSSLEAGUE')
on conflict (sport, model_version) do nothing;

-- Guard: model_config and crossleague_params are TWO tables describing ONE governance
-- fact (the domestic sample floor). Fail-close on disagreement rather than let the builder
-- silently prefer one. Called by the builder on every run.
create or replace function v2.fn_crossleague_config_guard(p_model_version text default 'crossleague_v1')
returns boolean language plpgsql stable as $$
declare cfg record; par record;
begin
  select * into cfg from v2.model_config where sport='soccer' and model_version=p_model_version;
  if cfg is null then
    raise exception 'CROSSLEAGUE_CONFIG_MISSING: v2.model_config has no soccer/% row', p_model_version;
  end if;
  select * into par from v2.crossleague_params where model_version=p_model_version;
  if par is null then
    raise exception 'CROSSLEAGUE_PARAMS_MISSING: v2.crossleague_params has no % row', p_model_version;
  end if;
  if cfg.sample_floor is distinct from par.sample_floor_domestic then
    raise exception 'CROSSLEAGUE_CONFIG_DRIFT: model_config.sample_floor=% != crossleague_params.sample_floor_domestic=% for %',
      cfg.sample_floor, par.sample_floor_domestic, p_model_version;
  end if;
  return true;
end $$;

-- ── 2) crossleague domestic-form features, as-of + availability-enforced ────
-- The competition exclusion set is IDENTICAL to v2.fn_crossleague_features (iss027). It is
-- a FROZEN model artifact tied to feature_version 'crossleague_domestic_form_asof_v1':
-- the OOS evidence that approved UCL/UEL was produced with exactly this feature, so the
-- list is versioned, not refactored. Changing it requires a NEW feature_version.
-- Addition over iss027: p_enforce_availability (cargado_at <= decision). For forward
-- production the row must have been LOADED before the decision, not merely played before
-- it; for historical replay cargado_at is bulk-backfill time and is not epoch availability,
-- so the caller passes false and the builder then refuses to claim temporal_safe.
create or replace function v2.fn_crossleague_features_asof(
  p_team_espn_id text, p_decision_time timestamptz,
  p_window_days int default 540, p_enforce_availability boolean default true
) returns table(n int, gf numeric, ga numeric, liga_modal int,
                data_asof timestamptz, max_source_event_time timestamptz)
language sql stable as $$
  select count(*)::int,
    avg(case when d.home_espn_id=p_team_espn_id then d.home_score else d.away_score end),
    avg(case when d.home_espn_id=p_team_espn_id then d.away_score else d.home_score end),
    mode() within group (order by d.liga_id),
    max(d.fecha), max(d.fecha)
  from public.historico_partidos_espn d
  where (d.home_espn_id=p_team_espn_id or d.away_espn_id=p_team_espn_id)
    and d.liga_id not in (2,3,848,13,11,15,16,17,20,45,48,66,81,137,143,180,181,667)
    and d.liga_id is not null and d.home_score is not null
    and d.fecha < p_decision_time
    and d.fecha >= p_decision_time - make_interval(days => p_window_days)
    and (not p_enforce_availability or d.cargado_at <= p_decision_time);
$$;

-- ── 3) crossleague lambdas from the SEALED phi snapshot (fail-closed) ───────
-- iss037 contract honoured: ONE cutoff resolved for the whole replay via
-- fn_crossleague_active_cutoff (sealed + integrity-verified manifests only), and each
-- league's phi read through fn_crossleague_phi_asof at that cutoff. The live mutable
-- v2.liga_fuerza is NEVER read here — a re-fit cannot retroactively change a sealed belief.
create or replace function v2.fn_crossleague_lambda_asof(
  p_home_espn_id text, p_away_espn_id text,
  p_home_liga int, p_away_liga int, p_competition_liga_id int,
  p_decision_time timestamptz,
  p_model_version text default 'crossleague_v1',
  p_window_days int default 540,
  p_enforce_availability boolean default true
) returns table(
  lambda_home numeric, lambda_away numeric, rho numeric,
  gf_home numeric, ga_home numeric, gf_away numeric, ga_away numeric,
  sample_home int, sample_away int, liga_home int, liga_away int,
  phi_home numeric, phi_away numeric, phi_model_version text,
  phi_training_cutoff timestamptz, phi_config_hash text,
  data_asof timestamptz, max_source_event_time timestamptz,
  temporal_safe boolean, status text, status_reason text
) language plpgsql stable as $$
declare
  par record; fh record; fa record; ph record; pa record;
  v_cut timestamptz; lh numeric; la numeric; lig_h int; lig_a int; asof timestamptz;
  nx_h int; nx_a int;
begin
  -- null-result helper values
  lambda_home := null; lambda_away := null; rho := null;
  temporal_safe := false;

  select * into par from v2.crossleague_params cp where cp.model_version = p_model_version;
  if par is null then
    status := 'DATA_INCOMPLETE';
    status_reason := 'CROSSLEAGUE_PARAMS_MISSING: sin parametros para '||p_model_version;
    return next; return;
  end if;
  rho := par.rho;

  -- (a) competition approval: OOS-gated, per competition (never a global average)
  if not exists (select 1 from v2.crossleague_competencias x
                 where x.competition_liga_id = p_competition_liga_id and x.aprobada is true) then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Competencia cruzada no aprobada OOS (solo UCL/UEL en v1)';
    return next; return;
  end if;

  -- (b) domestic form, temporal-safe
  select * into fh from v2.fn_crossleague_features_asof(p_home_espn_id, p_decision_time, p_window_days, p_enforce_availability);
  select * into fa from v2.fn_crossleague_features_asof(p_away_espn_id, p_decision_time, p_window_days, p_enforce_availability);
  gf_home := round(fh.gf,4); ga_home := round(fh.ga,4);
  gf_away := round(fa.gf,4); ga_away := round(fa.ga,4);
  sample_home := coalesce(fh.n,0); sample_away := coalesce(fa.n,0);
  lig_h := coalesce(fh.liga_modal, p_home_liga);
  lig_a := coalesce(fa.liga_modal, p_away_liga);
  liga_home := lig_h; liga_away := lig_a;

  if sample_home < par.sample_floor_domestic or sample_away < par.sample_floor_domestic then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Muestra domestica insuficiente para el modelo cross-league (<'
      ||par.sample_floor_domestic||'): local='||sample_home||' visitante='||sample_away;
    return next; return;
  end if;
  if gf_home is null or ga_home is null or gf_away is null or ga_away is null then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Sin tasas domesticas de goles para ambos equipos';
    return next; return;
  end if;

  -- (c) SEALED phi: one cutoff for the whole replay; fail-close if none <= decision
  v_cut := v2.fn_crossleague_active_cutoff(p_decision_time, p_model_version);
  if v_cut is null then
    status := 'DATA_INCOMPLETE';
    status_reason := 'PHI_SNAPSHOT_UNAVAILABLE: sin snapshot phi sellado e integro con cutoff<=decision_time';
    return next; return;
  end if;
  phi_training_cutoff := v_cut;
  select * into ph from v2.fn_crossleague_phi_asof(lig_h, p_decision_time, p_model_version);
  select * into pa from v2.fn_crossleague_phi_asof(lig_a, p_decision_time, p_model_version);
  if ph is null or pa is null or ph.phi is null or pa.phi is null
     or coalesce(ph.servible,false) = false or coalesce(pa.servible,false) = false then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Liga sin cobertura phi validada en el snapshot sellado (local='||lig_h||' visitante='||lig_a||')';
    return next; return;
  end if;
  phi_home := ph.phi; phi_away := pa.phi;
  phi_model_version := ph.phi_model_version; phi_config_hash := ph.phi_config_hash;

  -- (c2) cross-league coverage floor asserted explicitly from the SEALED rows (not only
  -- the precomputed `servible` flag), so a snapshot sealed with a weaker flag cannot pass.
  -- TABLE-QUALIFIED: the OUT params phi_model_version / phi_training_cutoff would otherwise
  -- shadow the identically named columns of v2.liga_fuerza_version ("column reference is
  -- ambiguous" at runtime). Caught by the first real execution of the builder.
  select lv.n_cruzados into nx_h from v2.liga_fuerza_version lv
   where lv.phi_model_version=p_model_version and lv.phi_training_cutoff=v_cut and lv.liga_id=lig_h;
  select lv.n_cruzados into nx_a from v2.liga_fuerza_version lv
   where lv.phi_model_version=p_model_version and lv.phi_training_cutoff=v_cut and lv.liga_id=lig_a;
  if coalesce(nx_h,0) < par.coverage_floor_cruzados or coalesce(nx_a,0) < par.coverage_floor_cruzados then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Cobertura cruzada insuficiente (<'||par.coverage_floor_cruzados
      ||' juegos): liga '||lig_h||'='||coalesce(nx_h,0)||' liga '||lig_a||'='||coalesce(nx_a,0);
    return next; return;
  end if;

  -- (d) temporal integrity of the feature inputs
  asof := greatest(fh.data_asof, fa.data_asof);
  data_asof := asof; max_source_event_time := asof;
  if asof is null then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Sin data_asof de features domesticas';
    return next; return;
  end if;
  if asof > p_decision_time then
    status := 'DATA_INCOMPLETE';
    status_reason := 'Fuga temporal: features domesticas posteriores a decision_time';
    return next; return;
  end if;
  if not p_enforce_availability then
    -- Replay without epoch-availability proof: emit the lambdas but never claim temporal_safe.
    temporal_safe := false;
  else
    temporal_safe := true;
  end if;

  -- (e) lambdas — same closed form and same coefficients as the OOS-validated iss027 fit
  lh := exp(least(par.a0 + par.batt*ln(greatest(gf_home,0.05)) + par.bdef*ln(greatest(ga_away,0.05))
                  + par.home_adv + (phi_home - phi_away), 2.5));
  la := exp(least(par.a0 + par.batt*ln(greatest(gf_away,0.05)) + par.bdef*ln(greatest(ga_home,0.05))
                  + (phi_away - phi_home), 2.5));
  lambda_home := round(lh,4); lambda_away := round(la,4);
  status := 'READY_UNVALIDATED';
  status_reason := 'cross-league Dixon-Coles + phi sellado (OOS validado por competencia)';
  return next;
end $$;

-- ── 4) fn_crossleague_p_reto: delegates to the ONE emitter (kills Over-2.5 hardcode) ──
-- OLD BODY (iss027) built its own 0..10 matrix and accumulated `if i+j>=3 then over`, i.e.
-- it always answered Over/Under 2.5 regardless of the real provider line, and it was a
-- SECOND probability authority that could drift from fn_dist_from_lambda. Both defects are
-- removed: lambdas come from fn_crossleague_lambda_asof, every market from
-- v2.fn_dist_from_lambda at the line the caller passes. No line => O/U stays NULL
-- (fail-close), never re-anchored to 2.5.
drop function if exists v2.fn_crossleague_p_reto(text,text,int,int,timestamptz,int);
create or replace function v2.fn_crossleague_p_reto(
  p_home_espn_id text, p_away_espn_id text,
  p_home_liga int, p_away_liga int, p_decision_time timestamptz,
  p_competition_liga_id int, p_over_line numeric default null,
  p_model_version text default 'crossleague_v1',
  p_enforce_availability boolean default true
) returns table(
  p_reto_home numeric, p_reto_draw numeric, p_reto_away numeric,
  btts_yes numeric, btts_no numeric,
  over_line numeric, p_over numeric, p_under numeric, p_push numeric,
  ou_line_type text, ou_supported boolean,
  lambda_home numeric, lambda_away numeric,
  score_dist jsonb, top_scores jsonb,
  sample_home int, sample_away int,
  phi_home numeric, phi_away numeric, phi_training_cutoff timestamptz, phi_config_hash text,
  temporal_safe boolean, model_status text, model_status_reason text, data_asof timestamptz
) language plpgsql stable as $$
declare lam record; cfg record; d jsonb;
begin
  select * into cfg from v2.model_config where sport='soccer' and model_version=p_model_version;
  select * into lam from v2.fn_crossleague_lambda_asof(
    p_home_espn_id, p_away_espn_id, p_home_liga, p_away_liga, p_competition_liga_id,
    p_decision_time, p_model_version, coalesce(cfg.window_days,540), p_enforce_availability);

  lambda_home := lam.lambda_home; lambda_away := lam.lambda_away;
  sample_home := lam.sample_home; sample_away := lam.sample_away;
  phi_home := lam.phi_home; phi_away := lam.phi_away;
  phi_training_cutoff := lam.phi_training_cutoff; phi_config_hash := lam.phi_config_hash;
  temporal_safe := lam.temporal_safe; data_asof := lam.data_asof; over_line := p_over_line;

  if lam.status <> 'READY_UNVALIDATED' or lam.lambda_home is null or lam.lambda_away is null then
    model_status := lam.status; model_status_reason := lam.status_reason;
    return next; return;
  end if;

  d := v2.fn_dist_from_lambda(lam.lambda_home, lam.lambda_away, p_over_line, lam.rho,
                              coalesce(cfg.max_goals,10));
  if d is null then
    model_status := 'DATA_INCOMPLETE';
    model_status_reason := 'El emisor canonico no pudo construir la matriz conjunta';
    return next; return;
  end if;

  p_reto_home := (d->>'p_home')::numeric;
  p_reto_draw := (d->>'p_draw')::numeric;
  p_reto_away := (d->>'p_away')::numeric;
  btts_yes    := (d->>'btts_yes')::numeric;
  btts_no     := (d->>'btts_no')::numeric;
  p_over      := case when p_over_line is not null then (d->>'p_over')::numeric end;
  p_under     := case when p_over_line is not null then (d->>'p_under')::numeric end;
  p_push      := case when p_over_line is not null then (d->>'p_push')::numeric end;
  ou_line_type := (d->>'ou_line_type');
  ou_supported := (d->>'ou_supported')::boolean;
  score_dist  := d->'dist';
  top_scores  := d->'top_scores';
  model_status := 'READY_UNVALIDATED';
  model_status_reason := lam.status_reason;
  return next;
end $$;

-- ── 5) reproducible per-competition routing (no event-id hardcode) ──────────
-- Authority chain, all versioned and reproducible from a clean bootstrap:
--   competition_provider_map (provider-id -> canonical id, mapping_version)
--   competition_catalog      (enabled / visibility governance)
--   model_registry           (which model is APPROVED for that competition)
--   crossleague_competencias (per-competition OOS approval for the crossleague model)
-- Domestic and crossleague approval for the SAME competition is a governance
-- contradiction (two models claiming one P_RETO) and RAISES rather than silently picking.
create or replace function v2.fn_soccer_model_route(
  p_provider text, p_provider_liga_id int, p_mapping_version text,
  p_dom_model_name text, p_dom_model_version text,
  p_xl_model_name text, p_xl_model_version text
) returns table(
  route text, model_name text, model_version text,
  competition_id int, catalog_competition_id text,
  catalog_enabled boolean, catalog_model_supported boolean,
  end_to_end boolean, dom_approved boolean, xl_approved boolean, route_reason text
) language plpgsql stable as $$
declare rc record; cat record; e2e boolean; dom boolean; xl boolean;
begin
  select * into rc from v2.fn_resolve_competition(p_provider, p_provider_liga_id, p_mapping_version);
  competition_id := rc.competition_id;

  select c.competition_id, c.enabled, c.model_supported into cat
  from v2.competition_catalog c
  where c.sport='soccer' and c.provider = p_provider
    and c.provider_competition_id = p_provider_liga_id::text
  limit 1;
  catalog_competition_id := cat.competition_id;
  catalog_enabled        := cat.enabled;
  catalog_model_supported:= cat.model_supported;

  -- canonical id must equal the provider identity that governs registry/features, else the
  -- approval and the priors would belong to a DIFFERENT competition (iss033 invariant).
  e2e := (rc.competition_id is not null and rc.competition_id = p_provider_liga_id);
  end_to_end := e2e;

  dom := exists (select 1 from v2.model_registry r
                 where r.sport='soccer' and r.model_name=p_dom_model_name
                   and r.model_version=p_dom_model_version and r.liga_id=p_provider_liga_id
                   and r.approved is true);
  xl  := exists (select 1 from v2.model_registry r
                 where r.sport='soccer' and r.model_name=p_xl_model_name
                   and r.model_version=p_xl_model_version and r.liga_id=p_provider_liga_id
                   and r.approved is true)
     and exists (select 1 from v2.crossleague_competencias x
                 where x.competition_liga_id=p_provider_liga_id and x.aprobada is true);
  dom_approved := dom; xl_approved := xl;

  if dom and xl then
    raise exception 'ROUTE_AMBIGUOUS: competencia provider % aprobada para el modelo domestico (%/%) Y para el cross-league (%/%); una competencia no puede tener dos autoridades de P_RETO',
      p_provider_liga_id, p_dom_model_name, p_dom_model_version, p_xl_model_name, p_xl_model_version;
  end if;

  -- Unmodelled events still occupy the canonical staged contract (visible, P_RETO NULL), and
  -- model_version is part of its PRIMARY KEY, so route NONE carries an explicit NO_MODEL identity
  -- rather than borrowing the domestic model_version (which would mislabel the row as produced by
  -- a model that never ran). Caught by the first real execution (NOT NULL violation on model_version).
  model_name := 'none'; model_version := 'NO_MODEL';
  if rc.competition_id is null then
    route := 'NONE'; route_reason := 'Competencia no mapeada/soportada (provider-id): evento visible sin P_RETO';
  elsif not e2e then
    route := 'NONE'; route_reason := 'MAPPING_NOT_END_TO_END: canonical competition_id ('||rc.competition_id
      ||') != identidad provider (liga_id '||p_provider_liga_id||') que gobierna registry/features; fail-close';
  elsif cat is null then
    route := 'NONE'; route_reason := 'CATALOG_MISSING: provider-id '||p_provider_liga_id
      ||' no existe en competition_catalog; evento visible sin P_RETO';
  elsif cat.enabled is not true then
    route := 'NONE'; route_reason := 'CATALOG_DISABLED: competencia '||coalesce(cat.competition_id,'?')
      ||' deshabilitada en competition_catalog';
  elsif dom then
    route := 'DOMESTIC';    model_name := p_dom_model_name; model_version := p_dom_model_version;
    route_reason := 'modelo domestico aprobado en model_registry';
  elsif xl then
    route := 'CROSSLEAGUE'; model_name := p_xl_model_name;  model_version := p_xl_model_version;
    route_reason := 'modelo cross-league aprobado (model_registry + crossleague_competencias OOS)';
  else
    route := 'NONE'; route_reason := 'Competencia no aprobada para el modelo';
  end if;
  return next;
end $$;

-- ── 6) UNIFIED STAGED ORCHESTRATOR (replaces the iss033 builder) ────────────
-- ONE canonical staged contract for soccer; the route only decides WHICH approved model
-- produces the joint distribution. Both routes persist score_dist + top_scores and derive
-- 1X2 / BTTS / real-line O-U (with push + line_type + supported) from THAT SAME matrix, so
-- the coherence gate cannot be satisfied by a second, divergent math path.
-- Exactly one staged row per (espn_event_id, decision_time): an event routes to exactly one
-- model, so there is never a parallel visible probability for the same event.
create or replace function v2.build_soccer_prediction_v2_staged(
  p_decision_time timestamptz,
  p_enforce_availability boolean default true,
  p_mapping_version text default null
) returns integer language plpgsql as $function$
declare n int; cfg_dom record; cfg_xl record; v_map text;
begin
  select * into cfg_dom from v2.model_config where sport='soccer' and model_version='dc-2026.09.1';
  if cfg_dom is null then raise exception 'MODEL_CONFIG_MISSING: soccer/dc-2026.09.1'; end if;
  select * into cfg_xl from v2.model_config where sport='soccer' and model_version='crossleague_v1';
  if cfg_xl is null then raise exception 'MODEL_CONFIG_MISSING: soccer/crossleague_v1'; end if;
  perform v2.fn_crossleague_config_guard('crossleague_v1');

  -- freeze ONE mapping_version for the whole build (never re-read the active pointer per row)
  v_map := coalesce(p_mapping_version, v2.fn_competition_active_mapping());
  if v_map is null then raise exception 'COMPETITION_MAPPING_UNSET: v2.competition_mapping_config vacio'; end if;

  with agenda as (   -- AGENDA = UNIVERSE. Nothing disappears; unsupported stays visible with P=NULL.
    select distinct on (a.espn_event_id) a.espn_event_id, a.liga_id, a.liga_nombre,
           a.home_nombre, a.away_nombre, a.fecha kickoff, a.home_espn_id, a.away_espn_id
    from public.agenda_espn a
    where a.deporte='soccer' and a.fecha > p_decision_time   -- strictly pre-kickoff decision
    order by a.espn_event_id, a.fecha
  ),
  routed as (
    select ag.*, rt.route, rt.model_name, rt.model_version, rt.competition_id,
           rt.catalog_competition_id, rt.catalog_enabled, rt.end_to_end,
           rt.dom_approved, rt.xl_approved, rt.route_reason
    from agenda ag
    left join lateral v2.fn_soccer_model_route(
      'espn', ag.liga_id, v_map,
      cfg_dom.model_name, cfg_dom.model_version,
      cfg_xl.model_name,  cfg_xl.model_version) rt on true
  ),
  -- ── DOMESTIC branch: same-competition goal rates as-of decision (iss033 semantics) ──
  dom as (
    select r.espn_event_id, r.liga_id, r.competition_id, r.home_nombre, r.away_nombre, r.kickoff,
           r.route, r.model_name, r.model_version, r.route_reason,
           r.catalog_competition_id, r.dom_approved, r.xl_approved,
           cfg_dom.feature_version f_version, cfg_dom.calibration_status calib,
           f.home_gf, f.home_gc, f.away_gf, f.away_gc, f.sample_home, f.sample_away,
           f.feature_data_asof, f.max_source_event_time,
           (f.max_source_event_time is not null and f.max_source_event_time <= p_decision_time
              and p_enforce_availability) temporal_safe_calc,
           null::numeric phi_home, null::numeric phi_away, null::text phi_mv,
           null::timestamptz phi_cutoff, null::text phi_hash,
           o.provider_total_line over_line, o.provider bookmaker, o.line_asof,
           v2.fn_score_dist(f.home_gf,f.home_gc,f.away_gf,f.away_gc,
                            lg.media_goles_local, lg.media_goles_visita, o.provider_total_line) d,
           null::text xl_status, null::text xl_reason
    from routed r
    left join lateral v2.fn_soccer_features_asof(
        r.home_espn_id, r.away_espn_id, r.liga_id, p_decision_time, cfg_dom.window_days,
        r.espn_event_id, p_enforce_availability) f on true
    left join lateral (select * from v2.fn_real_total_line(r.espn_event_id, p_decision_time)) o on true
    left join public.v_liga_promedios_futbol lg on lg.liga_id = r.liga_id
    where r.route = 'DOMESTIC'
  ),
  -- ── CROSSLEAGUE branch: sealed-phi lambdas -> the SAME canonical emitter ──
  xl as (
    select r.espn_event_id, r.liga_id, r.competition_id, r.home_nombre, r.away_nombre, r.kickoff,
           r.route, r.model_name, r.model_version, r.route_reason,
           r.catalog_competition_id, r.dom_approved, r.xl_approved,
           cfg_xl.feature_version f_version, cfg_xl.calibration_status calib,
           lam.gf_home home_gf, lam.ga_home home_gc, lam.gf_away away_gf, lam.ga_away away_gc,
           lam.sample_home, lam.sample_away,
           lam.data_asof feature_data_asof, lam.max_source_event_time,
           lam.temporal_safe temporal_safe_calc,
           lam.phi_home, lam.phi_away, lam.phi_model_version phi_mv,
           lam.phi_training_cutoff phi_cutoff, lam.phi_config_hash phi_hash,
           o.provider_total_line over_line, o.provider bookmaker, o.line_asof,
           case when lam.lambda_home is not null and lam.lambda_away is not null
                then v2.fn_dist_from_lambda(lam.lambda_home, lam.lambda_away,
                                            o.provider_total_line, lam.rho, cfg_xl.max_goals) end d,
           lam.status xl_status, lam.status_reason xl_reason
    from routed r
    left join lateral v2.fn_crossleague_lambda_asof(
        r.home_espn_id, r.away_espn_id, r.liga_id, r.liga_id, r.liga_id,
        p_decision_time, cfg_xl.model_version, cfg_xl.window_days, p_enforce_availability) lam on true
    left join lateral (select * from v2.fn_real_total_line(r.espn_event_id, p_decision_time)) o on true
    where r.route = 'CROSSLEAGUE'
  ),
  -- ── NO ROUTE: visible in the universe, P_RETO NULL, explicit governance reason ──
  none as (
    select r.espn_event_id, r.liga_id, r.competition_id, r.home_nombre, r.away_nombre, r.kickoff,
           r.route, r.model_name, r.model_version, r.route_reason,
           r.catalog_competition_id, r.dom_approved, r.xl_approved,
           null::text, null::text,
           null::numeric, null::numeric, null::numeric, null::numeric, null::int, null::int,
           null::timestamptz, null::timestamptz, false,
           null::numeric, null::numeric, null::text, null::timestamptz, null::text,
           o.provider_total_line, o.provider, o.line_asof,
           null::jsonb, null::text, null::text
    from routed r
    left join lateral (select * from v2.fn_real_total_line(r.espn_event_id, p_decision_time)) o on true
    where r.route = 'NONE'
  ),
  calc as (select * from dom union all select * from xl union all select * from none),
  pub as (
    select c.*,
      case
        when c.route = 'DOMESTIC' then
          (c.sample_home is not null and c.sample_away is not null
           and c.sample_home >= cfg_dom.sample_floor and c.sample_away >= cfg_dom.sample_floor
           and c.d is not null and c.temporal_safe_calc)
        when c.route = 'CROSSLEAGUE' then
          (c.xl_status = 'READY_UNVALIDATED' and c.d is not null and c.temporal_safe_calc)
        else false
      end as publish
    from calc c
  ),
  -- feature snapshot PERSISTED for every row whose features exist (replay anchor)
  snap as (
    insert into v2.feature_snapshot
      (espn_event_id, decision_time, home_gf, home_gc, away_gf, away_gc,
       sample_home, sample_away, feature_data_asof, max_source_event_time, feature_version,
       phi_home, phi_away, phi_model_version, phi_training_cutoff, phi_config_hash)
    select p.espn_event_id, p_decision_time, p.home_gf, p.home_gc, p.away_gf, p.away_gc,
       p.sample_home, p.sample_away, p.feature_data_asof, p.max_source_event_time, p.f_version,
       p.phi_home, p.phi_away, p.phi_mv, p.phi_cutoff, p.phi_hash
    from pub p
    where p.home_gf is not null and p.away_gf is not null
      and p.sample_home is not null and p.sample_away is not null
    on conflict (espn_event_id, decision_time, feature_version) do update
      set home_gf=excluded.home_gf, home_gc=excluded.home_gc,
          away_gf=excluded.away_gf, away_gc=excluded.away_gc,
          sample_home=excluded.sample_home, sample_away=excluded.sample_away,
          feature_data_asof=excluded.feature_data_asof,
          max_source_event_time=excluded.max_source_event_time,
          phi_home=excluded.phi_home, phi_away=excluded.phi_away,
          phi_model_version=excluded.phi_model_version,
          phi_training_cutoff=excluded.phi_training_cutoff,
          phi_config_hash=excluded.phi_config_hash
    returning espn_event_id, feature_version, feature_snapshot_id
  )
  insert into v2.soccer_prediction_v2_staged
    (espn_event_id, competition_id, home_team, away_team, kickoff, decision_time,
     feature_data_asof, max_source_event_time, sample_home, sample_away, temporal_safe,
     feature_version, model_version, model_name, model_route, calibration_status,
     p_home,p_draw,p_away, btts_yes,btts_no, over_line,p_over,p_under, line_source,line_asof,
     model_status, model_status_reason, provenance,
     competition_mapping_version, availability_verified, score_dist, top_scores,
     p_push, ou_line_type, ou_supported, feature_snapshot_id)
  select p.espn_event_id, p.competition_id, p.home_nombre, p.away_nombre, p.kickoff, p_decision_time,
     p.feature_data_asof, p.max_source_event_time, p.sample_home, p.sample_away, p.temporal_safe_calc,
     p.f_version, p.model_version, p.model_name, p.route, p.calib,
     case when p.publish then (p.d->>'p_home')::numeric end,
     case when p.publish then (p.d->>'p_draw')::numeric end,
     case when p.publish then (p.d->>'p_away')::numeric end,
     case when p.publish then (p.d->>'btts_yes')::numeric end,
     case when p.publish then (p.d->>'btts_no')::numeric end,
     p.over_line,
     case when p.publish and p.over_line is not null then (p.d->>'p_over')::numeric end,
     case when p.publish and p.over_line is not null then (p.d->>'p_under')::numeric end,
     case when p.over_line is not null then 'v_momios_confiables:'||coalesce(p.bookmaker,'?') end,
     p.line_asof,
     case when p.publish then 'READY_UNVALIDATED'
          when p.route = 'NONE' then 'NO_MODEL'
          else 'DATA_INCOMPLETE' end,
     -- Single reason, already clean (no '; ;', no leading separator): each branch emits one
     -- self-contained sentence and the route reason is only used when there is no model.
     case
       when p.publish and p.route='DOMESTIC' then
         'DC V2 as-of decision_time desde tasas FINAL de la misma competencia'
       when p.publish and p.route='CROSSLEAGUE' then
         'Cross-league Dixon-Coles con phi sellado as-of decision_time (OOS validado por competencia)'
       when p.route = 'NONE' then p.route_reason
       when p.route = 'CROSSLEAGUE' then
         coalesce(p.xl_reason, 'Datos insuficientes para el modelo cross-league')
       -- DOMESTIC fail-close reasons, most specific first
       when p.sample_home is null or p.sample_away is null then
         'Sin tasas de ambos equipos EN ESTA competencia'
       when p.sample_home < cfg_dom.sample_floor or p.sample_away < cfg_dom.sample_floor then
         'Muestra insuficiente (<'||cfg_dom.sample_floor||'): local='||p.sample_home||' visitante='||p.sample_away
       when not p_enforce_availability then
         'REPLAY_AVAILABILITY_UNVERIFIED: disponibilidad de epoca no verificada; no se reclama temporal_safe'
       when p.max_source_event_time is not null and p.max_source_event_time > p_decision_time then
         'Fuga temporal: features posteriores a decision_time'
       when p.d is null then 'El modelo no pudo estimar goles'
       else 'Datos insuficientes'
     end,
     jsonb_build_object(
        'engine', case p.route when 'DOMESTIC' then 'dc_goal_rates_asof'
                               when 'CROSSLEAGUE' then 'crossleague_dc_sealed_phi'
                               else 'none' end,
        'model_route', p.route, 'model_name', p.model_name,
        'event_liga_id', p.liga_id, 'catalog_competition_id', p.catalog_competition_id,
        'route_reason', p.route_reason,
        'domestic_approved', p.dom_approved, 'crossleague_approved', p.xl_approved,
        'feature_data_asof', p.feature_data_asof,
        'temporal_safe', p.temporal_safe_calc,
        'odds_is_context_not_preto', true,
        'competition_mapping_version', v_map,
        'availability_verified', p_enforce_availability,
        'availability_note', case when p_enforce_availability then 'ENFORCED_cargado_at<=decision'
                                  else 'REPLAY_AVAILABILITY_UNVERIFIED' end,
        'phi', case when p.route='CROSSLEAGUE' then jsonb_build_object(
                      'phi_home', p.phi_home, 'phi_away', p.phi_away,
                      'phi_model_version', p.phi_mv,
                      'phi_training_cutoff', p.phi_cutoff,
                      'phi_config_hash', p.phi_hash,
                      'phi_source', 'v2.fn_crossleague_phi_asof (sealed snapshot; live liga_fuerza NOT read)')
                    else null end,
        'lambda', case when p.d is not null then jsonb_build_object(
                      'lambda_home', p.d->'lambda_home', 'lambda_away', p.d->'lambda_away',
                      'rho', p.d->'rho', 'max_goals', p.d->'max_goals')
                    else null end),
     v_map, p_enforce_availability,
     case when p.publish then (p.d->'dist') end,
     case when p.publish then (p.d->'top_scores') end,
     case when p.publish and p.over_line is not null then (p.d->>'p_push')::numeric end,
     case when p.publish then (p.d->>'ou_line_type') end,
     case when p.publish then (p.d->>'ou_supported')::boolean end,
     s.feature_snapshot_id
  from pub p
  left join snap s on s.espn_event_id = p.espn_event_id and s.feature_version = p.f_version;

  get diagnostics n = row_count;
  return n;
end $function$;

-- ── 7) invariant view: ONE staged row (one P_RETO) per event+decision ───────
-- A violation would mean two models published a visible probability for the same event.
create or replace view v2.v_soccer_staged_identity_violations as
select espn_event_id, decision_time, count(*) n_rows,
       string_agg(distinct model_version, ',' order by model_version) model_versions
from v2.soccer_prediction_v2_staged
group by espn_event_id, decision_time
having count(*) > 1;
