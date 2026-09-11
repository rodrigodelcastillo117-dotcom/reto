# Calibration Release V1.2 — corrección y walk-forward por temporadas

11-sep-2026 · responde a issue #4 comentario `5640702130`

> **Sigue NO-PASS.** `P_CAL` sigue desconectado, `es_lock = false`,
> `validado_fuera_de_muestra = false`. Nada cambió en las pantallas.

---

## 0. Dos errores míos en el reporte anterior, y un agujero en los datos

### (a) Las líneas `.5` tenían la probabilidad inflada

Usé la fórmula con ±0.5 para **todas** las líneas. Sólo es correcta para líneas
enteras. En una `.5` inventaba una banda de push fantasma de ~8%, y como
`p_raw = p_win/(p_win+p_loss)` dividía entre una suma **menor que 1**, las
probabilidades de línea `.5` salían **infladas**.

Se ve directo: el modelo decía `p_push = 0.0827` en líneas `.5`, donde el push
es **imposible**. Corregido: ahora da 0.0000 modelo y 0.0000 real.

**Todos los números del reporte anterior estaban contaminados por esto.** Los de
aquí son los buenos.

### (b) Los folds del reporte anterior cayeron en un agujero de datos

`historico_partidos_espn` **no tiene la temporada 2025 de MLB**: 213 juegos de
~2,430, falta el **91%**. No es filtro mío, es la fuente.

| año | juegos MLB en la base |
|---|---|
| 2023 | 2,526 |
| 2024 | 2,092 |
| **2025** | **213** ← falta el 91% |
| 2026 | 2,492 |

Por eso mis folds de fechas arbitrarias daban 7 y 0 partidos. Rehecho **por
temporada**, que es lo que estaba pedido desde el principio.

Consecuencia honesta: el "holdout 2025-09-01 → 2026-08-30" del reporte anterior
era en realidad **la temporada 2026**, con un año de hueco antes. El split sigue
siendo válido (entrenar 2023-24, probar 2026 es incluso más duro), pero yo no lo
describí así porque no lo había visto.

---

## 1. Settlement correcto — `P(win) + P(push) + P(loss) = 100%`

Tenías razón: `P(WIN | no PUSH)` sirve para **evaluar** apuestas resueltas, pero
no es la probabilidad real de ganar y no debe mostrarse sola.

`calib_eventos` ahora guarda las tres. Suma = 1.000000 en los cuatro grupos.

| deporte | tipo línea | p_push modelo | push real | **p_win incondicional** | p_raw condicional |
|---|---|---|---|---|---|
| MLB | `.5` | 0.0000 | 0.0000 | 0.5151 | 0.5151 |
| MLB | entera | 0.0819 | **0.0872** | **0.5151** | 0.5606 |
| NFL | `.5` | 0.0000 | 0.0000 | 0.5549 | 0.5549 |
| NFL | entera | 0.0262 | **0.0327** | **0.5549** | 0.5695 |

El modelo subestima un poco el push (0.0819 vs 0.0872 en MLB). Queda anotado.

La diferencia entre 0.5151 y 0.5606 en línea entera es exactamente lo que
alertaste: **enseñar sólo el condicional infla el número que ve el usuario en
4.5 puntos.**

## 2. `feature_cutoff` real, no una fecha escrita

Tenías razón: `partido − 1 día` era una fecha válida, no una prueba. Ahora se
mide el **`max(fecha)` real de los partidos que entraron a las ventanas** que
alimentaron cada predicción (`calib_lambda.data_asof_real`).

| deporte | partidos | `data_asof >= partido` | margen mínimo | margen promedio |
|---|---|---|---|---|
| MLB | 6,019 | **0** | 1.00 día | 2.00 días |
| NFL | 1,440 | **0** | 1.00 día | 3.97 días |

## 3. Walk-forward por temporadas — selección de método

El método se elige **aquí**, no en el holdout.

