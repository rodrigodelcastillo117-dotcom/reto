# TOP_PICK_FORWARD_CAPTURE_V1 — HARDENING v4 · CIERRE FINAL (DESIGN + SHADOW, NO DEPLOY)

**Fecha:** 2026-09-08 · Prod solo SELECT/read-only · DDL/tests = LAB. Cierra los 3 blockers finales.
No crea ranker, no cambia P/EV/Kelly/economic authority, no autoriza modelos, no toca ISS-003/009.
Después de V4: **FROZEN** — no hay V5/V6.

---

## BLOCKER 1 — UNIVERSO COMPLETO ESTRUCTURADO

### Cuantificación real (eventos FUTUROS; medido en prod, read-only, 2026-09-08)
Población: análisis con `generado_en` cuyo `espn_data_json.header.competitions[0].date > now()`.

| Métrica | Valor |
|---|---|
| Análisis totales con `generado_en` | 382 (100% `analysis_version='meta-v3'`) |
| Con campo `all_candidates` | **0 / 382** |
| Eventos futuros | 31 |
| **N_CANONICAL_CANDIDATES** (v_pick_canonico, 29 eventos) | **116** |
| **N_ANALYSIS_RECOMMENDED_STRUCTURED** (objeto con mercado+pick) | **34** (30 eventos) |
| **N_ANALYSIS_NO_BET_STRUCTURED** | **0** |
| **N_ANALYSIS_NO_BET_UNSTRUCTURED** (elementos `string`) | **40** |
| **N_MATCHED_CANONICAL_TO_EMISSION** (join crudo mercado+pick) | **0** |
| ↳ tras despojar prefijo display `[…]` (heurístico) | 28 / 34 (**82%**, con 6 aún sin cruzar) |
| **N_UNMATCHED_CANONICAL** | 116 (crudo) / 88 (tras strip) |
| **N_UNMATCHED_ANALYSIS** | 34 (crudo) / 6 (tras strip) |

**Causa raíz del 0-match:** el `pick` de la emisión es un **string de display**, no un side normalizado:
`"[💰 PICK DE VALOR] ML Athletics"` vs canónico `"ML Athletics"`; y el orden difiere por deporte
(`"Seattle Seahawks ML"` NFL vs `"ML <equipo>"` MLB/canónico). Reconciliación por string = **lossy**
(recupera 82% con reglas por deporte; residuales `Over 8 Carreras`, `Los Angeles Rams ML`, …).

### UNIVERSE_COVERAGE_PCT
```
estructurado con provenance / total candidatos de la emisión   = 34 / 74  = 45.9%
estructurado reconciliable / universo canónico observable       = 28 / 116 = 24.1%
```
`STRUCTURED_UNIVERSE = INCOMPLETE` hoy. Ninguna fuente tiene a la vez **provenance completa +
universo estructurado completo + atomicidad de corrida**:

| Fuente | Provenance | Universo estructurado | Run-atomic |
|---|---|---|---|
| `analisis_json.picks_recomendados[]` | ✅ (P_RAW, P_DECISION, engine, prob_source) | ❌ solo la punta (34) | ✅ |
| `analisis_json.no_bet_picks[]` | ❌ | ❌ **texto libre (40/40)** | ✅ |
| `v_pick_canonico` | parcial (gate) | ✅ 116 sides | ❌ vista viva, vocabulario drifta |

### STRUCTURED_UNIVERSE_SOURCE (decisión)
`analisis_json.all_candidates[]` — **NUEVO, emitido por el productor**. Es preferible a reconstruir
desde una vista viva (lossy, no atómica). El texto libre **NUNCA** se interpreta como market/side.

### Clasificación de procedencia (persistida en `candidate_source_type`)
```
EMISSION_GENERATED_STRUCTURED  -- all_candidates[] (ideal) o picks_recomendados[] (parcial)
CANONICAL_OBSERVED             -- v_pick_canonico (solo alineación secundaria, no universo)
ANALYSIS_TEXT_ONLY             -- no_bet_picks[] string (raw_text; fuera del dataset científico)
UNKNOWN
```

