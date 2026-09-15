-- ============================================================================
-- iss052 — MLB DECISION SNAPSHOT CONTRACT (MLB_BRAIN step 1) · STAGED
-- ============================================================================
-- Addresses the STOP-SHIP in issue #4 comment 5624239448 against iss016.
-- NO PROD MUTATION · branch-only · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
--
-- WHAT WAS BROKEN IN iss016 (re-verified by reading the file + prod read-only):
--  1. POST-FIRST-PITCH SNAPSHOTS. `snapshot_mlb_predicciones()` selected
--       ae.fecha BETWEEN now() - interval '3 hours' AND now() + interval '4 days'
--     so it could create a *new* canonical snapshot up to THREE HOURS AFTER first pitch.
--  2. NO DECISION GATE ON READ. `v_prediccion_reto_mlb` took `DISTINCT ON (espn_event_id)
--     ... ORDER BY snapshot_at DESC` with no `snapshot_at < scheduled_at` condition, so the
--     post-start snapshot became the visible, canonical MLB P_RETO. Together, 1+2 are the
--     stop-ship: the model could "predict" a game already in progress.
--  3. NOT ACTUALLY IMMUTABLE. Called append-only, but no UPDATE/DELETE guard existed.
--  4. NO PROVENANCE SEAL. No decision_time, no feature snapshot/hash, no model_version,
--     no calibration_version, no data_asof/data_cutoff.
--  5. MARKETS NOT FROM ONE DISTRIBUTION. It persisted lambdas + total_esperado but not the
--     run distribution, so ML / totals / most-likely score could not all derive from a
--     single snapshot — the same defect class that broke soccer coherence.
--  6. WALL-CLOCK DEPENDENT CANONICAL READ (`scheduled_at >= now() - interval '6 hours'`),
--     so a historical read changes meaning as the clock moves.
--
-- THE FIX IS STRUCTURAL, NOT A WINDOW TWEAK (explicitly demanded: "no patches iss016 by
-- merely changing the -3h window"):
--   * `CHECK (decision_time < scheduled_at)` on the snapshot table makes a post-first-pitch
--     decision PHYSICALLY IMPOSSIBLE to store. No window, no cron schedule and no future
--     caller can reintroduce defect 1 or 2.
--   * The canonical read is a FUNCTION of an explicit as-of instant with no now() in it.
--   * Every market derives from ONE persisted run distribution, settled through the SAME
--     primitive soccer uses (v2.fn_total_weights from iss041) so the two sports cannot drift.
--   * Append-only enforced by trigger; provenance sealed per row.
--
-- WHAT THIS FILE DELIBERATELY DOES NOT DO — read this before calling MLB "done":
--   * It does NOT declare an MLB model validated. Measured in prod read-only on the REAL
--     walk-forward corpus (public.lab_mlb_wf, 1053 temporally-valid games, 2026-05-20..08-30,
--     outcomes joinable 1053/1053 to public.mlb_linescore):
--         moneyline Brier(model)    = 0.24750   vs  Brier(coinflip) = 0.25000
--         skill vs coinflip         = +1.00%    prob range only 0.3762..0.6540
--         per slice: DISCOVERY(519) 0.24785 · VALIDATION(260) 0.24826 · FINAL(274) 0.24612
--     and on the 153 games that actually carry reliable odds, head-to-head vs the no-vig market:
--         Brier(model) = 0.24497   Brier(market no-vig) = 0.24723
--         paired mean gain = +0.00226   sd = 0.05194   se = 0.00420   t = 0.538
--     t = 0.538 is NOT significant. The honest reading is NO DEMONSTRATED SKILL VS MARKET, not
--     "beats the market". public.lab_mlb_split_seal says the same thing from the other side: the
--     whole 1053-game universe is DEVELOPMENT (already globally inspected), so no SKILL_PASS is
--     admissible without a FINAL_TEST_FORWARD strictly after 2026-08-30. calibration_status
--     therefore stays UNVALIDATED and publish decisions stay with the gate, not with this file.
--   * It does NOT treat a positive Brier delta as skill. An earlier draft of fn_mlb_walk_forward
--     below returned BEATS_MARKET_PENDING_REVIEW on `skill_vs_market > 0`; the measurement above
--     shows that bar fires on noise (+0.00226, t=0.538). The verdict now requires a t statistic.
--   * `over_pct_ajustado` from the legacy engine is NOT used as the totals probability. It
--     is kept inside `payload` for traceability only; totals come from the distribution.
--
-- MARKET DATA IS ALSO CONTAMINATED AND IS FILTERED, NOT TRUSTED:
--   public.v_momios_confiables carries 159 of 1114 snapshots for these events at or AFTER first
--   pitch (measured). Every market read in this file is therefore bounded by
--   `snapshot_at <= decision_time`, never "latest".
-- ============================================================================

create schema if not exists v2;

-- ── 1) registry-driven MLB model config (immutable whole-row, like soccer) ───
create table if not exists v2.mlb_model_config (
  sport text not null, model_name text not null, model_version text not null,
  feature_version text not null, calibration_status text not null, calibration_version text,
  max_runs int not null default 18,          -- run-grid cap per team for the joint distribution
  dispersion_r numeric,                      -- Negative-Binomial dispersion; NULL => Poisson
  readiness_floor numeric not null default 0.60,  -- minimum data_readiness to publish
  min_games int not null default 20,              -- readiness denominator (sample floor per team)
  publish_authorized boolean not null default false,
  sealed_at timestamptz not null default now(),
  primary key (sport, model_version)
);

create or replace function v2.fn_mlb_model_config_immutable() returns trigger language plpgsql as $$
begin
  if to_jsonb(new) is distinct from to_jsonb(old) then
    raise exception 'MLB_MODEL_CONFIG_DRIFT: (%,%) es inmutable (whole-row); usa un model_version nuevo',
      new.sport, new.model_version;
  end if;
  return new;
end $$;
drop trigger if exists trg_mlb_model_config_immutable on v2.mlb_model_config;
create trigger trg_mlb_model_config_immutable before update on v2.mlb_model_config
  for each row execute function v2.fn_mlb_model_config_immutable();

-- r=5 mirrors the dispersion the legacy engine already used for its totals overlay; it is
-- recorded as CONFIG (versioned, auditable) instead of being buried in engine code.
-- publish_authorized stays TRUE only because this is a disposable branch: the gate that
-- actually decides visibility is model_status + the event gate, not this flag.
insert into v2.mlb_model_config
  (sport, model_name, model_version, feature_version, calibration_status, calibration_version,
   max_runs, dispersion_r, readiness_floor, min_games, publish_authorized)
values
  ('baseball','mlb_runs_nb_v1','mlb-2026.09.1','mlb_runrates_asof_v1','UNVALIDATED', null,
   18, 5.0, 0.60, 20, true)
on conflict (sport, model_version) do nothing;