| fold | partidos | Brier RAW | Brier Platt | LogLoss RAW | LogLoss Platt | ECE RAW | ECE Platt | veredicto |
|---|---|---|---|---|---|---|---|---|
| MLB temp. 2024 | 1,761 | 0.249350 | **0.244171** | 0.693294 | **0.681734** | 0.084979 | **0.052707** | Platt gana |
| NFL temp. 2023 | 286 | 0.236084 | **0.229063** | 0.665446 | **0.650182** | 0.085713 | **0.029357** | Platt gana |
| NFL temp. 2024 | 288 | **0.239526** | 0.250209 | **0.674386** | 0.695259 | **0.063650** | 0.119219 | Platt **no** gana |

- **MLB → Platt.** Gana en las tres métricas. (Un solo fold utilizable: 2025 no existe.)
- **NFL → identity.** **1-1 entre temporadas.** Inconsistente, y una regla que
  funciona una temporada y falla la siguiente no es una regla. `P_CAL = P_RAW`.

## 4. Confirmación única en el holdout

### MLB — temporada 2026, 2,377 partidos independientes

| | RAW | CAL (Platt) |
|---|---|---|
| Brier | 0.242715 | **0.238846** |
| Brier de un volado | 0.250000 | |

**Bootstrap agrupado por PARTIDO** (1000 remuestreos de los promedios por
partido, no por fila):

- Mejora media de Brier: **0.003900**
- **IC95: [0.001838, 0.005914]** — no cruza cero
- 100% de los remuestreos a favor

La mejora es **estadísticamente significativa** con el cluster correcto.

### NFL — temporada 2025, 285 partidos, método identity

| | RAW |
|---|---|
| Brier | **0.227672** |
| LogLoss | 0.646662 |
| ECE | 0.054154 |
| Brier de un volado | 0.250000 |

Se confirma una sola vez, con el método ya elegido en folds anteriores.

## 5. Líneas reales — BLOQUEO, no lo puedo hacer

Tenías razón en que las grids fijas prueban la distribución del modelo, no cómo
habría funcionado en la línea real. **Pero el dato no existe:**

| deporte | partidos del backtest | con línea real histórica |
|---|---|---|
| MLB | 6,022 | **169 (2.8%)** |
| NFL | 1,443 | **0 (0.0%)** |

`radar_odds_snapshots` empieza a capturar el **2026-05-06** (MLB) y **2026-08-16**
(casi todo lo demás). El backtest cubre 2023–2026.

No lo voy a simular. Lo que sí propongo: empezar a congelar la línea real en
`predicciones_congeladas` desde hoy, y que la validación contra línea real sea
un criterio **a futuro**, no algo que finjamos tener sobre el pasado.

## 6. Métodos rechazados

| modelo | método | por qué |
|---|---|---|
| NFL totales | `platt` | 1-1 entre temporadas. Inconsistente. |

**Isotónico sigue sin correrse.** No lo reporto como rechazado.

## 7. NFL nuevo vs NFL viejo — registrado por separado

Riesgo que marcaste. Verificado en vivo:

- `modelo_version_activa('football')` = **`nfl-2026.09.2`**, opinando en 51 partidos
- Registrado en `modelo_registry` como **PRODUCCION**, con nota explícita de que
  **no** es `nfl_ml_poisson_v1` (Poisson genérico, `MODEL_REJECTED`)

Apagar uno no apaga el otro.

## 8. Estado y lo que falta

`mlb_totales_normal_v1` y `nfl_totales_normal_v1` siguen **CHALLENGER**. No
entran a LO MEJOR, LOCK, Reto13M ni Parlay del Día.

Falta: Soccer 1X2 multiclase, isotónico, Fantasy con MAE/RMSE/coverage, migrar
los 8 llamadores de `zona_realidad/2`, y conectar `P_CAL`.

## 9. Mi lectura

**MLB**: la mejora de Platt ahora sí tiene respaldo defendible — IC95 que no
cruza cero sobre 2,377 partidos independientes. Pero el Brier queda en **0.2388**
contra 0.25. Es mejor que el azar de forma medible, y sigue siendo poco.

**NFL**: Brier **0.2276** RAW en la temporada 2025, con σ causal, conteo
uno-por-partido y método elegido antes de mirar. Es el mejor número del sistema
después del fútbol. Pero son **285 partidos** y el calibrador salió 1-1 entre
temporadas — eso me dice que la señal existe pero es inestable.

Con lo que hay hoy, yo no promovería ninguno de los dos.
