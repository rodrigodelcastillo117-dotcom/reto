-- ============================================================================
-- TOP_PICK_FORWARD_CAPTURE_V1 — DDL v4 CIERRE FINAL (SHADOW / NO DEPLOY / solo LAB branch)
-- ----------------------------------------------------------------------------
-- Cierra los 3 blockers finales:
--  B1 UNIVERSO COMPLETO ESTRUCTURADO: prefiere analisis_json.all_candidates[] (productor);
--     cae a picks_recomendados[] marcando is_full_universe=false; no_bet=texto => ANALYSIS_TEXT_ONLY.
--  B2 APPEND-ONLY REAL: hashes ANTES del INSERT, un solo INSERT..SELECT, 0 UPDATE/DELETE,
--     candado BEFORE UPDATE/DELETE/TRUNCATE INCONDICIONAL (sin GUC). Corrección = fila nueva.
--  B3 EMISSION LEDGER DURABLE: prediction_emission_ledger append-only en el punto productor,
--     sobrevive reanálisis; reconciliación LEDGER LEFT JOIN audit -> MISSING_EMISSIONS.
-- IDENTIDAD: decision_emission_id = UUID por corrida (no md5(contenido/ts)); emission_hash=SHA-256.
-- Requiere pgcrypto. NO cambia P/EV/Kelly/economic authority, NO autoriza modelos, NO ranker,
-- NO toca v_pick_canonico/economic_*/analisis_partidos-lógica ni ISS-003/009.
-- capture_schema_version = TOP_PICK_CAPTURE_V4
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- rol admin explícito para correcciones (idempotente; en LAB puede ya existir)
DO $r$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='tpc_admin') THEN
    CREATE ROLE tpc_admin NOLOGIN;
  END IF;
END $r$;