-- model_version EXPLICITAMENTE no canonica para los fixtures del runner. Existe para que un
-- fixture de prueba NUNCA comparta identidad con la distribucion canonica (ver el CHECK de
-- gobernanza mas abajo y el hallazgo del auditor que lo motivo).
insert into v2.mlb_model_config
  (sport, model_name, model_version, feature_version, calibration_status, calibration_version,
   max_runs, dispersion_r, readiness_floor, min_games, publish_authorized)
values
  ('baseball','mlb_test_fixture','mlb-fixture-v1','fixture','NOT_A_MODEL', null,
   18, 5.0, 0.60, 20, false)
on conflict (sport, model_version) do nothing;

-- ── 2) point-in-time feature snapshot (immutable, hashed) ───────────────────
create table if not exists v2.mlb_feature_snapshot (
  feature_snapshot_id uuid primary key default gen_random_uuid(),
  espn_event_id text not null,
  decision_time  timestamptz not null,
  feature_version text not null,
  lambda_home numeric, lambda_away numeric,
  data_readiness numeric,
  starter_home text, starter_away text,
  features jsonb,                      -- the exact feature payload used
  feature_hash text,                   -- md5 of the sealed feature payload
  data_asof timestamptz,               -- latest source observation time actually used
  asof_proven boolean not null default false,  -- could point-in-time safety be PROVEN?
  created_at timestamptz not null default now(),
  unique (espn_event_id, decision_time, feature_version)
);

create or replace function v2.fn_mlb_feature_snapshot_immutable() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MLB_FEATURE_SNAPSHOT_IMMUTABLE: DELETE prohibido (append-only)';
  end if;
  if row(new.lambda_home,new.lambda_away,new.data_readiness,new.feature_hash,new.data_asof,new.asof_proven)
     is distinct from
     row(old.lambda_home,old.lambda_away,old.data_readiness,old.feature_hash,old.data_asof,old.asof_proven) then
    raise exception 'MLB_FEATURE_SNAPSHOT_DRIFT: (%,%,%) ya sellado con features distintas; usa un feature_version nuevo',
      new.espn_event_id, new.decision_time, new.feature_version;
  end if;
  return new;
end $$;
drop trigger if exists trg_mlb_feature_snapshot_immutable on v2.mlb_feature_snapshot;
create trigger trg_mlb_feature_snapshot_immutable before update or delete on v2.mlb_feature_snapshot
  for each row execute function v2.fn_mlb_feature_snapshot_immutable();

-- ── 3) THE STRUCTURAL FIX: decision snapshot that cannot be post-first-pitch ─
create table if not exists v2.mlb_prediction_snapshot (
  espn_event_id text not null,
  decision_time timestamptz not null,
  model_version text not null,
  model_name    text,
  scheduled_at  timestamptz not null,          -- first pitch
  home_team text, away_team text, liga_nombre text,
  -- model output, ALL derived from run_dist below
  lambda_home numeric, lambda_away numeric, dispersion_r numeric,
  run_dist  jsonb,                             -- COMPLETE joint run distribution (single source)
  top_scores jsonb,                            -- canonical top-k exact scores, ordered
  p_home_ml numeric, p_away_ml numeric,        -- renormalized excluding regulation ties
  p_tie_regulation numeric,                    -- transparency: mass removed by renormalization
  total_line numeric, p_over numeric, p_under numeric, p_push numeric,
  ou_line_type text, ou_supported boolean,
  line_source text, line_asof timestamptz,
  total_esperado numeric,
  -- governance / provenance
  feature_version text, calibration_status text, calibration_version text,
  data_asof timestamptz, asof_proven boolean,
  data_readiness numeric,
  model_status text not null, model_status_reason text,
  provenance jsonb,
  feature_snapshot_id uuid references v2.mlb_feature_snapshot(feature_snapshot_id),
  built_at timestamptz not null default now(),
  primary key (espn_event_id, decision_time, model_version),
  -- ========================================================================
  -- THIS CONSTRAINT IS THE FIX. iss016 could write a snapshot up to 3h AFTER
  -- first pitch and the canonical view would then serve it as P_RETO. Here the
  -- database refuses to store a decision that is not strictly pre-first-pitch,
  -- so no window, cron schedule or future caller can reintroduce the defect.
  -- ========================================================================
  constraint mlb_pred_snapshot_pre_first_pitch check (decision_time < scheduled_at),

  -- ========================================================================
  -- GOBERNANZA COMPLETA. Hallazgo del auditor (issue #4, comentario 5626963399):
  -- dentro de la MISMA model_version canonica convivian 88 filas con
  -- calibration_status='UNVALIDATED' y 4 con calibration_status y data_readiness
  -- NULL. Esas 4 eran los fixtures WF0001..WF0004 del runner del gate. Mezclar
  -- contratos dentro de una model_version rompe la semantica de UNA distribucion
  -- canonica y vuelve ambiguo un replay. El arreglo de raiz es doble:
  --   1. este CHECK, que hace IMPOSIBLE una fila READY sin su contrato completo;
  --   2. el runner pasa a insertar sus fixtures bajo model_version
  --      'mlb-fixture-v1' con calibration_status='NOT_A_MODEL'.
  -- Una fila DATA_INCOMPLETE sigue permitida con todo NULL: asi debe ser, es el
  -- fail-close honesto. Probado en rama: canonica-incompleta bloqueada,
  -- DATA_INCOMPLETE permitida.
  -- ========================================================================
  constraint mlb_pred_gobernanza_completa check (
    model_status <> 'READY_UNVALIDATED'
    or (calibration_status is not null and feature_version is not null
        and data_readiness is not null and data_asof is not null and provenance is not null))
);
create index if not exists ix_mlb_pred_snapshot_event
  on v2.mlb_prediction_snapshot (espn_event_id, decision_time desc);

create or replace function v2.fn_mlb_prediction_snapshot_immutable() returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'MLB_PREDICTION_SNAPSHOT_IMMUTABLE: DELETE prohibido; un snapshot de decision es historia, no estado';
  end if;
  raise exception 'MLB_PREDICTION_SNAPSHOT_IMMUTABLE: UPDATE prohibido; una correccion se agrega como decision_time nuevo';
end $$;
drop trigger if exists trg_mlb_prediction_snapshot_immutable on v2.mlb_prediction_snapshot;
create trigger trg_mlb_prediction_snapshot_immutable before update or delete on v2.mlb_prediction_snapshot
  for each row execute function v2.fn_mlb_prediction_snapshot_immutable();

-- ── 4) POINT-IN-TIME feature source (append-only observations) ──────────────
-- The reason iss016 could not be made temporally honest is that its feature source
-- (mlb_stats_cache) holds CURRENT STATE with no observation time, so "what did we know at
-- decision time" is unanswerable and a historical replay is contaminated. The fix is to
-- read run rates from an APPEND-ONLY observation log keyed by observed_at. Only then can
-- asof_proven be true.
create table if not exists v2.mlb_run_rate_observation (
  team_espn_id text not null,
  observed_at  timestamptz not null,
  runs_scored_pg numeric not null,
  runs_allowed_pg numeric not null,
  games int not null,
  source text,
  primary key (team_espn_id, observed_at)
);
create table if not exists v2.mlb_league_baseline (
  observed_at timestamptz primary key,
  runs_per_game numeric not null,
  source text
);

