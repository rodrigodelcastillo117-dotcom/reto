-- ============================================================================
-- ISS-013 — Envoltorios canónicos para Qué Apostar y Reto 13M (CUTOVER)
-- Estado: PREPARADO / NO APLICADO. Producción congelada.
-- Objetivo: que estas dos superficies consuman UNA verdad canónica de elegibilidad
--           (v_pick_canonico) + estado de análisis, SIN inferencia en el frontend.
-- Regla: NO tocar el sizing/estado de dinero de Reto 13M (bugs abiertos #208-#213).
--        Solo EXPONER las llaves canónicas para que el frontend gatee la
--        presentación (accionable vs informativo) igual que el resto de la app.
-- ============================================================================

-- ---------- QUÉ APOSTAR ----------
-- destacados_del_dia() devuelve destacados_cache. Este wrapper añade, por
-- canonical_event_id (espn_event_id), las llaves canónicas desde v_pick_canonico
-- y analisis_partidos. economically_eligible sale del backend, NUNCA se infiere.
CREATE OR REPLACE FUNCTION public.destacados_del_dia_canonico(
  p_horas integer DEFAULT 48, p_deporte text DEFAULT NULL, p_solo_valor boolean DEFAULT true)
RETURNS TABLE(
  espn_event_id text, canonical_event_id text, deporte text, mercado text, fecha timestamptz,
  ev_pct numeric, vs_mercado_pts numeric,
  analysis_status text, economically_eligible boolean, reason_code text,
  classification text, prob_source text, p_decision numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT d.espn_event_id,
         d.espn_event_id AS canonical_event_id,
         d.deporte, d.mercado, d.fecha, d.ev_pct, d.vs_mercado_pts,
         CASE WHEN ap.analisis_json ? 'probabilidades' THEN 'FULL' ELSE 'UNAVAILABLE' END AS analysis_status,
         COALESCE(pc.es_pick, false) AS economically_eligible,
         COALESCE(pc.es_pick_reason, 'MODEL_VERSION_PROVENANCE_MISSING') AS reason_code,
         COALESCE(pc.clasificacion, 'ANALYSIS') AS classification,
         pc.fuente AS prob_source,
         pc.probabilidad_pct AS p_decision
  FROM public.destacados_del_dia(p_horas, p_deporte, p_solo_valor) d
  LEFT JOIN LATERAL (
    SELECT es_pick, es_pick_reason, clasificacion, fuente, probabilidad_pct
    FROM public.v_pick_canonico v
    WHERE v.espn_event_id = d.espn_event_id
      AND COALESCE(v.mercado,'') = COALESCE(d.mercado,'')
    ORDER BY v.rank_en_partido NULLS LAST LIMIT 1
  ) pc ON true
  LEFT JOIN public.analisis_partidos ap ON ap.espn_event_id = d.espn_event_id;
$$;
-- ROLLBACK: DROP FUNCTION IF EXISTS public.destacados_del_dia_canonico(integer,text,boolean);

-- ---------- RETO 13M ----------
-- reto_13m_estado(p_apodo) devuelve jsonb con el estado del reto (incluye sizing:
-- NO se toca). Este wrapper AÑADE un bloque `canonical` con la elegibilidad canónica
-- por evento, para que la pantalla marque accionable/informativo sin inventar nada.
-- El sizing/estado monetario permanece EXACTAMENTE igual (bugs #208-#213 aparte).
CREATE OR REPLACE FUNCTION public.reto_13m_estado_canonico(p_apodo text)
RETURNS jsonb LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH base AS (SELECT public.reto_13m_estado(p_apodo) AS j)
  SELECT jsonb_set(
    base.j,
    '{canonical}',
    COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'canonical_event_id', ev,
        'economically_eligible', COALESCE(pc.es_pick,false),
        'reason_code', COALESCE(pc.es_pick_reason,'MODEL_VERSION_PROVENANCE_MISSING'),
        'classification', COALESCE(pc.clasificacion,'ANALYSIS'),
        'prob_source', pc.fuente,
        'p_decision', pc.probabilidad_pct))
      FROM (
        SELECT DISTINCT (e->>'espn_event_id') AS ev
        FROM jsonb_array_elements(COALESCE(base.j->'partidos', base.j->'picks', '[]'::jsonb)) e
        WHERE e ? 'espn_event_id'
      ) ids
      LEFT JOIN LATERAL (
        SELECT es_pick, es_pick_reason, clasificacion, fuente, probabilidad_pct
        FROM public.v_pick_canonico v WHERE v.espn_event_id = ids.ev
        ORDER BY v.rank_en_partido NULLS LAST LIMIT 1
      ) pc ON true
    ), '[]'::jsonb)
  ) FROM base;
$$;
-- ROLLBACK: DROP FUNCTION IF EXISTS public.reto_13m_estado_canonico(text);

-- NOTA DE GOBERNANZA: con es_pick=false en todo (procedencia de modelo faltante),
-- economically_eligible sale false en ambas superficies → 0 picks accionables,
-- congruente con "0 picks hoy" en el resto de la app. Ninguna superficie inventa
-- elegibilidad ni probabilidad propia. El frontend de la rama unified-truth-v1
-- debe cambiarse para consumir estos wrappers (Hoy.tsx / Reto13M.tsx) EN EL MISMO
-- cutover; requiere prueba de humo en navegador antes de desplegar.
