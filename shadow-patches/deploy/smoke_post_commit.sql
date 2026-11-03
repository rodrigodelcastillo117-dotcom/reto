-- ============================================================================
-- SMOKE POST-COMMIT — ISS-003/009/009B (READ-ONLY; correr tras COMMIT exitoso)
--   psql "$DATABASE_URL" -f shadow-patches/deploy/smoke_post_commit.sql
-- No modifica nada. El smoke VISUAL del dossier MLB (frontend) es aparte (usuario).
-- ============================================================================

-- S1 superficies vivas no rompen
SELECT 'v_pick_canonico' AS obj, count(*) AS n FROM public.v_pick_canonico
UNION ALL SELECT 'v_mejores_picks_mlb', count(*) FROM public.v_mejores_picks_mlb
UNION ALL SELECT 'v_super_pick', count(*) FROM public.v_super_pick
UNION ALL SELECT 'v_oraculo_canonico', count(*) FROM public.v_oraculo_canonico
UNION ALL SELECT 'mejor_oportunidad_hoy(500)', count(*) FROM public.mejor_oportunidad_hoy(500);

-- S2 CASO Athletics ML — es_pick=false, reason real, calibracion_confiable=false, ev_pct intacto
SELECT deporte, home, away, mercado, pick_nombre, ev_pct, calibracion_confiable, es_pick, es_pick_reason
  FROM public.v_pick_canonico
 WHERE deporte='baseball' AND (home ILIKE '%Athletics%' OR away ILIKE '%Athletics%')
 ORDER BY ev_pct DESC;

-- S3 ISS-009 visibilidad: MLB siguen visibles como informativo con motivo (no desaparecieron)
SELECT nivel, economically_eligible, count(*) AS filas,
       count(*) FILTER (WHERE reason_code IS NOT NULL) AS con_reason
  FROM public.v_mejores_picks_mlb
 GROUP BY nivel, economically_eligible
 ORDER BY nivel;

-- S4 NONE persiste + MLB stake 0 en superficies automáticas
SELECT
  (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE) AS authorized_models,   -- 0
  (SELECT count(*) FROM public.mejor_oportunidad_hoy(500) WHERE kelly_pct>0)               AS moh_kelly_pos,       -- 0
  (SELECT count(*) FROM public.usuarios u CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r
     WHERE r.monto_autorizado>0)                                                            AS reto_monto_pos,      -- 0
  (SELECT count(*) FROM public.v_pick_canonico WHERE es_pick IS TRUE)                       AS vpc_es_pick_true;    -- 0
