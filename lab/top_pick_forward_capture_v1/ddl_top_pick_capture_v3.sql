-- ============================================================================
-- TOP_PICK_FORWARD_CAPTURE_V1 — DDL v3 HARDENED (SHADOW / NO DEPLOY / solo LAB branch)
-- ----------------------------------------------------------------------------
-- CAMBIO RECTOR V3: la emisión REAL de la predicción es el generador
-- `analizar-partido` materializado en public.analisis_partidos.analisis_json
-- (estampa generado_en = timestamp de emisión, analysis_version = 'meta-v3',
--  pick_engine_used, y por pick: prob=P_RAW, probabilidad_real=P_DECISION,
--  prob_source, ev_estimado, momio_mercado, precio_sellado_at, ...).
-- Por eso la captura PRIMARIA se toma de analisis_json (una corrida = un
-- generado_en) con LOGICAL_RUN_ATOMICITY=PASS; el gate económico canónico
-- (es_pick/es_pick_reason) se toma de v_pick_canonico como alineación
-- SECUNDARIA con su propio canonical_read_at y canonical_alignment_status.
-- ----------------------------------------------------------------------------
-- Observacional/append-only. NO cambia P/EV/Kelly/es_pick/stake, NO autoriza
-- modelos, NO toca economic_model_authority / v_pick_canonico / analisis_partidos
-- / oraculo_picks_tracking ni los triggers existentes. NO crea ranker.
-- REQUIERE: analysis_version='meta-v3' (productor) y, para el gate secundario,
-- v_pick_canonico @ ISS-009B (columna es_pick_reason). pgcrypto habilitado.
-- capture_schema_version = TOP_PICK_CAPTURE_V3
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- digest(...,'sha256')

-- ---------- 1) PRE-EVENTO: snapshot inmutable append-only (universo por corrida) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture (
  decision_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- identidad de CORRIDA (no de contenido): event ‖ generado_en ‖ analysis_version
  decision_emission_id    text NOT NULL,
  captured_at             timestamptz NOT NULL DEFAULT now(),      -- OBSERVADOR (trigger)
  decision_timestamp      timestamptz NOT NULL,                    -- PRODUCTOR = generado_en
  capture_schema_version  text NOT NULL DEFAULT 'TOP_PICK_CAPTURE_V3'
                            CHECK (capture_schema_version='TOP_PICK_CAPTURE_V3'),
  source_analysis_id      uuid,                                    -- analisis_partidos.id (metadato de origen)
  source_analysis_kind    text,                                    -- emission | recompute | non_prediction
  producer_version        text NOT NULL,                           -- analysis_version (meta-v3)
  -- identidad del candidato (UNIVERSO COMPLETO por corrida: recomendados + no_bet estructurados)
  espn_event_id           text NOT NULL,
  event_start_timestamp   timestamptz,                             -- de espn_data_json (misma corrida); puede faltar
  deporte                 text, liga text, home_team text, away_team text,
  market                  text NOT NULL,                           -- = pick.mercado
  side                    text NOT NULL,                           -- = parse(pick.pick)
  line                    text,                                    -- = parse(pick.pick) (raw)
  normalized_line         text NOT NULL,                           -- coalesce(nullif(btrim(line),''),'∅')
  candidate_kind          text NOT NULL DEFAULT 'recommended',     -- recommended | no_bet
  -- precio a la decisión (sellado por el productor)
  sportsbook              text, odds_decimal numeric,
  odds_captured_at        timestamptz,                             -- = pick.precio_sellado_at
  odds_source             text,                                    -- = pick.odds_source
  odds_verificadas        boolean,
  -- PROVENANCE DE MODELO (contrato §4)
  model_name              text,                                    -- = pick_engine_used
  model_version           text,                                    -- = analysis_version (+mode)
  model_mode              text,                                    -- = pick_engine_mode
  prob_source             text,                                    -- = pick.prob_source (p.ej. Poisson)
  -- AUTORIDADES REALES SEPARADAS (copiadas del productor, NO recalculadas)
  p_raw                   numeric,                                 -- = pick.prob            (P_RAW)
  p_decision              numeric,                                 -- = pick.probabilidad_real (P_DECISION)
  ev_decision             numeric,                                 -- = pick.ev_estimado (o ev_con_precio_real)
  momio_justo             numeric,                                 -- = pick.momio_justo
  clasificacion           text,                                    -- = pick.clasificacion
  provenance_complete     boolean NOT NULL,                        -- §4: model_name+model_version+p_raw+p_decision
  -- GATE ECONÓMICO CANÓNICO (alineación SECUNDARIA; procedencia y tiempo aparte)
  canonical_read_at         timestamptz,                           -- lectura de v_pick_canonico (≠ decision_timestamp)
  economic_eligible         boolean,                               -- = v_pick_canonico.es_pick
  eligibility_reason_code   text,                                  -- = v_pick_canonico.es_pick_reason
  ev_canonical              numeric,                               -- = v_pick_canonico.ev_pct
  canonical_alignment_status text,                                 -- MATCHED | DRIFTED | MISSING
  calibration_status        boolean,                               -- = v_pick_canonico.calibracion_confiable
  -- snapshot de inputs + provenance temporal + máscara de presencia
  features_input_json       jsonb NOT NULL DEFAULT '{}'::jsonb,    -- subset context de analisis_json (ausencia = ausencia)
  feature_presence_mask     jsonb NOT NULL DEFAULT '{}'::jsonb,
  source_snapshot_timestamps jsonb NOT NULL DEFAULT '{}'::jsonb,   -- {analisis:generado_en, precio_sellado:..., canonical:...}
  -- HASHES V3 (SHA-256 determinístico)
  prediction_snapshot_hash  text NOT NULL,                         -- contenido del pick
  event_prediction_digest   text,                                  -- corrida completa (orden de filas irrelevante)
  source_capture_point      text NOT NULL,
  CONSTRAINT tpc_decision_before_event
    CHECK (event_start_timestamp IS NULL OR decision_timestamp < event_start_timestamp)
);