-- Features AS OF an explicit instant. Nothing observed after p_decision_time can enter.
-- asof_proven is TRUE only when every input carried an observation time at or before the
-- decision; a caller that cannot prove it gets asof_proven=false and the builder fail-closes.
create or replace function v2.fn_mlb_features_asof(
  p_home_espn_id text, p_away_espn_id text, p_decision_time timestamptz,
  p_window_days int default 365, p_min_games int default 20
) returns table(
  lambda_home numeric, lambda_away numeric,
  rs_home numeric, ra_home numeric, rs_away numeric, ra_away numeric,
  games_home int, games_away int, league_rpg numeric,
  data_asof timestamptz, asof_proven boolean, data_readiness numeric
) language plpgsql stable as $$
-- p_min_games is the readiness denominator, NOT a silent constant. It is 20 because the real
-- point-in-time corpus supports it: derived from public.mlb_linescore over 2026-05-20..08-30 every
-- one of the 30 teams carries 61..76 completed games (avg 69.7, measured). A caller that lowers it
-- to manufacture a READY row is visible in the snapshot's own feature payload.
declare h record; a record; lg record; v_min_games int := greatest(1, p_min_games);
begin
  select * into h from v2.mlb_run_rate_observation o
   where o.team_espn_id = p_home_espn_id and o.observed_at <= p_decision_time
     and o.observed_at >= p_decision_time - make_interval(days => p_window_days)
   order by o.observed_at desc limit 1;
  select * into a from v2.mlb_run_rate_observation o
   where o.team_espn_id = p_away_espn_id and o.observed_at <= p_decision_time
     and o.observed_at >= p_decision_time - make_interval(days => p_window_days)
   order by o.observed_at desc limit 1;
  select * into lg from v2.mlb_league_baseline b
   where b.observed_at <= p_decision_time order by b.observed_at desc limit 1;

  rs_home := h.runs_scored_pg; ra_home := h.runs_allowed_pg; games_home := h.games;
  rs_away := a.runs_scored_pg; ra_away := a.runs_allowed_pg; games_away := a.games;
  league_rpg := lg.runs_per_game;
  data_asof := greatest(h.observed_at, a.observed_at, lg.observed_at);
  asof_proven := (h.observed_at is not null and a.observed_at is not null and lg.observed_at is not null
                  and data_asof <= p_decision_time);

  -- readiness = how much of the minimum sample both teams actually have (0..1)
  data_readiness := case
    when games_home is null or games_away is null then 0
    else round(least(1.0, least(games_home, games_away)::numeric / v_min_games), 4) end;

  if rs_home is null or ra_home is null or rs_away is null or ra_away is null
     or league_rpg is null or league_rpg <= 0 then
    return next; return;   -- lambdas NULL -> builder fail-closes with a data reason
  end if;

  -- Run expectancy: own offense x opponent defense, scaled by the league baseline.
  -- Simple, explicit and auditable. It is NOT claimed to be skilful; calibration_status
  -- stays UNVALIDATED until forward-accumulated snapshots can be scored.
  lambda_home := round(rs_home * ra_away / league_rpg, 4);
  lambda_away := round(rs_away * ra_home / league_rpg, 4);
  return next;
end $$;

-- ── 5) CANONICAL RUN DISTRIBUTION — the single source for every MLB market ───
-- Emits the COMPLETE joint run distribution in the SAME cell shape soccer uses
-- ({'s':'home-away','p':pct}), so v2.fn_matrix_market (iss042) and v2.fn_total_weights
-- (iss041) apply UNCHANGED. One settlement primitive across both sports means MLB totals
-- and soccer totals cannot drift apart.
--
-- Marginals: Negative Binomial (mean lambda, dispersion r) when r is supplied, else Poisson.
-- NB is used because MLB run counts are over-dispersed relative to Poisson; r is versioned
-- in v2.mlb_model_config rather than buried in engine code.
-- ASSUMPTION, stated plainly: home and away run counts are treated as INDEPENDENT. That is
-- an approximation (shared park/weather/umpire effects correlate them) and is one of the
-- things that must be validated before this model is trusted.
create or replace function v2.fn_mlb_run_dist(
  lam_h numeric, lam_a numeric, total_line numeric default null,
  disp_r numeric default null, maxr integer default 18
) returns jsonb language plpgsql immutable as $$
declare
  ph numeric[]; pa numeric[]; i int; j int; k int;
  cell numeric; css text[] := array[]::text[]; cpp numeric[] := array[]::numeric[];
  dist_sum numeric := 0; residual numeric; modal_idx int := 1;
  best numeric := -1; best_i int := 0; best_j int := 0;
  p_home_reg numeric := 0; p_away_reg numeric := 0; p_tie numeric := 0;
  p_over numeric := 0; p_under numeric := 0; p_push numeric := 0;
  ou_supported boolean := true; ou_line_type text; ou_reason text; frac numeric;
  w numeric[]; gi int; gj int; g numeric; dist jsonb := '[]'::jsonb; top_scores jsonb;
  denom numeric;
