# ISS-006.1 — RECONCILIACIÓN DE VERDAD SOCCER ML (read-only, sin deploy)

**AS_OF único:** 2026-09-07 12:50:29Z. Proyecto wpiztubmmmzclhlprgpd.
Deploy realizado en la sesión: SOLO Bloque 0 seguridad (no toca el pipeline de soccer).

## SOCCER_ML_AUTHORITY_TRUTH
Hay DOS nociones de "elegible" que NO son la misma:
1. **`v_pick_canonico.es_pick`** = bandera de RECOMENDACIÓN (tarjeta/análisis). Es la que se fuga.
2. **`favoritos_bien_pagados()`** = AUTORIDAD ECONÓMICA real de RETO 13M (dimensiona con Kelly). Lee `motor_cache`
   (motor determinista) + `mc.suficiente` + `calibrar_prob_motor_live` + precio real + whitelist de ligas
   (EPL/La Liga/Serie A/Bundesliga/Ligue 1/UCL/NFL/MLB/Liga MX). **NUNCA lee la ruta LLM (`motor_picks`).**

**Corrección honesta a mi ISS-006 previo:** dije "EV mostrado = EV que dimensiona" para los 5 LLM. **Es incorrecto.**
Verificado a este AS_OF: los 5 LLM tienen `in_RETO_fbp = NULL` y `in_super_pick = NULL` → NO llegan a ninguna
autoridad de sizing. La prob del LLM alimenta `ev_pct` y `es_pick=true` en la tarjeta canónica, pero **ningún
consumidor económico vivo la lee hoy.** Severidad real: **P1 LATENTE** (la bandera económica canónica `es_pick`
se pone TRUE por el LLM vía `COALESCE(calibracion_confiable,TRUE)`; estamos a un consumidor de distancia de que
mueva dinero), no una fuga activa de la prob del LLM al stake de RETO.

Evidencia económica dura: `reto_picks_mostrados` = 8 filas, **TODAS MLB, 0 soccer** (histórico). RETO nunca ha
dimensionado un pick de soccer. `favoritos_bien_pagados()` default = 3 filas; ampliada = 20, e incluye soccer
(Liga MX/La Liga/Serie A/UCL) con Kelly hasta 5% — pero desde `motor_cache` (determinista), no del LLM; y la
inserción a RETO filtra `info_completa AND falta NOT ILIKE 'ventaja de%'` (edge≤0.12) → hoy 0 soccer en RETO.

## WHY_OLD_REPORT_SAID_11_LLM
El MASTER_REPORT (AS_OF 03:41:49Z) es **internamente inconsistente**:
- Evidencia de Agent 02 (SQL) EN ESE MISMO AS_OF: *"v_pick_canonico soccer Moneyline = 5 filas TODAS
  fuente='motor_picks' (LLM), 0 de motor_futbol_calibrado"*.
- Titular/agregado de Agent 20: *"es_pick=16 (11 soccer ML + 5 MLB ML)"* y narrativa *"las 11 soccer ML vienen
  del motor LLM saltando el champion C1"*.
El "11 = todas LLM" fue una **sobre-generalización del agregado**: mezcló el conteo de es_pick soccer (11, que
incluía filas C1 y LLM en distintos instantes) con la observación puntual de Agent 02 (5 LLM). El propio reporte
avisó: *"champion soccer C1 = 0 es_pick (9 fixtures, 8 por piso muestra≥20, 1 veto sudamericano)"* y
*"es_pick oscila 16↔17 por avance de now()"*. Nunca hubo evidencia de "11 filas todas LLM"; la evidencia SQL decía 5 LLM.

## WHY_CURRENT_QUERY_SAYS_6_C1_5_LLM
1. **El deploy de seguridad no tocó soccer** (14 funciones de identidad/grants; ninguna del pipeline de picks).
2. **Deriva de slate + cron:** los 6 C1 vienen de `fut_predicciones` con `generado_at = 2026-09-07T09:00:00Z`
   (posterior al audit 03:41Z) y `muestra` 25–32 (≥20). En el audit C1 tenía 0 es_pick porque su slate de entonces
   tenía 8/9 fixtures por debajo del piso muestra≥20. Al regenerarse `fut_predicciones` para el slate de la noche
   MLS (todos ≥20), C1 pasó 0→6. Es refresco de datos, no cambio de pipeline.