-- ---------- helpers puros (SHA-256, normalización) ----------
CREATE OR REPLACE FUNCTION public.tpc_sha256(p_txt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT encode(digest(convert_to(coalesce(p_txt,''),'UTF8'),'sha256'),'hex') $$;

CREATE OR REPLACE FUNCTION public.tpc_norm_line(p_line text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(nullif(btrim(p_line),''),'∅') $$;

-- despoja prefijo display "[…] " del pick de la emisión (solo para alineación secundaria, no identidad)
CREATE OR REPLACE FUNCTION public.tpc_strip_label(p text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT btrim(regexp_replace(coalesce(p,''),'^\[[^\]]*\]\s*','')) $$;

-- hash de contenido de un candidato (representación canónica explícita)
CREATE OR REPLACE FUNCTION public.tpc_row_hash(
  p_market text, p_side text, p_nline text, p_praw numeric, p_pdec numeric,
  p_ev numeric, p_odds numeric, p_version text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
  SELECT public.tpc_sha256(jsonb_build_object(
    'market',p_market,'side',p_side,'line',p_nline,'p_raw',p_praw,'p_decision',p_pdec,
    'ev',p_ev,'odds',p_odds,'model_version',p_version)::text) $$;

-- ============================================================================
-- B3) LEDGER DURABLE (append-only; punto productor)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.prediction_emission_ledger (
  decision_emission_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),   -- IDENTIDAD de corrida
  event_id              text NOT NULL,
  emitted_at            timestamptz NOT NULL,                         -- = generado_en (PRODUCTOR)
  producer_version      text NOT NULL,
  engine                text,
  candidate_count       int,
  emission_hash         text NOT NULL,                                -- SHA-256 contenido (integridad)
  source_analysis_id    uuid,
  created_at            timestamptz NOT NULL DEFAULT now()            -- OBSERVADOR
);
-- idempotencia de RETRY (no colapsa emisiones reales: distinto emitted_at => otra fila)
CREATE UNIQUE INDEX IF NOT EXISTS ux_ledger_natural
  ON public.prediction_emission_ledger (event_id, emitted_at, emission_hash);
CREATE INDEX IF NOT EXISTS ix_ledger_event ON public.prediction_emission_ledger (event_id);

-- ============================================================================
-- B1) SNAPSHOT append-only (universo por corrida)
-- ============================================================================
CREATE TABLE IF NOT EXISTS public.top_pick_capture (
  capture_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  decision_emission_id    uuid NOT NULL REFERENCES public.prediction_emission_ledger(decision_emission_id),
  captured_at             timestamptz NOT NULL DEFAULT now(),
  decision_timestamp      timestamptz NOT NULL,                       -- = generado_en
  capture_schema_version  text NOT NULL DEFAULT 'TOP_PICK_CAPTURE_V4'
                            CHECK (capture_schema_version='TOP_PICK_CAPTURE_V4'),
  source_analysis_id      uuid,
  source_analysis_kind    text,
  producer_version        text NOT NULL,
  -- procedencia estructural del candidato
  candidate_source_type   text NOT NULL
     CHECK (candidate_source_type IN ('EMISSION_GENERATED_STRUCTURED','CANONICAL_OBSERVED','ANALYSIS_TEXT_ONLY','UNKNOWN')),
  is_full_universe        boolean NOT NULL DEFAULT false,             -- true solo si vino de all_candidates[]
  candidate_kind          text,                                       -- recommended | no_bet | all_candidate
  raw_text                text,                                       -- solo ANALYSIS_TEXT_ONLY
  -- identidad del candidato
  espn_event_id           text NOT NULL,
  event_start_timestamp   timestamptz,
  deporte text, liga text, home_team text, away_team text,
  market                  text,                                       -- NULL en ANALYSIS_TEXT_ONLY
  side                    text,
  line                    text,
  normalized_line         text NOT NULL DEFAULT '∅',
  -- precio a la decisión
  sportsbook text, odds_decimal numeric, odds_captured_at timestamptz, odds_source text, odds_verificadas boolean,
  -- provenance de modelo (contrato)
  model_name text, model_version text, model_mode text, prob_source text,
  -- autoridades reales separadas (copiadas, NO recalculadas)
  p_raw numeric, p_decision numeric, ev_decision numeric, momio_justo numeric, clasificacion text,
  eligibility boolean, eligibility_reason_code text,                  -- lo que YA decidió el motor
  provenance_complete boolean NOT NULL,
  -- gate económico canónico (alineación SECUNDARIA; procedencia/tiempo aparte)
  canonical_read_at timestamptz, canonical_es_pick boolean, canonical_reason_code text,
  canonical_ev numeric, canonical_alignment_status text, calibration_status boolean,
  -- snapshot de features + máscara
  features_input_json jsonb NOT NULL DEFAULT '{}'::jsonb,
  feature_presence_mask jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_snapshot_timestamps jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- HASHES (calculados ANTES del INSERT; sin post-update)
  prediction_snapshot_hash text NOT NULL,
  event_prediction_digest  text NOT NULL,
  source_capture_point text NOT NULL,
  CONSTRAINT tpc_decision_before_event
    CHECK (event_start_timestamp IS NULL OR decision_timestamp < event_start_timestamp),
  -- coherencia de procedencia: estructurado exige market/side; texto exige raw_text
  CONSTRAINT tpc_structured_has_identity
    CHECK (candidate_source_type <> 'ANALYSIS_TEXT_ONLY' OR (market IS NULL AND raw_text IS NOT NULL)),
  CONSTRAINT tpc_textonly_no_market
    CHECK (candidate_source_type = 'ANALYSIS_TEXT_ONLY' OR market IS NOT NULL)
);
-- DEDUP: identidad de corrida × pick estructurado (NULLS NOT DISTINCT, normalized_line nunca NULL)
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_emission_pick
  ON public.top_pick_capture (decision_emission_id, market, side, normalized_line) NULLS NOT DISTINCT
  WHERE candidate_source_type <> 'ANALYSIS_TEXT_ONLY';
-- DEDUP texto libre: por corrida × texto
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_emission_text
  ON public.top_pick_capture (decision_emission_id, raw_text)
  WHERE candidate_source_type = 'ANALYSIS_TEXT_ONLY';
CREATE INDEX IF NOT EXISTS ix_tpc_event ON public.top_pick_capture (espn_event_id);
CREATE INDEX IF NOT EXISTS ix_tpc_emis  ON public.top_pick_capture (decision_emission_id);
CREATE INDEX IF NOT EXISTS ix_tpc_prov  ON public.top_pick_capture (provenance_complete);

-- ---------- AUDIT append-only (por corrida) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_emission_id uuid,
  espn_event_id text NOT NULL,
  source_analysis_id uuid, source_analysis_kind text,
  decision_timestamp timestamptz, producer_version text,
  universe_source text,                         -- ALL_CANDIDATES | PICKS_RECOMENDADOS | NONE
  structured_universe_status text,              -- COMPLETE | INCOMPLETE
  expected_candidate_count int, captured_candidate_count int,
  text_only_count int, excluded_count int, complete_provenance_count int,
  status text NOT NULL CHECK (status IN ('COMPLETE','PARTIAL','FAILED','NO_CHANGE')),
  failure_code text,
  captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_audit_emission
  ON public.top_pick_capture_audit (decision_emission_id) WHERE decision_emission_id IS NOT NULL;

-- ---------- SETTLEMENT (post-evento; nunca muta snapshot) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_settlement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  espn_event_id text NOT NULL, market text NOT NULL, side text NOT NULL, normalized_line text NOT NULL DEFAULT '∅',
  outcome text CHECK (outcome IN ('win','loss','push','void')),
  score_final text, retorno numeric, closing_odds numeric, clv_pct numeric,
  settlement_source text, settled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (espn_event_id, market, side, normalized_line)
);

