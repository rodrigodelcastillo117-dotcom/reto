-- ============================================================================
-- TOP_PICK_FORWARD_CAPTURE_V1 — DDL (SHADOW / NO DEPLOY / aplicar solo en LAB branch)
-- Observacional: LEE v_pick_canonico (autoridades ya aplicadas) y hace APPEND.
-- No modifica P/EV/es_pick/stake, no autoriza modelos, no toca economic_model_authority
-- ni v_pick_canonico ni oraculo_picks_tracking ni los triggers existentes.
-- capture_schema_version = TOP_PICK_CAPTURE_V1
-- ============================================================================

-- ---------- 1) PRE-EVENTO: snapshot inmutable append-only ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture (
  decision_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  captured_at             timestamptz NOT NULL DEFAULT now(),
  decision_timestamp      timestamptz NOT NULL,
  capture_schema_version  text NOT NULL DEFAULT 'TOP_PICK_CAPTURE_V1'
                            CHECK (capture_schema_version = 'TOP_PICK_CAPTURE_V1'),
  -- identidad del candidato (UNIVERSO COMPLETO, no solo es_pick=true)
  espn_event_id           text NOT NULL,
  event_start_timestamp   timestamptz,          -- = v_pick_canonico.arranca_en
  deporte                 text,
  liga                    text,
  home_team               text,
  away_team               text,
  market                  text NOT NULL,        -- = mercado
  side                    text NOT NULL,        -- = pick_nombre
  line                    text,                 -- parse de pick_desc
  -- precio a la decisión
  sportsbook              text,                 -- = casa
  odds_decimal            numeric,              -- = momio_mercado
  odds_captured_at        timestamptz,          -- = momio_capturado_at
  odds_source             text,
  -- provenance de modelo
  model_name              text,
  model_version           text,
  model_source            text,                 -- = fuente
  provenance_status       text,                 -- de es_pick_reason (bajo NONE: MODEL_VERSION_PROVENANCE_MISSING)
  -- autoridades canónicas (copiadas, NO recalculadas)
  p_raw                   numeric,              -- NULL si no lo expone la fuente
  p_decision              numeric,              -- = probabilidad_pct
  ev_decision             numeric,              -- = ev_pct
  economic_eligible       boolean,              -- = es_pick
  eligibility_reason_code text,                 -- = es_pick_reason (si desplegado)
  es_pick                 boolean,              -- = es_pick (redundante explícito)
  model_skill             text,
  calibration_status      boolean,              -- = calibracion_confiable
  edge_reliability        text,
  data_readiness          text,
  data_completeness_pct   numeric,
  stake_final             numeric,              -- solo si una autoridad de sizing ya lo produjo; nunca fabricar
  -- snapshot de inputs + provenance temporal
  features_input_json     jsonb NOT NULL DEFAULT '{}'::jsonb,
  feature_source_timestamps jsonb NOT NULL DEFAULT '{}'::jsonb,
  signal_components       jsonb,                -- direcciones individuales; NO score
  feature_snapshot_hash   text NOT NULL,
  source_capture_point    text NOT NULL,        -- 'trigger:analisis_partidos' | 'job:resnapshot'
  is_full_universe        boolean NOT NULL DEFAULT true,
  -- GUARDS temporales (fail-closed a nivel motor)
  CONSTRAINT tpc_decision_before_event
    CHECK (event_start_timestamp IS NULL OR decision_timestamp < event_start_timestamp)
);

-- dedup: distintas decisiones (distinto ts) sobreviven; duplicado idéntico se rechaza
CREATE UNIQUE INDEX IF NOT EXISTS ux_top_pick_capture_identity
  ON public.top_pick_capture (
    espn_event_id, market, side, coalesce(line,''), coalesce(model_version,''),
    decision_timestamp, feature_snapshot_hash
  );
CREATE INDEX IF NOT EXISTS ix_tpc_event   ON public.top_pick_capture (espn_event_id);
CREATE INDEX IF NOT EXISTS ix_tpc_decis   ON public.top_pick_capture (decision_timestamp);
CREATE INDEX IF NOT EXISTS ix_tpc_sport_mkt ON public.top_pick_capture (deporte, market);

-- ---------- 2) POST-EVENTO: settlement separado (nunca modifica el snapshot) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_settlement (
  decision_id     uuid PRIMARY KEY REFERENCES public.top_pick_capture(decision_id),
  settled_at      timestamptz NOT NULL DEFAULT now(),
  outcome         text CHECK (outcome IN ('win','loss','push','void')),
  score_final     text,
  retorno         numeric,
  closing_odds    numeric,
  clv_pct         numeric,
  settlement_source text
);

-- ---------- 3) DISPLAY/SELECTED opcional (observacional, NO determina la predicción) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_display (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_id        uuid NOT NULL REFERENCES public.top_pick_capture(decision_id),
  selected_as_top_pick boolean,
  top_pick_rank      int,
  surface            text,
  selector_version   text,
  displayed_at       timestamptz NOT NULL DEFAULT now()
);