begin
  if lam_h is null or lam_a is null or lam_h <= 0 or lam_a <= 0 or lam_h > 30 or lam_a > 30 then
    return null;
  end if;
  if maxr is null or maxr < 10 then maxr := 18; end if;
  if maxr > 30 then maxr := 30; end if;

  -- marginal pmfs by stable recursion (no lgamma needed)
  ph := array_fill(0::numeric, array[maxr+1]);
  pa := array_fill(0::numeric, array[maxr+1]);
  if disp_r is null then
    ph[1] := exp(-lam_h); pa[1] := exp(-lam_a);
    for k in 1..maxr loop
      ph[k+1] := ph[k] * lam_h / k;
      pa[k+1] := pa[k] * lam_a / k;
    end loop;
  else
    ph[1] := power(disp_r/(disp_r+lam_h), disp_r);
    pa[1] := power(disp_r/(disp_r+lam_a), disp_r);
    for k in 1..maxr loop
      ph[k+1] := ph[k] * ((k + disp_r - 1)/k) * (lam_h/(disp_r+lam_h));
      pa[k+1] := pa[k] * ((k + disp_r - 1)/k) * (lam_a/(disp_r+lam_a));
    end loop;
  end if;

  -- joint grid, every cell emitted (no >=1% truncation), 2dp, modal cell tracked
  for i in 0..maxr loop for j in 0..maxr loop
    cell := ph[i+1] * pa[j+1];
    if cell > best then best := cell; best_i := i; best_j := j; end if;
    if round(cell*100, 2) > 0 then
      css := array_append(css, i||'-'||j);
      cpp := array_append(cpp, round(cell*100, 2));
      dist_sum := dist_sum + round(cell*100, 2);
    end if;
  end loop; end loop;
  if array_length(css,1) is null then return null; end if;
  for k in 1..array_length(css,1) loop
    if css[k] = best_i||'-'||best_j then modal_idx := k; end if;
  end loop;
  -- fold the rounding/truncation residual into the modal cell so the matrix sums to EXACTLY 100
  residual := round(100 - dist_sum, 2);
  cpp[modal_idx] := cpp[modal_idx] + residual;

  if total_line is not null then
    frac := total_line - floor(total_line);
    ou_line_type := case frac when 0 then 'WHOLE' when 0.5 then 'HALF'
                              when 0.25 then 'QUARTER' when 0.75 then 'QUARTER'
                              else 'UNSUPPORTED' end;
    if ou_line_type = 'UNSUPPORTED' then
      ou_supported := false; ou_reason := 'unsupported total line fraction '||frac;
    end if;
  end if;

  -- derive EVERY market by summing the SAME emitted cells
  for k in 1..array_length(css,1) loop
    gi := split_part(css[k],'-',1)::int; gj := split_part(css[k],'-',2)::int; g := cpp[k];
    if gi > gj then p_home_reg := p_home_reg + g;
    elsif gi < gj then p_away_reg := p_away_reg + g;
    else p_tie := p_tie + g; end if;
    if total_line is not null and ou_supported then
      w := v2.fn_total_weights(gi+gj, total_line);
      if w is null then ou_supported := false; ou_reason := 'settlement undefined for line '||total_line;
      else p_over := p_over + g*w[1]; p_push := p_push + g*w[2]; p_under := p_under + g*w[3]; end if;
    end if;
    dist := dist || jsonb_build_object('s', css[k], 'p', cpp[k]);
  end loop;

  select jsonb_agg(jsonb_build_object('s', s, 'p', p)) into top_scores
  from (select s, p from (
          select (e->>'s') s, (e->>'p')::numeric p,
                 split_part(e->>'s','-',1)::int gi2, split_part(e->>'s','-',2)::int gj2
          from jsonb_array_elements(dist) e
        ) z order by p desc, (gi2+gj2) asc, gi2 asc limit 5) t;

  -- MLB has no regulation tie: extra innings always produce a winner. The tie mass is
  -- REMOVED BY RENORMALIZATION and reported as p_tie_regulation so the adjustment is
  -- auditable rather than hidden. (Modelling extra innings explicitly is future work.)
  denom := p_home_reg + p_away_reg;
  if denom <= 0 then return null; end if;

  return jsonb_build_object(
    'lambda_home', round(lam_h,4), 'lambda_away', round(lam_a,4),
    'dispersion_r', disp_r, 'max_runs', maxr,
    'exp_total', round(lam_h + lam_a, 2),
    'p_home_ml', round(100*p_home_reg/denom, 1),
    'p_away_ml', round(100*p_away_reg/denom, 1),
    'p_tie_regulation', round(p_tie, 2),
    'total_line', total_line, 'ou_line_type', ou_line_type,
    'ou_supported', ou_supported, 'ou_reason', ou_reason,
    'p_over',  case when total_line is null or not ou_supported then null else round(p_over,1) end,
    'p_under', case when total_line is null or not ou_supported then null else round(p_under,1) end,
    'p_push',  case when total_line is null or not ou_supported then null else round(p_push,1) end,
    'predicted_score', (top_scores->0->>'s'),
    'predicted_score_prob', (top_scores->0->>'p')::numeric,
    'dist', dist, 'top_scores', top_scores,
    'dist_sum_pct', 100, 'dist_complete', true);
end $$;

-- ── 6) BUILDER: one immutable decision snapshot per event, strictly pre-first-pitch ──
-- Universe is agenda baseball with `fecha > p_decision_time`. A game already underway is
-- simply not in the universe, and the table CHECK makes it unstorable even if it were.
create or replace function v2.build_mlb_prediction_snapshot(
  p_decision_time timestamptz,
  p_require_asof_proven boolean default true
) returns integer language plpgsql as $function$
declare n int := 0; cfg record; r record; f record; o record; d jsonb;
  v_fs uuid; v_status text; v_reason text; v_publish boolean; v_hash text;