-- ---------- DISPLAY events (append-only) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_display (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_emission_id uuid NOT NULL, selector_version text, surface text,
  top_pick_rank int, selected_as_top_pick boolean, displayed_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- CORRECCIÓN append-only (única vía admin; nunca UPDATE del snapshot) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture_correction (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  corrects_capture_id uuid REFERENCES public.top_pick_capture(capture_id),
  reason text NOT NULL, corrected_payload jsonb NOT NULL,
  corrected_by text NOT NULL DEFAULT current_user, corrected_at timestamptz NOT NULL DEFAULT now()
);

-- ============================================================================
-- B2) APPEND-ONLY INCONDICIONAL (sin GUC). UPDATE/DELETE/TRUNCATE => REJECT.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.tpc_block_row_mutation() RETURNS trigger
LANGUAGE plpgsql AS $b$
BEGIN
  RAISE EXCEPTION 'APPEND_ONLY: % en % rechazado (snapshot inmutable; corrección = fila nueva)',
    TG_OP, TG_TABLE_NAME;
END $b$;
CREATE OR REPLACE FUNCTION public.tpc_block_truncate() RETURNS trigger
LANGUAGE plpgsql AS $b$
BEGIN
  RAISE EXCEPTION 'APPEND_ONLY: TRUNCATE en % rechazado', TG_TABLE_NAME;
END $b$;

CREATE TRIGGER tpc_ao_capture   BEFORE UPDATE OR DELETE ON public.top_pick_capture
  FOR EACH ROW EXECUTE FUNCTION public.tpc_block_row_mutation();
CREATE TRIGGER tpc_ao_capture_t BEFORE TRUNCATE ON public.top_pick_capture
  FOR EACH STATEMENT EXECUTE FUNCTION public.tpc_block_truncate();
CREATE TRIGGER tpc_ao_display   BEFORE UPDATE OR DELETE ON public.top_pick_display
  FOR EACH ROW EXECUTE FUNCTION public.tpc_block_row_mutation();
CREATE TRIGGER tpc_ao_ledger    BEFORE UPDATE OR DELETE ON public.prediction_emission_ledger
  FOR EACH ROW EXECUTE FUNCTION public.tpc_block_row_mutation();
CREATE TRIGGER tpc_ao_ledger_t  BEFORE TRUNCATE ON public.prediction_emission_ledger
  FOR EACH STATEMENT EXECUTE FUNCTION public.tpc_block_truncate();

