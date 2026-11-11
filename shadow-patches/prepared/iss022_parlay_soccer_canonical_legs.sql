-- ISS-022 — PARLAY: PATAS DE FÚTBOL USAN P_RETO CANÓNICA, SIN EXCEPCIONES.
-- *** STAGED — NO APLICADO A PROD ***
-- Requiere ISS-018 + ISS-021.
--
-- El ensamblador puede filtrar por cuota, nicho, correlación, bankroll y EV; NO puede
-- crear/recalibrar/reemplazar la probabilidad de una pata de fútbol. Para soccer:
-- prob = resolver_p_reto_futbol(...).prob_pct / 100.
-- Si el mercado/selección/línea no cabe en el contrato canónico, esa pata queda fuera.
-- En especial, alt-lines O/U distintas de la línea real del proveedor NO se re-tasan.

CREATE OR REPLACE FUNCTION public.construir_parlay_v2_reto__base(
  p_apodo text,
  p_modo text DEFAULT 'balanceado',
  p_ventana_horas integer DEFAULT 36
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_target_min_momio numeric; v_target_max_momio numeric;
  v_min_legs int; v_max_legs int;
  v_exigir_nicho_a boolean := false; v_min_prob_combinada numeric;
  v_bankroll_total numeric; v_bankroll_disponible numeric;
  v_legs_array jsonb[]; v_leg jsonb;
  v_momio_acum numeric := 1.0; v_prob_acum numeric := 1.0;
  v_ev_parlay numeric; v_kelly_fraction numeric; v_kelly_monto numeric;
  v_bet_cap numeric; v_bet_floor numeric := 20.0;
  v_ligas_count jsonb := '{}'::jsonb; v_liga_actual text; v_liga_n int;
  v_count int := 0; v_aviso text := null; v_candidatos_total int;
BEGIN
  CASE lower(p_modo)
    WHEN 'conservador' THEN
      v_target_min_momio := 1.5; v_target_max_momio := 2.8;
      v_min_legs := 1; v_max_legs := 2; v_exigir_nicho_a := true; v_min_prob_combinada := 0.35;
    WHEN 'balanceado' THEN
      v_target_min_momio := 4.0; v_target_max_momio := 10.0;
      v_min_legs := 3; v_max_legs := 4; v_min_prob_combinada := 0.08;
    WHEN 'audaz' THEN
      v_target_min_momio := 15.0; v_target_max_momio := 60.0;
      v_min_legs := 5; v_max_legs := 7; v_min_prob_combinada := 0.015;
    ELSE RAISE EXCEPTION 'Modo invalido: %', p_modo;
  END CASE;

  v_bankroll_disponible := public.get_bankroll_disponible(p_apodo);
  v_bankroll_total := public.get_bankroll_patrimonio(p_apodo);
  v_bet_cap := v_bankroll_total * 0.05;

  FOR v_leg IN
    WITH raw AS (
      SELECT
        vp.*,
        a.deporte,
        CASE WHEN a.deporte='soccer'
          THEN public.resolver_p_reto_futbol(vp.espn_event_id, vp.mercado, vp.pick_desc, NULL)
          ELSE NULL::jsonb
        END AS p_reto_res
      FROM public.v_picks_para_parlay vp
      LEFT JOIN public.agenda_espn a ON a.espn_event_id = vp.espn_event_id
      WHERE vp.match_date >= now()
        AND vp.match_date < now() + (p_ventana_horas || ' hours')::interval
        AND vp.momio::numeric > 1.01
    ),
    candidatos AS (
      SELECT
        r.pick_id, r.espn_event_id, r.partido, r.liga, r.mercado, r.pick_desc,
        r.momio::numeric AS momio,
        CASE
          WHEN r.deporte='soccer' THEN (r.p_reto_res->>'prob_pct')::numeric / 100.0
          ELSE public.calibrar_probabilidad(r.probabilidad_pct::numeric / 100.0)
        END AS prob,
        CASE
          WHEN r.deporte='soccer' THEN (r.p_reto_res->>'prob_pct')::numeric
          ELSE round(public.calibrar_probabilidad(r.probabilidad_pct::numeric / 100.0) * 100,1)
        END AS prob_pct,
        CASE
          WHEN r.deporte='soccer' THEN 'P_RETO'
          ELSE 'LEGACY_NON_SOCCER_PENDING_MATRIX'
        END AS prob_label,
        CASE
          WHEN r.deporte='soccer' THEN r.p_reto_res->>'prob_source'
          ELSE 'legacy_calibrar_probabilidad'
        END AS prob_source,
        CASE
          WHEN r.deporte='soccer' THEN r.p_reto_res->>'status'
          ELSE 'PENDING_SPORT_MIGRATION'
        END AS prob_status,
        r.p_reto_res->>'selection' AS canonical_selection,
        (r.p_reto_res->>'line')::numeric AS canonical_line,
        r.historial_wr, r.historial_muestra, r.historial_roi,
        r.tier, r.tier_label, r.razon, r.match_date,
        to_char(r.match_date AT TIME ZONE 'America/Mexico_City', 'DD Mon HH24:MI') AS hora_cdmx,
        public.clasificar_rango_momio(r.momio::numeric) AS rango_momio_clas,
        (SELECT roi_pct FROM public.nichos_rentables_v2 nr
          WHERE nr.fuente='ai_pro' AND nr.veredicto='rentable'
            AND nr.liga=r.liga AND nr.mercado=coalesce(r.mercado,'NULO')
            AND nr.rango_momio=public.clasificar_rango_momio(r.momio::numeric) LIMIT 1) AS nicho_roi,
        (SELECT roi_pct FROM public.v_ligas_rentables_v2 lr
          WHERE lr.fuente='ai_pro' AND lr.veredicto='rentable' AND lr.liga=r.liga LIMIT 1) AS liga_roi,
        (SELECT roi_pct FROM public.nichos_rentables_v2 nr
          WHERE nr.fuente='ai_pro' AND nr.veredicto='sangrante'
            AND nr.liga=r.liga AND nr.mercado=coalesce(r.mercado,'NULO')
            AND nr.rango_momio=public.clasificar_rango_momio(r.momio::numeric) LIMIT 1) AS nicho_sangrante_roi
      FROM raw r
      WHERE
        -- SOCCER: sólo entra si se resolvió P_RETO exacta. Cero fallback legacy.
        (r.deporte IS DISTINCT FROM 'soccer' OR r.p_reto_res->>'status'='OK')
    ),
    con_ev AS (
      SELECT c.*,
             round((c.prob * c.momio - 1) * 100,2) AS ev_pct
      FROM candidatos c
      WHERE c.prob IS NOT NULL AND c.prob > 0
        AND (c.prob * c.momio - 1) > 0
    )
    SELECT to_jsonb(t)
    FROM (
      SELECT *,
        CASE WHEN nicho_roi IS NOT NULL THEN 'A' WHEN liga_roi IS NOT NULL THEN 'B' ELSE 'C' END AS capa
      FROM con_ev
      WHERE nicho_sangrante_roi IS NULL
        AND (nicho_roi IS NOT NULL OR (NOT v_exigir_nicho_a AND liga_roi IS NOT NULL))
      ORDER BY CASE WHEN nicho_roi IS NOT NULL THEN 1 ELSE 2 END,
               coalesce(nicho_roi,liga_roi) DESC NULLS LAST,
               ev_pct DESC
    ) t
  LOOP
    EXIT WHEN v_count >= v_max_legs;
    v_liga_actual := v_leg->>'liga';
    v_liga_n := coalesce((v_ligas_count->>v_liga_actual)::int,0);
    IF v_liga_n >= 2 THEN CONTINUE; END IF;
    IF v_count >= v_min_legs AND v_momio_acum * (v_leg->>'momio')::numeric > v_target_max_momio THEN CONTINUE; END IF;

    v_legs_array := array_append(v_legs_array,v_leg);
    v_momio_acum := v_momio_acum * (v_leg->>'momio')::numeric;
    v_prob_acum := v_prob_acum * (v_leg->>'prob')::numeric;
    v_count := v_count + 1;
    v_ligas_count := v_ligas_count || jsonb_build_object(v_liga_actual,v_liga_n+1);
    IF v_momio_acum >= v_target_min_momio AND v_count >= v_min_legs THEN EXIT; END IF;
  END LOOP;

  IF v_count < v_min_legs THEN
    WITH raw AS (
      SELECT vp.*, a.deporte,
             CASE WHEN a.deporte='soccer'
               THEN public.resolver_p_reto_futbol(vp.espn_event_id,vp.mercado,vp.pick_desc,NULL)
             END AS p_reto_res
      FROM public.v_picks_para_parlay vp
      LEFT JOIN public.agenda_espn a ON a.espn_event_id=vp.espn_event_id
      WHERE vp.match_date >= now()
        AND vp.match_date < now() + (p_ventana_horas || ' hours')::interval
    )
    SELECT count(*) INTO v_candidatos_total
    FROM raw r
    WHERE (r.deporte IS DISTINCT FROM 'soccer' OR r.p_reto_res->>'status'='OK');

    v_aviso := format(
      'No hay material canónico suficiente para modo %s. Encontramos %s legs validados (necesitas %s). Candidatos con probabilidad resoluble: %s. Reto prefiere no construir el parlay antes que sustituir P_RETO por otra probabilidad.',
      p_modo,v_count,v_min_legs,v_candidatos_total);

    RETURN jsonb_build_object(
      'modo',p_modo,'apto_para_apostar',false,'aviso',v_aviso,
      'legs_encontrados',v_count,'legs_minimos_requeridos',v_min_legs,
      'legs',coalesce(to_jsonb(v_legs_array),'[]'::jsonb),
      'bankroll_disponible',v_bankroll_disponible,'bankroll_total',v_bankroll_total,
      'soccer_probability_contract','P_RETO_ONLY',
      'recomendacion','NO APUESTES HOY (sin patas canónicas suficientes)');
  END IF;

  v_ev_parlay := (v_prob_acum * v_momio_acum - 1) * 100;
  IF v_momio_acum > 1.01 AND v_ev_parlay > 0 THEN
    v_kelly_fraction := 0.25 * ((v_momio_acum * v_prob_acum - 1) / (v_momio_acum - 1));
    v_kelly_fraction := greatest(0,v_kelly_fraction);
    v_kelly_monto := round(v_bankroll_total * v_kelly_fraction,2);
    v_kelly_monto := least(v_kelly_monto,v_bet_cap);
  ELSE
    v_kelly_fraction := 0; v_kelly_monto := 0;
  END IF;

  IF v_prob_acum < v_min_prob_combinada THEN
    v_aviso := format('Probabilidad combinada baja: %s%%. Parlay arriesgado.',round(v_prob_acum*100,2));
  END IF;
  IF v_kelly_monto > 0 AND v_kelly_monto < v_bet_floor THEN
    v_aviso := coalesce(v_aviso||E'\n','') || format('Kelly sugiere $%s. Tu bankroll está bajo para este parlay.',round(v_kelly_monto,2));
  END IF;

  RETURN jsonb_build_object(
    'modo',p_modo,'apto_para_apostar',true,'num_legs',v_count,
    'momio_total',round(v_momio_acum,2),
    'prob_parlay_pct',round(v_prob_acum*100,2),
    'ev_parlay_pct',round(v_ev_parlay,2),
    'kelly_fraction_pct',round(v_kelly_fraction*100,2),
    'monto_kelly_sugerido',v_kelly_monto,
    'pago_potencial',round(v_kelly_monto*v_momio_acum,2),
    'ganancia_potencial',round(v_kelly_monto*(v_momio_acum-1),2),
    'bankroll_disponible',v_bankroll_disponible,'bankroll_total',v_bankroll_total,
    'legs',to_jsonb(v_legs_array),'aviso',v_aviso,
    'soccer_probability_contract','P_RETO_ONLY',
    'recomendacion','APOSTAR sólo si la capa económica también autoriza',
    'metodologia','Patas de fútbol: P_RETO exacta de matriz canónica. Ensamblador sólo filtra; no recalibra ni reemplaza la probabilidad.');
END;
$$;

-- CUTOVER: mismo RPC público; cambia únicamente su base interna.
CREATE OR REPLACE FUNCTION public.construir_parlay_v2(
  p_apodo text,
  p_modo text,
  p_ventana_horas integer
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT public.construir_parlay_v2_reto__base(public.apodo_scope(p_apodo),p_modo,p_ventana_horas);
$$;

-- VALIDACIÓN OBLIGATORIA:
-- 1) cada leg soccer debe traer prob_label='P_RETO' y prob_status='OK';
-- 2) leg.prob_pct = resolver_p_reto_futbol(...).prob_pct EXACTO;
-- 3) ninguna pata soccer puede usar calibrar_probabilidad(vp.probabilidad_pct);
-- 4) alt-line distinta de provider line no aparece;
-- 5) prob_parlay_pct = producto de las P_RETO de patas (dependencia/correlación se debe
--    advertir por separado; nunca se presenta ese producto como certeza conjunta calibrada).