### PRODUCER_INSTRUMENTATION_REQUIRED = **YES** (aditiva, no cambia ninguna decisión)
Parche mínimo en la edge function `analizar-partido`: al terminar de puntuar, **serializar todo
candidato ya evaluado** (el motor ya los calculó) en `analisis_json.all_candidates[]`:
```
all_candidates[] = [{
  market, side, line,
  P_RAW,           -- prob del motor
  P_DECISION,      -- probabilidad_real (calibrada)
  EV_DECISION,     -- ev_estimado / ev_con_precio_real
  prob_source,     -- p.ej. "Poisson"
  odds, odds_timestamp,   -- momio_mercado / precio_sellado_at
  eligibility, reason     -- es_pick / reason_code que YA decidió el motor
}, ...]
```
- **Aditivo**: no toca P/EV/es_pick/stake ni el orden de decisión; solo escribe lo que ya existe en
  memoria del motor para cada candidato (bet y no-bet), con **side normalizado** (sin prefijo display).
- Emite además `emission_uuid` (una vez por corrida) — ver IDENTIDAD.
- Objetivo alcanzado por diseño: `ONE LOGICAL EMISSION + ALL GENERATED CANDIDATES STRUCTURED + PROVENANCE COMPLETE`.

La captura V4 **prefiere** `all_candidates[]`; si aún no existe, cae a `picks_recomendados[]` marcando
`is_full_universe=false` y auditando `STRUCTURED_UNIVERSE=INCOMPLETE`. El texto libre se registra como
`ANALYSIS_TEXT_ONLY` (auditoría/completitud), jamás como candidato estructurado.

---

## BLOCKER 2 — APPEND-ONLY REAL, SIN GUC BYPASS

**Eliminado** el patrón V3 `INSERT → UPDATE digest → GUC admin`. En V4:
1. Se calcula **antes** de insertar: `prediction_snapshot_hash` (por fila), `event_prediction_digest`
   (corrida; hash sobre hashes ORDENADOS) y `emission_hash` (contenido de la corrida). Como
   `analisis_json` es **una sola columna jsonb** (lectura atómica), el digest se computa en una
   primera pasada y las filas se escriben **completas en un único INSERT ... SELECT**.
2. `POST_INSERT_MUTATIONS = 0` — no hay ningún UPDATE ni DELETE tras el INSERT.
3. Trigger `BEFORE UPDATE OR DELETE OR TRUNCATE` en `top_pick_capture`/`top_pick_display`/
   `prediction_emission_ledger`: **RAISE EXCEPTION incondicional**. No hay bypass por GUC.
   `APPEND_ONLY_BYPASS_NORMAL_PATH = 0`.
4. Excepción administrativa: NO existe en el flujo normal. Una corrección va a
   `top_pick_capture_correction` (append-only) vía `tpc_admin_correct()` **SECURITY DEFINER, owner =
   rol explícito** (`tpc_admin`); nunca muta el snapshot. `snapshots = immutable forever`; corrección =
   fila/evento nuevo.
5. La captura corre como función normal (ya no necesita SECURITY DEFINER para saltarse el candado,
   porque no muta). El DROP TABLE del rollback LAB no dispara triggers de fila; el TRUNCATE sí queda
   bloqueado por el guard de statement.

---

## BLOCKER 3 — EMISSION LEDGER DURABLE

`prediction_emission_ledger` — **append-only, escrito en el punto productor** por el trigger
`trg_a_emission_ledger` (corre ANTES que la captura por orden alfabético de nombre). Una fila por
emisión:
```
decision_emission_id  uuid    -- IDENTIDAD (producer emission_uuid, o generada al emitir)
event_id              text
emitted_at            timestamptz   -- = generado_en
producer_version      text
engine                text
candidate_count       int
emission_hash         text    -- SHA-256 del contenido de la corrida (separado de la identidad)
created_at            timestamptz DEFAULT now()
UNIQUE (event_id, emitted_at, emission_hash)   -- idempotencia de RETRY; NO colapsa emisiones reales
```
- **Durabilidad ante reanálisis:** el trigger escribe la fila del ledger en el commit de la emisión.
  Si luego `analisis_partidos` se **sobrescribe** (reanálisis), la fila del ledger de la emisión
  anterior **persiste** (append-only + tabla independiente). Evidencia no borrable.
