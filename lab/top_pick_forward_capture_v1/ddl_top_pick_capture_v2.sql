-- ============================================================================
-- TOP_PICK_FORWARD_CAPTURE_V1 — DDL v2 HARDENED (SHADOW / NO DEPLOY / solo LAB branch)
-- REQUIRED_CANONICAL_SCHEMA_VERSION = v_pick_canonico @ ISS-009B (columna es_pick_reason).
-- Observacional: LEE v_pick_canonico (autoridades ya aplicadas) y hace APPEND. No cambia
-- P/EV/es_pick/stake, no autoriza modelos, no toca economic_model_authority ni objetos canónicos.
-- capture_schema_version = TOP_PICK_CAPTURE_V1
-- ============================================================================

-- ---------- 1) PRE-EVENTO: snapshot inmutable append-only ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture (
  decision_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_emission_id    text NOT NULL,           -- hash del contenido canónico (identidad de decisión)
  captured_at             timestamptz NOT NULL DEFAULT now(),
  decision_timestamp      timestamptz NOT NULL,     -- = canonical_read_at
  canonical_read_at       timestamptz NOT NULL,
  capture_schema_version  text NOT NULL DEFAULT 'TOP_PICK_CAPTURE_V1'
                            CHECK (capture_schema_version='TOP_PICK_CAPTURE_V1'),
  source_analysis_id      uuid,                     -- analisis_partidos.id (metadato de origen)
  source_analysis_kind    text,                     -- emission | recompute | non_prediction
  -- identidad del candidato (universo completo)
  espn_event_id           text NOT NULL,
  event_start_timestamp   timestamptz NOT NULL,     -- = arranca_en (guard exige no-nulo)
  deporte                 text, liga text, home_team text, away_team text,
  market                  text NOT NULL,            -- = mercado
  side                    text NOT NULL,            -- = pick_nombre
  line                    text,                     -- = pick_desc
  market_generation_status text NOT NULL DEFAULT 'captured', -- captured | generated_but_excluded
  -- precio a la decisión
  sportsbook text, odds_decimal numeric, odds_captured_at timestamptz, odds_source text,
  -- provenance
  model_source text,                               -- = fuente
  provenance_status text,                           -- de es_pick_reason (bajo NONE: MODEL_VERSION_PROVENANCE_MISSING)
  -- autoridades canónicas (copiadas, NO recalculadas) — CONTRATO
  p_decision numeric NOT NULL,                      -- = probabilidad_pct (crítico)
  ev_decision numeric,                             -- = ev_pct (nullable: candidato sin precio)
  economic_eligible boolean NOT NULL,              -- = es_pick (crítico)
  es_pick boolean NOT NULL,                        -- = es_pick
  eligibility_reason_code text,                     -- = es_pick_reason (crítico de esquema; valor puede ser null)
  calibration_status boolean,                       -- = calibracion_confiable
  -- snapshot + provenance temporal + máscara de presencia
  features_input_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  feature_source_timestamps jsonb NOT NULL DEFAULT '{}'::jsonb,
  feature_presence_mask jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {p_raw:false, model_version:false, lineup:false,...}
  signal_components jsonb,                          -- direcciones; NO score
  prediction_snapshot_hash text NOT NULL,          -- hash por fila (integridad/replay)
  source_capture_point text NOT NULL,
  CONSTRAINT tpc_decision_before_event CHECK (decision_timestamp < event_start_timestamp)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_emission_pick
  ON public.top_pick_capture (decision_emission_id, market, side, coalesce(line,''));
CREATE INDEX IF NOT EXISTS ix_tpc_event ON public.top_pick_capture (espn_event_id);
CREATE INDEX IF NOT EXISTS ix_tpc_decis ON public.top_pick_capture (decision_timestamp);
CREATE INDEX IF NOT EXISTS ix_tpc_emis  ON public.top_pick_capture (decision_emission_id);

-- ---------- 2) AUDIT append-only (completitud/estado) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_emission_id text,
  espn_event_id text NOT NULL,
  source_analysis_id uuid, source_analysis_kind text,
  decision_timestamp timestamptz,
  expected_candidate_count int, captured_candidate_count int, excluded_count int,
  status text NOT NULL CHECK (status IN ('COMPLETE','PARTIAL','FAILED','NO_CHANGE')),
  failure_code text,
  captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_audit_emission
  ON public.top_pick_capture_audit (decision_emission_id) WHERE decision_emission_id IS NOT NULL;

