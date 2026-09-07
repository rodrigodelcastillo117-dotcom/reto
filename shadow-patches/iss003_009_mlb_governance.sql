-- ============================================================================
-- ISS-003 + ISS-009 — SHADOW PATCH — GOBERNANZA MLB
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY. Propuesta revisable. No aplicado a producción.
-- Mantiene obligatoriamente: CURRENT_AUTHORIZED_MODELS = NONE,
-- MLB economic_authorized = FALSE, MLB stake = $0. No autoriza MLB.
-- No recalibra, no tunea, no toca EXP_OFF/NB r=5/features. Solo cableado/gobernanza.
--
-- ISS-003 — el hardcode `calibracion_confiable=true` para MLB miente: sobreescribe
--   la señal REAL del modelo (predecir_mlb → edge_vs_mercado.confiable). Medido:
--   136 filas MLB hoy con calibracion_confiable=true y señal real false/NULL
--   (Athletics: modelo_confiable=FALSE, calibracion_confiable=TRUE).
--   Vive en DOS lugares:
--     (a) v_pick_canonico, rama MLB: `true AS bool` (col calibracion_confiable).
--     (b) v_mejores_picks_mlb: `COALESCE(j.confiable, true)` (el COALESCE(NULL,TRUE) prohibido).
--
-- ISS-009 — mientras MLB SKILL_FINAL=INSUFFICIENT, ninguna superficie debe
--   presentar MLB como PICK/ELITE/RECOMENDACIÓN/APOSTAR. Las superficies de
--   DINERO ya lo cumplen (economic_eligibility_v1: es_pick=0, moh=0, fbp=0,
--   v_super_pick apto=0 — probado). El HUECO es v_mejores_picks_mlb, que rotula
--   nivel 'ojo'/'fuerte' con EV sin pasar por ningún gate de skill/autorización.
--
-- Nota conceptual (exigida por el auditor): calibracion_confiable NO sustituye a
-- MODEL_SKILL. Son gates distintos: (a) arregla la señal de confianza del modelo;
-- (b)/ISS-009 aplica el candado de skill/gobernanza. Se tratan por separado.
-- ============================================================================