-- corrección administrativa: NO muta snapshot; solo inserta en la tabla de correcciones
CREATE OR REPLACE FUNCTION public.tpc_admin_correct(p_capture_id uuid, p_reason text, p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $a$
DECLARE v_id bigint;
BEGIN
  INSERT INTO public.top_pick_capture_correction(corrects_capture_id,reason,corrected_payload)
  VALUES (p_capture_id,p_reason,p_payload) RETURNING id INTO v_id;
  RETURN v_id;
END $a$;
ALTER FUNCTION public.tpc_admin_correct(uuid,text,jsonb) OWNER TO tpc_admin;

-- ============================================================================
-- CONTRATO DE VERSIÓN (fail-closed)
-- ============================================================================
CREATE OR REPLACE FUNCTION public.assert_capture_contract(p_aj jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $c$
DECLARE v_ver text; missing text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
       WHERE table_schema='public' AND table_name='v_pick_canonico' AND column_name='es_pick_reason')
  THEN RETURN 'CANONICAL_MISSING_es_pick_reason'; END IF;
  IF p_aj IS NULL THEN RETURN 'ANALISIS_JSON_NULL'; END IF;
  missing := (SELECT string_agg(k,',') FROM (
     SELECT unnest(ARRAY['generado_en','analysis_version']) k EXCEPT SELECT jsonb_object_keys(p_aj)) s);
  IF missing IS NOT NULL THEN RETURN 'RUN_MISSING_FIELD:'||missing; END IF;
  v_ver := p_aj->>'analysis_version';
  IF v_ver IS DISTINCT FROM 'meta-v3' THEN RETURN 'UNSUPPORTED_PRODUCER_VERSION:'||coalesce(v_ver,'<null>'); END IF;
  RETURN NULL;
END $c$;

-- ============================================================================
-- CAPTURA V4: hashes ANTES del INSERT, un solo INSERT..SELECT, 0 post-update, sin GUC.
-- Universo: all_candidates[] (preferido) o picks_recomendados[] (parcial). Texto libre => ANALYSIS_TEXT_ONLY.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.capture_top_pick_universe(
  p_analysis_id uuid, p_source text DEFAULT 'trigger:analisis_partidos', p_analysis_kind text DEFAULT 'emission'
) RETURNS text
LANGUAGE plpgsql SET search_path TO 'public'
AS $fn$
DECLARE
  a record; aj jsonb; v_missing text;
  v_event text; v_generado timestamptz; v_ver text; v_engine text; v_mode text;
  v_event_start timestamptz; v_canon_read timestamptz;
  v_emission uuid; v_ehash text; v_universe text; v_arr jsonb;
  v_expected int; v_captured int; v_text int; v_prov int; v_excluded int; v_digest text;
  v_deporte text; v_liga text; v_home text; v_away text; v_ctx jsonb;
BEGIN
  SELECT * INTO a FROM public.analisis_partidos WHERE id=p_analysis_id;
  IF NOT FOUND THEN RETURN 'NO_ROW'; END IF;
  aj := a.analisis_json;

  v_missing := public.assert_capture_contract(aj);
  IF v_missing IS NOT NULL THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,status,failure_code)
    VALUES (NULL,COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id),p_analysis_id,p_analysis_kind,
      NULLIF(aj->>'generado_en','')::timestamptz,'FAILED',v_missing);
    RETURN 'FAILED_CONTRACT:'||v_missing;
  END IF;

  v_event   := COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id);
  v_generado:= (aj->>'generado_en')::timestamptz;
  v_ver     := aj->>'analysis_version';
  v_engine  := aj->>'pick_engine_used';
  v_mode    := aj->>'pick_engine_mode';

  -- IDENTIDAD: leer del LEDGER (escrito por trg_a_emission_ledger, ya visible en esta tx)
  SELECT decision_emission_id INTO v_emission FROM public.prediction_emission_ledger
   WHERE event_id=v_event AND emitted_at=v_generado ORDER BY created_at DESC LIMIT 1;
  IF v_emission IS NULL THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,producer_version,status,failure_code)
    VALUES (NULL,v_event,p_analysis_id,p_analysis_kind,v_generado,v_ver,'FAILED','LEDGER_ROW_MISSING');
    RETURN 'FAILED_NO_LEDGER';
  END IF;

  -- Idempotencia por corrida
  IF EXISTS (SELECT 1 FROM public.top_pick_capture_audit WHERE decision_emission_id=v_emission) THEN
    RETURN 'NO_CHANGE';
  END IF;

  BEGIN v_event_start := NULLIF(a.espn_data_json #>> '{header,competitions,0,date}','')::timestamptz;
  EXCEPTION WHEN OTHERS THEN v_event_start := NULL; END;
  v_deporte:=aj->>'deporte'; v_liga:=aj->>'liga'; v_home:=aj->>'home'; v_away:=aj->>'away';
  v_ctx := jsonb_strip_nulls(jsonb_build_object(
    'forma_local',aj->'forma_local','forma_visitante',aj->'forma_visitante','lesiones',aj->'lesiones',
    'h2h_resumen',aj->'h2h_resumen','goles_esperados',aj->'goles_esperados','fatiga_viaje',aj->'fatiga_viaje',
    'momentum',aj->'momentum','estadio',aj->'estadio','clima',aj->'clima','probabilidades',aj->'probabilidades'));

  -- FUENTE DE UNIVERSO: preferir all_candidates[]; si no, picks_recomendados[]
  IF jsonb_typeof(aj->'all_candidates')='array' THEN
    v_arr := aj->'all_candidates'; v_universe := 'ALL_CANDIDATES';
  ELSIF jsonb_typeof(aj->'picks_recomendados')='array' THEN
    v_arr := aj->'picks_recomendados'; v_universe := 'PICKS_RECOMENDADOS';
  ELSE
    v_arr := '[]'::jsonb; v_universe := 'NONE';
  END IF;

  -- lectura canónica SECUNDARIA (snapshot MVCC propio, tiempo aparte)
  v_canon_read := clock_timestamp();
  CREATE TEMP TABLE _canon ON COMMIT DROP AS
    SELECT mercado, pick_nombre, es_pick, es_pick_reason, ev_pct, calibracion_confiable
    FROM public.v_pick_canonico WHERE espn_event_id=v_event;

  -- PASO 1: materializar candidatos estructurados con hash por fila (SIN insertar todavía)
  CREATE TEMP TABLE _cand ON COMMIT DROP AS
  WITH raw AS (SELECT pk FROM jsonb_array_elements(v_arr) pk WHERE jsonb_typeof(pk)='object')
  SELECT
    (pk->>'market')  AS market_ac, (pk->>'side') AS side_ac, (pk->>'line') AS line_ac,
    (pk->>'mercado') AS market_pr, (pk->>'pick') AS side_pr,      -- forma picks_recomendados
    pk AS obj
  FROM raw;

  -- normalización de columnas según la fuente (all_candidates trae market/side limpios)
  CREATE TEMP TABLE _norm ON COMMIT DROP AS
  SELECT
    COALESCE(market_ac, market_pr) AS market,
    COALESCE(side_ac, public.tpc_strip_label(side_pr)) AS side,       -- side limpio (sin prefijo display)
    COALESCE(line_ac, obj->>'line') AS line,
    NULLIF(obj->>'prob','')::numeric                                    AS p_raw,
    COALESCE(NULLIF(obj->>'P_RAW','')::numeric, NULLIF(obj->>'prob','')::numeric) AS p_raw2,
    COALESCE(NULLIF(obj->>'P_DECISION','')::numeric, NULLIF(obj->>'probabilidad_real','')::numeric) AS p_decision,
    COALESCE(NULLIF(obj->>'EV_DECISION','')::numeric, NULLIF(obj->>'ev_con_precio_real','')::numeric,
             NULLIF(obj->>'ev_estimado','')::numeric) AS ev_decision,
    COALESCE(NULLIF(obj->>'odds','')::numeric, NULLIF(obj->>'momio_mercado','')::numeric) AS odds_decimal,
    COALESCE(NULLIF(obj->>'odds_timestamp','')::timestamptz, NULLIF(obj->>'precio_sellado_at','')::timestamptz) AS odds_at,
    obj->>'prob_source' AS prob_source, obj->>'odds_source' AS odds_source,
    NULLIF(obj->>'odds_verificadas','')::boolean AS odds_verificadas,
    NULLIF(obj->>'momio_justo','')::numeric AS momio_justo, obj->>'clasificacion' AS clasificacion,
    COALESCE(NULLIF(obj->>'eligibility','')::boolean, NULLIF(obj->>'es_pick','')::boolean) AS eligibility,
    COALESCE(obj->>'reason', obj->>'reason_code') AS reason_code,
    obj AS obj
  FROM _cand;

  SELECT count(*) INTO v_expected FROM _norm;
  -- filas excluidas por guard temporal (decisión >= evento)
  v_excluded := 0;
  IF v_event_start IS NOT NULL AND v_generado >= v_event_start THEN
    v_excluded := v_expected;  -- toda la corrida es post-evento: nada se captura como válido
  END IF;

  -- digest de corrida: hash sobre hashes de fila ORDENADOS (orden de filas irrelevante) — ANTES del INSERT
  SELECT public.tpc_sha256(string_agg(h,';' ORDER BY h)) INTO v_digest
  FROM (SELECT public.tpc_row_hash(market,side,public.tpc_norm_line(line),
               COALESCE(p_raw2,p_raw),p_decision,ev_decision,odds_decimal,v_ver) AS h FROM _norm) z;
  v_digest := COALESCE(v_digest, public.tpc_sha256(v_emission::text));  -- corrida sin candidatos estructurados

  -- PASO 2: un ÚNICO INSERT..SELECT de candidatos estructurados (filas COMPLETAS, 0 post-update)
  WITH ins AS (
    INSERT INTO public.top_pick_capture(
      decision_emission_id, decision_timestamp, source_analysis_id, source_analysis_kind, producer_version,
      candidate_source_type, is_full_universe, candidate_kind,
      espn_event_id, event_start_timestamp, deporte, liga, home_team, away_team,
      market, side, line, normalized_line,
      sportsbook, odds_decimal, odds_captured_at, odds_source, odds_verificadas,
      model_name, model_version, model_mode, prob_source,
      p_raw, p_decision, ev_decision, momio_justo, clasificacion, eligibility, eligibility_reason_code,
      provenance_complete,
      canonical_read_at, canonical_es_pick, canonical_reason_code, canonical_ev, canonical_alignment_status, calibration_status,
      features_input_json, feature_presence_mask, source_snapshot_timestamps,
      prediction_snapshot_hash, event_prediction_digest, source_capture_point)
    SELECT
      v_emission, v_generado, p_analysis_id, p_analysis_kind, v_ver,
      'EMISSION_GENERATED_STRUCTURED', (v_universe='ALL_CANDIDATES'), 'all_candidate',
      v_event, v_event_start, v_deporte, v_liga, v_home, v_away,
      n.market, n.side, n.line, public.tpc_norm_line(n.line),
      n.obj->>'casa',
      CASE WHEN n.odds_at IS NOT NULL AND n.odds_at > v_generado THEN NULL ELSE n.odds_decimal END,
      CASE WHEN n.odds_at IS NOT NULL AND n.odds_at > v_generado THEN NULL ELSE n.odds_at END,
      n.odds_source, n.odds_verificadas,
      v_engine, v_ver, v_mode, n.prob_source,
      COALESCE(n.p_raw2,n.p_raw), n.p_decision, n.ev_decision, n.momio_justo, n.clasificacion, n.eligibility, n.reason_code,
      (v_engine IS NOT NULL AND v_ver IS NOT NULL AND COALESCE(n.p_raw2,n.p_raw) IS NOT NULL AND n.p_decision IS NOT NULL),
      v_canon_read, c.es_pick, c.es_pick_reason, c.ev_pct,
      CASE WHEN c.mercado IS NULL THEN 'MISSING'
           WHEN c.ev_pct IS NOT DISTINCT FROM n.ev_decision THEN 'MATCHED' ELSE 'DRIFTED' END,
      c.calibracion_confiable,
      v_ctx,
      jsonb_build_object('p_raw',COALESCE(n.p_raw2,n.p_raw) IS NOT NULL,'p_decision',n.p_decision IS NOT NULL,
        'model_version',v_ver IS NOT NULL,'odds',n.odds_decimal IS NOT NULL,'prob_source',n.prob_source IS NOT NULL,
        'canonical_gate',c.mercado IS NOT NULL),
      jsonb_strip_nulls(jsonb_build_object('analisis',to_jsonb(v_generado),'precio_sellado',to_jsonb(n.odds_at),'canonical',to_jsonb(v_canon_read))),
      public.tpc_row_hash(n.market,n.side,public.tpc_norm_line(n.line),COALESCE(n.p_raw2,n.p_raw),n.p_decision,n.ev_decision,n.odds_decimal,v_ver),
      v_digest, p_source
    FROM _norm n
    LEFT JOIN _canon c ON c.mercado=n.market AND c.pick_nombre=n.side
    WHERE NOT (v_event_start IS NOT NULL AND v_generado >= v_event_start)   -- guard temporal
      AND n.market IS NOT NULL AND n.side IS NOT NULL
    ON CONFLICT (decision_emission_id, market, side, normalized_line) DO NOTHING
    RETURNING provenance_complete)
  SELECT count(*), count(*) FILTER (WHERE provenance_complete) INTO v_captured, v_prov FROM ins;

  -- texto libre no_bet => ANALYSIS_TEXT_ONLY (nunca market/side estructurado); INSERT separado
  WITH ins2 AS (
    INSERT INTO public.top_pick_capture(
      decision_emission_id, decision_timestamp, source_analysis_id, source_analysis_kind, producer_version,
      candidate_source_type, is_full_universe, candidate_kind, raw_text,
      espn_event_id, event_start_timestamp, deporte, liga, home_team, away_team,
      normalized_line, provenance_complete,
      features_input_json, feature_presence_mask, source_snapshot_timestamps,
      prediction_snapshot_hash, event_prediction_digest, source_capture_point)
    SELECT
      v_emission, v_generado, p_analysis_id, p_analysis_kind, v_ver,
      'ANALYSIS_TEXT_ONLY', false, 'no_bet', t.txt,
      v_event, v_event_start, v_deporte, v_liga, v_home, v_away,
      '∅', false,
      '{}'::jsonb, jsonb_build_object('text_only',true),
      jsonb_strip_nulls(jsonb_build_object('analisis',to_jsonb(v_generado))),
      public.tpc_sha256('TEXTONLY|'||t.txt), v_digest, p_source
    FROM (SELECT jsonb_array_elements_text(aj->'no_bet_picks') AS txt
          WHERE jsonb_typeof(aj->'no_bet_picks')='array') t
    ON CONFLICT (decision_emission_id, raw_text) DO NOTHING
    RETURNING 1)
  SELECT count(*) INTO v_text FROM ins2;

  INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
    source_analysis_kind,decision_timestamp,producer_version,universe_source,structured_universe_status,
    expected_candidate_count,captured_candidate_count,text_only_count,excluded_count,complete_provenance_count,status)
  VALUES (v_emission,v_event,p_analysis_id,p_analysis_kind,v_generado,v_ver,v_universe,
    CASE WHEN v_universe='ALL_CANDIDATES' THEN 'COMPLETE' ELSE 'INCOMPLETE' END,
    v_expected,v_captured,v_text,v_excluded,v_prov,
    CASE WHEN v_excluded=0 AND v_captured=v_expected THEN 'COMPLETE' ELSE 'PARTIAL' END);
  RETURN 'OK';