3. Los 5 LLM (Libertadores, Greek SL, Liga Portugal, UCL×2) son ligas que el motor determinista NO cubre
   (`muestra`/match a ligamx_partidos ausente) → C1 no produce nada ahí y la fila LLM sobrevive el dedup.

## Las 11 filas es_pick=true @ AS_OF 12:50:29Z

| event_id | partido | liga | pick | fuente | model_version | P_RAW | P_FAIR | P_mostrada | calib_confiable | MODEL_SKILL | EMPIRICAL_SUFFICIENCY | SEMANTIC_VALIDITY | DATA_READINESS | decision_price | decision_price_ts | EXACT_DECISION_PRICE | EV | eligibility_reason | es_pick | stake_authorized | consumer |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 761799 | Vancouver vs LA Galaxy | MLS | Empate | motor_futbol_calibrado | C1 Dixon-Coles (fut_pred gen 09:00Z) | ~24.7 | (100/momio_justo) | 24.7 | true | PASS (champion) | muestra=32≥20 ✓ ; FORWARD **pendiente** | ✓ | ✓ odds 12:49Z | 5.5 | 12:49:03Z | pre-match snapshot (NO locked close) | +35.9 | ev≥2.5 & COALESCE(calib,TRUE) | true | **$0** (MLS fuera de whitelist fbp; in_RETO_fbp null) | tarjeta v_pick_canonico |
| 761786 | Philadelphia vs FC Cincinnati | MLS | Gana Cincinnati | motor_futbol_calibrado | C1 (gen 09:00Z) | ~28.1 | 100/momio_justo | 28.1 | true | PASS | muestra=30≥20 ✓ ; FORWARD pendiente | ✓ | ✓ | 4.2 | 12:49:03Z | pre-match snapshot | +18.0 | ev≥2.5 & calib=true | true | **$0** (MLS no whitelist) | tarjeta |
| 761794 | Austin vs Colorado | MLS | Gana Austin | motor_futbol_calibrado | C1 (gen 09:00Z) | ~45.9 | 100/momio_justo | 45.9 | true | PASS | muestra=26≥20 ✓ ; FORWARD pendiente | ✓ | ✓ | 2.45 | 12:49:03Z | pre-match snapshot | +12.5 | ev≥2.5 & calib=true | true | **$0** (MLS no whitelist) | tarjeta |
| 761793 | Minnesota vs FC Dallas | MLS | Gana Dallas | motor_futbol_calibrado | C1 (gen 09:00Z) | ~28.7 | 100/momio_justo | 28.7 | true | PASS | muestra=26≥20 ✓ ; FORWARD pendiente | ✓ | ✓ | 3.7 | 12:49:03Z | pre-match snapshot | +6.2 | ev≥2.5 & calib=true | true | **$0** (MLS no whitelist) | tarjeta |
| 761787 | Atlanta vs Orlando | MLS | Gana Orlando | motor_futbol_calibrado | C1 (gen 09:00Z) | ~34.6 | 100/momio_justo | 34.6 | true | PASS | muestra=25≥20 ✓ ; FORWARD pendiente | ✓ | ✓ | 3.05 | 12:49:03Z | pre-match snapshot | +5.5 | ev≥2.5 & calib=true | true | **$0** (MLS no whitelist) | tarjeta |
| 761796 | Portland vs St. Louis | MLS | Gana Portland | motor_futbol_calibrado | C1 (gen 09:00Z) | ~47.7 | 100/momio_justo | 47.7 | true | PASS | muestra=25≥20 ✓ ; FORWARD pendiente | ✓ | ✓ | 2.15 | 12:49:03Z | pre-match snapshot | +2.6 | ev≥2.5 & calib=true | true | **$0** (MLS no whitelist) | tarjeta |
| 401912543 | Ind. del Valle vs Flamengo | Copa Libertadores | IdV ML | **motor_picks (LLM)** | analizar-partido LLM (analisis 2026-09-07 00:47Z) | 46.8 (LLM) | n/d (momio_justo NULL) | 46.8 | **NULL** | **NONE (LLM no validado)** | **N/A** (sin muestra/backtest) | ✓ | precio ✓ | 2.65 | 08:29:02Z | NO (snapshot 4h viejo) | +24.0 | **COALESCE(NULL,TRUE) bypass** | true | **$0** (no whitelist, fbp no lee LLM) | tarjeta |
| 401896777 | Panathinaikos vs Kifisia | Super League Greece | Empate | **motor_picks (LLM)** | analizar-partido LLM (2026-09-06 18:45Z) | 23.1 (LLM) | n/d | 23.1 | **NULL** | **NONE** | N/A | ✓ | precio ✓ | 5.0 | 07:49:01Z | NO | +15.5 | **COALESCE bypass** | true | **$0** | tarjeta |
| 401915441 | Como vs RB Leipzig | UEFA Champions | Leipzig ML | **motor_picks (LLM)** | analizar-partido LLM (2026-09-06 21:45Z) | 31.1 (LLM) | n/d | 31.1 | **NULL** | **NONE** | N/A | ✓ | precio ✓ | 3.7 | 08:49:03Z | NO | +15.1 | **COALESCE bypass** | true | **$0** (UCL sí whitelist pero fbp usa motor_cache, no LLM) | tarjeta |
| 401885474 | Estrela vs Braga | Liga Portugal | Braga ML | **motor_picks (LLM)** | analizar-partido LLM (2026-09-06 21:45Z) | 65.3 (LLM) | n/d | 65.3 | **NULL** | **NONE** | N/A | ✓ | precio ✓ (1.741 en ventana 1.30-1.85) | 1.741 | 12:49:03Z | NO | +13.7 | **COALESCE bypass** | true | **$0** (Liga Portugal no whitelist) | tarjeta |
| 401915440 | Slavia Prague vs Lens | UEFA Champions | Slavia ML | **motor_picks (LLM)** | analizar-partido LLM (2026-09-06 21:45Z) | 44.0 (LLM) | n/d | 44.0 | **NULL** | **NONE** | N/A (motor_cache.suficiente=FALSE) | ✓ | precio ✓ | 2.55 | 08:49:03Z | NO | +12.2 | **COALESCE bypass** | true | **$0** (fbp usa motor_cache; para este partido motor_cache opina Lens 57.3, NO Slavia) | tarjeta |

