# ISS-006.2 — ECONOMIC MODEL AUTHORITY · REVIEW (PATCH_READY, NO DEPLOY)

Validado READ-ONLY contra prod `wpiztubmmmzclhlprgpd` en transacciones `BEGIN…ROLLBACK`
(compila sobre el esquema real; 0 persistencia). Archivo: `shadow-patches/iss006_2_autoridad_economica.sql`.

## REGLA CANÓNICA
`MODEL_OUTPUT_EXISTS` ≠ `ECONOMICALLY_ELIGIBLE`.
```
ECONOMICALLY_ELIGIBLE :=
    ECONOMIC_MODEL_AUTHORIZED      -- registro explícito (deporte,mercado,fuente,model_version); fail-closed
AND MODEL_SKILL_PASS               -- calibracion_confiable IS TRUE   (NULL = FAIL, sin COALESCE)
AND EMPIRICAL_SUFFICIENCY_OK       -- muestra exigida aguas arriba
AND SEMANTIC_VALIDITY              -- pick_sin_discrepancia_motores
AND DATA_READINESS                 -- dato clave (alineación/abridor) donde aplica
AND EXACT_DECISION_PRICE           -- momio_mercado NOT NULL (precio real)
AND EV > threshold
AND NOT MARKET_ABSTENTION
```
Un modelo/fuente/versión no listado como `economic_authorized=true` ⇒ **FALSE**. Ninguna herencia por NULL ni por versión previa.

## REGISTRY_SEED (gobernanza ACTUAL — todo en $0)
Tabla `public.economic_model_authority(deporte, mercado, fuente, model_version, economic_authorized, reason, authorized_at, authorized_by, actualizado_at)`, PK (deporte,mercado,fuente,model_version), default `economic_authorized=false`.

| deporte | mercado | fuente | model_version | economic_authorized | reason |
|---|---|---|---|---|---|
| soccer | Moneyline | motor_picks | llm | **false** | LLM_NOT_VALIDATED |
| soccer | Moneyline | motor_futbol_calibrado | c1 | **false** | FORWARD_EVIDENCE_PENDING |
| baseball | Moneyline | motor_mlb_cuantitativo | mlb_v1 | **false** | SKILL_INSUFFICIENT |
| soccer | Moneyline | motor_cache | v1 | **false** | FORWARD_EVIDENCE_PENDING |
| baseball | Moneyline | motor_cache | v1 | **false** | SKILL_INSUFFICIENT |
| football | Moneyline | motor_cache | v1 | **false** | NFL_MODEL_OFF |
| soccer | Moneyline | motor_pick_del_dia | v1 | **false** | FORWARD_EVIDENCE_PENDING |
| baseball | Moneyline | motor_pick_del_dia | v1 | **false** | SKILL_INSUFFICIENT |
| *(cualquier otra combinación)* | | | | **false por defecto** | fail-closed |

Corrección aceptada del usuario: **motor_mlb_cuantitativo NO se autoriza** (MLB SKILL_FINAL=INSUFFICIENT ⇒ $0).

## CURRENT_AUTHORIZED_MODELS
**Ninguno.** 0 filas con `economic_authorized=true`. Todo el dinero queda gateado a $0.

## SQL_DIFF (resumen; patch completo en el .sql)
1. **CREATE TABLE** `economic_model_authority` (+ REVOKE anon/PUBLIC, GRANT SELECT auth/service) + seed.
2. **`economic_model_authorized(deporte,mercado,fuente,model_version)`** → la pregunta única (ALLOW exige match exacto).
3. Helpers `deporte_registry()`, `model_version_de_fuente()`.
4. **v_pick_canonico.es_pick**: antepone `economic_model_authorized(...)` y cambia `COALESCE(calibracion_confiable,true)` → `calibracion_confiable IS TRUE`.
5. **mejor_oportunidad_hoy**: sustituye la reconstrucción a mano `(coalesce(calibracion_confiable,true) or Moneyline)` por `v.es_pick` (fin del bypass paralelo).
6. **favoritos_bien_pagados**: gate de `info_completa` y de `fraccion` (Kelly) por `economic_model_authorized(dep,'Moneyline','motor_cache','v1')` → RETO 13M no registra ni dimensiona sin autorización.
7. **v_super_pick** (DESTACADOS): gate de `apto_para_mostrar` y `kelly_pct_sugerido`.
8. **tg_filtrar_pick_del_dia**: gate de `NEW.kelly_pct_sugerido`.
9. **POST-VERIFY** en la misma transacción: si `es_pick+fbp+moh+super <> 0` bajo la semilla → aborta. Todo en un `BEGIN…COMMIT`; si un substring cambió en prod → `SUBSTR_NOT_FOUND` y ROLLBACK (sin deploy parcial).