END;
$fn$;

-- ============================================================================
-- TRIGGERS en analisis_partidos: (a) LEDGER durable primero, (b) captura aislada.
-- ============================================================================
-- (a) LEDGER — corre primero por nombre (trg_a_...). Mínimo, robusto.
CREATE OR REPLACE FUNCTION public.trg_emission_ledger() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $t$
DECLARE v_event text; v_gen timestamptz; v_ver text; v_hash text; v_cnt int; v_uuid uuid;
BEGIN
  IF NEW.analisis_json IS NULL OR NOT (NEW.analisis_json ? 'generado_en') THEN RETURN NEW; END IF;
  v_event := COALESCE(NULLIF(NEW.espn_event_id_canonico,''),NEW.espn_event_id);
  v_gen   := (NEW.analisis_json->>'generado_en')::timestamptz;
  v_ver   := NEW.analisis_json->>'analysis_version';
  v_cnt   := COALESCE(jsonb_array_length(NEW.analisis_json->'all_candidates'),
                      jsonb_array_length(NEW.analisis_json->'picks_recomendados'),0);
  -- emission_hash de contenido (SHA-256), separado de la identidad
  v_hash  := public.tpc_sha256(v_event||'|'||(NEW.analisis_json->>'generado_en')||'|'||coalesce(v_ver,'')||'|'||
                               coalesce((NEW.analisis_json->'all_candidates')::text,
                                        (NEW.analisis_json->'picks_recomendados')::text,''));
  -- IDENTIDAD: UUID del productor si existe, si no gen_random_uuid() (una vez por corrida)
  v_uuid  := COALESCE(NULLIF(NEW.analisis_json->>'emission_uuid','')::uuid, gen_random_uuid());
  BEGIN
    INSERT INTO public.prediction_emission_ledger(decision_emission_id,event_id,emitted_at,producer_version,
      engine,candidate_count,emission_hash,source_analysis_id)
    VALUES (v_uuid,v_event,v_gen,coalesce(v_ver,'<null>'),NEW.analisis_json->>'pick_engine_used',v_cnt,v_hash,NEW.id)
    ON CONFLICT (event_id, emitted_at, emission_hash) DO NOTHING;   -- RETRY idempotente
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'trg_emission_ledger: no se pudo registrar emisión % (%): %', v_event, v_gen, SQLERRM;
  END;
  RETURN NEW;