-- DEDUP_V3: identidad de corrida × pick; normalized_line nunca NULL + NULLS NOT DISTINCT (PG 17.6)
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_emission_pick
  ON public.top_pick_capture (decision_emission_id, market, side, normalized_line) NULLS NOT DISTINCT;
CREATE INDEX IF NOT EXISTS ix_tpc_event ON public.top_pick_capture (espn_event_id);
CREATE INDEX IF NOT EXISTS ix_tpc_decis ON public.top_pick_capture (decision_timestamp);
CREATE INDEX IF NOT EXISTS ix_tpc_emis  ON public.top_pick_capture (decision_emission_id);
CREATE INDEX IF NOT EXISTS ix_tpc_prov  ON public.top_pick_capture (provenance_complete);

-- ---------- 2) AUDIT append-only (completitud/estado por corrida; aislado) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_capture_audit (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_emission_id text,
  espn_event_id text NOT NULL,
  source_analysis_id uuid, source_analysis_kind text,
  decision_timestamp timestamptz,                                  -- generado_en de la corrida
  producer_version text,
  expected_candidate_count int, captured_candidate_count int, excluded_count int,
  complete_provenance_count int,
  status text NOT NULL CHECK (status IN ('COMPLETE','PARTIAL','FAILED','NO_CHANGE')),
  failure_code text,
  captured_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_tpc_audit_emission
  ON public.top_pick_capture_audit (decision_emission_id) WHERE decision_emission_id IS NOT NULL;

-- ---------- 3) SETTLEMENT (post-evento; key market/side/line; nunca muta el snapshot) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_settlement (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  espn_event_id text NOT NULL, market text NOT NULL, side text NOT NULL,
  normalized_line text NOT NULL DEFAULT '∅',
  outcome text CHECK (outcome IN ('win','loss','push','void')),
  score_final text, retorno numeric, closing_odds numeric, clv_pct numeric,
  settlement_source text, settled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (espn_event_id, market, side, normalized_line)
);

