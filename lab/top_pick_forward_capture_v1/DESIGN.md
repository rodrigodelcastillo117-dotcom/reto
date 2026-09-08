# TOP_PICK_FORWARD_CAPTURE_V1 — Diseño (DESIGN + SHADOW, NO DEPLOY)

**Fecha:** 2026-09-08 · Prod investigado solo SELECT/read-only · DDL/tests = LAB/SHADOW.
**No toca ISS-003/009, no autoriza modelos, no cambia P/EV/economic authority, no crea ranker.**
Captura **observacional**: solo registra lo que las autoridades canónicas ya produjeron.

```
VEREDICTO: TOP_PICK_FORWARD_CAPTURE_V1_DESIGN = PASS
```
Se puede implementar sin crear otra autoridad (solo LEE `v_pick_canonico` + salidas de `economic_eligibility_v1`, y hace append a tablas nuevas aisladas) y la temporalidad es demostrable por fila (`arranca_en` + timestamps de features). Nada modifica P/EV/es_pick/stake ni `economic_model_authority`.

---

## CURRENT_WRITE_PATH (observado, read-only)
- Tabla de análisis: **`public.analisis_partidos`** (columna `analisis_json`, `espn_data_json`, `espn_event_id`, `espn_event_id_canonico`).
- Triggers `AFTER INSERT/UPDATE` en `analisis_partidos`:
  - `trg_sync_analisis_a_tracking` → `sync_analisis_a_tracking()` → INSERT en `oraculo_picks_tracking`.
  - `trg_auto_track_ai_pro_picks` → `track_ai_pro_picks_from_analisis()` → INSERT en `oraculo_picks_tracking`.
- Ambos iteran **solo** `analisis_json -> 'picks_recomendados'` (los picks que el LLM recomienda) ⇒ **selection bias ya presente**: no se registra el universo completo (mercados/side no recomendados, `es_pick=false`, EV negativo).
- Escriben `features_json` = el objeto `pick` del LLM (+ momio_ia/verificado/casa). **NO** escriben `features_input_json` ni `data_completeness_pct` (100% NULL, confirmado). No hay `model_version`, ni timestamps de provenance por feature, ni snapshot del universo.

## CANONICAL_CAPTURE_POINT
- **Universo completo evaluable = la vista canónica `public.v_pick_canonico`** (una fila por evento×mercado×side, con `probabilidad_pct` (P_DECISION), `ev_pct` (EV_DECISION), `es_pick` (= `economic_eligibility_v1.eligible`), `es_pick_reason` (= reason_code), `arranca_en` (event_start), `momio_mercado`/`momio_capturado_at`, `deporte`, `liga`, `home`, `away`, `casa`, `odds_source`, `calibracion_confiable`, `muestra_calibracion`, `clasificacion`, `confianza`, `zona`, `nivel_ventaja`). Es la ÚNICA superficie que ya expone TODOS los candidatos con las autoridades aplicadas.
- **Momento de decisión = escritura de `analisis_partidos`** (mismo evento que el tracker actual).
- **Punto mínimo correcto:** un trigger `AFTER INSERT/UPDATE` en `analisis_partidos` que, para `NEW.espn_event_id(_canonico)`, hace un **snapshot de TODAS las filas de `v_pick_canonico` de ese evento** y las **append**ea a la tabla de captura. No crea autoridad: solo lee `v_pick_canonico` (que ya aplica `economic_eligibility_v1`).
- Alternativa/compañera (para re-snapshots por cambio de odds/lineup sin nueva escritura de análisis): job programado que re-snapshotea eventos con juego futuro. Append-only ⇒ cada snapshot se conserva.