begin
  select * into cfg from v2.mlb_model_config
   where sport='baseball' and model_version='mlb-2026.09.1';
  if cfg is null then raise exception 'MLB_MODEL_CONFIG_MISSING: baseball/mlb-2026.09.1'; end if;

  for r in
    select distinct on (a.espn_event_id) a.espn_event_id, a.fecha scheduled_at,
           a.home_nombre, a.away_nombre, a.liga_nombre, a.home_espn_id, a.away_espn_id
    from public.agenda_espn a
    where a.deporte='baseball' and a.fecha > p_decision_time
    order by a.espn_event_id, a.fecha
  loop
    select * into f from v2.fn_mlb_features_asof(
             r.home_espn_id, r.away_espn_id, p_decision_time, 365, cfg.min_games);
    select * into o from v2.fn_real_total_line(r.espn_event_id, p_decision_time);

    d := case when f.lambda_home is not null and f.lambda_away is not null
              then v2.fn_mlb_run_dist(f.lambda_home, f.lambda_away,
                                      o.provider_total_line, cfg.dispersion_r, cfg.max_runs)
         end;

    v_publish := (d is not null
                  and coalesce(f.data_readiness,0) >= cfg.readiness_floor
                  and (coalesce(f.asof_proven,false) or not p_require_asof_proven)
                  and coalesce(f.asof_proven,false));   -- publishing ALWAYS needs proven as-of
    v_status := case when v_publish then 'READY_UNVALIDATED' else 'DATA_INCOMPLETE' end;
    v_reason := case
      when v_publish then 'MLB run-rate NB model as-of decision_time; todos los mercados derivan de run_dist'
      when f.lambda_home is null or f.lambda_away is null then
        'Sin observaciones de carreras as-of para ambos equipos (o sin baseline de liga) <= decision_time'
      when not coalesce(f.asof_proven,false) then
        'AS_OF_NOT_PROVEN: alguna entrada carece de observed_at <= decision_time; no se publica probabilidad'
      when coalesce(f.data_readiness,0) < cfg.readiness_floor then
        'Muestra insuficiente: data_readiness '||coalesce(f.data_readiness,0)||' < '||cfg.readiness_floor
      when d is null then 'El modelo no pudo construir la distribucion de carreras'
      else 'Datos insuficientes' end;

    v_hash := md5(coalesce(f.lambda_home::text,'')||'|'||coalesce(f.lambda_away::text,'')||'|'
                  ||coalesce(f.rs_home::text,'')||'|'||coalesce(f.ra_home::text,'')||'|'
                  ||coalesce(f.rs_away::text,'')||'|'||coalesce(f.ra_away::text,'')||'|'
                  ||coalesce(f.league_rpg::text,'')||'|'||cfg.feature_version);

    insert into v2.mlb_feature_snapshot
      (espn_event_id, decision_time, feature_version, lambda_home, lambda_away,
       data_readiness, features, feature_hash, data_asof, asof_proven)
    values (r.espn_event_id, p_decision_time, cfg.feature_version, f.lambda_home, f.lambda_away,
       f.data_readiness,
       jsonb_build_object('rs_home',f.rs_home,'ra_home',f.ra_home,'rs_away',f.rs_away,
                          'ra_away',f.ra_away,'league_rpg',f.league_rpg,
                          'games_home',f.games_home,'games_away',f.games_away),
       v_hash, f.data_asof, coalesce(f.asof_proven,false))
    on conflict (espn_event_id, decision_time, feature_version) do nothing;

    select feature_snapshot_id into v_fs from v2.mlb_feature_snapshot
     where espn_event_id=r.espn_event_id and decision_time=p_decision_time
       and feature_version=cfg.feature_version;

    insert into v2.mlb_prediction_snapshot
      (espn_event_id, decision_time, model_version, model_name, scheduled_at,
       home_team, away_team, liga_nombre,
       lambda_home, lambda_away, dispersion_r, run_dist, top_scores,
       p_home_ml, p_away_ml, p_tie_regulation,
       total_line, p_over, p_under, p_push, ou_line_type, ou_supported,
       line_source, line_asof, total_esperado,
       feature_version, calibration_status, calibration_version,
       data_asof, asof_proven, data_readiness,
       model_status, model_status_reason, provenance, feature_snapshot_id)
    values (r.espn_event_id, p_decision_time, cfg.model_version, cfg.model_name, r.scheduled_at,
       r.home_nombre, r.away_nombre, r.liga_nombre,
       f.lambda_home, f.lambda_away, cfg.dispersion_r,
       case when v_publish then d->'dist' end,
       case when v_publish then d->'top_scores' end,
       case when v_publish then (d->>'p_home_ml')::numeric end,
       case when v_publish then (d->>'p_away_ml')::numeric end,
       case when v_publish then (d->>'p_tie_regulation')::numeric end,
       o.provider_total_line,
       case when v_publish and o.provider_total_line is not null then (d->>'p_over')::numeric end,
       case when v_publish and o.provider_total_line is not null then (d->>'p_under')::numeric end,
       case when v_publish and o.provider_total_line is not null then (d->>'p_push')::numeric end,
       case when v_publish then (d->>'ou_line_type') end,
       case when v_publish then (d->>'ou_supported')::boolean end,
       case when o.provider_total_line is not null then 'v_momios_confiables:'||coalesce(o.provider,'?') end,
       o.line_asof,
       case when v_publish then (d->>'exp_total')::numeric end,
       cfg.feature_version, cfg.calibration_status, cfg.calibration_version,
       f.data_asof, coalesce(f.asof_proven,false), f.data_readiness,
       v_status, v_reason,
       jsonb_build_object(
         'engine','mlb_runs_nb_asof','model_name',cfg.model_name,
         'independence_assumption','home/away run counts treated as independent (approximation; must be validated)',
         'tie_handling','regulation-tie mass removed by renormalization; reported as p_tie_regulation',
         'feature_hash', v_hash, 'data_asof', f.data_asof,
         'asof_proven', coalesce(f.asof_proven,false),
         'odds_is_context_not_preto', true,
         'totals_source','run_dist (legacy over_pct_ajustado NOT used)',
         'decision_pre_first_pitch', true),
       v_fs)
    on conflict (espn_event_id, decision_time, model_version) do nothing;
    n := n + 1;
  end loop;
  return n;
end $function$;

-- ── 7) 2-WAY market discrepancy (MLB has no draw) ───────────────────────────
create or replace function v2.fn_mlb_market_discrepancy(
  p_home_ml numeric, p_over numeric,
  p_odds_home numeric, p_odds_away numeric,
  p_odds_over numeric, p_odds_under numeric
) returns table(nv_home numeric, nv_over numeric, winner_gap numeric, total_gap numeric,
                flag text, suppress boolean, reason text)
language plpgsql immutable as $$
declare m record; t record; wg numeric; tg numeric;
begin
  select * into m from v2.fn_novig_2way(p_odds_home, p_odds_away);
  select * into t from v2.fn_novig_2way(p_odds_over, p_odds_under);
  nv_home := m.nv_1; nv_over := t.nv_1;
  wg := case when m.nv_1 is null or p_home_ml is null then null else round(p_home_ml - m.nv_1,1) end;
  tg := case when t.nv_1 is null or p_over   is null then null else round(p_over   - t.nv_1,1) end;
  winner_gap := wg; total_gap := tg;
  -- Market ABSENCE is not a discrepancy; it is a distinct diagnostic state and must never
  -- fabricate a gap or make an event ineligible on its own.
  if wg is null and tg is null then
    flag:='NO_MARKET_DIAGNOSTIC'; suppress:=false; reason:='sin momios para diagnostico modelo-vs-mercado';
    return next; return;
  end if;
  if (wg is not null and abs(wg) >= 18) or (tg is not null and abs(tg) >= 18)
     or (wg is not null and abs(wg) >= 12 and tg is not null and abs(tg) >= 12) then
    flag:='QUALITY_DOWNGRADE'; suppress:=true;
    reason:=concat_ws('; ',
      case when wg is not null and abs(wg)>=12 then 'winner_gap '||wg||'pp (modelo '||p_home_ml||' vs no-vig '||m.nv_1||')' end,
      case when tg is not null and abs(tg)>=12 then 'total_gap '||tg||'pp (modelo over '||p_over||' vs no-vig '||t.nv_1||')' end);
    return next; return;
  end if;
  if (wg is not null and abs(wg) >= 12) or (tg is not null and abs(tg) >= 12) then
    flag:='REVIEW_REQUIRED'; suppress:=true;
    reason:=concat_ws('; ',
      case when wg is not null and abs(wg)>=12 then 'winner_gap '||wg||'pp' end,
      case when tg is not null and abs(tg)>=12 then 'total_gap '||tg||'pp' end);
    return next; return;
  end if;
  flag:='OK'; suppress:=false; reason:='dentro de tolerancia'; return next;
end $$;

-- ── 8) COHERENCE GATE: every published scalar must derive from run_dist ─────
-- Reuses v2.fn_matrix_market (iss042) unchanged, because run_dist uses the same cell shape.
create or replace function v2.fn_mlb_event_gate_status(
  p_dist jsonb, p_home_ml numeric, p_away_ml numeric,
  p_total_line numeric, p_over numeric, p_under numeric, p_push numeric,
  p_ou_line_type text, p_ou_supported boolean, p_top_scores jsonb,
  p_odds_home numeric, p_odds_away numeric, p_odds_over numeric, p_odds_under numeric,
  p_tol numeric default 0.2
) returns table(coherence_ok boolean, disc_flag text, suppress boolean,
                top_only_eligible boolean, gate_reason text)