-- ---------- 4) DISPLAY events (append-only; observacional, NO determina la predicción) ----------
CREATE TABLE IF NOT EXISTS public.top_pick_display (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  decision_emission_id text NOT NULL, selector_version text, surface text,
  top_pick_rank int, selected_as_top_pick boolean, displayed_at timestamptz NOT NULL DEFAULT now()
);

-- ---------- 5) CONTRATO DE VERSIÓN (fail-closed; §9) ----------
-- (a) analisis_json tiene los campos esperados de corrida y por-pick;
-- (b) analysis_version ∈ {'meta-v3'}; (c) v_pick_canonico @ ISS-009B (es_pick_reason).
CREATE OR REPLACE FUNCTION public.assert_capture_contract(p_analysis_json jsonb)
RETURNS text LANGUAGE plpgsql STABLE AS $c$
DECLARE v_ver text; p jsonb; missing text;
BEGIN
  -- (c) gate secundario: columna canónica presente
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
       WHERE table_schema='public' AND table_name='v_pick_canonico' AND column_name='es_pick_reason')
  THEN RETURN 'CANONICAL_MISSING_es_pick_reason'; END IF;
  -- (a) campos de corrida
  IF p_analysis_json IS NULL THEN RETURN 'ANALISIS_JSON_NULL'; END IF;
  missing := (SELECT string_agg(k,',') FROM (
     SELECT unnest(ARRAY['generado_en','analysis_version']) k
     EXCEPT SELECT jsonb_object_keys(p_analysis_json)) s);
  IF missing IS NOT NULL THEN RETURN 'RUN_MISSING_FIELD:'||missing; END IF;
  -- (b) versión soportada explícita
  v_ver := p_analysis_json->>'analysis_version';
  IF v_ver IS DISTINCT FROM 'meta-v3' THEN
    RETURN 'UNSUPPORTED_PRODUCER_VERSION:'||coalesce(v_ver,'<null>');
  END IF;
  -- (a) campos por-pick del primer recomendado (si existe)
  p := (p_analysis_json->'picks_recomendados')->0;
  IF p IS NOT NULL THEN
    missing := (SELECT string_agg(k,',') FROM (
       SELECT unnest(ARRAY['mercado','pick','prob','probabilidad_real']) k
       EXCEPT SELECT jsonb_object_keys(p)) s);
    IF missing IS NOT NULL THEN RETURN 'PICK_MISSING_FIELD:'||missing; END IF;
  END IF;
  RETURN NULL;   -- contrato OK
END;
$c$;