**Mapeo a los campos base (nombres reales, sin inventar semánticas):**
| Campo pedido | Fuente canónica |
|---|---|
| espn_event_id | `v_pick_canonico.espn_event_id` |
| event_start_timestamp / intended_game_date | `arranca_en` |
| deporte, liga, home_team, away_team | `deporte, liga, home, away` |
| market / side / line | `mercado` / `pick_nombre` / (parse de `pick_desc`) |
| sportsbook / odds_decimal / odds_captured_at / odds_source | `casa` / `momio_mercado` / `momio_capturado_at` / `odds_source` |
| P_DECISION / EV_DECISION | `probabilidad_pct` / `ev_pct` |
| economic_eligible / eligibility_reason_code / es_pick | `es_pick` / `es_pick_reason` / `es_pick` |
| calibration_status | `calibracion_confiable` (+ `muestra_calibracion`) |
| P_RAW | **no expuesto en v_pick_canonico** → NULL salvo que exista en `analisis_json`; no se fabrica |
| model_name/version/source/provenance_status | `fuente`/`odds_source` + `provenance_status` derivado de `es_pick_reason` (bajo NONE = `MODEL_VERSION_PROVENANCE_MISSING`); `model_version` real cuando exista autoridad |
| MODEL_SKILL / edge_reliability / data_readiness / data_completeness_pct | de `analisis_json`/features cuando existan; **ausencia = NULL**, no imputar |
| stake_final | **no en v_pick_canonico** (autoridad de sizing aparte); se registra solo si una autoridad canónica ya lo produjo; bajo NONE ⇒ 0/NULL, nunca fabricado |

---

## PROPOSED_SCHEMA (nuevas tablas, aisladas, append-only) — capture_schema_version = `TOP_PICK_CAPTURE_V1`

### `top_pick_capture` (PRE-EVENTO, append-only, outcome UNKNOWN)
Identidad y snapshot inmutable de lo que sabía el motor al decidir. Ver DDL en `ddl_top_pick_capture_v1.sql`.
Columnas: `decision_id uuid` (PK), `captured_at`, `decision_timestamp`, `capture_schema_version`,
identidad del evento/mercado/side/línea, event_start (`arranca_en`), deporte/liga/equipos,
odds (decimal/captured_at/source/sportsbook), provenance (model_name/version/source/provenance_status),
autoridades (`p_raw`, `p_decision`, `ev_decision`, `economic_eligible`, `eligibility_reason_code`, `es_pick`,
`model_skill`, `calibration_status`, `edge_reliability`, `data_readiness`, `data_completeness_pct`, `stake_final`),
`features_input_json jsonb`, `feature_source_timestamps jsonb`, `signal_components jsonb`, `feature_snapshot_hash text`,
`source_capture_point text` ('trigger:analisis_partidos' | 'job:resnapshot'), `is_full_universe boolean`.

### `top_pick_settlement` (POST-EVENTO, separada; nunca modifica el snapshot)
`decision_id` (FK→top_pick_capture, sin cascade destructivo), `settled_at`, `outcome` (win/loss/push/void),
`score_final`, `retorno`, `closing_odds`, `clv_pct`, `settlement_source`. 1:1 con la decisión liquidable.

### `top_pick_display` (opcional, observacional; NO determina la predicción)
`decision_id` (FK), `selected_as_top_pick boolean`, `top_pick_rank int`, `surface text`, `selector_version text`, `displayed_at`.

**Aislamiento:** tablas nuevas, sin triggers hacia autoridades, sin FKs que cascadeen a objetos canónicos. Rollback = DROP (ver §ROLLBACK).

---

## FEATURE_SCHEMA_V1
`features_input_json` contiene SOLO lo disponible a T-decisión, tomado de `v_pick_canonico`/`analisis_json` (nunca reconstruido con "JOIN latest"):
```
{ "schema": "TOP_PICK_CAPTURE_V1",
  "odds": {"decimal":..,"casa":..,"source":..,"captured_at":..},
  "canonical": {"p_decision":..,"ev_pct":..,"es_pick":..,"reason_code":..,"calibracion_confiable":..,"muestra_calibracion":..,"zona":..,"nivel_ventaja":..,"clasificacion":..,"confianza":..},
  "soccer": {"team_strength":..,"lineup_status":..,"xg_valid":..,"venue":..,"rest":..,"form":..}   // solo si existen
  "mlb":    {"sp":..,"bullpen":..,"offense":..,"park":..,"lineup":..,"rest":..}                     // solo si existen
  // NFL/NHL/NBA/Tennis: únicamente señales que realmente existan
}
```
**Ausencia se persiste como ausencia** (clave omitida o `null` + su timestamp ausente); no se inventan señales.