language plpgsql immutable as $$
declare coh boolean := true; reasons text := null; d record;
  dist_sum numeric; n_cells int; n_uniq int; mh numeric; ma numeric; denom numeric;
  expected_lt text; expected_sup boolean; frac numeric; true_top jsonb; top_keys jsonb;
begin
  if p_dist is null or jsonb_typeof(p_dist) <> 'array' or jsonb_array_length(p_dist)=0 then
    coh := false; reasons := concat_ws('; ', reasons, 'MATRIX_MISSING_OR_EMPTY');
  else
    select count(*), count(distinct x->>'s'), round(sum((x->>'p')::numeric),2)
      into n_cells, n_uniq, dist_sum from jsonb_array_elements(p_dist) x;
    if n_uniq <> n_cells then coh:=false; reasons:=concat_ws('; ',reasons,'MATRIX_DUPLICATE_SCORE'); end if;
    if abs(dist_sum - 100) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'MATRIX_SUM_NOT_100'); end if;
    if exists (select 1 from jsonb_array_elements(p_dist) x
               where x->>'s' is null or x->>'s' !~ '^[0-9]+-[0-9]+$'
                  or (x->>'p') is null or (x->>'p')::numeric < 0) then
      coh:=false; reasons:=concat_ws('; ',reasons,'MATRIX_CELL_INVALID'); end if;

    -- ML must equal the tie-renormalized matrix split, not some independent number
    mh := v2.fn_matrix_market(p_dist,'1X2','HOME');
    ma := v2.fn_matrix_market(p_dist,'1X2','AWAY');
    denom := mh + ma;
    if p_home_ml is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_home_ml');
    elsif denom > 0 and abs(p_home_ml - round(100*mh/denom,1)) > p_tol then
      coh:=false; reasons:=concat_ws('; ',reasons,'ML_HOME_NOT_FROM_MATRIX'); end if;
    if p_away_ml is null then coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:p_away_ml');
    elsif denom > 0 and abs(p_away_ml - round(100*ma/denom,1)) > p_tol then
      coh:=false; reasons:=concat_ws('; ',reasons,'ML_AWAY_NOT_FROM_MATRIX'); end if;
    if p_home_ml is not null and p_away_ml is not null and abs((p_home_ml+p_away_ml)-100) > p_tol then
      coh:=false; reasons:=concat_ws('; ',reasons,'SUM_ML_NOT_100'); end if;

    if p_top_scores is null or jsonb_typeof(p_top_scores) <> 'array'
       or jsonb_array_length(p_top_scores) <> 5 then
      coh:=false; reasons:=concat_ws('; ',reasons,'TOPK_NOT_5');
    else
      select jsonb_agg(z.s) into true_top from (
        select c->>'s' s from jsonb_array_elements(p_dist) c
        order by (c->>'p')::numeric desc,
                 (split_part(c->>'s','-',1)::int + split_part(c->>'s','-',2)::int) asc,
                 split_part(c->>'s','-',1)::int asc limit 5) z;
      select jsonb_agg(t->>'s') into top_keys from jsonb_array_elements(p_top_scores) t;
      if top_keys is distinct from true_top then coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_ORDER'); end if;
      if exists (select 1 from jsonb_array_elements(p_top_scores) t
                 where abs((t->>'p')::numeric - v2.fn_matrix_market(p_dist,'EXACT',t->>'s')) > p_tol) then
        coh:=false; reasons:=concat_ws('; ',reasons,'TOP_SCORES_PROB'); end if;
    end if;

    if p_total_line is not null then
      frac := p_total_line - floor(p_total_line);
      expected_lt := case when frac=0 then 'WHOLE' when frac=0.5 then 'HALF'
                          when frac in (0.25,0.75) then 'QUARTER' else 'UNSUPPORTED' end;
      expected_sup := expected_lt <> 'UNSUPPORTED';
      if p_ou_line_type is distinct from expected_lt then coh:=false; reasons:=concat_ws('; ',reasons,'OU_LINE_TYPE_MISMATCH'); end if;
      if p_ou_supported is distinct from expected_sup then coh:=false; reasons:=concat_ws('; ',reasons,'OU_SUPPORTED_MISMATCH'); end if;
      if expected_sup then
        if p_over is null or p_under is null or p_push is null then
          coh:=false; reasons:=concat_ws('; ',reasons,'NULL_FIELD:ou');
        else
          if abs((p_over+p_push+p_under)-100) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_SUM_NOT_100'); end if;
          if abs(p_over  - v2.fn_matrix_market(p_dist,'OU','OVER', p_total_line)) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_OVER'); end if;
          if abs(p_under - v2.fn_matrix_market(p_dist,'OU','UNDER',p_total_line)) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNDER'); end if;
          if abs(p_push  - v2.fn_matrix_market(p_dist,'OU','PUSH', p_total_line)) > p_tol then coh:=false; reasons:=concat_ws('; ',reasons,'OU_PUSH'); end if;
        end if;
      else
        if p_over is not null or p_under is not null or p_push is not null then
          coh:=false; reasons:=concat_ws('; ',reasons,'OU_UNSUPPORTED_MUST_BE_NULL'); end if;
      end if;
    end if;
  end if;

  coherence_ok := coh;
  if not coh then reasons := concat_ws('; ', 'COHERENCE_FAIL', reasons); end if;
  select * into d from v2.fn_mlb_market_discrepancy(p_home_ml, p_over, p_odds_home, p_odds_away, p_odds_over, p_odds_under);
  disc_flag := d.flag; suppress := coalesce(d.suppress,false);
  if suppress then reasons := concat_ws('; ', reasons, d.flag||': '||d.reason); end if;
  top_only_eligible := coherence_ok and not suppress;
  gate_reason := nullif(reasons,'');
  return next;
end $$;

-- ── 9) CLOCK-INDEPENDENT CANONICAL READ ─────────────────────────────────────
-- iss016's canonical view embedded now() twice (`scheduled_at >= now() - 6h` and an
-- unbounded latest-snapshot pick), so the same historical question returned different
-- answers as the clock moved. Here the canonical read is a FUNCTION OF AN EXPLICIT INSTANT
-- and contains no now() at all: "what did the model say for this event, as known at p_asof".
-- Because the table CHECK guarantees decision_time < scheduled_at, anything this returns is
-- necessarily a pre-first-pitch decision.
create or replace function v2.fn_mlb_prediction_asof(
  p_event_id text, p_asof timestamptz, p_model_version text default 'mlb-2026.09.1'
) returns setof v2.mlb_prediction_snapshot language sql stable as $$
  select * from v2.mlb_prediction_snapshot s
  where s.espn_event_id = p_event_id
    and s.model_version = p_model_version
    and s.decision_time <= p_asof
  order by s.decision_time desc
  limit 1;
$$;