-- ---------- 3) SETTLEMENT (post-evento; key market/side/line; nunca muta el snapshot) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_settlement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  espn_event_id text NOT NULL, market text NOT NULL, side text NOT NULL, line text NOT NULL DEFAULT '',
  outcome text CHECK (outcome IN ('win','loss','push','void')),
  score_final text, retorno numeric, closing_odds numeric, clv_pct numeric,
  settlement_source text, settled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (espn_event_id, market, side, line)
);

-- ---------- 4) DISPLAY events (append-only) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_display (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_emission_id text NOT NULL, selector_version text, surface text,
  top_pick_rank int, selected_as_top_pick boolean, displayed_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- 5) CAPTURE_CONTRACT (fail-closed sobre presencia de columnas críticas) ----------
CREATE OR REPLACE FUNCTION public.assert_capture_contract() RETURNS text
LANGUAGE plpgsql STABLE AS $c$
DECLARE missing text;
BEGIN
  SELECT string_agg(col,',') INTO missing FROM (
    SELECT unnest(ARRAY['espn_event_id','mercado','pick_nombre','arranca_en','momio_capturado_at',
                        'probabilidad_pct','ev_pct','es_pick','es_pick_reason']) AS col
    EXCEPT
    SELECT column_name FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_pick_canonico'
  ) m;
  RETURN missing;   -- NULL => contrato OK; texto => faltan columnas críticas
END;
$c$;

-- ---------- 6) FUNCIÓN DE CAPTURA (contrato + lectura atómica + digest + guards + audit) ----------
CREATE OR REPLACE FUNCTION public.capture_top_pick_universe(
  p_event_id text, p_source text DEFAULT 'trigger:analisis_partidos', p_analysis_id uuid DEFAULT NULL,
  p_analysis_kind text DEFAULT NULL
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE
  v_missing text; v_read timestamptz := clock_timestamp();
  v_digest text; v_emission text; v_expected int; v_captured int := 0; v_excluded int := 0;
  r record;
BEGIN
  -- CONTRATO
  v_missing := public.assert_capture_contract();
  IF v_missing IS NOT NULL THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,status,failure_code)
    VALUES (NULL,p_event_id,p_analysis_id,p_analysis_kind,v_read,'FAILED','CONTRACT_MISSING_FIELD:'||v_missing);
    RETURN 'FAILED_CONTRACT';
  END IF;

  -- LECTURA ATÓMICA ÚNICA del universo canónico del evento
  CREATE TEMP TABLE _snap ON COMMIT DROP AS
    SELECT espn_event_id, arranca_en, deporte, liga, home, away, mercado, pick_nombre, pick_desc,
           momio_mercado, momio_capturado_at, odds_source, casa, fuente,
           probabilidad_pct, ev_pct, es_pick, es_pick_reason, calibracion_confiable
    FROM public.v_pick_canonico WHERE espn_event_id = p_event_id;

  SELECT count(*) INTO v_expected FROM _snap;
  IF v_expected = 0 THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,expected_candidate_count,captured_candidate_count,excluded_count,status)
    VALUES (NULL,p_event_id,p_analysis_id,p_analysis_kind,v_read,0,0,0,'NO_CHANGE');
    DROP TABLE _snap; RETURN 'NO_CANDIDATES';
  END IF;

  -- DIGEST de contenido -> decision_emission_id (estable ante updates no-predictivos)
  SELECT md5(string_agg(md5(coalesce(mercado,'')||'|'||coalesce(pick_nombre,'')||'|'||coalesce(pick_desc,'')||'|'||
             coalesce(probabilidad_pct::text,'')||'|'||coalesce(ev_pct::text,'')||'|'||
             coalesce(momio_mercado::text,'')||'|'||coalesce(es_pick::text,'')||'|'||coalesce(es_pick_reason,'')),
             ',' ORDER BY mercado,pick_nombre,pick_desc))
    INTO v_digest FROM _snap;
  v_emission := md5(p_event_id||'|'||v_digest);

  -- Idempotencia: emisión ya auditada => no-op (update no-predictivo o replay)
  IF EXISTS (SELECT 1 FROM public.top_pick_capture_audit WHERE decision_emission_id=v_emission) THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,expected_candidate_count,captured_candidate_count,excluded_count,status)
    VALUES (v_emission||':replay',p_event_id,p_analysis_id,p_analysis_kind,v_read,v_expected,0,0,'NO_CHANGE');
    DROP TABLE _snap; RETURN 'NO_CHANGE';
  END IF;

  FOR r IN SELECT * FROM _snap LOOP
    -- GUARD temporal: event_start no-nulo y decisión < evento
    IF r.arranca_en IS NULL OR v_read >= r.arranca_en THEN
      v_excluded := v_excluded + 1; CONTINUE;
    END IF;
    INSERT INTO public.top_pick_capture(
      decision_emission_id, decision_timestamp, canonical_read_at, source_analysis_id, source_analysis_kind,
      espn_event_id, event_start_timestamp, deporte, liga, home_team, away_team,
      market, side, line, sportsbook, odds_decimal, odds_captured_at, odds_source,
      model_source, provenance_status, p_decision, ev_decision, economic_eligible, es_pick,
      eligibility_reason_code, calibration_status,
      features_input_json, feature_source_timestamps, feature_presence_mask,
      prediction_snapshot_hash, source_capture_point, market_generation_status)
    VALUES (
      v_emission, v_read, v_read, p_analysis_id, p_analysis_kind,
      r.espn_event_id, r.arranca_en, r.deporte, r.liga, r.home, r.away,
      r.mercado, r.pick_nombre, r.pick_desc, r.casa, r.momio_mercado, r.momio_capturado_at, r.odds_source,
      r.fuente, r.es_pick_reason, r.probabilidad_pct, r.ev_pct, r.es_pick, r.es_pick,
      r.es_pick_reason, r.calibracion_confiable,
      jsonb_strip_nulls(jsonb_build_object('canonical',
        jsonb_build_object('p_decision',r.probabilidad_pct,'ev_pct',r.ev_pct,'es_pick',r.es_pick,
          'reason_code',r.es_pick_reason,'calibracion_confiable',r.calibracion_confiable),
        'odds', jsonb_build_object('decimal',r.momio_mercado,'casa',r.casa,'source',r.odds_source,'captured_at',r.momio_capturado_at))),
      jsonb_strip_nulls(jsonb_build_object('odds',r.momio_capturado_at,'p_decision',v_read)),
      jsonb_build_object('p_raw',false,'model_version',false,'lineup',false,'injuries',false,'xg',false,'data_readiness',false),
      md5(coalesce(r.mercado,'')||coalesce(r.pick_nombre,'')||coalesce(r.pick_desc,'')||coalesce(r.probabilidad_pct::text,'')||coalesce(r.ev_pct::text,'')||coalesce(r.momio_mercado::text,'')||coalesce(r.es_pick::text,'')),
      p_source, 'captured')
    ON CONFLICT (decision_emission_id, market, side, coalesce(line,'')) DO NOTHING;
    v_captured := v_captured + 1;
  END LOOP;

  INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
    source_analysis_kind,decision_timestamp,expected_candidate_count,captured_candidate_count,excluded_count,status)
  VALUES (v_emission,p_event_id,p_analysis_id,p_analysis_kind,v_read,v_expected,v_captured,v_excluded,
    CASE WHEN v_excluded=0 THEN 'COMPLETE' ELSE 'PARTIAL' END);
  DROP TABLE _snap;
  RETURN 'OK';