### FEATURE PROVENANCE — `feature_source_timestamps` (OBLIGATORIO)
```
{ "odds": "2026-09-08T03:12:00Z", "lineup": "…", "team_stats": "…", "xg": "…", "p_decision": "<decision_timestamp>" }
```
Permite demostrar por señal: `feature_timestamp <= decision_timestamp < event_start_timestamp`. Señal sin timestamp demostrable ⇒ se marca `"<feature>_ts": null` y esa señal queda `TEMPORAL_UNKNOWN` (no se usa como safe en V1).

### HASH / REPRODUCIBILIDAD
`feature_snapshot_hash = md5(canonical_json_ordenado(features_input_json ‖ p_decision ‖ ev_decision ‖ odds_decimal ‖ market ‖ side ‖ line))`.
Uso: detectar mutación accidental, snapshot duplicado, replay inconsistente. **No es señal predictiva.**

### SIGNAL AGREEMENT — capturar, no puntuar
`signal_components jsonb` guarda direcciones individuales que YA existan, p.ej. `{"model":"home","matchup":"home","lineup":"neutral","form":"away","market":"home"}`. **No** se calcula `agreement_score`/pesos/thresholds aún.

---

## TEMPORAL_GUARDS (fail-closed)
En el trigger/función de captura, ANTES de insertar cada fila:
1. `decision_timestamp < arranca_en` (evento no empezado). Si falla ⇒ **REJECT** esa fila (skip + WARNING), no se inserta.
2. Cada timestamp en `feature_source_timestamps` debe ser `<= decision_timestamp`. Si alguno es futuro ⇒ esa señal se descarta (no se persiste como safe) o se marca `TEMPORAL_UNKNOWN`; una odds/lineup/feature con ts > decisión ⇒ **no** entra como valor safe.
3. `outcome` prohibido en `top_pick_capture` (no existe la columna). Cualquier intento de escribir resultado en la captura pre-evento es imposible por diseño.
4. CHECK constraints: `decision_timestamp IS NOT NULL`, `arranca_en IS NULL OR decision_timestamp < arranca_en`, `capture_schema_version = 'TOP_PICK_CAPTURE_V1'`.
Adversarial (feature futura / odds futura / lineup futura / resultado ya conocido) ⇒ **FAIL CLOSED / REJECT** (guards 1–3).

## DEDUP_POLICY
- **Identidad de decisión:** `(espn_event_id, market, side, line, model_version, decision_timestamp)`.
- **UNIQUE** sobre `(espn_event_id, market, side, line, coalesce(model_version,''), decision_timestamp, feature_snapshot_hash)`:
  - Dos decisiones legítimas del mismo mercado con **distinto** `decision_timestamp` (cambió odds/lineup/P/EV) ⇒ **sobreviven** (append).
  - Reinserción **idéntica** (mismo ts + mismo hash) ⇒ **rechazada** (`ON CONFLICT DO NOTHING`).
- No se deduplican snapshots legítimos que representen cambios reales.

## SETTLEMENT_DESIGN
- Post-evento, un job/función de liquidación inserta en `top_pick_settlement` (append/1-por-decisión) leyendo el resultado real (marcadores/score) + closing odds + CLV.
- **Nunca** hace UPDATE de `top_pick_capture`. El snapshot pre-evento es inmutable (idealmente `REVOKE UPDATE` al rol de settlement; ver DDL).
- `outcome` vive solo aquí. Métricas se calculan por JOIN `capture ⟕ settlement`.

---