-- ---------- 4) FUNCIÓN DE CAPTURA (SELECT canónico -> APPEND; con guards) ----------
-- Tolerante a esquema: usa to_jsonb(v) para leer columnas aunque es_pick_reason aún no exista.
CREATE OR REPLACE FUNCTION public.capture_top_pick_universe(
  p_event_id text,
  p_decision_ts timestamptz DEFAULT now(),
  p_source text DEFAULT 'trigger:analisis_partidos'
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE
  v record; j jsonb; n int := 0;
  v_event_start timestamptz; v_hash text; v_line text; v_reason text;
  v_feat jsonb; v_fts jsonb;
BEGIN
  FOR v IN SELECT * FROM public.v_pick_canonico WHERE espn_event_id = p_event_id
  LOOP
    j := to_jsonb(v);
    v_event_start := NULLIF(j->>'arranca_en','')::timestamptz;

    -- GUARD 1: decisión antes del evento (fail-closed)
    IF v_event_start IS NOT NULL AND p_decision_ts >= v_event_start THEN CONTINUE; END IF;

    v_reason := j->>'es_pick_reason';           -- NULL si la columna no existe (pre ISS-009B)
    v_line   := j->>'pick_desc';

    -- feature snapshot: SOLO valores disponibles a T-decisión (de la vista canónica)
    v_feat := jsonb_strip_nulls(jsonb_build_object(
      'schema','TOP_PICK_CAPTURE_V1',
      'canonical', jsonb_build_object(
        'p_decision', j->>'probabilidad_pct', 'ev_pct', j->>'ev_pct',
        'es_pick', j->>'es_pick', 'reason_code', v_reason,
        'calibracion_confiable', j->>'calibracion_confiable',
        'muestra_calibracion', j->>'muestra_calibracion',
        'clasificacion', j->>'clasificacion', 'confianza', j->>'confianza',
        'zona', j->>'zona', 'nivel_ventaja', j->>'nivel_ventaja'),
      'odds', jsonb_build_object('decimal', j->>'momio_mercado', 'casa', j->>'casa',
        'source', j->>'odds_source', 'captured_at', j->>'momio_capturado_at')
    ));

    -- provenance temporal por señal (solo timestamps demostrables)
    v_fts := jsonb_strip_nulls(jsonb_build_object(
      'odds', j->>'momio_capturado_at',
      'p_decision', to_jsonb(p_decision_ts)#>>'{}'
    ));
    -- GUARD 2: ninguna señal con timestamp futuro respecto a la decisión
    IF (v_fts->>'odds') IS NOT NULL AND (v_fts->>'odds')::timestamptz > p_decision_ts THEN
       v_feat := v_feat - 'odds'; v_fts := v_fts - 'odds';   -- se descarta como safe (no se persiste como válido)
    END IF;

    v_hash := md5(coalesce(v_feat::text,'') || '|' || coalesce(j->>'probabilidad_pct','') || '|' ||
                  coalesce(j->>'ev_pct','') || '|' || coalesce(j->>'momio_mercado','') || '|' ||
                  coalesce(j->>'mercado','') || '|' || coalesce(j->>'pick_nombre','') || '|' || coalesce(v_line,''));

    INSERT INTO public.top_pick_capture (
      decision_timestamp, espn_event_id, event_start_timestamp, deporte, liga, home_team, away_team,
      market, side, line, sportsbook, odds_decimal, odds_captured_at, odds_source,
      model_name, model_version, model_source, provenance_status,
      p_raw, p_decision, ev_decision, economic_eligible, eligibility_reason_code, es_pick,
      calibration_status, data_completeness_pct, stake_final,
      features_input_json, feature_source_timestamps, feature_snapshot_hash, source_capture_point, is_full_universe
    ) VALUES (
      p_decision_ts, p_event_id, v_event_start, j->>'deporte', j->>'liga', j->>'home', j->>'away',
      j->>'mercado', j->>'pick_nombre', v_line, j->>'casa',
      NULLIF(j->>'momio_mercado','')::numeric, NULLIF(j->>'momio_capturado_at','')::timestamptz, j->>'odds_source',
      NULL, NULL, j->>'fuente', v_reason,
      NULL, NULLIF(j->>'probabilidad_pct','')::numeric, NULLIF(j->>'ev_pct','')::numeric,
      NULLIF(j->>'es_pick','')::boolean, v_reason, NULLIF(j->>'es_pick','')::boolean,
      NULLIF(j->>'calibracion_confiable','')::boolean, NULL, NULL,
      v_feat, v_fts, v_hash, p_source, true
    )
    ON CONFLICT (espn_event_id, market, side, coalesce(line,''), coalesce(model_version,''),
                 decision_timestamp, feature_snapshot_hash) DO NOTHING;
    n := n + 1;
  END LOOP;
  RETURN n;
END;
$fn$;

-- ---------- 5) TRIGGER en analisis_partidos (tolerante a fallos: nunca aborta el pipeline vivo) ----------
CREATE OR REPLACE FUNCTION public.trg_capture_top_pick() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $t$
BEGIN
  BEGIN
    PERFORM public.capture_top_pick_universe(
      COALESCE(NULLIF(NEW.espn_event_id_canonico,''), NEW.espn_event_id),
      now(), 'trigger:analisis_partidos');
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'trg_capture_top_pick: captura omitida para % (%)', NEW.espn_event_id, SQLERRM;
  END;
  RETURN NEW;
END;
$t$;

CREATE TRIGGER trg_top_pick_capture
  AFTER INSERT OR UPDATE ON public.analisis_partidos
  FOR EACH ROW EXECUTE FUNCTION public.trg_capture_top_pick();

-- ---------- 6) settlement no debe poder mutar el snapshot (defensa) ----------
-- (En deploy real: REVOKE UPDATE ON public.top_pick_capture FROM <rol_settlement>;)