-- Board as of an instant (no now()). A caller that wants "live" passes now() ITSELF, which
-- keeps the wall-clock dependency at the edge instead of baking it into canonical truth.
create or replace function v2.fn_mlb_canonical_board(
  p_asof timestamptz, p_model_version text default 'mlb-2026.09.1'
) returns table(
  canonical_event_id text, sport text, home_team text, away_team text, liga_nombre text,
  scheduled_at timestamptz, decision_time timestamptz, model_version text,
  p_home_ml numeric, p_away_ml numeric, p_tie_regulation numeric,
  total_line numeric, p_over numeric, p_under numeric, p_push numeric,
  model_status text, model_status_reason text, calibration_status text,
  data_asof timestamptz, asof_proven boolean, data_readiness numeric,
  model_snapshot_id uuid, prob_source text
) language sql stable as $$
  select distinct on (s.espn_event_id)
    s.espn_event_id, 'baseball'::text, s.home_team, s.away_team, s.liga_nombre,
    s.scheduled_at, s.decision_time, s.model_version,
    s.p_home_ml, s.p_away_ml, s.p_tie_regulation,
    s.total_line, s.p_over, s.p_under, s.p_push,
    s.model_status, s.model_status_reason, s.calibration_status,
    s.data_asof, s.asof_proven, s.data_readiness,
    s.feature_snapshot_id,
    'mlb_runs_nb_asof'::text
  from v2.mlb_prediction_snapshot s
  where s.model_version = p_model_version
    and s.decision_time <= p_asof
  order by s.espn_event_id, s.decision_time desc;
$$;

-- ── 10) event gate + candidates over the real snapshot path ─────────────────
create or replace view v2.v_mlb_event_gate as
select s.espn_event_id as canonical_event_id, s.decision_time, s.model_version,
       g.coherence_ok, g.disc_flag, coalesce(g.suppress,false) as suppress,
       (s.model_status='READY_UNVALIDATED' and coalesce(g.coherence_ok,false)
        and not coalesce(g.suppress,false)) as top_only_eligible,
       g.gate_reason
from v2.mlb_prediction_snapshot s
left join lateral (
  select mc.home_ml, mc.away_ml from public.v_momios_confiables mc
  where mc.espn_event_id = s.espn_event_id and mc.confiable is true
    and mc.snapshot_at <= s.decision_time
  order by mc.snapshot_at desc limit 1) oml on true
left join lateral (
  select mc.over_odds, mc.under_odds from public.v_momios_confiables mc
  where mc.espn_event_id = s.espn_event_id and mc.confiable is true
    and mc.snapshot_at <= s.decision_time and mc.over_line = s.total_line
  order by mc.snapshot_at desc limit 1) oou on true
left join lateral v2.fn_mlb_event_gate_status(
  s.run_dist, s.p_home_ml, s.p_away_ml, s.total_line, s.p_over, s.p_under, s.p_push,
  s.ou_line_type, s.ou_supported, s.top_scores,
  oml.home_ml, oml.away_ml, oou.over_odds, oou.under_odds) g on true;

create or replace view v2.v_mlb_daily_candidates as
select s.espn_event_id as canonical_event_id, s.home_team, s.away_team, s.liga_nombre,
       s.scheduled_at, s.decision_time, s.model_version,
       s.feature_snapshot_id as model_snapshot_id,
       cand.canonical_market, cand.canonical_side, cand.canonical_line,
       cand.canonical_probability, cand.canonical_push, cand.canonical_line_type,
       s.data_readiness
from v2.mlb_prediction_snapshot s
join v2.v_mlb_event_gate g
  on g.canonical_event_id = s.espn_event_id
 and g.decision_time = s.decision_time
 and g.model_version = s.model_version
 and g.top_only_eligible
cross join lateral (values
    ('ML'::text, 'HOME'::text, null::numeric, s.p_home_ml, null::numeric, null::text),
    ('ML',       'AWAY',        null,         s.p_away_ml, null,          null),
    ('OU',       'OVER',        s.total_line, case when s.total_line is not null then s.p_over  end, s.p_push, s.ou_line_type),
    ('OU',       'UNDER',       s.total_line, case when s.total_line is not null then s.p_under end, s.p_push, s.ou_line_type)
) cand(canonical_market, canonical_side, canonical_line, canonical_probability, canonical_push, canonical_line_type)
where s.model_status = 'READY_UNVALIDATED' and cand.canonical_probability is not null;

-- one decision snapshot per (event, decision_time) across model_versions => one P_RETO
create or replace view v2.v_mlb_snapshot_identity_violations as
select espn_event_id, decision_time, count(*) n_rows,
       string_agg(distinct model_version, ',' order by model_version) model_versions
from v2.mlb_prediction_snapshot
group by espn_event_id, decision_time
having count(*) > 1;

-- post-first-pitch audit: must ALWAYS be empty (the CHECK guarantees it; the view proves it)
create or replace view v2.v_mlb_post_first_pitch_violations as
select espn_event_id, decision_time, scheduled_at, model_version
from v2.mlb_prediction_snapshot
where decision_time >= scheduled_at;