## TEST_PLAN (LAB, en branch efímero; ver `test_plan.sql`)
| Test | Verifica |
|---|---|
| T1 | captura tiene `decision_timestamp < arranca_en` (antes del evento) |
| T2 | ningún `feature_source_timestamps.*` > `decision_timestamp` |
| T3 | `top_pick_capture` no tiene columna/valor de outcome al insertar |
| T4 | settlement NO modifica el snapshot (hash pre/post idéntico; UPDATE revocado) |
| T5 | dos decisiones legítimas mismo mercado, distinto ts ⇒ 2 filas |
| T6 | duplicado idéntico (mismo ts+hash) ⇒ 1 fila (ON CONFLICT DO NOTHING) |
| T7 | `model_version`/`provenance_status` persistidos |
| T8 | `p_raw`/`p_decision`/`ev_decision` exactos vs `v_pick_canonico`/autoridad |
| T9 | `economic_eligible`/`eligibility_reason_code` exactos vs `es_pick`/`es_pick_reason` |
| T10 | `CURRENT_AUTHORIZED_MODELS` sin cambios; `economic_model_authority` intacta |
| ADV | feature/odds/lineup futura o resultado conocido ⇒ REJECT/omitido |

## STORAGE_ESTIMATE
- Universo canónico: `v_pick_canonico` ≈ 100–300 filas/día (todos los mercados/side de la cartelera). Snapshot por emisión de análisis; con re-análisis/re-snapshots ~2–4×.
- Fila base ≈ 0.4 KB + `features_input_json` ≈ 1–3 KB ⇒ ~2–3.5 KB/fila.
- Estimado: **~300–1200 filas/día × ~3 KB ≈ 1–3.5 MB/día ≈ 0.4–1.3 GB/año** (`top_pick_capture`); settlement ~0.1 KB/fila. Índices ~+30%.
- Overhead de inserción: el trigger hace 1 SELECT sobre `v_pick_canonico` filtrado por evento (índice por `espn_event_id`) + N inserts en tabla append-only sin triggers ⇒ bajo. Si el snapshot completo pesa, versionar `features_input_json` (solo claves con valor) y comprimir (TOAST lo hace) — sin sacrificar el pipeline en vivo (el trigger de captura debe ser tolerante: en error hace WARNING y RETURN, nunca aborta la escritura de `analisis_partidos`).

## EXACT_DIFF
Todo aditivo y aislado (archivos en este directorio, **NO ejecutados**):
- `ddl_top_pick_capture_v1.sql` — `CREATE TABLE top_pick_capture`, `top_pick_settlement`, `top_pick_display`; índices; UNIQUE de dedup; CHECKs temporales; función `capture_top_pick_universe()` (SECURITY DEFINER, SELECT de v_pick_canonico → INSERT append-only con guards); trigger `AFTER INSERT/UPDATE ON analisis_partidos` que la invoca de forma tolerante a fallos.
- `rollback_top_pick_capture_v1.sql` — DROP de trigger, función y 3 tablas (seguro: objetos nuevos, sin dependientes canónicos).
- **Sin cambios** a `v_pick_canonico`, `economic_*`, `oraculo_picks_tracking`, ni a los triggers existentes.

## ROLLBACK_PLAN
`DROP TRIGGER trg_top_pick_capture ON public.analisis_partidos; DROP FUNCTION capture_top_pick_universe(); DROP TABLE top_pick_display, top_pick_settlement, top_pick_capture;`
Seguro y completo: las 3 tablas y la función/trigger son nuevas y no tienen dependientes canónicos (nada las referencia). No hay `DROP CASCADE` sobre objetos existentes.

## FORWARD HOLDOUT
```
HISTORICAL_DATA_CONTAMINATED_THROUGH = 2026-09-08
```
La captura marcará `captured_at`; las ventanas DEVELOPMENT / VALIDATION / FINAL_UNTOUCHED se definirán **después** de acumular datos, sin mirar performance. FINAL_UNTOUCHED deberá empezar tras el freeze de este diseño y del primer despliegue de captura.

## NO TOCAR AUTORIDAD ECONÓMICA / RANKER
La captura no autoriza modelos, no modifica `es_pick`/P/EV, no calcula Kelly ni stake, no crea ranker. Solo registra. `CURRENT_AUTHORIZED_MODELS=NONE` y MLB `stake=$0` se mantienen; ISS-003/009 intacto.