END $t$;

CREATE TRIGGER trg_a_emission_ledger
  AFTER INSERT OR UPDATE ON public.analisis_partidos
  FOR EACH ROW EXECUTE FUNCTION public.trg_emission_ledger();

-- (b) CAPTURA — corre después; doble BEGIN/EXCEPTION anidado (aislamiento del audit).
CREATE OR REPLACE FUNCTION public.trg_capture_top_pick() RETURNS trigger
LANGUAGE plpgsql SET search_path TO 'public' AS $t$
DECLARE v_kind text;
BEGIN
  v_kind := CASE WHEN TG_OP='INSERT' THEN 'emission'
                 WHEN NEW.reanalizado_at IS DISTINCT FROM OLD.reanalizado_at THEN 'recompute'
                 ELSE 'non_prediction' END;
  BEGIN
    PERFORM public.capture_top_pick_universe(NEW.id,'trigger:analisis_partidos',v_kind);
  EXCEPTION WHEN OTHERS THEN
    BEGIN
      INSERT INTO public.top_pick_capture_audit(espn_event_id,source_analysis_id,source_analysis_kind,
        decision_timestamp,status,failure_code)
      VALUES (COALESCE(NULLIF(NEW.espn_event_id_canonico,''),NEW.espn_event_id),NEW.id,v_kind,
              clock_timestamp(),'FAILED',left(SQLERRM,200));
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'trg_capture_top_pick: captura Y audit fallaron para % (%)', NEW.id, SQLERRM;
    END;
  END;
  RETURN NEW;   -- NUNCA tumba analisis_partidos