-- ---------- 6) helpers puros ----------
CREATE OR REPLACE FUNCTION public.tpc_sha256(p_txt text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT encode(digest(convert_to(p_txt,'UTF8'),'sha256'),'hex') $$;

CREATE OR REPLACE FUNCTION public.tpc_norm_line(p_line text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$ SELECT coalesce(nullif(btrim(p_line),''),'∅') $$;

-- ---------- 7) FUNCIÓN DE CAPTURA (PRIMARIO=analisis_json; gate canónico SECUNDARIO) ----------
CREATE OR REPLACE FUNCTION public.capture_top_pick_universe(
  p_analysis_id uuid,
  p_source text DEFAULT 'trigger:analisis_partidos',
  p_analysis_kind text DEFAULT 'emission'
) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $fn$
DECLARE
  a record; aj jsonb; v_missing text;
  v_event text; v_generado timestamptz; v_ver text; v_engine text; v_mode text;
  v_event_start timestamptz; v_canon_read timestamptz;
  v_emission text; v_expected int := 0; v_captured int := 0; v_excluded int := 0; v_prov int := 0;
  v_deporte text; v_liga text; v_home text; v_away text;
  arr jsonb; pk jsonb; kind text;
  v_market text; v_side text; v_line text; v_nline text;
  v_praw numeric; v_pdec numeric; v_ev numeric; v_odds numeric; v_odds_at timestamptz;
  v_prov_complete boolean; v_snap_hash text; v_digest text;
  v_es boolean; v_reason text; v_ev_canon numeric; v_calib boolean; v_align text;
  v_ctx jsonb; v_mask jsonb; v_feat jsonb;
  digest_acc text := '';
BEGIN
  -- Origen de la corrida (una fila = una emisión)
  SELECT * INTO a FROM public.analisis_partidos WHERE id = p_analysis_id;
  IF NOT FOUND THEN RETURN 'NO_ROW'; END IF;
  aj := a.analisis_json;

  -- CONTRATO (fail-closed; audit FAILED; NUNCA aborta el producto porque el trigger aísla)
  v_missing := public.assert_capture_contract(aj);
  IF v_missing IS NOT NULL THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,status,failure_code)
    VALUES (NULL, COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id),
            p_analysis_id,p_analysis_kind, NULLIF(aj->>'generado_en','')::timestamptz,
            'FAILED', v_missing);
    RETURN 'FAILED_CONTRACT:'||v_missing;
  END IF;

  v_event   := COALESCE(NULLIF(a.espn_event_id_canonico,''), a.espn_event_id);
  v_generado:= (aj->>'generado_en')::timestamptz;                 -- decision_timestamp (PRODUCTOR)
  v_ver     := aj->>'analysis_version';                           -- meta-v3
  v_engine  := aj->>'pick_engine_used';
  v_mode    := aj->>'pick_engine_mode';
  v_emission:= md5(v_event||'|'||(aj->>'generado_en')||'|'||v_ver);  -- IDENTIDAD DE CORRIDA (§1)

  -- Idempotencia por corrida (retry de la misma emisión => no dup)
  IF EXISTS (SELECT 1 FROM public.top_pick_capture_audit WHERE decision_emission_id=v_emission) THEN
    INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
      source_analysis_kind,decision_timestamp,producer_version,status)
    VALUES (v_emission||':replay',v_event,p_analysis_id,p_analysis_kind,v_generado,v_ver,'NO_CHANGE');
    RETURN 'NO_CHANGE';
  END IF;

  -- event_start desde la MISMA corrida (espn_data_json), sin recalcular
  BEGIN
    v_event_start := NULLIF(a.espn_data_json #>> '{header,competitions,0,date}','')::timestamptz;
  EXCEPTION WHEN OTHERS THEN v_event_start := NULL; END;

  -- metadatos de evento del propio json (fallback a columnas si existen en json)
  v_deporte := aj->>'deporte'; v_liga := aj->>'liga';
  v_home := aj->>'home'; v_away := aj->>'away';

  -- context features top-level (subset demostrable; ausencia = ausencia; SIN reconstrucción)
  v_ctx := jsonb_strip_nulls(jsonb_build_object(
    'forma_local', aj->'forma_local', 'forma_visitante', aj->'forma_visitante',
    'lesiones', aj->'lesiones', 'h2h_resumen', aj->'h2h_resumen',
    'goles_esperados', aj->'goles_esperados', 'fatiga_viaje', aj->'fatiga_viaje',
    'momentum', aj->'momentum', 'estadio', aj->'estadio', 'clima', aj->'clima',
    'probabilidades', aj->'probabilidades'));

  -- lectura canónica SECUNDARIA (snapshot MVCC propio; su tiempo aparte)
  v_canon_read := clock_timestamp();
  CREATE TEMP TABLE _canon ON COMMIT DROP AS
    SELECT mercado, pick_nombre, pick_desc, es_pick, es_pick_reason, ev_pct, calibracion_confiable
    FROM public.v_pick_canonico WHERE espn_event_id = v_event;

  -- recorre UNIVERSO por corrida: picks_recomendados (+ no_bet_picks estructurados)
  FOR kind, arr IN
    SELECT 'recommended', aj->'picks_recomendados'
    UNION ALL
    SELECT 'no_bet', aj->'no_bet_picks'
  LOOP
    IF jsonb_typeof(arr) <> 'array' THEN CONTINUE; END IF;
    FOR pk IN SELECT jsonb_array_elements(arr) LOOP
      IF jsonb_typeof(pk) <> 'object' THEN CONTINUE; END IF;   -- no_bet a veces escalares
      v_expected := v_expected + 1;

      v_market := pk->>'mercado';
      v_side   := pk->>'pick';
      v_line   := pk->>'pick';
      v_nline  := public.tpc_norm_line(v_line);
      IF v_market IS NULL OR v_side IS NULL THEN
        v_excluded := v_excluded + 1; CONTINUE;                 -- sin identidad mínima
      END IF;

      v_praw := NULLIF(pk->>'prob','')::numeric;                -- P_RAW
      v_pdec := NULLIF(pk->>'probabilidad_real','')::numeric;   -- P_DECISION
      v_ev   := COALESCE(NULLIF(pk->>'ev_con_precio_real','')::numeric, NULLIF(pk->>'ev_estimado','')::numeric);
      v_odds := NULLIF(pk->>'momio_mercado','')::numeric;
      v_odds_at := NULLIF(pk->>'precio_sellado_at','')::timestamptz;

      -- GUARD temporal: decisión (generado_en) < evento
      IF v_event_start IS NOT NULL AND v_generado >= v_event_start THEN
        v_excluded := v_excluded + 1; CONTINUE;
      END IF;
      -- GUARD: ningún timestamp de precio en el futuro respecto a la decisión
      IF v_odds_at IS NOT NULL AND v_odds_at > v_generado THEN
        v_odds := NULL; v_odds_at := NULL;                       -- se descarta como safe
      END IF;

      -- PROVENANCE_COMPLETE (§4): NO se recalcula ni infiere
      v_prov_complete := (v_engine IS NOT NULL AND v_ver IS NOT NULL
                          AND v_praw IS NOT NULL AND v_pdec IS NOT NULL);

      -- gate económico canónico SECUNDARIO por join event+market+side
      SELECT c.es_pick, c.es_pick_reason, c.ev_pct, c.calibracion_confiable
        INTO v_es, v_reason, v_ev_canon, v_calib
        FROM _canon c WHERE c.mercado=v_market AND c.pick_nombre=v_side LIMIT 1;
      IF NOT FOUND THEN v_align := 'MISSING'; v_es:=NULL; v_reason:=NULL; v_ev_canon:=NULL; v_calib:=NULL;
      ELSE
        v_align := CASE WHEN v_ev_canon IS NOT DISTINCT FROM v_ev THEN 'MATCHED' ELSE 'DRIFTED' END;
      END IF;

      -- HASH_V3: sha256 sobre jsonb canónico explícito del contenido del pick
      v_snap_hash := public.tpc_sha256(
        jsonb_build_object('market',v_market,'side',v_side,'line',v_nline,
          'p_raw',v_praw,'p_decision',v_pdec,'ev',v_ev,'odds',v_odds,'model_version',v_ver)::text);
      digest_acc := digest_acc || v_snap_hash || ';';

      v_feat := v_ctx;   -- solo context demostrable a T-decisión
      v_mask := jsonb_build_object(
        'p_raw', v_praw IS NOT NULL, 'p_decision', v_pdec IS NOT NULL,
        'model_version', v_ver IS NOT NULL, 'odds', v_odds IS NOT NULL,
        'prob_source', (pk->>'prob_source') IS NOT NULL,
        'canonical_gate', v_align='MATCHED' OR v_align='DRIFTED');

      INSERT INTO public.top_pick_capture(
        decision_emission_id, captured_at, decision_timestamp, source_analysis_id, source_analysis_kind,
        producer_version, espn_event_id, event_start_timestamp, deporte, liga, home_team, away_team,
        market, side, line, normalized_line, candidate_kind,
        sportsbook, odds_decimal, odds_captured_at, odds_source, odds_verificadas,
        model_name, model_version, model_mode, prob_source,
        p_raw, p_decision, ev_decision, momio_justo, clasificacion, provenance_complete,
        canonical_read_at, economic_eligible, eligibility_reason_code, ev_canonical,
        canonical_alignment_status, calibration_status,
        features_input_json, feature_presence_mask, source_snapshot_timestamps,
        prediction_snapshot_hash, source_capture_point)
      VALUES (
        v_emission, now(), v_generado, p_analysis_id, kind,
        v_ver, v_event, v_event_start, v_deporte, v_liga, v_home, v_away,
        v_market, v_side, v_line, v_nline, kind,
        pk->>'casa', v_odds, v_odds_at, pk->>'odds_source', NULLIF(pk->>'odds_verificadas','')::boolean,
        v_engine, v_ver, v_mode, pk->>'prob_source',
        v_praw, v_pdec, v_ev, NULLIF(pk->>'momio_justo','')::numeric, pk->>'clasificacion', v_prov_complete,
        v_canon_read, v_es, v_reason, v_ev_canon,
        v_align, v_calib,
        v_feat, v_mask,
        jsonb_strip_nulls(jsonb_build_object('analisis',to_jsonb(v_generado),
          'precio_sellado',to_jsonb(v_odds_at),'canonical',to_jsonb(v_canon_read))),
        v_snap_hash, p_source)
      ON CONFLICT (decision_emission_id, market, side, normalized_line) DO NOTHING;

      IF FOUND THEN
        v_captured := v_captured + 1;
        IF v_prov_complete THEN v_prov := v_prov + 1; END IF;
      END IF;
    END LOOP;
  END LOOP;

  -- digest de corrida: hash sobre hashes ORDENADOS => orden de filas irrelevante
  v_digest := public.tpc_sha256(
    (SELECT string_agg(h,';' ORDER BY h) FROM unnest(string_to_array(rtrim(digest_acc,';'),';')) h));
  -- El UPDATE del digest es la ÚNICA mutación legítima del snapshot: se habilita el
  -- guard admin SOLO en esta transacción de captura (SET LOCAL, se revierte al commit).
  SET LOCAL app.allow_admin_mutation = 'on';
  UPDATE public.top_pick_capture SET event_prediction_digest = v_digest
    WHERE decision_emission_id = v_emission;
  SET LOCAL app.allow_admin_mutation = 'off';

  INSERT INTO public.top_pick_capture_audit(decision_emission_id,espn_event_id,source_analysis_id,
    source_analysis_kind,decision_timestamp,producer_version,expected_candidate_count,
    captured_candidate_count,excluded_count,complete_provenance_count,status)
  VALUES (v_emission,v_event,p_analysis_id,p_analysis_kind,v_generado,v_ver,
    v_expected,v_captured,v_excluded,v_prov,
    CASE WHEN v_excluded=0 AND v_captured=v_expected THEN 'COMPLETE' ELSE 'PARTIAL' END);
  RETURN 'OK';
END;
$fn$;

-- ---------- 8) TRIGGER en analisis_partidos (doble BEGIN/EXCEPTION: aislamiento del audit §8) ----------
CREATE OR REPLACE FUNCTION public.trg_capture_top_pick() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $t$
DECLARE v_kind text;
BEGIN
  v_kind := CASE WHEN TG_OP='INSERT' THEN 'emission'
                 WHEN NEW.reanalizado_at IS DISTINCT FROM OLD.reanalizado_at THEN 'recompute'
                 ELSE 'non_prediction' END;
  BEGIN
    PERFORM public.capture_top_pick_universe(NEW.id, 'trigger:analisis_partidos', v_kind);
  EXCEPTION WHEN OTHERS THEN
    -- la captura falló: intentar auditar el fallo en su PROPIO bloque aislado
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
END;
$t$;

