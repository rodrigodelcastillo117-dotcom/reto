# UNIFIED_PICK_SURFACES_V1 — CONTRATO CANÓNICO

**Estado:** contrato diseñado, función de clasificación implementada y **testeada en runtime (12/12)**. Superficies **no migradas** (requiere inventario de consumo del frontend).

---

## 1. Inventario — 46 objetos, 42 sin gate

| Gate | Objetos |
|---|---|
| **SI** (llama `economic_eligibility_v1` o `decision_pick_v1`) | `v_pick_canonico`, `v_mejores_picks_mlb` ¹, `v_super_pick` |
| **HEREDA** (consume `v_pick_canonico` / `es_pick`) | `v_oraculo_canonico` |
| **NO** | los otros 42 |

¹ `v_mejores_picks_mlb` adquirió el gate con el deploy de ISS-003/009 V2. Antes no lo tenía.

### Subconjunto de mayor riesgo: columnas de dinero **sin** gate

| Objeto | kelly | stake | anon |
|---|---|---|---|
| `pick_del_dia` | SI | SI | SI |
| `pick_del_dia_temporada_1` | SI | SI | SI |
| `picks_temporada_1` | — | SI | SI |
| `picks` | — | SI | authenticated |
| `_backup_picks_fantasma_20260526` | — | SI | SI |
| `v_picks_premium` | SI | — | SI |
| `picks_recomendados_hoy` | SI | — | SI |
| `picks_recomendados_hoy_raw` | SI | — | SI |
| `ai_picks_historial` | SI | — | SI |
| `pick_learning_data` | SI | — | SI |

Diez objetos con forma de dinero (`kelly`/`stake`/`monto`) que **nunca pasan por la autoridad económica** y son legibles sin autenticar.

### Clasificación propuesta

| Clase | Objetos | Acción |
|---|---|---|
| **CANONICAL** | `v_pick_canonico`, `v_mejores_picks_mlb` | mantener; son la autoridad |
| **ADAPTER** | `v_oraculo_canonico`, `v_super_pick` | auditar que el gate se aplique de verdad (no solo que se mencione) |
| **DANGEROUS** | `pick_del_dia`, `pick_del_dia_temporada_1`, `picks_temporada_1`, `v_picks_premium`, `picks_recomendados_hoy`, `picks_recomendados_hoy_raw`, `nfl_picks_premium` | dinero o lenguaje de recomendación sin gate + anon |
| **DEPRECATE** | `_backup_picks_fantasma_20260526`, `picks_liga_rename_backup_20260829`, `oraculo_picks_tracking_duplicados_20260829`, `pick_debug_logs` | backup/debug/duplicados expuestos a anon |
| **LEGACY_READONLY** | `picks_huerfanos`, `picks_con_liga_inconsistente`, `v_picks_medibles`, `oraculo_*` | diagnóstico/medición; prohibir como superficie de recomendación |
| **UNKNOWN** | el resto | requiere inventario de consumo |

**No borré nada.** Sin saber qué pantalla consume cada objeto, borrar o revocar a ciegas rompe producción.

## 2. Taxonomía — implementada y testeada

`shadow-patches/unified/clasificacion_pick_v1.sql` — función pura, `STABLE`, modelada sobre `economic_eligibility_v1`.

**No contiene ni un umbral numérico inventado:**

- **VALUE_PICK** delega íntegramente en `economically_eligible`, que ya encapsula EV vs `ev_threshold` y la autorización del modelo.
- **MOST_LIKELY** usa un criterio **relativo** — ser el lado de mayor `P_DECISION` dentro de su propio mercado — no un `P > 60 %` arbitrario.
- **TOP_PICK** exige la conjunción de `economically_eligible` + `accuracy_evidence='SUFFICIENT'` + `calibration_status='VALIDATED'` + `data_readiness='READY'` + `model_skill='SKILL_PASS'` + `exact_decision_price`. Hoy es **inalcanzable por construcción** porque no existe evidencia forward.

Salida: `{classification, reason_code, authorized_bet, gates{9}}`.

`authorized_bet` es la **única** llave que el frontend debe consultar para decidir si puede hablar de apostar. Solo `TOP_PICK` y `VALUE_PICK` la ponen en `true`.

### Tests — `evaluated_rows=12 · violations=0 · coverage_status=PASS_NONEMPTY`