-- ── 11) WALK-FORWARD HARNESS — a verdict that requires a t statistic, not a sign ──
-- Scores SEALED pre-first-pitch snapshots against real finals taken from public.mlb_linescore
-- (the only outcome source with full coverage: 1053/1053 of the walk-forward corpus joins, vs
-- 307/1053 for marcadores_archivo). Outcomes are summed per competitor over all innings, so
-- extra-inning games settle correctly.
--
-- WHY THE BAR IS A t STATISTIC AND NOT `gain > 0`:
--   measured on prod's own 153 odds-carrying games, the legacy model's Brier gain over the
--   no-vig market was +0.00226 with sd 0.05194, se 0.00420 -> t = 0.538. A `gain > 0` rule
--   calls that "beats the market". It is noise. Brier differences on binary outcomes have a
--   standard deviation roughly 20x the effect size at this sample, so any verdict that does not
--   divide by se is not evidence. p_min_t defaults to 2.0 (~95% two-sided).
--
-- WHY A POSITIVE RESULT STILL CANNOT PROMOTE THE MODEL BY ITSELF:
--   public.lab_mlb_split_seal records that the entire historical universe is DEVELOPMENT and
--   was already globally inspected. Scoring inside it is in-sample at the selection level. So a
--   significant result on decision_time <= the seal's development_hasta returns
--   SKILL_IN_DEVELOPMENT_ONLY, which is explicitly NOT a promotion verdict. Only a window
--   strictly after the seal can return FORWARD_SKILL_PENDING_GOVERNANCE.
create or replace function v2.fn_mlb_walk_forward(
  p_from timestamptz, p_to timestamptz,
  p_model_version text default 'mlb-2026.09.1', p_min_n int default 200,
  p_min_t numeric default 2.0, p_development_hasta date default date '2026-08-30'
) returns table(
  n_scored int, brier_ml numeric, logloss_ml numeric,
  brier_coinflip numeric, skill_vs_coinflip numeric,
  n_with_market int, brier_market numeric, mean_gain numeric, se_gain numeric, t_stat numeric,
  verdict text, note text
) language plpgsql stable as $$
declare v record; v_post int;
begin
  -- refuse to score anything that is not a sealed pre-first-pitch snapshot; the CHECK makes this
  -- impossible to violate on write, and this re-asserts it on read so a future relaxation shows up.
  select count(*)::int into v_post from v2.mlb_prediction_snapshot where decision_time >= scheduled_at;
  if v_post > 0 then
    n_scored := 0; verdict := 'CORRUPT_SNAPSHOT_TABLE';
    note := format('%s snapshots post-primer-pitcheo presentes; el CHECK fue removido. '
                || 'No se emite metrica sobre una tabla contaminada.', v_post);
    return next; return;
  end if;

  with snap as (
    select distinct on (s.espn_event_id) s.*
    from v2.mlb_prediction_snapshot s
    where s.model_version = p_model_version
      and s.p_home_ml is not null
      and s.decision_time >= p_from and s.decision_time < p_to
    order by s.espn_event_id, s.decision_time desc
  ),
  res as (   -- real finals from per-inning linescore; ties (suspended games) excluded from ML
    select l.espn_event_id,
           sum(case when l.lado='home' then l.carreras else 0 end) home_runs,
           sum(case when l.lado='away' then l.carreras else 0 end) away_runs
    from public.mlb_linescore l
    group by 1
  ),
  j as (
    select s.espn_event_id, s.decision_time,
           (s.p_home_ml/100.0)::numeric p_hat,
           (case when r.home_runs > r.away_runs then 1 else 0 end)::numeric y,
           (select mc.home_ml from public.v_momios_confiables mc
             where mc.espn_event_id=s.espn_event_id and mc.confiable is true
               and mc.snapshot_at <= s.decision_time     -- never post-first-pitch odds
             order by mc.snapshot_at desc limit 1) oh,
           (select mc.away_ml from public.v_momios_confiables mc
             where mc.espn_event_id=s.espn_event_id and mc.confiable is true
               and mc.snapshot_at <= s.decision_time
             order by mc.snapshot_at desc limit 1) oa
    from snap s join res r on r.espn_event_id = s.espn_event_id
    where r.home_runs <> r.away_runs
  ),
  q as (
    select j.*, case when oh > 1 and oa > 1 then (1.0/oh)/((1.0/oh)+(1.0/oa)) end mq from j
  ),
  pr as (
    select *, case when mq is not null then power(mq-y,2) - power(p_hat-y,2) end gain from q
  )
  select count(*)::int n,
         round(avg(power(p_hat-y,2))::numeric,5) b,
         round(avg(-(y*ln(greatest(p_hat,1e-6)) + (1-y)*ln(greatest(1-p_hat,1e-6))))::numeric,5) ll,
         round(avg(power(0.5-y,2))::numeric,5) bc,
         count(gain)::int nm,
         round(avg(power(mq-y,2))::numeric,5) bm,
         round(avg(gain)::numeric,5) mg,
         round((stddev_samp(gain)/sqrt(nullif(count(gain),0)))::numeric,5) se
    into v
  from pr;

  n_scored := coalesce(v.n,0); brier_ml := v.b; logloss_ml := v.ll; brier_coinflip := v.bc;
  skill_vs_coinflip := case when v.b is not null and v.bc > 0 then round(1 - v.b/v.bc, 5) end;
  n_with_market := coalesce(v.nm,0); brier_market := v.bm; mean_gain := v.mg; se_gain := v.se;
  t_stat := case when v.se > 0 then round(v.mg / v.se, 3) end;

  if n_scored < p_min_n then
    verdict := 'INSUFFICIENT_HISTORY';
    note := format('n=%s < minimo %s. Sin muestra suficiente no se emite veredicto de calibracion.',
                   n_scored, p_min_n);
  elsif n_with_market = 0 or t_stat is null then
    verdict := 'NO_MARKET_BASELINE';
    note := format('n=%s scoreados pero %s con momios pre-decision; sin baseline no-vig no hay '
                || 'veredicto de skill. El mercado es la unica vara relevante.', n_scored, n_with_market);
  elsif t_stat < p_min_t then
    verdict := 'NO_SKILL_VS_MARKET';
    note := format('ganancia Brier %s vs no-vig con se %s -> t=%s < %s. NO es significativo: '
                || 'P_RETO MLB permanece UNVALIDATED. Un delta positivo sin t no es evidencia.',
                   mean_gain, se_gain, t_stat, p_min_t);
  elsif p_to <= (p_development_hasta + 1)::timestamptz then
    verdict := 'SKILL_IN_DEVELOPMENT_ONLY';
    note := format('t=%s supera %s pero la ventana termina dentro del universo DEVELOPMENT '
                || '(sellado hasta %s, ya inspeccionado globalmente). Resultado in-sample a nivel de '
                || 'seleccion: NO promueve. Se requiere FINAL_TEST_FORWARD estrictamente posterior.',
                   t_stat, p_min_t, p_development_hasta);
  else
    verdict := 'FORWARD_SKILL_PENDING_GOVERNANCE';
    note := format('t=%s supera %s sobre ventana forward posterior a %s (n=%s, con mercado %s). '
                || 'Candidato legitimo a promocion; requiere decision de gobernanza, no auto-promocion.',
                   t_stat, p_min_t, p_development_hasta, n_scored, n_with_market);
  end if;
  return next;
end $$;

-- ============================================================================
-- ROLLBACK (branch only):
--   drop view if exists v2.v_mlb_daily_candidates, v2.v_mlb_event_gate,
--     v2.v_mlb_snapshot_identity_violations, v2.v_mlb_post_first_pitch_violations;
--   drop function if exists v2.fn_mlb_walk_forward(timestamptz,timestamptz,text,int,numeric,date),
--     v2.fn_mlb_canonical_board(timestamptz,text), v2.fn_mlb_prediction_asof(text,timestamptz,text),
--     v2.fn_mlb_event_gate_status(jsonb,numeric,numeric,numeric,numeric,numeric,numeric,text,boolean,jsonb,numeric,numeric,numeric,numeric,numeric),
--     v2.fn_mlb_market_discrepancy(numeric,numeric,numeric,numeric,numeric,numeric),
--     v2.build_mlb_prediction_snapshot(timestamptz,boolean),
--     v2.fn_mlb_run_dist(numeric,numeric,numeric,numeric,integer),
--     v2.fn_mlb_features_asof(text,text,timestamptz,integer,integer);
--   drop table if exists v2.mlb_prediction_snapshot, v2.mlb_feature_snapshot,
--     v2.mlb_run_rate_observation, v2.mlb_league_baseline, v2.mlb_model_config;
--
-- iss016 is SUPERSEDED by this file and must NOT be applied at cutover: its writer can
-- create post-first-pitch snapshots and its canonical view will serve them.
-- ============================================================================