Notas: `P_RAW`/`P_FAIR` para C1 = prob del motor / prob calibrada (100/momio_justo); para LLM `P_FAIR` no existe
(momio_justo NULL en la rama motor_picks). `muestra_calibracion` grande en C1 (1152–2612) = muestra de calibración
por mercado/rango; `muestra` C1 (25–32) = muestra de historia de equipo. `stake_authorized=$0` para las 11 a este
AS_OF (MLS fuera de whitelist fbp; ligas LLM fuera de whitelist o dimensionadas por motor_cache).

## CURRENT_AUTHORIZED_MODELS (autoridad económica de facto, favoritos_bien_pagados)
- `motor_cache` (motor determinista por deporte) con `suficiente=true` + `calibrar_prob_motor_live` + precio real,
  SOLO ligas whitelist (EPL/La Liga/Serie A/Bundesliga/Ligue 1/UCL/NFL/MLB/Liga MX) — y para RETO además
  `info_completa AND edge≤0.12`.
- **NO autorizado (pero hoy fija es_pick=true por fallback):** `motor_picks` (LLM analizar-partido).

## CURRENT_ECONOMIC_BLOCKERS
- **motor_picks (LLM):** sin modelo validado (MODEL_SKILL=NONE). Debe ser `ECONOMIC_ELIGIBILITY=FALSE` SIEMPRE;
  puede ser `INFORMATIVE_ANALYSIS`. Hoy pasa es_pick=true por `COALESCE(calibracion_confiable,TRUE)`.