- **Reconciliación** `v_emission_ledger_reconciliation` = `LEDGER LEFT JOIN capture_audit`:
```
EXPECTED_EMISSIONS = filas del ledger
COMPLETE_EMISSIONS = ledger con audit status='COMPLETE'
PARTIAL_EMISSIONS  = ledger con audit status='PARTIAL'
MISSING_EMISSIONS  = ledger SIN ninguna captura/audit  -> hueco detectado
```
- **MISSED_CAPTURE_DETECTABILITY:** emisión A (captura falla) → B sobrescribe el análisis →
  el ledger conserva A → `MISSING_EMISSIONS` contiene A (T34/T35). Residual único: si el propio
  INSERT del ledger falla (best-effort, RAISE WARNING para no matar el producto), ese hueco no es
  detectable vía ledger; queda el backstop `v_top_pick_unledgered_analysis` mientras el análisis no
  se haya sobrescrito. Documentado, no oculto.

---

## IDENTIDAD — DECISION_EMISSION_ID_V4
```
V3:  decision_emission_id = md5(event | generado_en | version)      -- riesgo: colisión por
                                                                       resolución de timestamp
V4:  decision_emission_id = UUID emitido UNA vez por corrida (productor emission_uuid; si falta,
                            el trigger del ledger genera gen_random_uuid() al emitir).
     emission_hash        = SHA-256 del contenido (SEPARADO; integridad, no identidad).
```
- Identifica la **emisión**, no el contenido. Dos corridas reales con contenido idéntico ⇒ dos UUID
  ⇒ dos filas de ledger (T36). Retry de la misma corrida ⇒ dedup por `UNIQUE(event_id,emitted_at,
  emission_hash)`.
- Elimina la ambigüedad de `md5(event|ts|ver)` cuando dos corridas comparten el mismo segundo.

---

## VEREDICTO (honesto)

```
STRUCTURED_UNIVERSE   = COMPLETE_BY_DESIGN / INCOMPLETE_IN_RUNTIME
                        (hoy 45.9%; COMPLETE requiere el parche aditivo all_candidates[] en el productor)
PROVENANCE            = COMPLETE   (para los candidatos estructurados: model_name+version+P_RAW+P_DECISION)
EMISSION_LEDGER       = DURABLE    (diseñado; probable en LAB YA)
POST_INSERT_MUTATIONS = 0
APPEND_ONLY_SECURITY  = trigger incondicional (sin GUC) + corrección append-only SECURITY DEFINER/rol
MISSED_CAPTURE_DETECTABILITY = ledger LEFT JOIN audit (sobrevive overwrite)
DECISION_EMISSION_ID_V4 = UUID por corrida (identidad) + SHA-256 contenido (integridad)
```

Los **3 blockers quedan cerrados en diseño**. La **única** pieza que exige tocar el productor es el
parche aditivo `all_candidates[]` (no cambia decisiones). Por eso:

```
TOP_PICK_FORWARD_CAPTURE_V1_DESIGN = PASS            (3 blockers cerrados en diseño)
READY_FOR_LAB_EXECUTION            = YES             (ledger + captura + append-only + reconciliación probables en LAB)
STRUCTURED_UNIVERSE_RUNTIME_PASS   = BLOCKED_ON_ADDITIVE_PRODUCER_PATCH (all_candidates[])
PROD_DEPLOY_AUTHORIZATION          = PENDING_REVIEW
```

No declaro `STRUCTURED_UNIVERSE = COMPLETE` en runtime porque en prod hoy es 45.9%: sería fabricar.
Con el parche aditivo del productor aplicado y capturado, el gate de universo cierra a 100% por
construcción (all_candidates[] = universo evaluado completo, estructurado, con provenance).