| Test | Qué prueba | Resultado |
|---|---|---|
| T1 | ctx vacío → ANALYSIS, `authorized_bet=false` | PASS |
| T2 | `economically_eligible=NULL` → no autoriza | PASS |
| T3 | llave ausente (undefined) → no autoriza | PASS |
| **T4** | **P de mercado con TODOS los gates forzados → ANALYSIS** (caso NFL) | **PASS** |
| T5 | elegible → VALUE_PICK, `authorized_bet=true` | PASS |
| **T6** | **"MUY PROBABLE PERO MAL PRECIO" → MOST_LIKELY sin autorizar** | **PASS** |
| T7 | sin accuracy/calibration → NO es TOP_PICK | PASS |
| T8 | con evidencia completa → SÍ es TOP_PICK (gate vivo, no código muerto) | PASS |
| T9 | `data_readiness=INSUFFICIENT` → ANALYSIS | PASS |
| T10 | `data_readiness=STALE` → ANALYSIS | PASS |
| T11 | valor no booleano en elegible → no autoriza | PASS |
| **T12** | **lado no dominante → ANALYSIS** (impide 2 picks por moneyline) | **PASS** |

T4 y T12 son los que cierran estructuralmente los dos defectos de NFL: probabilidad de casa presentada como propia, y ambos lados como picks.

## 3. Contrato de fila canónica

Estructura única, reutilizable por todos los deportes. **Ningún consumidor recalcula P, EV ni Kelly.**

```
event_id · sport · league · market · side · line
P_RAW · P_DECISION · P_MARKET · prob_source · model_version
EV_DECISION
MODEL_SKILL · ACCURACY_EVIDENCE · DATA_READINESS
ECONOMIC_AUTHORIZED · ECONOMICALLY_ELIGIBLE · ELIGIBILITY_REASON_CODE
kelly_base · risk_multiplier · stake_pre_portfolio · stake_final
classification · authorized_bet
generated_at · decision_time · odds_timestamp
```

`prob_source` ∈ `MODEL` · `MARKET_NO_VIG` · `DERIVED_MARKET` · `HISTORICAL` · `UNKNOWN`.
Con cualquier valor distinto de `MODEL`, la clasificación **no puede** superar `ANALYSIS`.

## 4. Cadena de dinero

```
P_RAW → P_DECISION → EV_DECISION → kelly_base
      → confidence/data_readiness → risk_multiplier
      → stake_pre_portfolio → portfolio constraints → STAKE_FINAL
```

Regla que se preserva: **la incertidumbre reduce exposición, no deforma P.** `P_DECISION` nunca se ajusta para "representar" incertidumbre; esta entra por `risk_multiplier`.

## 5. Contrato frontend — fail-closed

```js
// ÚNICA condición válida para hablar de apostar
const puedeApostar = row.authorized_bet === true;

// PROHIBIDO inferir pick de:
//   markets.length > 0 · EV > 0 · P > 50 · Kelly calculable · momio disponible
```

`false`, `null` y `undefined` se tratan **igual**: informativo.

### Copy — incompatibilidades prohibidas

Si `authorized_bet !== true`, **ninguna** de estas cadenas puede aparecer para ese mercado:

`PICK SUGERIDO` · `PICK PREMIUM` · `APOSTAR` · `FUERTE` · `OJO` · `AGUANTA` · `RECOMENDADO`

Vocabulario correcto por clase:

| Clase | Encabezado | Puede decir | No puede decir |
|---|---|---|---|
| `ANALYSIS` | "Análisis" | prob, EV, mercado | nada de apuesta |
| `MOST_LIKELY` | "Más probable" | "muy probable — mal precio" | "apuesta", "pick" |
| `VALUE_PICK` | "Valor" | "valor detectado", sizing | "seguro", "garantizado" |
| `TOP_PICK` | "Top Pick" | recomendación plena | — |

## 6. Migración — U0…U3 (no ejecutada)

**U0 — inventario de consumo.** Qué pantalla consume cada uno de los 46 objetos. **Bloqueante:** el frontend no está en este repo.
**U1 — retirar DEPRECATE** (backup/debug/duplicados expuestos a anon). Es un `REVOKE`, no cambia contratos.
**U2 — migrar DANGEROUS**: añadir `economically_eligible` + `reason_code` + `classification` **al final** del SELECT, con asserts ordinales tipo ISS-003/009 V2.
**U3 — contrato frontend fail-closed** y limpieza de copy.

**Por qué no ejecuté U1–U3:** cambiar el contrato de una vista sin verificación ordinal ya rompió un deploy esta semana. Hacerlo sobre 7 vistas DANGEROUS sin saber qué las consume, y con deploy prohibido, sería repetir el error a mayor escala.
