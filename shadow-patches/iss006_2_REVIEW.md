# ISS-006.2 v2 — ECONOMIC MODEL AUTHORITY + CANONICAL ELIGIBILITY · REVIEW (PATCH_READY, NO DEPLOY)

Validado READ-ONLY contra prod `wpiztubmmmzclhlprgpd` (BEGIN…ROLLBACK; 0 persistencia).
Archivo: `shadow-patches/iss006_2_autoridad_economica.sql`.

## ARQUITECTURA (una sola decisión canónica)
```
modelo produce algo -> PROVENANCE real (model_version/id/hash) -> 8 GATES
   -> economic_eligibility_v1() -> ECONOMICALLY_ELIGIBLE + reason_code -> TODAS las pantallas
```
No cinco decisiones. Las 5 cabezas consumen `economic_eligibility_v1` (o la decisión canónica `es_pick` que ya la usa).

## MODEL_VERSION_PROVENANCE_MAP (evidencia real)
| fuente económica (viva) | tabla/salida | ¿versión inmutable en la fila? | PROVENANCE |
|---|---|---|---|
| motor_picks (LLM) | analisis_partidos.analisis_json | `analysis_version`/`pick_engine_used` sí, pero NO model_id/model_hash del modelo | **MISSING** (no identidad de modelo) |
| motor_futbol_calibrado | fut_predicciones | sólo `generado_at`; sin columna de versión | **MISSING** |
| motor_mlb_cuantitativo | v_picks_mlb_modelo ← predecir_mlb() runtime | sin model_version en la salida | **MISSING** |
| motor_cache | motor_cache(espn_event_id,ventana,probabilidades,suficiente,muestra_minima,calculado_at) | sin versión | **MISSING** |
| motor_pick_del_dia | evaluar_pick_vs_modelo() runtime | sin versión | **MISSING** |

Versionado real SÓLO existe en la capa lab/shadow (NO cableada a las superficies vivas):
`lab_dq_decision.model_version/eligibility_version/skill_policy_version`, `lab_*_forward.model_version`,
`mlb_shadow_predicciones.model_version`, `model_weights.model_version`, `calibracion_estado_v2.calibration_version`.

**Consecuencia (fail-closed):** como ninguna fuente viva emite versión, `economic_eligibility_v1` recibe
`model_version=NULL` → gate de provenance FALLA primero → **$0 por provenance, antes de skill/EV/precio.**
NO se inventa `'v1'`. Reason dominante medido en vivo: `MODEL_VERSION_PROVENANCE_MISSING` (128/128 ML).

## CANONICAL_ECONOMIC_ELIGIBILITY — `economic_eligibility_v1(p_ctx jsonb) -> {eligible, reason_code, gates{}}`
Fail-closed. **NULL = FALSE** por gate (todos envueltos en COALESCE(...,false)). 8 gates identificables:
`economic_model_authorized` (registry, version exacta) · `model_skill` (`SKILL_PASS`; **no** es calibracion_confiable) ·
`empirical_sufficiency` (`OK`; concepto distinto de skill) · `semantic_validity` (`PASS`) · `data_readiness` (`READY`) ·
`exact_decision_price` (`true`, ver abajo) · `ev` (> threshold) · `market_abstention_ok` (no abstención).
`eligible = AND de los 8`. `reason_code` = primer gate que falla (orden fijo) o `ELIGIBLE`.

## EXACT_DECISION_PRICE (no es "momio_mercado IS NOT NULL")
`exact_decision_price()` exige, en `radar_odds_snapshots ⋈ agenda_espn`: bookmaker real · identidad exacta de evento
(join por espn_event_id) · market/side exactos (home/away/draw/over/under presentes según el pick) · snapshot
**pre-kickoff** (`snapshot_at < agenda.fecha`, ⇒ no live) · ts válido (≤ 3 días) · overround sano `1.0–1.25`
(no fantasma/interpolado). Medido en vivo: **40** filas ML tienen EXACT_DECISION_PRICE=true (gate discriminante, no trivial).

