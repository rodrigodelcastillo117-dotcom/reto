# MLB — MATCHDAY READINESS

**Semáforo: 🟡 YELLOW — usable como motor de análisis, fail-closed económicamente. Condicionado a desplegar ISS-003/009 V2.**

Evidencia read-only (`BEGIN READ ONLY`, `transaction_read_only=on` verificado). Sin DDL/DML.

---

## 1. Estado científico (sin cambios)

```
MODEL_SKILL              = INSUFFICIENT
ECONOMIC_AUTHORITY       = FALSE
STAKE                    = 0
CURRENT_AUTHORIZED_MODELS= NONE
```

Verificado en producción: `economic_model_authority` tiene **0 filas totales** (no solo 0 autorizadas — la tabla está vacía). El gate `economic_eligibility_v1` devuelve `eligible=false` con `MODEL_VERSION_PROVENANCE_MISSING` para el contexto MLB real.

**Sonda adversarial (H4):** forzando `model_version='v99.9'` **y** `model_skill='SKILL_PASS'` y todos los gates en verde, el resultado sigue siendo `eligible=false` con `ECONOMIC_MODEL_UNAUTHORIZED`. El cierre económico no depende del `model_skill` que declare la superficie: depende del registro vacío. Esa es la garantía fuerte.

## 2. Cobertura de mañana

| Métrica | Valor |
|---|---|
| Eventos MLB en agenda (72 h) | 35 |
| Con odds | **14** |
| Sin odds | **21** |
| Filas en `v_pick_canonico` | 140 |
| `es_pick = true` | 0 ✅ |

**21 de 35 partidos no tienen odds.** Sin precio no hay EV ni valor: esos partidos solo pueden mostrarse como análisis sin componente económico.

## 3. El bug ISS-003a está vivo en producción ahora mismo

```
MLB en v_pick_canonico: 140 filas
calibracion_confiable = TRUE en 140/140
```

Hoy la app afirma que **toda** la MLB está "bien calibrada". Esa afirmación no está respaldada: `MODEL_SKILL = INSUFFICIENT`. Es exactamente el hardcode `true AS bool` que la Parte 1 de ISS-003/009 corrige a `false`.

**Mientras V2 no se despliegue, cualquier copy tipo "bien calibrado" en MLB es incorrecto.** Es el argumento más fuerte para desplegar V2 mañana.

El assert **I1** del wrapper V2 mide esto con cobertura sustantiva real (140 filas): post-deploy debe ser 0/140.

## 4. ISS-009 — visibilidad

Pre-deploy observado: `v_mejores_picks_mlb` con `nivel IN ('ojo','fuerte')` = **3 filas** (dinámico por cartelera; el runbook V1 registró 5 otro día). Post-V2 deben degradarse a `informativo` con `economically_eligible=false` y `reason_code='MODEL_VERSION_PROVENANCE_MISSING'`, sin desaparecer (asserts G1–G4).

## 5. Riesgos de datos no cerrados

Auditados a nivel de esquema; **no verificados empíricamente esta noche** (requieren series históricas):

| Riesgo | Estado |
|---|---|
| Latest-snapshot leakage en stats de bateo/pitcheo | ⚠️ NO VERIFICADO |
| Timestamp de confirmación de pitcher abridor | ⚠️ NO VERIFICADO |
| Stats posteriores al partido en features AS-OF | ⚠️ NO VERIFICADO |
| Partidos duplicados / home-away invertido | ⚠️ NO VERIFICADO |
| Odds stale | Parcial: snapshot global fresco (04:21Z), pero 21/35 sin odds |

No los marco como PASS. Requieren un test temporal dedicado con histórico, que no cabía esta noche sin comprometer las fases previas.

## 6. Qué se puede usar mañana

**Se puede:** MLB como motor de análisis — probabilidad del modelo con procedencia (`motor_mlb_cuantitativo`), EV, ventaja, mercado. Etiquetado como informativo.

**No se puede:** presentar MLB como apuesta autorizada, mostrar sizing/stake, ni afirmar "bien calibrado" (falso hasta que V2 despliegue).

## 7. Acción recomendada

1. **Desplegar ISS-003/009 V2** (validado en lab: T1–T7 PASS). Es lo que corrige el "bien calibrado" falso y degrada las 3 filas ojo/fuerte.
2. Revisar copy MLB en la UI: eliminar "aguanta", "fuerte", "pick" para mercados no elegibles.
3. Investigar los 21 partidos sin odds antes del primer horario (22:35Z).