END $t$;

CREATE TRIGGER trg_b_top_pick_capture
  AFTER INSERT OR UPDATE ON public.analisis_partidos
  FOR EACH ROW EXECUTE FUNCTION public.trg_capture_top_pick();

-- ============================================================================
-- RECONCILIACIÓN y salud
-- ============================================================================
-- LEDGER LEFT JOIN audit => EXPECTED/COMPLETE/PARTIAL/MISSING (sobrevive overwrite del análisis)
CREATE OR REPLACE VIEW public.v_emission_ledger_reconciliation AS
SELECT l.decision_emission_id, l.event_id, l.emitted_at, l.producer_version, l.candidate_count,
       au.status AS capture_status,
       CASE
         WHEN au.status='COMPLETE' THEN 'COMPLETE'
         WHEN au.status='PARTIAL'  THEN 'PARTIAL'
         WHEN au.id IS NULL        THEN 'MISSING'
         ELSE 'OTHER' END AS reconciliation_state
FROM public.prediction_emission_ledger l
LEFT JOIN public.top_pick_capture_audit au ON au.decision_emission_id = l.decision_emission_id;

-- backstop: análisis con generado_en SIN fila de ledger (solo detectable antes de un overwrite)
CREATE OR REPLACE VIEW public.v_top_pick_unledgered_analysis AS
SELECT a.id AS analysis_id, COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id) AS event_id,
       (a.analisis_json->>'generado_en')::timestamptz AS generado_en