## GATE_BY_GATE_TESTS (12/12 PASS, controlado)
Con registry ALLOW para (TEST,Moneyline,motor_test,c1) y contexto que pasa TODO:
| test | resultado |
|---|---|
| todos los gates true | eligible=TRUE, reason=ELIGIBLE ✓ |
| skill=false | $0 ✓ | empirical=false | $0 ✓ | semantic=false | $0 ✓ | data=false | $0 ✓ |
| exact_decision_price=false | $0 ✓ | market_abstention=true | $0 ✓ | ev≤threshold | $0 ✓ |
| skill KEY ausente (NULL) | $0, reason=SKILL_INSUFFICIENT ✓ (NULL=FALSE) |
| provenance MISSING | reason=MODEL_VERSION_PROVENANCE_MISSING ✓ |
Sólo `registry=true + los 8 gates true` ⇒ ECONOMICALLY_ELIGIBLE=TRUE.

## REAL_VERSION_INHERITANCE_TEST (usando la provenance que consumen las superficies)
Registry ALLOW sólo para `model_version='c1'`. Mismo contexto/fuente, cambiando SÓLO el campo de provenance:
- `model_version='c1'` → eligible=TRUE.
- `model_version='c2'` (versión nueva, misma fuente) → **$0, reason=ECONOMIC_MODEL_UNAUTHORIZED**, sin tocar registry.
La función lee `p_ctx->>'model_version'` (lo que la superficie pone desde la fila), no se llama con 'c2' hardcodeado.
⇒ una versión nueva NO hereda autorización.

## UPDATED_SQL_DIFF (resumen; patch completo en el .sql)
1. `economic_model_authority` (registry con trazabilidad: reason/authorized_at/authorized_by), 0 filas ALLOW.
2. `economic_model_authorized()` (ALLOW exige version exacta).
3. `exact_decision_price()` (gate real multi-condición).
4. `economic_eligibility_v1()` (decisión canónica, 8 gates, reason_code, NULL=FALSE).
5. 5 cabezas → consumen la decisión canónica: `v_pick_canonico.es_pick`, `mejor_oportunidad_hoy` (usa es_pick),
   `favoritos_bien_pagados` (engine/motor_cache), `v_super_pick` (engine/motor_picks), `tg_filtrar_pick_del_dia` (engine).
6. POST-VERIFY en la transacción: total económico debe ser 0 bajo 0-ALLOW, si no ROLLBACK.
`model_version=NULL` en todas las cabezas (MISSING) hasta que las fuentes expongan provenance real.

## UPDATED_CONSUMER_MAP (ninguna superficie salta la decisión canónica)
- `economic_eligibility_v1` es el único juez. Llamado en: v_pick_canonico, favoritos_bien_pagados, v_super_pick, tg_filtrar_pick_del_dia.
- Consumidores que heredan vía `es_pick`: reto_picks_hoy__base (stake RETO), mejor_oportunidad_hoy, rongol_veto__base, v_oraculo_canonico, revisar_apuesta__base, analisis_completo, filtro_pick.
- Primitivas de sizing (kelly_stake/kelly_fraccion_pct/kelly_usuario) sólo se alcanzan tras la decisión canónica → sin picks, no dimensionan.

## ESTADO (medido en vivo, rolled back)
`CURRENT_AUTHORIZED_MODELS = NONE` · Soccer económicos = 0 · MLB = 0 · NFL = 0 ·
5 cabezas → ALL_ZERO=true · reason dominante = MODEL_VERSION_PROVENANCE_MISSING · exact_decision_price discriminante (40 true).
Análisis informativos siguen visibles (es_pick=false + probabilidad_pct); `stake=0`.

## ROLLBACK_PLAN
Deploy en UNA transacción; si un substring derivó → SUBSTR_NOT_FOUND → ROLLBACK (sin deploy parcial). Reversión:
restaurar las 5 definiciones desde el DEPLOY_ROLLBACK_SNAPSHOT (pg_get_*def capturado al aplicar) +
`DROP FUNCTION economic_eligibility_v1, exact_decision_price, economic_model_authorized, deporte_registry; DROP TABLE economic_model_authority;`.

## PREDEPLOY_ISS006_GATE = **PASS**
engine 12/12 · versión-inheritance real (c1→elegible, c2→$0) · exact_decision_price real (40 true) ·
5 cabezas por la decisión canónica → ALL_ZERO · provenance MISSING honrado (sin inventar version). **NO DEPLOY.**