CREATE TRIGGER trg_top_pick_capture
  AFTER INSERT OR UPDATE ON public.analisis_partidos
  FOR EACH ROW EXECUTE FUNCTION public.trg_capture_top_pick();

-- ---------- 9) APPEND_ONLY_ENFORCEMENT (real; §7) ----------
-- UPDATE/DELETE sobre snapshot y display => REJECT salvo GUC admin explícito.
CREATE OR REPLACE FUNCTION public.tpc_block_mutation() RETURNS trigger
LANGUAGE plpgsql AS $b$
BEGIN
  IF current_setting('app.allow_admin_mutation', true) = 'on' THEN
    RETURN CASE WHEN TG_OP='DELETE' THEN OLD ELSE NEW END;
  END IF;
  RAISE EXCEPTION 'APPEND_ONLY: % en % rechazado (snapshot inmutable)', TG_OP, TG_TABLE_NAME;
END;
$b$;

CREATE TRIGGER tpc_append_only_capture
  BEFORE UPDATE OR DELETE ON public.top_pick_capture
  FOR EACH ROW EXECUTE FUNCTION public.tpc_block_mutation();
CREATE TRIGGER tpc_append_only_display
  BEFORE UPDATE OR DELETE ON public.top_pick_display
  FOR EACH ROW EXECUTE FUNCTION public.tpc_block_mutation();