- **motor_futbol_calibrado (C1) soccer:** MODEL_SKILL=PASS y muestra≥20 y precio real, pero **FORWARD_EVIDENCE /
  REAL_EVENT_E2E NO demostrado cerrado en esta sesión** y `EXACT_DECISION_PRICE` = snapshot pre-partido, no cierre
  bloqueado. Por gobernanza (C1 FROZEN hasta evidencia forward) → deben seguir **$0 / NOT_ECONOMICALLY_ELIGIBLE**
  aunque tengan skill. NO invento cierre retroactivo de esos blockers.
- MLS específicamente: además está fuera de la whitelist de fbp (nunca se dimensiona por RETO).

## EXPECTED_PICKS_AFTER_CORRECT_GATING
Con autorización económica explícita + C1 soccer aún frozen por FORWARD_EVIDENCE:
- **es_pick soccer ML económicos = 0.** Los 5 LLM → `INFORMATIVE_ANALYSIS` (ECONOMIC_ELIGIBILITY=false).
  Los 6 C1 → `NOT_ECONOMICALLY_ELIGIBLE` hasta que gobernanza marque `autorizado=true` con evidencia forward.
- Si/ cuando se demuestre FORWARD_EVIDENCE de C1 soccer, se flipa UNA fila del registro y los C1 con todos los
  gates (skill+suficiencia+precio+EV>0) pasan a elegibles. El LLM nunca.

## TEST ADVERSARIAL (estado actual demostrado; lo que el fix debe garantizar)
| # | Caso | Estado ACTUAL (medido) | Con fix propuesto |
|---|---|---|---|
| 1 | LLM Soccer ML EV+50% → $0 | stake=$0 (in_RETO_fbp null; fbp no lee LLM). PERO es_pick=true (recomendación). Demostrado con IdV EV+24 / Braga EV+13.7 | es_pick=false; INFORMATIVE_ANALYSIS; stake=$0 sin importar EV |
| 2 | LLM calib_confiable=NULL → $0 | es_pick=**true** (BUG, los 5) ; stake=$0 | es_pick=false (autorización explícita, sin COALESCE) |
| 3 | LLM con precio real → $0 | Braga @1.741 real, es_pick=true, stake=$0 | es_pick=false; stake=$0 |
| 4 | C1 sin empirical sufficiency → $0 | v_picks_futbol_calibrado exige muestra≥20 → si <20 no entra al canónico → $0 | igual + gate explícito EMPIRICAL_SUFFICIENCY_OK |
| 5 | C1 sin exact decision price → $0 | es_pick exige momio_mercado NOT NULL; sin precio → es_pick false; fbp exige m NOT NULL | igual + EXACT_DECISION_PRICE explícito |
| 6 | C1 con todos los gates → puede ser elegible | fbp dimensiona soccer whitelist vía motor_cache (La Liga/Liga MX/UCL en muestra ampliada, Kelly hasta 5%) | elegible SOLO si registro `autorizado=true` (hoy C1 soccer=false por FROZEN) |
| 7 | Cambiar texto/prob del LLM nunca cambia stake | RETO stake = fbp(motor_cache); independiente de picks_recomendados_hoy/analisis_partidos → invariante se cumple para RETO | se refuerza: es_pick tampoco depende del LLM |

Observación clave del test 1/2/3: hoy el **stake** ya es $0, pero la **bandera de recomendación** (es_pick) sí se
contamina con el LLM. El fix cierra la clase entera, no solo la manifestación.

## DIFF PROPUESTO (NO APLICADO) — AUTORIZACIÓN ECONÓMICA EXPLÍCITA (fail-closed)
Objetivo del usuario: NO `NULL→FALSE`, sino "¿este modelo está explícitamente autorizado para mover dinero? SÍ/NO".
Cualquier `motor_x` nuevo nace NO autorizado.

