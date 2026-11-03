-- ============================================================================
-- iss050 — MLB "Ver análisis completo" DOSSIER MANIFEST · PARITY WITH SOCCER/NFL · STAGED
-- ============================================================================
-- issue #4 comment 5620196530 ("que los 3 sean iguales") — third sibling of the
-- unified dossier trilogy. SAME shell/contract as soccer (iss030 v3) and NFL
-- (iss049); DIFFERENT brain per sport. Mirrors EXACTLY the return contract of
-- v2.fn_soccer_dossier_manifest: same column names/types/order.
--
-- MLB BRAIN CONTRACT (MLB_BRAIN_INVENTORY.md + issue #4): unlike NFL, MLB HAS a
-- real own model (predecir_mlb, Poisson/NB — λ run-rates + starter/home exponent).
-- The real internal P may be shown HONESTLY even though the model is UNVALIDATED.
-- Therefore MLB behaves like soccer (MODEL_ACTIVE + used_in_p_reto=true), NOT like
-- NFL (NO_OWN_MODEL):
--   * modelo_p_reto => role MODEL_ACTIVE when the canonical MLB prediction is present
--     with its OWN immutable snapshot proven prediction_timestamp <= decision_time
--     and temporally safe. effective_value = the real internal P (prob_home) READ
--     FROM THE FROZEN SNAPSHOT; feature_snapshot_id/feature_version populated from the
--     same frozen row. P_RETO = P_RAW, CALIBRATION_STATUS = NOT_VALIDATED (UNVALIDATED),
--     surfaced honestly in provider/provenance text.
--   * If a canonical prediction is served (mlb_modelo_snapshot, the thin overwrite
--     serving surface) but NO immutable snapshot row is linked => role
--     MODEL_ACTIVE_TEMPORAL_UNPROVEN, used_in_p_reto=false (fail-closed, never silent),
--     exactly like soccer's staged-without-feature_snapshot case.
--
-- TRACEABILITY DISCIPLINE (the iss030 v3 trap, DO NOT REPEAT): MODEL_ACTIVE rows are
--   resolved from the IMMUTABLE versioned snapshot `public.mlb_shadow_predicciones`
--   (id uuid, prediction_timestamp, model_version, prob_home, lambda_home/away,
--   exponent, features_hash), NOT from the thin consumption/serving surface
--   `public.mlb_modelo_snapshot` (mod_home/away/over + actualizado only — no id, no
--   version, no per-feature as_of). Using the serving surface for MODEL traceability
--   would be a BORROWED timestamp/value, exactly the v2-vs-v3 defect the soccer audit
--   rejected. mlb_modelo_snapshot is read ONLY as a "was something served?" signal to
--   drive the UNPROVEN fail-close (analogue of soccer's v_futpro_v2 convenience use).
--
-- NEVER RECOMPUTE HISTORICAL BELIEF ON READ: the dossier reads the PERSISTED prediction
--   snapshot; it NEVER re-runs predecir_mlb. The emitted P/λ/exponent are byte-copies of
--   the frozen mlb_shadow_predicciones row and are invariant to any post-seal mutation of
--   the live feature sources (mlb_stats_cache, pitchers, bullpen, splits). This is the
--   permanent "MLB historical/read-time recomputation" regression guard.
--
-- HARD temporal rule (identical to soccer/NFL): a source is valid_prematch ONLY if
--   data_asof <= decision_time. Sources with no defensible per-row ingest as_of
--   (weather: mlb_clima_hora is a per-city forecast hour, not an ingest as_of, and is
--   keyed by team city — neutral-site/city trap; season form/standings:
--   mlb_forma_temporada has no as_of column) => role AVAILABLE_NOT_USED / freshness
--   NO_ASOF, never an invented as_of, never used. A capture strictly AFTER decision_time
--   => post_decision_capture=true, excluded from prematch coverage, and the valid earlier
--   capture is never deleted.
--
-- MARKET (sportsbook no-vig, total line, opening/closing, CLV) is NEVER P_RETO and
--   NEVER MODEL_ACTIVE (momios_mercado / odds_pro_snapshots, role MARKET, used=false).
--
-- decision_time authority = the immutable per-run MLB prediction capture
--   (mlb_shadow_predicciones.prediction_timestamp), NEVER first pitch
--   (mlb_shadow_predicciones.game_date / momios_mercado.fecha). No frozen capture and no
--   explicit argument => fail-closed NO_DECISION_TIME (exactly like soccer/NFL).
--
-- NO va en supabase/migrations. NO aplicar bajo freeze. Branch-only.
-- ============================================================================

create schema if not exists v2;

-- signature parity with iss030/iss049 => drop before recreate.
drop function if exists v2.fn_mlb_dossier_manifest(text, timestamptz);

create or replace function v2.fn_mlb_dossier_manifest(
  p_event_id text, p_decision_time timestamptz default null
) returns table(
  source_name text, provider text, provenance text, available boolean,
  data_asof timestamptz, decision_time timestamptz, freshness_seconds bigint,
  freshness_status text, missing_reason text, role text,
  temporally_safe boolean, used_in_p_reto boolean, post_decision_capture boolean,
  -- same trailing traceability columns as soccer; for MLB feature_snapshot_id/version
  -- come from the frozen mlb_shadow_predicciones row. max_source_event_time is NULL:
  -- the MLB frozen snapshot persists no separate max-source-event-time column, and the
  -- temporal guarantee is carried by prediction_timestamp (= features_as_of). We do NOT
  -- fabricate one from game_date (that is first pitch, a FUTURE event time).
  effective_value numeric, feature_snapshot_id uuid, feature_version text,
  max_source_event_time timestamptz
) language plpgsql stable as $$
declare
  v_dec timestamptz;
  sp  public.mlb_shadow_predicciones%rowtype;  -- %rowtype => all fields NULL if no frozen row (fail-closed, no "record not assigned")
  v_sp_found boolean := false;
  v_serving_found boolean := false;
  v_snapshot_linked boolean := false;
  v_model_ready boolean := false;
  v_temporal_ok boolean := false;
  v_model_active_ok boolean := false;
  v_home_team text; v_away_team text;
  v_gp text;                                   -- espn_event_id -> mlb_game_pk bridge (identity, via mlb_stats_cache)
begin
  -- ── 1) CANONICAL frozen prediction (authority = immutable versioned snapshot) ──
  --   Prefer the prod-mirror version (prod_espejo_*) over the shadow challenger, then
  --   the latest capture. Never the thin serving surface mlb_modelo_snapshot.
  if to_regclass('public.mlb_shadow_predicciones') is not null then
    select spp.* into sp from public.mlb_shadow_predicciones spp
     where spp.espn_event_id = p_event_id
       and (p_decision_time is null or spp.prediction_timestamp = p_decision_time)
     order by (spp.model_version ilike 'prod_espejo%') desc nulls last,
              spp.prediction_timestamp desc
     limit 1;
  end if;
  v_sp_found := (sp.id is not null);

  -- serving surface: ONLY a "was a canonical prediction served?" signal (drives the
  -- UNPROVEN fail-close). NEVER a source of MODEL value/as_of/traceability.
  if to_regclass('public.mlb_modelo_snapshot') is not null then
    select (ms.mod_home is not null) into v_serving_found
      from public.mlb_modelo_snapshot ms where ms.espn_event_id = p_event_id limit 1;
    v_serving_found := coalesce(v_serving_found, false);
  end if;

  -- ── 2) decision_time AUTHORITY = frozen prediction_timestamp; else explicit arg.
  --   NEVER first pitch (game_date / momios_mercado.fecha). None => fail-closed.
  v_dec := coalesce(sp.prediction_timestamp, p_decision_time);
  if v_dec is null then
    return query select 'decision_time'::text,'—'::text,'—'::text,false,
      null::timestamptz,null::timestamptz,null::bigint,'NO_DECISION_TIME'::text,
      'sin decision_time real (mlb_shadow_predicciones.prediction_timestamp / argumento): NO se usa el primer pitcheo (game_date)'::text,
      'AVAILABLE_NOT_USED'::text,false,false,false,
      null::numeric,null::uuid,null::text,null::timestamptz;
    return;
  end if;

  v_home_team := sp.home_team;
  v_away_team := sp.away_team;

  -- espn_event_id -> mlb_game_pk identity bridge (mlb_stats_cache). Used ONLY to reach
  -- the game_pk-keyed context tables (umpire/lineups); it is not a temporal proof.
  if to_regclass('public.mlb_stats_cache') is not null then
    select sc.mlb_game_pk into v_gp from public.mlb_stats_cache sc
      where sc.espn_event_id = p_event_id and sc.mlb_game_pk is not null
      order by sc.cached_at desc limit 1;
    if v_home_team is null then
      select sc.home_team, sc.away_team into v_home_team, v_away_team
        from public.mlb_stats_cache sc where sc.espn_event_id = p_event_id limit 1;
    end if;
  end if;

  -- ── 3) MODEL readiness + EXACT snapshot traceability + temporal proof ──
  v_snapshot_linked := (v_sp_found and sp.id is not null
                        and sp.features_hash is not null and sp.prob_home is not null);
  v_model_ready := (v_sp_found or v_serving_found);  -- a canonical prediction exists
  v_temporal_ok := (v_snapshot_linked
                    and sp.prediction_timestamp is not null
                    and sp.prediction_timestamp <= v_dec);
  v_model_active_ok := (v_model_ready and v_snapshot_linked and v_temporal_ok);

  return query
  with src as (
    -- ══ MODEL: P_RETO — real internal P from the FROZEN snapshot (UNVALIDATED) ══
    select 'modelo_p_reto'::text sn,
      'motor MLB Poisson/NB (predecir_mlb) — UNVALIDATED'::text prov,
      'public.mlb_shadow_predicciones (P_RETO=P_RAW · CALIBRATION_STATUS=NOT_VALIDATED)'::text prv,
      v_model_ready av, sp.prediction_timestamp asof, 'MODEL'::text rc,
      case when not v_model_ready then 'sin predicción MLB (ni snapshot inmutable ni fila servida) para el evento'
           when not v_snapshot_linked then 'predicción servida SIN snapshot inmutable enlazado (id/features_hash) -> trazabilidad no demostrable'
           else null end mr,
      false postd, sp.prob_home eff
    -- ══ MODEL features that ALTER P — the Poisson λ run-rates, from the EXACT frozen row ══
    union all select 'feat_lambda_home','λ Poisson local (feature del modelo)',
      'public.mlb_shadow_predicciones.lambda_home (congelada)',
      (v_snapshot_linked and sp.lambda_home is not null), sp.prediction_timestamp,'MODEL',
      case when not v_snapshot_linked then 'snapshot inmutable no enlazado/enlazable'
           when sp.lambda_home is null then 'snapshot sin λ local' end,
      false, sp.lambda_home
    union all select 'feat_lambda_away','λ Poisson visita (feature del modelo)',
      'public.mlb_shadow_predicciones.lambda_away (congelada)',
      (v_snapshot_linked and sp.lambda_away is not null), sp.prediction_timestamp,'MODEL',
      case when not v_snapshot_linked then 'snapshot inmutable no enlazado/enlazable'
           when sp.lambda_away is null then 'snapshot sin λ visita' end,
      false, sp.lambda_away
    union all select 'feat_exponent','exponente abridor/ventaja-local (hiperparám del modelo)',
      'public.mlb_shadow_predicciones.exponent (congelado; features_hash traza el vector)',
      (v_snapshot_linked and sp.exponent is not null), sp.prediction_timestamp,'MODEL',
      case when not v_snapshot_linked then 'snapshot inmutable no enlazado/enlazable'
           when sp.exponent is null then 'snapshot sin exponente' end,
      false, sp.exponent

    -- ══ CONTEXT (own ingest as_of; never MODEL_ACTIVE, never P_RETO) ══
    -- starting pitchers — mlb_stats_cache per-event cache (espn-keyed), real cached_at.
    -- OVERWRITE cache (expires_at) => a past decision can only see a post-decision refresh.
    union all select 'pitchers_abridores','ESPN/MLB (cache por evento)','mlb_stats_cache (home/away_pitcher_era/fip/hand)',
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id
              and (sc.home_pitcher_name is not null or sc.away_pitcher_name is not null) and sc.cached_at<=v_dec),
      (select max(sc.cached_at) from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec)
             then 'sin cache de abridores <= decision (cache expira/overwrite; sólo refresh post-decisión)' end,
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at>v_dec), null::numeric
    -- bullpen fatigue — same per-event cache
    union all select 'bullpen_fatiga','ESPN/MLB (cache por evento)','mlb_stats_cache (home/away_bullpen_fatigue)',
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id
              and (sc.home_bullpen_fatigue is not null or sc.away_bullpen_fatigue is not null) and sc.cached_at<=v_dec),
      (select max(sc.cached_at) from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec)
             then 'sin cache de bullpen <= decision' end,
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at>v_dec), null::numeric
    -- park factor — per-event (real as_of), not the static mlb_estadios ref
    union all select 'park_factor','ESPN/MLB (cache por evento)','mlb_stats_cache (park_factor_runs/hr, park_name)',
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.park_factor_runs is not null and sc.cached_at<=v_dec),
      (select max(sc.cached_at) from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.park_factor_runs is not null and sc.cached_at<=v_dec)
             then 'sin park factor <= decision' end,
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at>v_dec), null::numeric
    -- platoon splits vs LHP/RHP — per-event cache
    union all select 'splits_platoon','ESPN/MLB (cache por evento)','mlb_stats_cache (home/away_team_vs_lhp/rhp)',
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id
              and (sc.home_team_vs_lhp is not null or sc.away_team_vs_rhp is not null) and sc.cached_at<=v_dec),
      (select max(sc.cached_at) from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec)
             then 'sin splits L/R <= decision' end,
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at>v_dec), null::numeric
    -- team last-10 form — per-event cache
    union all select 'forma_last10','ESPN/MLB (cache por evento)','mlb_stats_cache (home/away_team_last10)',
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id
              and (sc.home_team_last10 is not null or sc.away_team_last10 is not null) and sc.cached_at<=v_dec),
      (select max(sc.cached_at) from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at<=v_dec)
             then 'sin forma last-10 <= decision' end,
      exists(select 1 from public.mlb_stats_cache sc where sc.espn_event_id=p_event_id and sc.cached_at>v_dec), null::numeric
    -- umpire — game_pk-keyed table reached via the stats_cache bridge; real cargado_at
    union all select 'umpire','MLB (umpire scorecard)','mlb_umpire_juego <- mlb_game_pk (puente mlb_stats_cache)',
      (v_gp is not null and exists(select 1 from public.mlb_umpire_juego u where u.mlb_game_pk=v_gp and u.cargado_at<=v_dec)),
      (select max(u.cargado_at) from public.mlb_umpire_juego u where u.mlb_game_pk=v_gp and u.cargado_at<=v_dec),
      'CONTEXT',
      case when v_gp is null then 'sin puente espn_event_id->mlb_game_pk (mlb_stats_cache) -> umpire no enlazable'
           when not exists(select 1 from public.mlb_umpire_juego u where u.mlb_game_pk=v_gp and u.cargado_at<=v_dec)
             then 'sin umpire <= decision' end,
      (v_gp is not null and exists(select 1 from public.mlb_umpire_juego u where u.mlb_game_pk=v_gp and u.cargado_at>v_dec)), null::numeric
    -- lineups (probable/real) — game_pk-keyed via bridge; real cargado_at
    union all select 'alineaciones','MLB (lineup)','mlb_alineacion <- mlb_game_pk (puente mlb_stats_cache)',
      (v_gp is not null and exists(select 1 from public.mlb_alineacion a where a.mlb_game_pk=v_gp and a.cargado_at<=v_dec)),
      (select max(a.cargado_at) from public.mlb_alineacion a where a.mlb_game_pk=v_gp and a.cargado_at<=v_dec),
      'CONTEXT',
      case when v_gp is null then 'sin puente espn_event_id->mlb_game_pk -> alineación no enlazable'
           when not exists(select 1 from public.mlb_alineacion a where a.mlb_game_pk=v_gp and a.cargado_at<=v_dec)
             then 'sin alineación <= decision' end,
      (v_gp is not null and exists(select 1 from public.mlb_alineacion a where a.mlb_game_pk=v_gp and a.cargado_at>v_dec)), null::numeric

    -- ══ CONTEXT sin as_of demostrable => NO_ASOF fail-closed ══
    -- weather — mlb_clima_hora.hora_utc is a per-CITY forecast hour, not an ingest as_of,
    -- keyed by team city (neutral/city trap). No defensible per-row as_of => NO_ASOF.
    union all select 'clima','proveedor (forecast por ciudad)','mlb_clima_hora (hora_utc = hora de pronóstico, NO as_of de ingesta; keyed por ciudad)',
      false, null::timestamptz,'CONTEXT_NOASOF',
      'mlb_clima_hora.hora_utc es hora de pronóstico por ciudad del equipo, no as_of de ingesta demostrable -> NO_ASOF, nunca sustituye sede',
      false, null::numeric
    -- season form / standings — mlb_forma_temporada has NO as_of column => NO_ASOF
    union all select 'standings_temporada','MLB','mlb_forma_temporada (rpg/permitidas_pg por equipo)',
      exists(select 1 from public.mlb_forma_temporada f where f.equipo in (v_home_team, v_away_team)),
      null::timestamptz,'CONTEXT_NOASOF',
      'mlb_forma_temporada sin columna de as_of por fila -> no fuente temporal demostrable',
      false, null::numeric

    -- ══ MARKET (never P_RETO, never MODEL_ACTIVE, used_in_p_reto=false) ══
    -- sportsbook no-vig ML price — momios_mercado (real actualizado as_of; fecha = first pitch)
    union all select 'momios_novig','libro (momios_mercado.casa)','momios_mercado (p_home/p_away no-vig, ml_home/ml_away)',
      exists(select 1 from public.momios_mercado m where m.espn_event_id=p_event_id and m.actualizado<=v_dec),
      (select max(m.actualizado) from public.momios_mercado m where m.espn_event_id=p_event_id and m.actualizado<=v_dec),
      'MARKET',
      case when not exists(select 1 from public.momios_mercado m where m.espn_event_id=p_event_id and m.actualizado<=v_dec)
             then 'sin momios no-vig <= decision -> ML fail-closed' end,
      exists(select 1 from public.momios_mercado m where m.espn_event_id=p_event_id and m.actualizado>v_dec), null::numeric
    -- total (O/U) line — momios_mercado.total_linea/over_odds; MARKET, never P_RETO
    union all select 'total_line','libro (momios_mercado.casa)','momios_mercado (total_linea/over_odds/under_odds)',
      exists(select 1 from public.momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null and m.actualizado<=v_dec),
      (select max(m.actualizado) from public.momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null and m.actualizado<=v_dec),
      'MARKET',
      case when not exists(select 1 from public.momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null and m.actualizado<=v_dec)
             then 'sin línea total real <= decision -> O/U fail-closed' end,
      exists(select 1 from public.momios_mercado m where m.espn_event_id=p_event_id and m.actualizado>v_dec), null::numeric
    -- opening/closing + CLV — odds_pro_snapshots (Pinnacle+); MARKET context only
    union all select 'odds_pro_clv','Pinnacle+ (apertura/cierre/CLV)','odds_pro_snapshots (is_opening/is_closing/clv_percentage)',
      exists(select 1 from public.odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec),
      (select max(o.created_at) from public.odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec),
      'MARKET',
      case when not exists(select 1 from public.odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec)
             then 'sin snapshot Pinnacle+ <= decision (cobertura MLB puede ser vacía) -> CLV no disponible' end,
      exists(select 1 from public.odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at>v_dec), null::numeric
  )
  select s.sn, s.prov, s.prv, s.av, s.asof, v_dec,
    case when s.asof is null then null else extract(epoch from (v_dec - s.asof))::bigint end,
    -- freshness_status
    case
      when s.rc='MODEL' and not v_snapshot_linked then 'MODEL_ACTIVE_TEMPORAL_UNPROVEN'
      when s.rc='CONTEXT_NOASOF' then 'NO_ASOF'
      when s.asof is null then 'NO_ASOF'
      when s.asof > v_dec then 'FUTURE_INVALID'
      when v_dec - s.asof <= interval '48 hours' then 'FRESH' else 'STALE' end,
    s.mr,
    -- role
    case
      when s.rc='MODEL' then
        case when v_model_active_ok and s.av and s.asof is not null and s.asof<=v_dec then 'MODEL_ACTIVE'
             when v_model_ready and not v_snapshot_linked then 'MODEL_ACTIVE_TEMPORAL_UNPROVEN'
             else 'AVAILABLE_NOT_USED' end
      when s.rc='MARKET' then 'MARKET'
      when s.rc='CONTEXT_NOASOF' then 'AVAILABLE_NOT_USED'
      else case when s.av and s.asof is not null and s.asof<=v_dec then 'CONTEXT_ONLY' else 'AVAILABLE_NOT_USED' end
    end,
    (s.asof is not null and s.asof<=v_dec),
    -- used_in_p_reto: ONLY a MODEL row with the EXACT immutable snapshot linked + temporal proof
    (s.rc='MODEL' and v_model_active_ok and s.av and s.asof is not null and s.asof<=v_dec),
    coalesce(s.postd,false),
    -- trailing traceability
    s.eff,
    case when s.rc='MODEL' and v_snapshot_linked then sp.id else null end,
    case when s.rc='MODEL' and v_snapshot_linked then sp.model_version else null end,
    null::timestamptz   -- MLB frozen snapshot persists no separate max_source_event_time; never fabricate from game_date (first pitch)
  from src s;
end $$;

-- Validate on branch (iss050 test): a real MLB event with a frozen prod-mirror snapshot
-- (MODEL_ACTIVE, real P as effective_value, snapshot id + version, used_in_p_reto=true,
-- byte-stable no-recompute proof), an UNPROVEN fail-close (served but no immutable
-- snapshot), MARKET labelled never P_RETO, a post-decision capture excluded + earlier
-- kept, NO_ASOF context fail-closed, and NO_DECISION_TIME fail-closed (never first pitch).
