# TOP_PICK_FORWARD_CAPTURE_V1 — HARDENING v2 (DESIGN + SHADOW, NO DEPLOY)

**Fecha:** 2026-09-08 · Prod solo SELECT/read-only · DDL/tests = LAB. Cierra los 6 puntos + subrequisitos.
No crea ranker, no cambia P/EV/economic authority, no autoriza modelos, no toca ISS-003/009.

```
TOP_PICK_FORWARD_CAPTURE_V1_DESIGN = PASS
READY_FOR_LAB_EXECUTION = YES
PROD_DEPLOY_AUTHORIZATION = PENDING_REVIEW
```

Idea rectora del hardening: **la predicción de récord es `v_pick_canonico` (motor canónico), no `analisis_json` (LLM).** Por eso la identidad de decisión se deriva del **contenido canónico** y el snapshot se toma en **una sola lectura** de la vista. `analisis_partidos` solo actúa como *señal de "algo pasó en este evento"*; su update NO define por sí mismo una decisión.

---

## 1. DECISION_EVENT_DEFINITION + DECISION_TIMESTAMP_SOURCE
`analisis_partidos` (columnas reales): `id, espn_event_id, analisis_json, espn_data_json, clima_json, created_at, reanalizado_prepartido, lineups_confirmadas, analisis_prepartido_json, reanalizado_at, espn_event_id_canonico`. **No hay `updated_at` ni versión.**

Clasificación de lo que dispara el trigger:
| Clase | Señal en analisis_partidos | ¿Nueva decisión? |
|---|---|---|
| PREDICTION_EMISSION | INSERT (con `analisis_json`) | Sí (si cambia el contenido canónico) |
| PREDICTION_RECOMPUTE | UPDATE que cambia `reanalizado_at`/`analisis_prepartido_json` | Sí (si cambia el contenido canónico) |
| NON_PREDICTION_UPDATE | UPDATE de `clima_json`/`espn_data_json`/`lineups_confirmadas` sin cambiar la predicción | No |
| SETTLEMENT_UPDATE | (no ocurre en esta tabla; la liquidación vive en el grading de oraculo) | No |
| UI/METADATA_UPDATE | (no aplica a esta tabla) | No |

**Definición operativa (robusta a la clasificación):** una **decisión** = un **estado distinto del contenido canónico** de `v_pick_canonico` para el evento.
```
prediction_snapshot_digest(event) = md5( string_agg ordenado sobre filas canónicas del evento de:
      market|side|line|p_decision|ev_decision|odds_decimal|es_pick|reason ) )
decision_emission_id = md5( espn_event_id || '|' || prediction_snapshot_digest )
```
- Un update **no-predictivo** ⇒ contenido canónico idéntico ⇒ **mismo `decision_emission_id`** ⇒ dedup ⇒ 0 registros nuevos.
- Un **recompute real** (cambia P/EV/odds/es_pick) ⇒ digest distinto ⇒ **nuevo `decision_emission_id`**.

`DECISION_TIMESTAMP_SOURCE`: **no** `clock_timestamp()` arbitrario. Se usa `canonical_read_at` = instante de la lectura atómica de `v_pick_canonico`, y se guarda además `source_analysis_id`=`analisis_partidos.id` y `source_analysis_kind` (emission/recompute/non_prediction) para trazabilidad. El `decision_timestamp` de récord = `canonical_read_at` (cuándo el motor tenía ese estado), estable porque la identidad la fija el contenido, no el reloj.

## 2. SNAPSHOT_ATOMICITY = PASS
- La captura lee **`v_pick_canonico` en UN solo `SELECT`** dentro de la función ⇒ todas las filas (todos los market/side + su `momio_capturado_at`) provienen de **un mismo snapshot MVCC** ⇒ atómicas entre sí.
- **No se mezclan fuentes** para los campos de predicción: P/EV/es_pick/reason/odds salen SOLO de esa lectura de `v_pick_canonico`. `analisis_json` se referencia únicamente como metadato de origen (`source_analysis_id`), nunca como fuente de P/EV.
- Correspondencia demostrable: `decision_emission_id` (hash del contenido) + `canonical_read_at` + `prediction_snapshot_hash` por fila. Si dos lecturas dan el mismo digest, es la misma decisión; si difieren, es otra. No existe el caso "análisis A + odds B + vista C" porque hay una sola lectura y una sola fuente de predicción.

## 3. REQUIRED_CANONICAL_SCHEMA_VERSION + CAPTURE_CONTRACT (sin tolerancia silenciosa)
```
REQUIRED_CANONICAL_SCHEMA_VERSION = v_pick_canonico @ ISS-009B (44 col, con es_pick_reason)
```
`eligibility_reason_code` es campo crítico ⇒ **la captura requiere que ISS-009B esté desplegado** (columna `es_pick_reason`). Orden de despliegue explícito: **ISS-009B primero, luego captura.** No se usa `to_jsonb` tolerante para campos críticos.

