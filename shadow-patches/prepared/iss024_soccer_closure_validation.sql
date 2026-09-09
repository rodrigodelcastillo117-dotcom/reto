-- ISS-024 — SOCCER CLOSURE VALIDATION / ACCEPTANCE MATRIX
-- *** READ-ONLY VALIDATION. Ejecutar DESPUÉS de ISS-018..023 en preview/cutover txn. ***
-- No corrige nada; falla/expone cualquier violación antes de liberar.

-- 1) Universo + cobertura de P_RETO (los eventos NO desaparecen por falta de modelo).
WITH ev AS (
  SELECT a.espn_event_id,a.fecha,a.home_nombre,a.away_nombre
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.fecha BETWEEN now() AND now()+interval '48 hours'
)
SELECT
  count(*) AS event_universe,
  count(p.canonical_event_id) AS matrix_rows,
  count(*) FILTER(WHERE p.model_status='UNVALIDATED' AND p.p_local_gana IS NOT NULL) AS p_reto_ready,
  count(*) FILTER(WHERE p.model_status='INSUFFICIENT_SAMPLE') AS insufficient_sample,
  count(*) FILTER(WHERE p.model_status='TEMPORAL_UNSAFE') AS temporal_unsafe,
  count(*) FILTER(WHERE p.canonical_event_id IS NULL) AS no_model_row
FROM ev LEFT JOIN public.v_prediccion_reto_futbol p ON p.canonical_event_id=ev.espn_event_id;

-- 2) Invariantes probabilísticos. Debe devolver CERO filas.
SELECT canonical_event_id,
       p_local_gana+p_empate+p_visita_gana AS sum_1x2,
       p_btts_yes+p_btts_no AS sum_btts,
       p_over+p_under AS sum_ou
FROM public.v_prediccion_reto_futbol
WHERE model_status='UNVALIDATED' AND (
  (p_local_gana IS NOT NULL AND abs((p_local_gana+p_empate+p_visita_gana)-100)>1.5)
  OR (p_btts_yes IS NOT NULL AND abs((p_btts_yes+p_btts_no)-100)>1.5)
  OR (linea_ou IS NOT NULL AND abs((p_over+p_under)-100)>1.5)
);

-- 3) Integridad temporal. Debe devolver CERO filas.
SELECT canonical_event_id,scheduled_at,model_generated_at,provider_line_asof,model_status
FROM public.v_prediccion_reto_futbol
WHERE (model_generated_at IS NOT NULL AND model_generated_at>scheduled_at)
   OR (provider_line_asof IS NOT NULL AND provider_line_asof>scheduled_at);

-- 4) Línea O/U: la publicada debe coincidir con provider_total_line_raw. CERO filas.
SELECT canonical_event_id,linea_ou,provider_total_line_raw,provider_name,provider_line_asof
FROM public.v_prediccion_reto_futbol
WHERE linea_ou IS NOT NULL AND linea_ou IS DISTINCT FROM provider_total_line_raw;

-- 5) Muestra insuficiente nunca puede publicar P. CERO filas.
SELECT canonical_event_id,model_sample,model_status,p_local_gana,p_btts_yes,p_over
FROM public.v_prediccion_reto_futbol
WHERE model_sample<min_sample_required
  AND (p_local_gana IS NOT NULL OR p_empate IS NOT NULL OR p_visita_gana IS NOT NULL
       OR p_btts_yes IS NOT NULL OR p_btts_no IS NOT NULL OR p_over IS NOT NULL OR p_under IS NOT NULL);

-- 6) Dependencias prohibidas en el NUEVO core de fútbol. Todos los booleanos deben ser FALSE.
SELECT
  position('v_pick_canonico' in pg_get_functiondef('public.analisis_futbol_reto_core(text)'::regprocedure))>0 AS has_v_pick_canonico,
  position('destacados' in pg_get_functiondef('public.analisis_futbol_reto_core(text)'::regprocedure))>0 AS has_destacados,
  position('pred_futbol_espn' in pg_get_functiondef('public.analisis_futbol_reto_core(text)'::regprocedure))>0 AS has_parallel_espn_prob,
  position('predecir_mlb' in pg_get_functiondef('public.analisis_futbol_reto_core(text)'::regprocedure))>0 AS has_mlb,
  position('nfl_' in pg_get_functiondef('public.analisis_futbol_reto_core(text)'::regprocedure))>0 AS has_nfl,
  position('calcular_ev' in pg_get_functiondef('public.analisis_futbol_reto_core(text)'::regprocedure))>0 AS has_ev_calc;