## EXPECTED_BEFORE_AFTER (medido en dry-run sobre datos vivos)
| superficie | antes | después |
|---|---|---|
| v_pick_canonico es_pick (total) | 13 | **0** |
| — soccer / MLB / NFL | (soccer LLM+C1, MLB) | 0 / 0 / 0 |
| reto_picks_hoy puede_apostar | >0 | **0** |
| favoritos_bien_pagados info_completa | >0 | **0** |
| mejor_oportunidad_hoy filas | 9 | **0** |
| v_super_pick apto_para_mostrar | >0 | **0** |

`Soccer ML = 0 · MLB ML = 0 · NFL = 0` picks económicos. Los análisis siguen existiendo (filas presentes con `probabilidad_pct`, `es_pick=false`) → **INFORMATIVE_ANALYSIS** visible; `stake=0`.

## ADVERSARIAL_TESTS (12) — todos PASS
| # | Caso | Resultado |
|---|---|---|
| 1 | LLM + EV +50% + precio real → $0 | PASS (t1 auth=false; es_pick_after inc. LLM=0; moh=0; super=0) |
| 2 | LLM calibracion_confiable=NULL → $0 | PASS (bool_or(new_es_pick) sobre motor_picks = false) |
| 3 | fuente desconocida `motor_nuevo` → $0 | PASS (economic_model_authorized(...,‘motor_nuevo’,...) = false) |
| 4 | model_version nueva (`c2`) de fuente previa → $0 | PASS (solo `c1` sembrada; c2 = false) |
| 5 | C1 skill PASS pero forward pendiente → $0 | PASS (registry soccer/C1=false → es_pick soccer after=0) |
| 6 | C1 todos los gates pero registry=false → $0 | PASS (allow-flip: before=6, after-flip=6 ⇒ sólo el registry lo habilita) |
| 7 | registry=true pero skill FAIL → $0 | PASS por construcción (`calibracion_confiable IS TRUE`; filas calib=false ya caen) |
| 8 | registry=true pero sin exact decision price → $0 | PASS por construcción (`momio_mercado IS NOT NULL`) |
| 9 | MLB EV enorme, SKILL insuficiente → $0 | PASS (MLB registry=false → es_pick MLB=0; fbp info=0) |
| 10 | cambiar prob/texto del LLM no cambia stake | PASS (LLM nunca autorizado; stake/kelly/es_pick=0 sea cual sea la prob) |
| 11 | análisis informativo sigue visible | PASS (filas siguen en v_pick_canonico con es_pick=false + probabilidad_pct) |
| 12 | ninguna superficie económica salta el registry | PASS (5 cabezas gateadas; ver CONSUMER_MAP) |

## CONSUMER_MAP (toda ruta a dinero pasa por el registry)
Cabezas económicas independientes → **gateadas directamente**:
- `v_pick_canonico.es_pick` → propaga a `reto_picks_hoy__base` (stake RETO), `rongol_veto__base`, `v_oraculo_canonico`, `revisar_apuesta__base`, `analisis_completo`, `filtro_pick`.
- `mejor_oportunidad_hoy` (reconstruía es_pick a mano → ahora usa `v.es_pick`).
- `favoritos_bien_pagados` → `reto_registrar_favoritos` / `reto_13m_estado__base` (RETO 13M).
- `v_super_pick` (DESTACADOS) → `refrescar_destacados`.
- `tg_filtrar_pick_del_dia` (pick del día).

Primitivas de sizing (`kelly_stake`, `kelly_fraccion_pct`, `kelly_usuario`) SOLO se alcanzan a través de esas cabezas; con las cabezas en 0, no dimensionan nada económico. `v_favorito_mlb` lee motor_cache (display; sin stake) — revisar por prolijidad, no es ruta de dinero.

## ROLLBACK_PLAN
Reversión total (el patch es aditivo + reemplazos de definición):
```
BEGIN;
-- restaurar las 5 definiciones desde el snapshot pre-deploy (pg_get_functiondef/viewdef capturados al aplicar)
--   v_pick_canonico, mejor_oportunidad_hoy, favoritos_bien_pagados, v_super_pick, tg_filtrar_pick_del_dia
DROP TABLE IF EXISTS public.economic_model_authority;
DROP FUNCTION IF EXISTS public.economic_model_authorized(text,text,text,text);
DROP FUNCTION IF EXISTS public.deporte_registry(text);
DROP FUNCTION IF EXISTS public.model_version_de_fuente(text);
COMMIT;
```
(El deploy captura primero `pg_get_*def` de las 5 → DEPLOY_ROLLBACK_SNAPSHOT, igual que Bloque 0. Alternativa blanda: `UPDATE economic_model_authority SET economic_authorized=true …` para reactivar selectivamente sin revertir código.)

## PREDEPLOY_ISS006_GATE = **PASS**
Core compila sobre esquema real; las 5 cabezas compilan (replace byte-fidelity, guardas SUBSTR_NOT_FOUND) y el POST-VERIFY da `ALL_ZERO=true` en dry-run sobre datos vivos. **NO DEPLOY** — espera GO.