```sql
-- (1) Registro fail-closed de fuentes con permiso económico.
CREATE TABLE IF NOT EXISTS public.fuentes_economicas_autorizadas (
  fuente      text NOT NULL,
  deporte     text NOT NULL DEFAULT '*',
  mercado     text NOT NULL DEFAULT '*',
  autorizado  boolean NOT NULL DEFAULT false,
  motivo      text,
  actualizado_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (fuente, deporte, mercado)
);
REVOKE ALL ON public.fuentes_economicas_autorizadas FROM anon, authenticated, PUBLIC;

-- Semilla que codifica la gobernanza ACTUAL (editable en un solo lugar):
INSERT INTO public.fuentes_economicas_autorizadas(fuente,deporte,mercado,autorizado,motivo) VALUES
  ('motor_picks',           '*',      '*', false, 'LLM analizar-partido: sin modelo validado. Solo INFORMATIVE_ANALYSIS.'),
  ('motor_mlb_cuantitativo','baseball','*', true,  'Motor MLB cuantitativo (ya autoridad económica de facto).'),
  ('motor_futbol_calibrado','soccer', '*', false, 'C1 Dixon-Coles FROZEN hasta FORWARD_EVIDENCE/REAL_EVENT_E2E.')
ON CONFLICT (fuente,deporte,mercado) DO NOTHING;

-- (2) La pregunta única.
CREATE OR REPLACE FUNCTION public.fuente_autorizada_economica(p_fuente text, p_deporte text, p_mercado text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $fn$
  SELECT COALESCE(bool_or(autorizado), false)
  FROM public.fuentes_economicas_autorizadas
  WHERE autorizado AND fuente = p_fuente
    AND (deporte = '*' OR deporte = p_deporte)
    AND (mercado = '*' OR mercado = p_mercado);
$fn$;

-- (3) v_pick_canonico: reemplazar el cálculo de es_pick (bloque 'marcado') por:
--   es_pick :=
--        public.fuente_autorizada_economica(c.fuente, c.deporte, c.mercado)   -- AUTHORIZED_MODEL_SOURCE (fail-closed)
--    AND c.momio_mercado IS NOT NULL                                          -- EXACT_DECISION_PRICE (precio real)
--    AND COALESCE(c.ev_pct,-1) >= 2.5                                         -- EV>0 (con piso vigente)
--    AND c.calibracion_confiable = TRUE                                       -- EMPIRICAL_SUFFICIENCY/skill EXPLÍCITO (NO COALESCE)
--    AND NOT (c.deporte ~~ 'baseball%' AND c.mercado='Over/Under')            -- (veto MLB O/U vigente)
--    AND pick_sin_discrepancia_motores(c.espn_event_id,c.mercado,c.pick_desc) -- SEMANTIC_VALIDITY
--    AND NOT mercado_en_abstencion(c.mercado,c.pick_desc);
--   -- y AÑADIR:
--   es_informativo := (NOT <es_pick de arriba>) AND c.probabilidad_pct IS NOT NULL;  -- LLM => informativo, ECONOMIC_ELIGIBILITY=false
```

Efecto con la semilla propuesta: es_pick soccer ML = 0 (5 LLM→informativo; 6 C1→frozen). Para reactivar C1 soccer:
`UPDATE fuentes_economicas_autorizadas SET autorizado=true WHERE fuente='motor_futbol_calibrado' AND deporte='soccer'`
(con evidencia forward), una sola línea, auditable. MLB queda igual (autorizado). Cualquier `motor_x` futuro nace
NO autorizado → jamás apostable por NULL.

**REGRESIÓN OBLIGATORIA antes de aplicar (cuando haya GO):** (a) es_pick soccer LLM = 0; (b) es_pick soccer C1 = 0
mientras autorizado=false, y = 6 si se autoriza; (c) MLB ML es_pick sin cambios; (d) EXACT_DECISION_PRICE:
decidir si "snapshot pre-partido" cuenta o se exige cierre bloqueado (#186); (e) confirmar que ningún consumidor
económico (fbp/v_super_pick) cambia (no leen es_pick).

**NO APLICADO. Espera GO.**