**CAPTURE_CONTRACT (fail-closed):** antes de capturar, `assert_capture_contract()` verifica en `information_schema` que `v_pick_canonico` expone TODAS las columnas críticas:
```
espn_event_id, mercado, pick_nombre, arranca_en, momio_capturado_at,
probabilidad_pct (P_DECISION), ev_pct (EV_DECISION), es_pick, es_pick_reason (eligibility_reason_code)
```
Si falta alguna ⇒ `CAPTURE_CONTRACT = FAIL_CLOSED`: la función NO inserta y registra `top_pick_capture_audit.status='FAILED', failure_code='CONTRACT_MISSING_FIELD:<col>'`. JSON flexible se permite **solo** para features opcionales por-deporte, siempre acompañado de `capture_schema_version` + `feature_presence_mask`.
(`P_RAW`/`model_version` no están en v_pick_canonico: se declaran **explícitamente ausentes en V1** vía `feature_presence_mask`, no se ocultan; se capturarán cuando la autoridad los exponga → `TOP_PICK_CAPTURE_V2`.)

## 4. CAPTURE_AUDIT_DESIGN — la falla no es silenciosa
Tabla `top_pick_capture_audit` (append-only): `decision_emission_id, espn_event_id, source_analysis_id, source_analysis_kind, decision_timestamp, expected_candidate_count, captured_candidate_count, excluded_count, status, failure_code, captured_at`.
Estados: `COMPLETE` (expected=captured, sin excepción) · `PARTIAL` (excluded>0 por guard temporal/contract parcial) · `FAILED` (excepción o contract fail).
```
CAPTURE_COMPLETENESS_PCT = 100 * sum(captured) FILTER(status=COMPLETE) / sum(expected)
```
**El dataset futuro solo tratará como universo completo las emisiones con `status='COMPLETE'` y `expected_candidate_count = captured_candidate_count`.** La escritura del producto (`analisis_partidos`) **sobrevive** siempre (trigger envuelto en BEGIN…EXCEPTION → audit FAILED + RETURN NEW).

## 5. DEDUP_V2 (4 casos probados en T11–T13, T6)
- **Identidad de fila:** `UNIQUE(decision_emission_id, market, side, coalesce(line,''))`.
- Misma **emisión exacta** repetida (mismo digest) ⇒ mismo `decision_emission_id` ⇒ `ON CONFLICT DO NOTHING` ⇒ **1 registro**.
- **Nueva emisión real** (mismo pick, distinto contenido) ⇒ nuevo `decision_emission_id` ⇒ **nuevo registro**.
- **Cambio real de odds/P/features** ⇒ digest cambia ⇒ nuevo `decision_emission_id` ⇒ **nuevo registro**.
- **Update UI/metadatos** ⇒ digest idéntico ⇒ mismo `decision_emission_id` ⇒ **0 registros** (y el audit no duplica la emisión).
`prediction_snapshot_hash` por fila detecta mutación/replay inconsistente (no es señal predictiva).

## 6. UNIVERSE_COMPLETENESS_DESIGN
Por emisión: `EXPECTED_MARKET_SIDE_COUNT` = filas de `v_pick_canonico` del evento en la lectura; `CAPTURED_MARKET_SIDE_COUNT` = filas insertadas o ya presentes de esa emisión; `DIFF = expected − captured − excluded`. `COMPLETE` exige `DIFF=0`.
`market_generation_status` por candidato:
- `market_not_generated` — no aparece en v_pick_canonico (el motor no lo generó) → **explícito**, no se cuenta como faltante.
- `generated_but_excluded` — está en la vista pero el guard temporal lo excluyó (event_start nulo o decisión≥evento) → `excluded_count`.
- `captured` — snapshotado.
Así se compara **ALL GENERATED CANDIDATES vs TOP SELECTED**, nunca "subset desconocido vs top".

## DISPLAY_EVENT_MODEL (append-only, event-based)
`top_pick_display`: `id, decision_emission_id, selector_version, surface, top_pick_rank, selected_as_top_pick, displayed_at`. **Sin UPDATE de "último estado"**; cada exhibición es una fila. Permite medir por separado: **generated → selected → displayed → settled**.

## SETTLEMENT_V2
`top_pick_settlement` keyed por **(espn_event_id, market, side, coalesce(line,''))** (no por evento): soporta `WIN/LOSS/PUSH/VOID` y resolución dependiente de market/side/line (spreads/totals/props). Una liquidación se relaciona por JOIN con **todos** los snapshots (varias emisiones) de esa predicción **sin modificar ninguno**. `resuelto_por` (line-specific), `closing_odds`, `clv_pct`, `settled_at`, `settlement_source`. Nunca UPDATE de `top_pick_capture`.

