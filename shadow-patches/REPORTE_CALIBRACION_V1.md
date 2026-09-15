# Calibration Release V1 — reporte

11-sep-2026 · `cal_v1_2026_09_11` · orden del dueño en issue #4, comentario `5640472806`

> **Esto NO es una promoción a producción.** Es el reporte que se pidió antes de
> decidir. Nada cambió todavía en las pantallas.

---

## 1. Ventanas train / test

Separadas temporalmente. El test es un **holdout que ningún ajuste vio**.

| modelo | train | test (holdout) |
|---|---|---|
| `mlb_totales_normal_v1` | 2023-05-29 → 2025-08-31 | 2025-09-01 → 2026-08-30 |
| `nfl_totales_normal_v1` | 2021-12-07 → 2025-01-31 | 2025-02-01 → 2026-02-08 |

## 2. N de eventos independientes

Un evento = **un (partido, línea)**. Un `Over 8.5` y su `Under 8.5` son el
**mismo** evento, no dos.

| modelo | eventos train | partidos train | eventos test | **partidos test** | pushes test |
|---|---|---|---|---|---|
| MLB totales | 26,183 | 3,423 | 18,293 | **2,390** | 827 |
| NFL totales | 9,341 | 950 | 2,817 | **286** | 43 |

Los PUSH se **excluyen** de Brier/LogLoss/ECE — la apuesta es nula, no es
acierto ni fallo — y se reportan aparte.

## 3. RAW vs CAL fuera de muestra

### MLB totales — 2,390 partidos independientes

| métrica | RAW | CAL (Platt) | |
|---|---|---|---|
| Brier | 0.244934 | **0.240648** | −1.75% |
| LogLoss | 0.683656 | **0.674285** | mejor |
| **ECE** | 0.061675 | **0.007949** | **−87.1%** |
| Brier de un volado | 0.250000 | | |

**Método elegido: Platt.** Gana en las tres. El ECE cae casi 8×.

### NFL totales — 286 partidos independientes

| métrica | RAW | CAL (Platt) | |
|---|---|---|---|
| Brier | **0.227486** | 0.234880 | peor |
| LogLoss | **0.646281** | 0.662206 | peor |
| ECE | **0.055334** | 0.097505 | peor |
| Brier de un volado | 0.250000 | | |

**Método elegido: identity → `P_CAL = P_RAW`.** El calibrador pierde en las tres
fuera de muestra, así que no se usa. Es la regla que fijaste, aplicada sin
forzarla.

## 4. Métodos rechazados

| modelo | método | por qué |
|---|---|---|
| NFL totales | `platt` | No le gana al RAW fuera de muestra en ninguna de las tres métricas. `P_CAL = P_RAW`. |

Parámetros ajustados (Newton-Raphson, determinista):

- MLB: `a = −0.20055355`, `b = 0.72473497`
- NFL: `a = −0.17012208`, `b = 0.67964935`

En los dos, **b < 1**: la pendiente encoge el logit hacia 0, que es la firma
matemática de un modelo sobreconfiado. Coincide con todo lo medido antes.

**No se probó isotónico.** No lo reporto como rechazado porque no lo corrí.

## 5. temporal_violations = 0

| comprobación | MLB | NFL |
|---|---|---|
| eventos de train dentro de la ventana de test | 0 | 0 |
| eventos con `feature_cutoff >= fecha_partido` | 0 | 0 |

El segundo es **0 por construcción**: lo impide el CHECK
`calib_evento_sin_fuga` en `calib_eventos`. No es una consulta que salió bien,
es una restricción que hace imposible guardar el dato malo.

**Fuga que encontré y cerré durante este trabajo:** `dispersion_totales` medía
la σ sobre *toda* la historia. Eso es un parámetro in-sample. Ahora la σ de cada
partido se estima con ventana móvil de 24 meses **sólo de partidos anteriores**
(`calib_lambda.sd_rodante`), y se descartan los 410 partidos sin suficiente
historia de residuos.

## 6. Prueba de PUSH

| tipo de línea | eventos | pushes | % | p promedio sin push | tasa real sin push |
|---|---|---|---|---|---|
| `.5` | 23,252 | **0** | 0.00% | 0.5162 | 0.4580 |
| entera | 23,252 | **2,028** | 8.72% | **0.5592** | **0.5017** |