-- 7) Full-data dossier para TODOS los eventos próximos: contrato, manifest y no error.
WITH ev AS (
  SELECT a.espn_event_id
  FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.fecha BETWEEN now() AND now()+interval '48 hours'
), d AS (
  SELECT e.espn_event_id,public.analisis_futbol_reto_core(e.espn_event_id) payload FROM ev e
)
SELECT
  count(*) AS events,
  count(*) FILTER(WHERE payload?'error') AS errors,
  count(*) FILTER(WHERE payload#>>'{_analysis_contract,version}'='SOCCER_FULL_DATA_V1') AS correct_contract,
  count(*) FILTER(WHERE jsonb_typeof(payload->'coverage_manifest')='array') AS with_manifest,
  count(*) FILTER(WHERE coalesce(jsonb_array_length(payload->'coverage_manifest'),0)>=10) AS manifest_ge_10_features
FROM d;

-- 8) Ninguna entrada USADA puede violar as_of <= decision_time. CERO filas.
WITH ev AS (
  SELECT a.espn_event_id FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.fecha BETWEEN now() AND now()+interval '48 hours'
), d AS (
  SELECT e.espn_event_id,public.analisis_futbol_reto_core(e.espn_event_id) payload FROM ev e
), m AS (
  SELECT d.espn_event_id,x.value item FROM d CROSS JOIN LATERAL jsonb_array_elements(d.payload->'coverage_manifest') x(value)
)
SELECT espn_event_id,item->>'feature' feature,item->>'source' source,item->>'as_of' as_of,item->>'decision_time' decision_time
FROM m
WHERE coalesce((item->>'used_in_model')::boolean,false) OR coalesce((item->>'used_in_context')::boolean,false)
  AND item->>'temporal_status' NOT IN ('STATIC','SAFE_ASOF','SAFE_COMPUTED_ASOF','SAFE_CURRENT');

-- 9) P_RETO del dossier = matriz exacta. CERO filas.
WITH ev AS (
  SELECT a.espn_event_id FROM public.agenda_espn a
  WHERE a.deporte='soccer' AND a.fecha BETWEEN now() AND now()+interval '48 hours'
), d AS (
  SELECT e.espn_event_id,public.analisis_futbol_reto_core(e.espn_event_id) payload FROM ev e
)
SELECT d.espn_event_id,
       p.p_local_gana matrix_home,(d.payload#>>'{1_el_resumen,p_reto,p_local_gana}')::numeric dossier_home,
       p.linea_ou matrix_line,(d.payload#>>'{1_el_resumen,p_reto,linea_ou}')::numeric dossier_line
FROM d JOIN public.v_prediccion_reto_futbol p ON p.canonical_event_id=d.espn_event_id
WHERE p.p_local_gana IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_local_gana}')::numeric
   OR p.p_empate IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_empate}')::numeric
   OR p.p_visita_gana IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_visita_gana}')::numeric
   OR p.p_btts_yes IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_btts_yes}')::numeric
   OR p.p_btts_no IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_btts_no}')::numeric
   OR p.linea_ou IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,linea_ou}')::numeric
   OR p.p_over IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_over}')::numeric
   OR p.p_under IS DISTINCT FROM (d.payload#>>'{1_el_resumen,p_reto,p_under}')::numeric;

-- 10) Resolver Mi Idea/Parlay: ningún soccer OK puede diferir de la matriz. CERO filas.
WITH c AS (
  SELECT vp.*,public.resolver_p_reto_futbol(vp.espn_event_id,vp.mercado,vp.pick_desc,NULL) r
  FROM public.v_picks_para_parlay vp
  JOIN public.agenda_espn a ON a.espn_event_id=vp.espn_event_id AND a.deporte='soccer'
  WHERE vp.match_date>=now() AND vp.match_date<now()+interval '48 hours'
)
SELECT espn_event_id,mercado,pick_desc,r
FROM c
WHERE r->>'status'='OK' AND (r->>'prob_pct')::numeric IS NULL;

-- 11) Casos visuales conocidos: inventario puntual para smoke humano.
SELECT a.espn_event_id,a.home_nombre,a.away_nombre,a.fecha,
       p.model_status,p.unavailable_reason,p.lo_mas_probable_1x2,p.mejor_1x2_pct,
       p.linea_ou,p.p_over,p.p_under,p.model_sample,p.provider_name,p.provider_line_asof
FROM public.agenda_espn a
LEFT JOIN public.v_prediccion_reto_futbol p ON p.canonical_event_id=a.espn_event_id
WHERE a.deporte='soccer' AND (
  (public.reto_norm_txt(a.home_nombre) LIKE '%barcelona%' AND public.reto_norm_txt(a.away_nombre) LIKE '%feyenoord%')
  OR (public.reto_norm_txt(a.home_nombre) LIKE '%stuttgart%' AND public.reto_norm_txt(a.away_nombre) LIKE '%viking%')
  OR (public.reto_norm_txt(a.home_nombre) LIKE '%liverpool%' AND public.reto_norm_txt(a.away_nombre) LIKE '%atletico%')
  OR (public.reto_norm_txt(a.home_nombre) LIKE '%paris saint%' AND public.reto_norm_txt(a.away_nombre) LIKE '%slovan%')
  OR (public.reto_norm_txt(a.home_nombre) LIKE '%sporting%' AND public.reto_norm_txt(a.away_nombre) LIKE '%galatasaray%')
  OR (public.reto_norm_txt(a.home_nombre) LIKE '%napoli%' AND public.reto_norm_txt(a.away_nombre) LIKE '%arsenal%')
)
ORDER BY a.fecha DESC;

-- PASS DE BACKEND SOCCER exige:
-- temporal violations=0; invariant violations=0; forbidden deps=false; dossier errors=0;
-- P mismatch=0; todos los missing clasificados; y smoke de latencia por separado.