## STORAGE_ESTIMATE_V2 (heap + TOAST + índices + audit + settlement + display)
Universo `v_pick_canonico` ≈ 100–300 filas/evento-día; emisiones/evento ≈ 1–3 (inicial + prepartido + algún recompute real de odds). Solo emisiones con **cambio de contenido** generan filas (dedup por hash).
| Escenario | capture rows/día | heap+TOAST | índices | audit | settlement/display | **total/año** |
|---|---|---|---|---|---|---|
| LOW | ~200 | ~0.5 MB/d | +0.2 MB/d | ~0.02 MB/d | ~0.1 MB/d | **~0.3 GB** |
| EXPECTED | ~600 | ~1.6 MB/d | +0.6 MB/d | ~0.05 MB/d | ~0.3 MB/d | **~0.9 GB** |
| HIGH | ~1500 | ~4.5 MB/d | +1.5 MB/d | ~0.1 MB/d | ~0.8 MB/d | **~2.5 GB** |
`features_input_json` va a TOAST (comprimido); `feature_presence_mask` mantiene filas ligeras. Overhead de inserción: 1 SELECT indexado por `espn_event_id` + N inserts append-only sin triggers; el trigger es tolerante a fallos (no bloquea el pipeline vivo).

## TEST_PLAN_T1_T20 (LAB, branch efímero; ver `test_plan_v2.sql`)
T1 captura con decision<event · T2 ningún feature_ts>decision · T3 sin outcome en captura · T4 settlement no muta snapshot (hash pre/post idéntico; UPDATE revocado) · T5 dos decisiones legítimas distinto contenido → 2 filas · T6 duplicado idéntico → 1 fila · T7 model_version/provenance persistido (o marcado ausente en mask) · T8 P_RAW/P_DECISION/EV_DECISION exactos vs autoridad · T9 economic_eligibility exacta vs autoridad · T10 CURRENT_AUTHORIZED_MODELS sin cambios · **T11 non-prediction UPDATE → 0 captures** · **T12 identical emission replay → no duplicate** · **T13 real recompute → nuevo decision_emission_id** · **T14 expected==captured** · **T15 excepción de captura → escritura de producto sobrevive + audit FAILED** · **T16 falta campo canónico crítico → capture FAIL_CLOSED** · **T17 mixed source revisions → reject** (digest distinto entre filas del mismo id ⇒ imposible por construcción; test verifica que todas las filas de un id comparten prediction_snapshot_digest) · **T18 settlement PUSH/VOID/line-specific** · **T19 display event append-only** · **T20 completeness query reproducible**.

## UPDATED_EXACT_DIFF / UPDATED_ROLLBACK
- `ddl_top_pick_capture_v2.sql` — tablas `top_pick_capture` (+`decision_emission_id`,`prediction_snapshot_hash`,`canonical_read_at`,`source_analysis_id`,`source_analysis_kind`,`feature_presence_mask`,`market_generation_status`), `top_pick_capture_audit`, `top_pick_settlement` (keyed market/side/line), `top_pick_display`; `assert_capture_contract()`; `capture_top_pick_universe()` (contract-check + lectura atómica + digest + guards + audit); trigger tolerante en `analisis_partidos`. **REQUIERE ISS-009B (es_pick_reason).**
- `rollback_top_pick_capture_v2.sql` — DROP de trigger/funciones/4 tablas nuevas (sin CASCADE a canónicos).
- **Sin cambios** a v_pick_canonico / economic_* / oraculo_picks_tracking / triggers existentes.

## ORDEN DE DESPLIEGUE (explícito, sin acople silencioso)
1. ISS-009B desplegado (v_pick_canonico con `es_pick_reason`) — `REQUIRED_CANONICAL_SCHEMA_VERSION`.
2. LAB: aplicar `ddl_top_pick_capture_v2.sql` en branch efímero + correr `test_plan_v2.sql` (T1–T20 verdes).
3. Revisión → recién entonces `PROD_DEPLOY_AUTHORIZATION`.
Si se quisiera capturar ANTES de ISS-009B, sería un `capture_schema_version` DISTINTO (sin `eligibility_reason_code`), declarado explícitamente — no tolerancia silenciosa. **Recomendación: capturar después de ISS-009B.**

`HISTORICAL_DATA_CONTAMINATED_THROUGH = 2026-09-08`. Ventanas DEV/VALIDATION/FINAL_UNTOUCHED se fijarán tras acumular datos, sin mirar performance.
