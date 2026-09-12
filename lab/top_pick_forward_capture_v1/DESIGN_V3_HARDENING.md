# TOP_PICK_FORWARD_CAPTURE_V1 — HARDENING v3 (DESIGN + SHADOW, NO DEPLOY)

**Fecha:** 2026-09-08 · Prod solo SELECT/read-only · DDL/tests = LAB. Cierra los 10 blockers V3.
No crea ranker, no cambia P/EV/Kelly/economic authority, no autoriza modelos, no toca ISS-003/009.

```
TOP_PICK_FORWARD_CAPTURE_V1_DESIGN = PASS
READY_FOR_LAB_EXECUTION = YES
PROD_DEPLOY_AUTHORIZATION = PENDING_REVIEW
```

## Cambio rector de V3 (evidencia nueva)
La **emisión real** de la predicción NO es el trigger de DB; es el generador `analizar-partido` materializado en `public.analisis_partidos.analisis_json`, que **ya estampa provenance**:
- `generado_en` (100% de las filas) = **timestamp de emisión real**.
- `analysis_version` = `"meta-v3"` (100%) + `pick_engine_used`/`pick_engine_mode`/`pick_engine_stats` = **versión del productor**.
- Por pick: `prob` (**P_RAW**) + `prob_source` (p.ej. "Poisson" = modelo) · `probabilidad_real` (**P_DECISION**) — distintos en 51% (271/530) ⇒ autoridades reales separadas · `ev_estimado`/`ev_con_precio_real` · `momio_mercado`/`momio_justo` · `clasificacion` · `precio_sellado_at` · `odds_source`/`odds_verificadas`.
- Context features top-level: `forma_local/visitante`, `lesiones`, `h2h_resumen`, `goles_esperados`, `fatiga_viaje`, `momentum`, `estadio`, `clima`, `probabilidades`.

Por eso la captura PRIMARIA se toma de `analisis_json` (una corrida = un `generado_en`), no de `v_pick_canonico`.

---

## 1. DECISION_ID_SOURCE + prediction_snapshot_hash (separados)
```
decision_emission_id = md5( espn_event_id || '|' || generado_en || '|' || analysis_version )   -- identidad de CORRIDA
prediction_snapshot_hash = sha256( jsonb canónico del contenido del pick )                     -- identidad de CONTENIDO
```
- 10:00 P=0.62 y 13:00 P=0.62 ⇒ `generado_en` distinto ⇒ **decision_emission_id distinto** ⇒ 2 capturas (aunque el contenido/hash coincida). **Bug conceptual resuelto.**
- Reintento de la MISMA corrida (mismo `generado_en`, el trigger vuelve a disparar) ⇒ mismo `decision_emission_id` ⇒ dedup.
- `prediction_snapshot_hash` sirve para integridad/replay, no para identidad de corrida.

## 2. DECISION_TIMESTAMP_SOURCE ≠ captured_at
```
decision_timestamp = (analisis_json ->> 'generado_en')::timestamptz   -- del PRODUCTOR
captured_at        = now()                                            -- del OBSERVADOR (trigger)
```
Se persisten por separado. `decision_timestamp` viene del proceso que generó la predicción, no del consumidor. **No se usa `clock_timestamp()` del trigger como decision_timestamp.**
`TRUE_DECISION_EMISSION_POINT` = edge function `analizar-partido` → `analisis_partidos.analisis_json` (`generado_en`,`analysis_version`). No requiere nueva instrumentación forward: ya existe. (Si en el futuro se moviera la generación, esos dos campos son el contrato mínimo a preservar.)

## 3. DB_SNAPSHOT_CONSISTENCY vs LOGICAL_RUN_ATOMICITY
Las fuentes que alimentan la predicción pueden actualizarse independientemente (odds vía `radar_odds_snapshots`, stats, lineup, LLM). Por eso:
- **Captura PRIMARIA desde `analisis_json`** ⇒ **LOGICAL_RUN_ATOMICITY = PASS** para los campos de esa corrida (P_RAW, P_DECISION, EV, odds sellada `precio_sellado_at`, model/engine, features) — todos comparten `generado_en`.
- **Gate económico** (`es_pick`,`eligibility_reason_code`,`ev_pct` canónico) se toma de `v_pick_canonico` como **alineación SECUNDARIA**, con su **propio** `canonical_read_at` y `canonical_alignment_status` (MATCHED/DRIFTED/MISSING por join event+market+side). No se funde con la corrida: se marca su procedencia y tiempo aparte.
```
DB_SNAPSHOT_CONSISTENCY = PASS      (cada lectura es un snapshot MVCC)
LOGICAL_RUN_ATOMICITY   = PASS      (para el registro primario analisis_json)
                        = PARTIAL   (para el gate canónico secundario: puede haber drift de odds vs la corrida)
```
Se persiste `source_snapshot_timestamps = {analisis:generado_en, precio_sellado:precio_sellado_at, canonical:canonical_read_at}` para probar procedencia.