-- NOTA: la función de captura escribe event_prediction_digest con un UPDATE — la ÚNICA
-- mutación legítima del snapshot. Por eso corre SECURITY DEFINER y fija SET LOCAL
-- app.allow_admin_mutation='on' solo alrededor de ESE UPDATE (ver bloque 7), revirtiéndolo
-- de inmediato; cualquier otro UPDATE/DELETE externo sigue rechazado.
-- top_pick_settlement y top_pick_capture_audit permanecen mutables (INSERT/UPDATE permitido).

-- ---------- 10) HEALTH VIEW (detección de huecos §8) ----------
CREATE OR REPLACE VIEW public.v_top_pick_capture_health AS
SELECT date_trunc('day', decision_timestamp) AS day,
  count(*) FILTER (WHERE status='COMPLETE')                       AS complete_emissions,
  count(*) FILTER (WHERE status='PARTIAL')                        AS partial_emissions,
  count(*) FILTER (WHERE status='FAILED')                         AS failed_emissions,
  count(*) FILTER (WHERE status='NO_CHANGE')                      AS nochange_emissions,
  round(100.0 * count(*) FILTER (WHERE status='FAILED')
        / NULLIF(count(*) FILTER (WHERE status IN ('COMPLETE','PARTIAL','FAILED')),0), 3)
                                                                  AS capture_failure_rate_pct,
  sum(complete_provenance_count)                                 AS provenance_complete_rows,
  sum(captured_candidate_count)                                  AS captured_rows