-- ============================================================================
-- PARTE 1 (ISS-003a) — v_pick_canonico: calibracion_confiable MLB = FALSE (fail-closed)
-- ============================================================================
-- CORRECCIÓN SEMÁNTICA (2026-09-07): NO mapear mm.confiable a calibracion_confiable.
-- Probado en predecir_mlb: `edge_vs_mercado.confiable = (brecha <= BRECHA_ALERTA)`
-- donde brecha = |prob_modelo - prob_mercado|. => MLB_CONFIABLE_SEMANTICS = EDGE_RELIABILITY
-- (divergencia modelo-vs-mercado), NO confianza de calibración. Meterlo en
-- calibracion_confiable sería renombrar un concepto para pasar un gate (justo el
-- patrón que originó estos bugs).
-- MLB NO tiene una fuente real de confianza de calibración (y su skill es negativo,
-- #191: el modelo pierde contra la tasa base; predecir_mlb amortigua 70% a base).
-- => fail-closed: calibracion_confiable MLB = FALSE (literal). El literal viejo era
-- `true AS bool`. La señal de edge (mm.confiable) se conserva donde ya se usa como
-- edge (v_mejores_picks_mlb) y en predecir_mlb; NO se pierde, pero NO va aquí.
DO $vpc$
DECLARE s text; s2 text;
  needle text := 'true AS bool';
  repl   text := 'false';
BEGIN
  SELECT pg_get_viewdef('public.v_pick_canonico'::regclass, true) INTO s;
  -- guardas de unicidad y de drift
  IF (length(s) - length(replace(s, needle, ''))) / length(needle) <> 1 THEN
    RAISE EXCEPTION 'ISS003_VPC_NEEDLE_NO_UNICO (apariciones<>1)';
  END IF;
  s2 := replace(s, needle, repl);
  IF s2 = s THEN RAISE EXCEPTION 'ISS003_VPC_SUBSTR_NOT_FOUND'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_pick_canonico AS ' || s2;
  RAISE NOTICE 'v_pick_canonico: calibracion_confiable MLB -> mm.confiable OK';
END $vpc$;


-- ============================================================================
-- PARTE 2 (ISS-003b + ISS-009) — v_mejores_picks_mlb: NULL=FAIL + gate de gobernanza
-- ============================================================================
-- Cambios vs def viva:
--   (ISS-003b) `COALESCE(j.confiable, true)` -> `COALESCE(j.confiable, false)`.
--   (ISS-009)  añade `economically_eligible` + `reason_code` desde
--              economic_eligibility_v1 (baseball, mercado, motor_mlb_cuantitativo,
--              model_version=NULL => MISSING => false hoy), y degrada `nivel` a
--              'informativo' cuando NO es económicamente elegible. Así la tarjeta
--              puede seguir mostrando análisis (prob, EV, ventaja) pero NO como
--              recomendación 'fuerte'/'ojo' mientras el skill sea insuficiente.
-- El resto del cuerpo es transcripción de la def viva (no se cambia la matemática).
CREATE OR REPLACE VIEW public.v_mejores_picks_mlb AS
WITH picks AS (
  SELECT m.espn_event_id, m.arranca_en, m.liga_nombre, m.home_nombre, m.away_nombre,
         m.mercado, m.pick, m.prob, m.detalle, m.favorito, m.favorito_pct, m.confiable,
         o.ml_home, o.ml_away, o.total_linea, o.over_odds, o.under_odds
    FROM v_picks_mlb_modelo m
    LEFT JOIN odds_espn o ON o.espn_event_id = m.espn_event_id
), con_momio AS (
  SELECT p.*,
    CASE
      WHEN p.mercado='Moneyline' AND p.pick=('ML '||p.home_nombre) THEN p.ml_home
      WHEN p.mercado='Moneyline' AND p.pick=('ML '||p.away_nombre) THEN p.ml_away
      WHEN p.mercado='Over/Under' AND p.pick ~~ 'Over %'  AND p.total_linea::text=split_part(p.pick,' ',2) THEN p.over_odds
      WHEN p.mercado='Over/Under' AND p.pick ~~ 'Under %' AND p.total_linea::text=split_part(p.pick,' ',2) THEN p.under_odds
      ELSE NULL::numeric END AS cuota,
    CASE
      WHEN p.mercado='Moneyline'  AND p.ml_home>1 AND p.ml_away>1 THEN 1/p.ml_home + 1/p.ml_away
      WHEN p.mercado='Over/Under' AND p.over_odds>1 AND p.under_odds>1 THEN 1/p.over_odds + 1/p.under_odds
      ELSE NULL::numeric END AS suma_implicita
  FROM picks p
), juzgado AS (
  SELECT c.*, filtro_pick_live(c.prob/100.0, c.cuota, c.mercado, 'baseball') AS f,
    CASE WHEN c.suma_implicita>0 THEN round(1/c.cuota/c.suma_implicita*100,1) ELSE NULL::numeric END AS mercado_sin_comision
  FROM con_momio c WHERE c.cuota > 1
), final AS (
  SELECT j.*, ((j.f->>'prob_calibrada')::numeric) - j.mercado_sin_comision AS brecha_pp
  FROM juzgado j
  -- ISS-003b: NULL=FAIL (antes COALESCE(j.confiable, true))
  WHERE ((j.f->>'pasa')::boolean) AND (j.mercado <> 'Moneyline' OR COALESCE(j.confiable, false))
)
SELECT DISTINCT ON (espn_event_id) espn_event_id, arranca_en, home_nombre, away_nombre,
  mercado, pick, cuota, prob AS prob_modelo,
  (f->>'prob_calibrada')::numeric AS prob_calibrada,
  mercado_sin_comision, round(brecha_pp,1) AS ventaja_pp,
  (f->>'wr_necesario')::numeric AS necesitas_pct,
  (f->>'ev_pct')::numeric AS ev_pct,
  COALESCE((f->>'calibrado')::boolean, true) AS calibrado,
  -- ISS-009: gate de gobernanza (hoy false: MLB no autorizado / skill insuficiente)
  (economic_eligibility_v1(jsonb_build_object(
      'deporte','baseball','mercado',mercado,'fuente','motor_mlb_cuantitativo',
      'model_version',NULL::text,'ev_pct',(f->>'ev_pct')::numeric,'ev_threshold',2.5))->>'eligible')::boolean
    AS economically_eligible,
  economic_eligibility_v1(jsonb_build_object(
      'deporte','baseball','mercado',mercado,'fuente','motor_mlb_cuantitativo',
      'model_version',NULL::text,'ev_pct',(f->>'ev_pct')::numeric,'ev_threshold',2.5))->>'reason_code'
    AS reason_code,
  -- nivel: solo es recomendación si es económicamente elegible; si no, 'informativo'
  CASE
    WHEN NOT (economic_eligibility_v1(jsonb_build_object(
         'deporte','baseball','mercado',mercado,'fuente','motor_mlb_cuantitativo',
         'model_version',NULL::text,'ev_pct',(f->>'ev_pct')::numeric,'ev_threshold',2.5))->>'eligible')::boolean
      THEN 'informativo'
    WHEN brecha_pp >= 12 THEN 'ojo'
    WHEN brecha_pp >= 3  THEN 'fuerte'
    ELSE 'flojo' END AS nivel,
  detalle,
  equipo_corto(home_nombre,'baseball') AS home_corto,
  equipo_corto(away_nombre,'baseball') AS away_corto,
  CASE
    WHEN mercado='Moneyline' AND pick=('ML '||home_nombre) THEN equipo_corto(home_nombre,'baseball')||' ML'
    WHEN mercado='Moneyline' AND pick=('ML '||away_nombre) THEN equipo_corto(away_nombre,'baseball')||' ML'
    ELSE upper(pick) END AS etiqueta,
  equipo_corto(favorito,'baseball') AS favorito_corto, favorito_pct,
  CASE WHEN mercado='Moneyline' THEN pick=('ML '||favorito) ELSE NULL::boolean END AS pick_es_favorito
FROM final
ORDER BY espn_event_id, ((f->>'ev_pct')::numeric) DESC;
-- Contrato: se AÑADEN columnas (economically_eligible, reason_code) y `nivel` pasa a
-- 'informativo' bajo NONE. El frontend debe: (1) no rotular como PICK/RECOMENDADO
-- cuando nivel='informativo' o economically_eligible=false; (2) mostrar la razón.


-- ============================================================================
-- PARTE 3 (ISS-009, OPCIONAL / gobernanza profunda) — skill como registro
-- ============================================================================
-- HOY el gate g_skill de economic_eligibility_v1 confía en el model_skill que
-- pasa la superficie (ver caso B de los tests: skill='SKILL_PASS' forzado ->
-- g_skill=true). Es seguro porque las superficies pasan NULL, pero es una
-- SUPERFICIE DE BYPASS: un edit podría pasar 'SKILL_PASS' para MLB.
--
-- PROPUESTA (mismo espíritu que economic_model_authority de ISS-006.2): el skill
-- debe ser un REGISTRO de gobernanza, no una afirmación de la superficie. Añadir
-- `skill_final` al registry y que economic_eligibility_v1 derive g_skill del
-- registro de la versión autorizada, NO del ctx.
--
-- ATENCIÓN: esto MODIFICA economic_eligibility_v1 (gate de dinero ya desplegado
-- en ISS-006.2). Hoy el efecto neto es idéntico (todo sigue en false porque no
-- hay filas autorizadas), pero cierra el bypass. Se deja como OPCIONAL: requiere
-- su propio deploy atómico + POST-VERIFY. NO incluido en el deploy principal de
-- ISS-003/009 salvo GO explícito.
--
--   ALTER TABLE public.economic_model_authority ADD COLUMN IF NOT EXISTS skill_final text;  -- default NULL = INSUFFICIENT
--   -- y en economic_eligibility_v1, reemplazar:
--   --   g_skill := (p_ctx->>'model_skill') = 'SKILL_PASS'
--   -- por:
--   --   g_skill := EXISTS (SELECT 1 FROM economic_model_authority a
--   --                       WHERE a.deporte=... AND a.mercado=... AND a.fuente=...
--   --                         AND a.model_version=mv AND a.economic_authorized
--   --                         AND a.skill_final='SKILL_PASS');
--   -- Efecto: un modelo es skill-PASS SOLO si su fila autorizada lo declara.
--   --         MLB, sin fila autorizada, es skill-INSUFFICIENT por defecto.
-- (Solo documentado; no ejecutado en este bloque.)


-- ============================================================================
-- PARTE 4 (ISS-009B) — analisis_completo: el dossier no dice "PICK SUGERIDO" si no elegible
-- ============================================================================
-- ROOT CAUSE: el banner "🎯 PICK SUGERIDO POR EL MOTOR UNIFICADO" (AnalisisCompletoModal)
-- enciende con `mercados.length > 0` — es decir, "hay info de mercado" se confunde con
-- "hay apuesta recomendada". El payload `jmkt` (= 1_el_resumen.mercados) se arma
-- `from v_pick_canonico c` (join por espn_event_id+pick), que YA trae `c.es_pick` (el
-- resultado del gate económico canónico), pero jmkt NO lo propaga.
-- PROVENANCE: suficiente. c = v_pick_canonico → no se inventan joins por nombre/equipo.
--
-- FIX MÍNIMO (insert en el fragmento jmkt, no se reescribe la función): propagar
-- economically_eligible = c.es_pick y stake_final = 0. El frontend gatea el banner con eso.
-- (reason_code: ver nota abajo — requiere exponerlo desde v_pick_canonico; opcional.)
DO $ac$
DECLARE s text; s2 text;
  needle text := '''como_se_calculo'', c.razon)';
  repl   text := '''economically_eligible'', c.es_pick, ''stake_final'', 0, ''como_se_calculo'', c.razon)';
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO s FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='analisis_completo';
  IF (length(s)-length(replace(s,needle,'')))/length(needle) <> 1 THEN
    RAISE EXCEPTION 'ISS009B_ANCHOR_NO_UNICO'; END IF;
  s2 := replace(s, needle, repl);
  IF s2 = s THEN RAISE EXCEPTION 'ISS009B_ANCHOR_NOT_FOUND'; END IF;
  EXECUTE s2;  -- re-CREATE OR REPLACE FUNCTION analisis_completo con el fragmento parcheado
  RAISE NOTICE 'analisis_completo: jmkt propaga economically_eligible/stake_final OK';