FROM public.analisis_partidos a
WHERE a.analisis_json ? 'generado_en'
  AND NOT EXISTS (SELECT 1 FROM public.prediction_emission_ledger l
    WHERE l.event_id=COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id)
      AND l.emitted_at=(a.analisis_json->>'generado_en')::timestamptz);

CREATE OR REPLACE VIEW public.v_top_pick_capture_health AS
SELECT date_trunc('day',decision_timestamp) AS day,
  count(*) FILTER (WHERE status='COMPLETE') AS complete, count(*) FILTER (WHERE status='PARTIAL') AS partial,
  count(*) FILTER (WHERE status='FAILED') AS failed,
  count(*) FILTER (WHERE structured_universe_status='INCOMPLETE') AS incomplete_universe,
  round(100.0*count(*) FILTER (WHERE status='FAILED')
        /NULLIF(count(*) FILTER (WHERE status IN ('COMPLETE','PARTIAL','FAILED')),0),3) AS failure_rate_pct,
  sum(complete_provenance_count) AS provenance_complete_rows
FROM public.top_pick_capture_audit GROUP BY 1 ORDER BY 1 DESC;

-- dataset científico: solo estructurado con provenance completa (nunca ANALYSIS_TEXT_ONLY)
CREATE OR REPLACE VIEW public.v_top_pick_science_dataset AS
SELECT c.*, s.outcome, s.retorno, s.closing_odds, s.clv_pct
FROM public.top_pick_capture c
LEFT JOIN public.top_pick_settlement s
  ON s.espn_event_id=c.espn_event_id AND s.market=c.market AND s.side=c.side AND s.normalized_line=c.normalized_line
WHERE c.candidate_source_type='EMISSION_GENERATED_STRUCTURED' AND c.provenance_complete IS TRUE;

-- Deploy real: REVOKE UPDATE,DELETE ON top_pick_capture, top_pick_display, prediction_emission_ledger FROM PUBLIC;
