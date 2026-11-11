-- ISS-021 — RESOLVER CANÓNICO P_RETO PARA MI IDEA / ORÁCULO / PARLAY.
-- *** STAGED — NO APLICADO A PROD ***
-- Requiere ISS-018 aplicado primero.
--
-- Objetivo: cualquier superficie que reciba texto libre de mercado/selección resuelve
-- SIEMPRE contra v_prediccion_reto_futbol. Nunca cae a probabilidad de mercado, a
-- v_pick_canonico, a destacados_cache ni a una estimación local/LLM.
--
-- Contrato fail-closed:
--   OK                  -> prob_pct es P_RETO exacta de la matriz.
--   NO_MODEL            -> evento no está en matriz.
--   NO_PROBABILITY      -> evento existe pero muestra/temporalidad no permite P.
--   UNSUPPORTED_MARKET  -> mercado fuera de 1X2/BTTS/O-U canónico.
--   SELECTION_UNRESOLVED-> no se pudo mapear el lado.
--   LINE_MISMATCH       -> O/U solicitado no coincide con línea real de proveedor.

CREATE OR REPLACE FUNCTION public.reto_norm_txt(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT trim(regexp_replace(
    lower(public.sin_acentos(coalesce(p_text,''))),
    '\s+', ' ', 'g'
  ));
$$;

CREATE OR REPLACE FUNCTION public.reto_strip_pick_badges(p_text text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $$
  SELECT trim(regexp_replace(coalesce(p_text,''), '^\s*\[[^]]+\]\s*', '', 'g'));
$$;

CREATE OR REPLACE FUNCTION public.resolver_p_reto_futbol(
  p_event text,
  p_mercado text,
  p_seleccion text DEFAULT NULL,
  p_linea numeric DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_res_event jsonb;
  v_event text;
  r record;
  v_m text;
  v_s text;
  v_home text;
  v_away text;
  v_linea_text numeric;
  v_linea_req numeric;
  v_prob numeric;
  v_side text;
  v_family text;
BEGIN
  v_res_event := public.resolver_evento_canonico(p_event);
  v_event := coalesce(v_res_event->>'espn_event_id', p_event);

  SELECT * INTO r
  FROM public.v_prediccion_reto_futbol
  WHERE canonical_event_id = v_event
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'status','NO_MODEL','canonical_event_id',v_event,
      'prob_pct',NULL,'reason','evento sin fila en la matriz canónica de fútbol');
  END IF;

  IF r.model_status IS DISTINCT FROM 'UNVALIDATED'
     OR (r.p_local_gana IS NULL AND r.p_empate IS NULL AND r.p_visita_gana IS NULL) THEN
    RETURN jsonb_build_object(
      'status','NO_PROBABILITY','canonical_event_id',v_event,
      'model_status',r.model_status,'prob_pct',NULL,
      'reason',coalesce(r.unavailable_reason,'P_RETO no disponible para este evento'));
  END IF;

  v_m := public.reto_norm_txt(p_mercado);
  v_s := public.reto_norm_txt(public.reto_strip_pick_badges(coalesce(p_seleccion,p_mercado)));
  v_home := public.reto_norm_txt(r.home_nombre);
  v_away := public.reto_norm_txt(r.away_nombre);

  -- Extrae línea escrita en selección/mercado (Over 2.5, Under 3.5...).
  BEGIN
    v_linea_text := nullif(substring(v_s from '([0-9]+(?:\.[0-9]+)?)'),'')::numeric;
  EXCEPTION WHEN others THEN
    v_linea_text := NULL;
  END;
  v_linea_req := coalesce(p_linea, v_linea_text);

  -- 1X2 / Moneyline
  IF v_m ~ '(moneyline|1x2|ganador|resultado|\bml\b|gana)' THEN
    v_family := '1X2';
    IF v_s ~ '(empate|draw|^x$)' THEN
      v_prob := r.p_empate; v_side := 'Empate';
    ELSIF (v_home <> '' AND position(v_home in v_s) > 0)
       OR v_s ~ '(gana local|local|casa|home)' THEN
      v_prob := r.p_local_gana; v_side := r.home_nombre;
    ELSIF (v_away <> '' AND position(v_away in v_s) > 0)
       OR v_s ~ '(gana visitante|visitante|fuera|away)' THEN
      v_prob := r.p_visita_gana; v_side := r.away_nombre;
    ELSE
      -- Caso común: "Austin FC ML" / "ML Galatasaray".
      IF v_home <> '' AND position(v_home in public.reto_norm_txt(regexp_replace(v_s,'\bml\b','','g'))) > 0 THEN
        v_prob := r.p_local_gana; v_side := r.home_nombre;
      ELSIF v_away <> '' AND position(v_away in public.reto_norm_txt(regexp_replace(v_s,'\bml\b','','g'))) > 0 THEN
        v_prob := r.p_visita_gana; v_side := r.away_nombre;
      ELSE
        RETURN jsonb_build_object(
          'status','SELECTION_UNRESOLVED','canonical_event_id',v_event,
          'market_family','1X2','prob_pct',NULL,
          'reason','no se pudo resolver local/empate/visitante desde la selección');
      END IF;
    END IF;

  -- BTTS
  ELSIF v_m ~ '(btts|ambos anotan|ambos marcan|both teams)' THEN
    v_family := 'BTTS';
    IF r.p_btts_yes IS NULL OR r.p_btts_no IS NULL THEN
      RETURN jsonb_build_object(
        'status','NO_PROBABILITY','canonical_event_id',v_event,
        'market_family','BTTS','prob_pct',NULL,
        'reason','BTTS no disponible en la conjunta canónica');
    END IF;
    IF v_s ~ '(^| )no( |$)|no ambos|no marcan' THEN
      v_prob := r.p_btts_no; v_side := 'No ambos';
    ELSE
      v_prob := r.p_btts_yes; v_side := 'Ambos anotan';
    END IF;

  -- Over / Under. La línea debe coincidir EXACTAMENTE con la línea real del proveedor.
  ELSIF v_m ~ '(over|under|mas de|menos de|total|goles)' OR v_s ~ '(over|under|mas de|menos de)' THEN
    v_family := 'OU';
    IF r.linea_ou IS NULL OR r.p_over IS NULL OR r.p_under IS NULL THEN
      RETURN jsonb_build_object(
        'status','NO_PROBABILITY','canonical_event_id',v_event,
        'market_family','OU','prob_pct',NULL,
        'reason','sin O/U canónico en línea real de proveedor');
    END IF;
    IF v_linea_req IS NULL THEN
      -- Si la selección sólo dice Over/Under sin cifra, usa la línea canónica explícitamente.
      v_linea_req := r.linea_ou;
    END IF;
    IF abs(v_linea_req - r.linea_ou) > 0.0001 THEN
      RETURN jsonb_build_object(
        'status','LINE_MISMATCH','canonical_event_id',v_event,
        'market_family','OU','requested_line',v_linea_req,
        'canonical_line',r.linea_ou,'prob_pct',NULL,
        'reason','la línea solicitada no coincide con la línea real canónica; no se re-tasa una alt-line');
    END IF;
    IF v_s ~ '(under|menos)' THEN
      v_prob := r.p_under; v_side := 'Under '||r.linea_ou;
    ELSIF v_s ~ '(over|mas)' THEN
      v_prob := r.p_over; v_side := 'Over '||r.linea_ou;
    ELSE
      RETURN jsonb_build_object(
        'status','SELECTION_UNRESOLVED','canonical_event_id',v_event,
        'market_family','OU','canonical_line',r.linea_ou,'prob_pct',NULL,
        'reason','no se pudo resolver Over o Under');
    END IF;
  ELSE
    RETURN jsonb_build_object(
      'status','UNSUPPORTED_MARKET','canonical_event_id',v_event,
      'prob_pct',NULL,'reason','mercado fuera del contrato canónico actual 1X2/BTTS/O-U');
  END IF;

  IF v_prob IS NULL THEN
    RETURN jsonb_build_object(
      'status','NO_PROBABILITY','canonical_event_id',v_event,
      'market_family',v_family,'selection',v_side,'prob_pct',NULL,
      'reason','la matriz no publicó P_RETO para esta selección');
  END IF;

  RETURN jsonb_build_object(
    'status','OK',
    'canonical_event_id',v_event,
    'market_family',v_family,
    'selection',v_side,
    'line',CASE WHEN v_family='OU' THEN r.linea_ou ELSE NULL END,
    'prob_pct',v_prob,
    'prob_source',r.prob_source,
    'model_status',r.model_status,
    'model_sample',r.model_sample,
    'model_generated_at',r.model_generated_at,
    'data_asof',r.data_asof,
    'score_version',r.score_version
  );
END;
$$;

-- Enriquecedor de Mi Idea. Mantiene intacto el veredicto económico de __base,
-- pero agrega P_RETO como carril predictivo separado. No altera EV ni autorización.
CREATE OR REPLACE FUNCTION public.veredicto_lote_reto(p_apodo text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_base jsonb;
  v_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_deporte text;
  v_p jsonb;
BEGIN
  v_base := public.veredicto_lote__base(public.apodo_scope(p_apodo));

  FOR v_item IN SELECT value FROM jsonb_array_elements(coalesce(v_base->'items','[]'::jsonb)) LOOP
    SELECT a.deporte INTO v_deporte
    FROM public.agenda_espn a
    WHERE a.espn_event_id = v_item->>'espn_event_id';

    IF v_deporte = 'soccer' THEN
      v_p := public.resolver_p_reto_futbol(
        v_item->>'espn_event_id',
        v_item->>'mercado',
        coalesce(v_item->>'boleto', v_item->>'mercado'),
        NULL
      );
      v_item := v_item || jsonb_build_object(
        'prediction_lane', jsonb_build_object(
          'label','P_RETO',
          'status',v_p->>'status',
          'market_family',v_p->>'market_family',
          'selection',v_p->>'selection',
          'line',v_p->'line',
          'prob_pct',v_p->'prob_pct',
          'prob_source',v_p->>'prob_source',
          'model_status',v_p->>'model_status',
          'reason',v_p->>'reason'
        )
      );
    END IF;

    v_items := v_items || jsonb_build_array(v_item);
  END LOOP;

  RETURN jsonb_set(v_base,'{items}',v_items,true);
END;
$$;

-- CUTOVER: conservar mismo RPC público; sólo cambia la implementación interna.
CREATE OR REPLACE FUNCTION public.veredicto_lote(p_apodo text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.veredicto_lote_reto(public.apodo_scope(p_apodo));
$$;

-- VALIDACIÓN OBLIGATORIA:
-- 1) para todo item soccer con prediction_lane.status='OK', prob_pct debe ser idéntico
--    a resolver_p_reto_futbol(event,mercado,seleccion,linea)->prob_pct;
-- 2) nunca copiar mercado_sin_vig_pct / probabilidad_pct legacy a prediction_lane;
-- 3) alt-lines O/U distintas de provider line => LINE_MISMATCH, no P;
-- 4) unsupported markets => UNSUPPORTED_MARKET, no P inventada;
-- 5) non-soccer conserva comportamiento previo hasta su propia matriz.