END $ac$;
-- reason_code (opcional, no-duplicante): exponer `reason_code` desde v_pick_canonico
-- (una sola llamada a economic_eligibility_v1 por fila, la misma que ya calcula es_pick)
-- y añadir 'reason_code', c.reason_code al jmkt. Se especifica en el REVIEW; no se fuerza
-- aquí para mantener el diff mínimo. economically_eligible = c.es_pick basta para el gate.
--
-- FRONTEND (AnalisisCompletoModal / BannerPickCanonico): condición del banner cambia de
--   `mercados.length > 0`  →  `mercados.some(m => m.economically_eligible === true)`.
--   Mercados con economically_eligible=false se muestran bajo "ANÁLISIS INFORMATIVO —
--   NO APUESTA AUTORIZADA" (prob/EV/matchup visibles; sin PICK SUGERIDO/stake).

-- ============================================================================
-- POST-VERIFY (para el deploy real; aquí como comprobación)
--   V1  0 filas MLB con calibracion_confiable=true y señal real (mm.confiable) <> true.
--   V2  v_mejores_picks_mlb: 0 filas MLB con nivel IN ('ojo','fuerte') (todas 'informativo' o 'flojo' bajo NONE).
--   V3  MLB economic picks/stake = 0 en TODAS las superficies (v_pick_canonico es_pick,
--       mejor_oportunidad_hoy, favoritos_bien_pagados, v_super_pick apto, reto_picks_hoy).
--   V4  CURRENT_AUTHORIZED_MODELS = NONE.
-- ============================================================================