END;
$fn$;

-- ---------- 7) TRIGGER tolerante a fallos en analisis_partidos ----------
CREATE OR REPLACE FUNCTION public.trg_capture_top_pick() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $t$
DECLARE v_kind text;
BEGIN
  v_kind := CASE WHEN TG_OP='INSERT' THEN 'emission'
                 WHEN NEW.reanalizado_at IS DISTINCT FROM OLD.reanalizado_at THEN 'recompute'
                 ELSE 'non_prediction' END;
  BEGIN
    PERFORM public.capture_top_pick_universe(
      COALESCE(NULLIF(NEW.espn_event_id_canonico,''), NEW.espn_event_id),
      'trigger:analisis_partidos', NEW.id, v_kind);
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.top_pick_capture_audit(espn_event_id,source_analysis_id,source_analysis_kind,
      decision_timestamp,status,failure_code)
    VALUES (COALESCE(NEW.espn_event_id_canonico,NEW.espn_event_id),NEW.id,v_kind,clock_timestamp(),'FAILED',left(SQLERRM,200));
  END;
  RETURN NEW;
END;
$t$;

CREATE TRIGGER trg_top_pick_capture
  AFTER INSERT OR UPDATE ON public.analisis_partidos
  FOR EACH ROW EXECUTE FUNCTION public.trg_capture_top_pick();

-- Deploy real: REVOKE UPDATE ON public.top_pick_capture FROM <rol_settlement>;  (snapshot inmutable)