## 4. PROVENANCE_COMPLETE_CONTRACT (model_version y P_RAW obligatorios)
`MODEL_VERSION_SOURCE = analysis_version (meta-v3) + pick_engine_used/mode`; `P_RAW_SOURCE = pick.prob`; `P_DECISION = pick.probabilidad_real`; `model_name = pick_engine_used`; `prob_source = pick.prob_source`.
```
PROVENANCE_COMPLETE = (model_name IS NOT NULL AND model_version IS NOT NULL
                       AND p_raw IS NOT NULL AND p_decision IS NOT NULL)
```
Una fila con `PROVENANCE_COMPLETE=FALSE` **no** entra al dataset científico principal (se marca, no se descarta del log). No se recalcula ni se infiere: si el productor no lo emitió, queda FALSE.

## 5. HASH_V3 (determinístico, SHA-256 vía pgcrypto)
`pgcrypto` está disponible (`digest(...,'sha256')`). Hash sobre representación canónica explícita (no concat ambiguo):
```
prediction_snapshot_hash = encode(digest( convert_to(
   jsonb_build_object('market',market,'side',side,'line',normalized_line,
     'p_raw',p_raw,'p_decision',p_decision,'ev',ev_decision,'odds',odds_decimal,'model_version',model_version)::text,
   'UTF8'),'sha256'),'hex')
event_prediction_digest = sha256 sobre array de picks ORDENADO por (market,side,normalized_line) -> orden de filas irrelevante.
```
Tests HASH_V3: mismo contenido→mismo hash; distinto orden de filas→mismo digest; cambio P/odds/line→hash distinto.

## 6. line NULL — DEDUP_V3
`normalized_line = coalesce(nullif(btrim(line),''),'∅')` + **UNIQUE ... NULLS NOT DISTINCT** (PG 17.6 lo soporta):
```
UNIQUE NULLS NOT DISTINCT (decision_emission_id, market, side, normalized_line)
```
Doble candado: la línea normalizada nunca es NULL ('∅' para Moneyline) **y** NULLS NOT DISTINCT. Test **T26/T12**: ML con `line=NULL` no permite duplicados.

## 7. APPEND_ONLY_ENFORCEMENT (real, no documental)
Trigger `BEFORE UPDATE OR DELETE` en `top_pick_capture` y `top_pick_display` que **RAISE EXCEPTION** salvo que la sesión declare rol admin explícito (`SET LOCAL app.allow_admin_mutation='on'`). `top_pick_settlement` permanece separada (INSERT/UPDATE permitido allí). Tests T27: UPDATE/DELETE snapshot ⇒ REJECT; settlement INSERT ⇒ OK.

## 8. CAPTURE_AUDIT_FAILURE_ISOLATION
- La captura se envuelve en `BEGIN…EXCEPTION` en el trigger ⇒ una falla NO tumba `analisis_partidos`.
- **Además**, la escritura del audit se envuelve en su **propio** `BEGIN…EXCEPTION` anidado ⇒ si falla el audit, tampoco propaga.
- Detección de huecos: vista `v_top_pick_capture_health` (por día): `COMPLETE_EMISSIONS`, `PARTIAL_EMISSIONS`, `FAILED_EMISSIONS`, `CAPTURE_FAILURE_RATE = failed/(complete+partial+failed)`. Además, un chequeo de huecos = análisis con `generado_en` sin fila de audit correspondiente (emisiones perdidas).

## 9. REQUIRED_CANONICAL_SCHEMA_VERSION (contrato explícito de versión)
```
REQUIRED_PRODUCER_SCHEMA = analisis_json.analysis_version = 'meta-v3'
REQUIRED_CANONICAL_SCHEMA = v_pick_canonico @ ISS-009B (columna es_pick_reason presente)  # para el gate secundario
```
`assert_capture_contract()` verifica: (a) columnas/typos de `analisis_json` esperados (generado_en, analysis_version, picks_recomendados; por pick prob, probabilidad_real, mercado, pick); (b) `analysis_version` ∈ conjunto soportado {'meta-v3'} — si aparece otra versión ⇒ status `PARTIAL`+`failure_code=UNSUPPORTED_PRODUCER_VERSION:<v>` (no se interpreta silenciosamente); (c) para el gate secundario, `es_pick_reason` presente en v_pick_canonico. Despliegue **después** de ISS-003/009; sin acople silencioso a estados intermedios.

## Campos base (mapeo real)
| Campo | Fuente |
|---|---|
| decision_emission_id / decision_timestamp | md5(event‖generado_en‖analysis_version) / `generado_en` |
| captured_at | now() |
| model_name / model_version / prob_source | `pick_engine_used` / `analysis_version`(+mode) / pick `prob_source` |
| P_RAW / P_DECISION / EV_DECISION | `prob` / `probabilidad_real` / `ev_estimado`(ev_con_precio_real) |
| market / side / line / normalized_line | `mercado` / parse(`pick`) / parse(`pick`) / coalesce(…, '∅') |
| odds_decimal / odds_captured_at | `momio_mercado` / `precio_sellado_at` |
| event_start_timestamp | `espn_data_json.header.competitions[0].date` (misma fila/corrida) |
| economic_eligible / eligibility_reason_code (2ª) | `v_pick_canonico.es_pick` / `es_pick_reason` (con canonical_read_at + alignment) |
| features_input_json | subset de analisis_json context (forma/lesiones/h2h/goles_esperados/…); ausencia = ausencia |
| feature_presence_mask | {p_raw:true, model_version:true, lineup:?, xg:?, …} |
| provenance_complete | contrato §4 |

