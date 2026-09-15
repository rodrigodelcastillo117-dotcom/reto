-- ISS-016 — MATRIZ CANÓNICA DE PREDICCIÓN (MLB).  *** STAGED — NO APLICADO A PROD ***
-- Gate #18: no se aplican cambios de esquema a producción hasta el cutover coordinado.
-- Este archivo se aplica JUNTO con el deploy del frontend en el cutover.
--
-- OBJETIVO: exponer la MISMA probabilidad del modelo MLB (predecir_mlb) como P_RETO,
-- con MODEL_STATUS=UNVALIDATED (autoridad económica NONE), SIN inventar procedencia y
-- SIN recomputar la verdad histórica en cada lectura. Espeja la arquitectura de fútbol:
-- se PERSISTE un snapshot inmutable y la vista canónica LEE el artefacto persistido.
--
-- Motor existente (real, backtesteado): predecir_mlb() → Poisson de carreras + overlay
-- Negative-Binomial (r=5) para totales; ML amortiguado 70% hacia 52.8; sin draw.
-- Mercados: Moneyline (local/visita) + Over/Under. NO run line (no lo emite el motor).

-- 1) SNAPSHOT INMUTABLE (append-only). Una fila por (evento, momento de predicción).
--    NO se sobre-escribe (a diferencia de mlb_modelo_snapshot, que hace UPSERT y pierde
--    historia). Así la calibración/Brier futura mide la predicción REAL de pre-partido.
CREATE TABLE IF NOT EXISTS public.mlb_prediccion_snapshot (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  espn_event_id text NOT NULL,
  snapshot_at   timestamptz NOT NULL DEFAULT now(),
  scheduled_at  timestamptz,
  home_nombre   text,
  away_nombre   text,
  liga_nombre   text,
  p_local_gana  numeric,   -- gana_local_pct (amortiguado, del motor)
  p_visita_gana numeric,   -- gana_visita_pct
  lambda_home   numeric,
  lambda_away   numeric,
  total_esperado numeric,
  linea_ou      numeric,
  p_over        numeric,   -- over_pct_ajustado en la línea
  p_under       numeric,   -- under_pct_ajustado
  calidad       numeric,   -- completitud de mlb_stats_cache (data_readiness)
  payload       jsonb,     -- salida cruda de predecir_mlb (trazabilidad)
  CONSTRAINT mlb_pred_snap_uq UNIQUE (espn_event_id, snapshot_at)
);
CREATE INDEX IF NOT EXISTS ix_mlb_pred_snap_evento ON public.mlb_prediccion_snapshot (espn_event_id, snapshot_at DESC);

-- 2) ESCRITOR (append-only). Inserta un snapshot por juego próximo con datos listos.
--    Idempotente por minuto: si ya hay snapshot de este evento en el último p_dedup_min,
--    no vuelve a insertar (evita ráfagas). Ejecutar por cron cada ~30-60 min.
CREATE OR REPLACE FUNCTION public.snapshot_mlb_predicciones(p_dedup_min integer DEFAULT 45)
RETURNS integer
LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE v_n integer := 0;
BEGIN
  INSERT INTO public.mlb_prediccion_snapshot
    (espn_event_id, scheduled_at, home_nombre, away_nombre, liga_nombre,
     p_local_gana, p_visita_gana, lambda_home, lambda_away, total_esperado,
     linea_ou, p_over, p_under, calidad, payload)
  SELECT ae.espn_event_id,
         ae.fecha,
         ae.home_nombre, ae.away_nombre, ae.liga_nombre,
         (j->>'gana_local_pct')::numeric,
         (j->>'gana_visita_pct')::numeric,
         (j->>'lam_home')::numeric,
         (j->>'lam_away')::numeric,
         (j->>'total_esperado')::numeric,
         (j->>'linea_ou')::numeric,
         (j->>'over_pct_ajustado')::numeric,
         (j->>'under_pct_ajustado')::numeric,
         (j->>'calidad')::numeric,
         j
  FROM agenda_espn ae
  CROSS JOIN LATERAL public.predecir_mlb(ae.espn_event_id) AS j
  WHERE ae.deporte = 'baseball'
    AND ae.fecha BETWEEN now() - interval '3 hours' AND now() + interval '4 days'
    AND (j ? 'gana_local_pct')
    AND NOT EXISTS (
      SELECT 1 FROM public.mlb_prediccion_snapshot s
      WHERE s.espn_event_id = ae.espn_event_id
        AND s.snapshot_at > now() - make_interval(mins => p_dedup_min));
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END;
$$;

-- 3) VISTA CANÓNICA: lee el snapshot MÁS RECIENTE por evento (NO recomputa).
--    Mismas columnas/semántica que v_prediccion_reto_futbol donde aplica.
CREATE OR REPLACE VIEW public.v_prediccion_reto_mlb AS
WITH ultimo AS (
  SELECT DISTINCT ON (espn_event_id) *
  FROM public.mlb_prediccion_snapshot
  WHERE scheduled_at >= now() - interval '6 hours'
  ORDER BY espn_event_id, snapshot_at DESC
)
SELECT espn_event_id AS canonical_event_id,
       'baseball'::text AS sport,
       home_nombre, away_nombre, liga_nombre,
       scheduled_at,
       p_local_gana,
       NULL::numeric AS p_empate,           -- MLB no tiene empate
       p_visita_gana,
       CASE WHEN p_local_gana >= p_visita_gana THEN home_nombre ELSE away_nombre END AS lo_mas_probable_1x2,
       GREATEST(p_local_gana, p_visita_gana) AS mejor_1x2_pct,
       NULL::numeric AS p_btts_yes,
       NULL::numeric AS p_btts_no,
       linea_ou, p_over, p_under,
       'motor_mlb_cuantitativo'::text AS prob_source,
       'UNVALIDATED'::text AS model_status,
       calidad,
       round(GREATEST(p_local_gana, p_visita_gana) * (0.6 + 0.4 * COALESCE(calidad,0)), 1) AS reto_score,
       'NO_DISPONIBLE_MODELO'::text AS btts_status,
       'mlb_v1_provisional'::text AS score_version,
       total_esperado, lambda_home, lambda_away,   -- específicos MLB
       snapshot_at
FROM ultimo;

-- 4) CRON (STAGED — se activa en el cutover). Snapshot cada 45 min.
--    SELECT cron.schedule('mlb-snapshot-predicciones','*/45 * * * *',
--      $$ SELECT public.snapshot_mlb_predicciones(45); $$);

-- ROLLBACK:
--   DROP VIEW public.v_prediccion_reto_mlb;
--   DROP FUNCTION public.snapshot_mlb_predicciones(integer);
--   DROP TABLE public.mlb_prediccion_snapshot;
--   (y cron.unschedule('mlb-snapshot-predicciones') si se activó)
--
-- NOTA DE VERIFICACIÓN: al aplicarse en el cutover, correr snapshot_mlb_predicciones()
-- una vez y validar que v_prediccion_reto_mlb devuelve filas con p_local_gana+p_visita_gana≈100
-- y líneas O/U variadas, antes del smoke.
