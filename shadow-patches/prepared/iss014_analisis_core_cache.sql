-- ISS-014 — Cache del core de análisis (fix de latencia P0 del modal).
-- APLICADO en prod como ADITIVO (no toca analisis_completo; producción del
-- frontend sigue congelada). El frontend de la rama llama analisis_completo_cached.
-- Medido: analisis_completo_core ~4.5s (hasta ~60s) por click → cache hit ~3ms.

CREATE TABLE IF NOT EXISTS public.analisis_core_cache (
  espn_event_id text PRIMARY KEY,
  payload       jsonb NOT NULL,
  generado_at   timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.analisis_completo_cached(p_event text, p_ttl_min integer DEFAULT 20)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  v_res jsonb; v_canon text; v_hit jsonb; v_gen timestamptz;
BEGIN
  v_res   := public.resolver_evento_canonico(p_event);
  v_canon := v_res->>'espn_event_id';
  IF v_canon IS NULL THEN
    RETURN jsonb_build_object('error','partido no encontrado','reason_code',v_res->>'reason_code','id_recibido',p_event);
  END IF;
  SELECT payload, generado_at INTO v_hit, v_gen
  FROM public.analisis_core_cache WHERE espn_event_id = v_canon;
  IF v_hit IS NOT NULL AND v_gen > now() - make_interval(mins => p_ttl_min) THEN
    RETURN v_hit || jsonb_build_object('_cache', jsonb_build_object('hit', true, 'generado_at', v_gen));
  END IF;
  v_hit := public.analisis_completo_core(v_canon);
  IF v_hit ? 'error' THEN RETURN v_hit; END IF;
  INSERT INTO public.analisis_core_cache(espn_event_id, payload, generado_at)
  VALUES (v_canon, v_hit, now())
  ON CONFLICT (espn_event_id) DO UPDATE SET payload = excluded.payload, generado_at = now();
  RETURN v_hit || jsonb_build_object('_cache', jsonb_build_object('hit', false, 'generado_at', now()));
END;
$$;

-- SEGUIMIENTO (no bloqueante): un cron de "cache warming" para partidos próximos
-- haría que también el PRIMER click sea rápido. Hoy el primer click paga el
-- cómputo una vez (acotado por el timeout de 12s del modal) y los demás son ~3ms.
-- ROLLBACK: DROP FUNCTION public.analisis_completo_cached(text,integer); DROP TABLE public.analisis_core_cache;