## STORAGE_ESTIMATE_V3
Universo primario = candidatos por corrida ≈ 3.8/evento (reco+no_bet estructurados); emisiones/evento ≈ 1–3. Mucho menor que v_pick_canonico completo.
| Escenario | rows/día | heap+TOAST+idx | audit+settle+display | **GB/año** |
|---|---|---|---|---|
| LOW | ~60 | ~0.2 MB/d | ~0.05 MB/d | **~0.09 GB** |
| EXPECTED | ~200 | ~0.7 MB/d | ~0.15 MB/d | **~0.3 GB** |
| HIGH | ~600 | ~2.0 MB/d | ~0.4 MB/d | **~0.9 GB** |
(Si además se captura el universo completo de v_pick_canonico como snapshot secundario de cobertura: +0.4–1.3 GB/año, opcional y marcado PROVENANCE_COMPLETE=FALSE.)

## TEST_PLAN_T1_T28 (ver `test_plan_v3.sql`)
T1–T10 (v2) + T11 non-prediction UPDATE→0 · T12 replay→no dup · T13 recompute real→nuevo id · T14 expected==captured · T15 excepción captura→producto sobrevive+audit FAILED · T16 falta campo crítico→FAIL_CLOSED · T17 mixed revisions→PARTIAL/reject · T18 settlement PUSH/VOID/line-specific · T19 display append-only · T20 completeness reproducible · **T21 recompute real mismo contenido→NUEVA emisión (distinto generado_en)** · **T22 retry misma emisión→no dup** · **T23 decision_timestamp≠captured_at preservado** · **T24 mixed logical source revisions→PARTIAL/REJECT por contrato** · **T25 missing model_version→provenance_complete=false** · **T26 ML line=NULL dup protection** · **T27 UPDATE/DELETE snapshot→rejected; settlement insert OK** · **T28 audit-write failure no rompe product write**.

## UPDATED_DDL_V3 / UPDATED_ROLLBACK_V3
- `ddl_top_pick_capture_v3.sql` — captura PRIMARIA desde `analisis_json` (con generado_en/analysis_version/prob/probabilidad_real/engine + gate canónico secundario), SHA-256, NULLS NOT DISTINCT, append-only enforcement, audit con aislamiento anidado, provenance_complete, health view. **REQUIERE `analysis_version='meta-v3'` y (para gate) ISS-009B.**
- `rollback_top_pick_capture_v3.sql` — DROP de triggers/funciones/tablas/vista nuevas (sin CASCADE a canónicos).
- **Sin cambios** a analisis_partidos/v_pick_canonico/economic_*/oraculo_picks_tracking ni triggers existentes.

`HISTORICAL_DATA_CONTAMINATED_THROUGH = 2026-09-08`. Ventanas DEV/VALIDATION/FINAL_UNTOUCHED tras acumular datos, sin mirar performance.

## ENTREGA (resumen de estados)
```
TRUE_DECISION_EMISSION_POINT     = analizar-partido → analisis_partidos.analisis_json (generado_en, analysis_version)
DECISION_ID_SOURCE               = md5(event‖generado_en‖analysis_version)  (identidad de corrida, ≠ contenido)
DECISION_TIMESTAMP_SOURCE        = analisis_json.generado_en  (≠ captured_at)
DB_SNAPSHOT_CONSISTENCY          = PASS
LOGICAL_RUN_ATOMICITY            = PASS (primario) / PARTIAL (gate canónico secundario, con timestamps)
PROVENANCE_COMPLETE_CONTRACT     = model_name+model_version+P_RAW+P_DECISION presentes; si no → FALSE (fuera del dataset principal)
MODEL_VERSION_SOURCE             = analysis_version(meta-v3)+pick_engine_used
P_RAW_SOURCE                     = analisis_json.picks[].prob
DEDUP_V3                         = UNIQUE NULLS NOT DISTINCT (emission_id,market,side,normalized_line) + normalized_line '∅'
HASH_V3                          = SHA-256 sobre jsonb canónico ordenado (pgcrypto)
APPEND_ONLY_ENFORCEMENT          = trigger BEFORE UPDATE/DELETE → REJECT (salvo admin GUC); settlement aparte
CAPTURE_AUDIT_FAILURE_ISOLATION  = doble BEGIN/EXCEPTION anidado + v_top_pick_capture_health
REQUIRED_CANONICAL_SCHEMA_VERSION= producer meta-v3 + v_pick_canonico@ISS-009B
```