Dos cosas:

1. En líneas `.5` el push es **imposible** y sale 0. Correcto por construcción.
2. Las probabilidades de línea entera y `.5` son **cantidades distintas**
   (0.5592 vs 0.5162). Tu regla estaba bien: calibrar un `Over 8` con evidencia
   de `Over 8.5` habría estado mal.

Comprobación de cordura del 8.72%: para σ ≈ 4.6, la masa en un entero exacto es
≈ 1/(4.6·√2π) = 8.7%. Cuadra.

Las líneas enteras usan corrección de continuidad y su `p_raw` es
`P(WIN | no PUSH)`, no `P(total > línea)` a secas.

## 7. Replay determinista

**Pregunta:** ¿recalibrar mañana cambia las predicciones de ayer?

1. Se congelaron 200 predicciones con `cal_v1_2026_09_11`.
   Huella: `4f88066940ea10c58313da519bb216ff`
2. Se recalibró con más datos (train hasta 2026-06-01, 35,642 eventos en vez de
   26,183) → `cal_v2_simulacion`. **Los parámetros sí cambiaron**:
   `b` 0.72473497 → 0.69728907.
3. Huella después: `4f88066940ea10c58313da519bb216ff` — **idéntica**.

**REPLAY OK.** El calibrador cambió y las predicciones de ayer no se movieron.

Funciona porque `predicciones_congeladas` guarda `p_raw`, `p_cal`,
`model_version` y `calibration_version` en el momento de decidir, con
`pc_antes_del_saque` impidiendo registrar una predicción después del partido.
Recalibrar crea una `calibration_version` nueva; **no toca** las filas viejas.
El replay lee, no recalcula.

## 8. Estado de los modelos

| model_version | mercado | estado | por qué |
|---|---|---|---|
| `mlb_totales_poisson_v1` | O/U | **MODEL_REJECTED** | Sobreconfiado: dice 65% y entrega 58.5% |
| `nfl_totales_poisson_v1` | O/U | **MODEL_REJECTED** | Poisson no modela puntos de NFL |
| `mlb_ml_poisson_v1` | ML | **MODEL_REJECTED** | Brier 0.25056 vs 0.25 de un volado |
| `nfl_ml_poisson_v1` | ML | **MODEL_REJECTED** | Brier 0.25514 vs 0.25 de un volado |
| `mlb_totales_normal_v1` | O/U | **CHALLENGER** | Brier 0.2406 con Platt. Modelo nuevo, no curva sobre el malo |
| `nfl_totales_normal_v1` | O/U | **CHALLENGER** | Brier 0.2275 RAW. **Sólo 286 partidos de holdout** |

## 9. Lo que NO está hecho

1. **Soccer 1X2 multiclase.** El esquema ya lo soporta (`p_raw_multi`,
   `clase_real`) pero no se ajustó. Falta.
2. **Isotónico.** No corrido.
3. **Walk-forward de varios folds.** Esto es un solo corte train/test más
   holdout. La orden pedía walk-forward *y* holdout.
4. **Fantasy** con MAE/RMSE/coverage. No empezado.
5. **Conectar `P_CAL` al camino de decisión.** Deliberadamente NO conectado:
   sigue vigente el NO-PASS y las pantallas siguen con `es_lock = false` y
   `validado_fuera_de_muestra = false`.
6. **Los 8 llamadores de `zona_realidad/2`** siguen sin migrar.

## 10. Mi lectura, para que no la tomes de mí sino de los números

**MLB**: el calibrador Platt es una mejora clara y bien medida — ECE de 0.0617 a
0.0079 sobre 2,390 partidos independientes. Pero el Brier queda en **0.2406**
contra 0.25 de un volado. Es mejor que el azar, no mucho mejor.

**NFL**: Brier RAW **0.2275** sobre un holdout que ningún ajuste vio, con σ
causal y conteo uno-por-partido — corrobora el 0.22834 que reporté antes, ahora
con la metodología que exigió el auditor. **Pero son 286 partidos.** Esa muestra
es chica para promover nada.

Ninguno de los dos está listo para que la app diga "CALIBRADO".