FROM public.top_pick_capture_audit
GROUP BY 1 ORDER BY 1 DESC;

-- Chequeo de EMISIONES PERDIDAS: análisis con generado_en sin audit correspondiente.
CREATE OR REPLACE VIEW public.v_top_pick_missing_emissions AS
SELECT a.id AS analysis_id,
       COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id) AS espn_event_id,
       (a.analisis_json->>'generado_en')::timestamptz AS generado_en,
       a.analisis_json->>'analysis_version' AS analysis_version
FROM public.analisis_partidos a
WHERE a.analisis_json ? 'generado_en'
  AND NOT EXISTS (
    SELECT 1 FROM public.top_pick_capture_audit au
    WHERE au.decision_emission_id = md5(
       COALESCE(NULLIF(a.espn_event_id_canonico,''),a.espn_event_id)||'|'||
       (a.analisis_json->>'generado_en')||'|'||(a.analisis_json->>'analysis_version')));

-- ---------- 11) DATASET CIENTÍFICO (solo provenance_complete; NO ranker, NO score) ----------
CREATE OR REPLACE VIEW public.v_top_pick_science_dataset AS
SELECT c.*, s.outcome, s.retorno, s.closing_odds, s.clv_pct
FROM public.top_pick_capture c
LEFT JOIN public.top_pick_settlement s
  ON s.espn_event_id=c.espn_event_id AND s.market=c.market AND s.side=c.side
 AND s.normalized_line=c.normalized_line
WHERE c.provenance_complete IS TRUE;

-- Deploy real: REVOKE UPDATE,DELETE ON public.top_pick_capture, public.top_pick_display FROM PUBLIC;
