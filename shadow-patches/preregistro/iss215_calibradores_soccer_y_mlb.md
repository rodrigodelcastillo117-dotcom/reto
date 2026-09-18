# ISS215 — Preregistro: calibradores de `soccer_canonical_v2` y `mlb_one_brain_v2`

Escrito y commiteado **antes** de correr la prueba. Una sola corrida. Una sola
hipótesis primaria por deporte. Sin re-rebanar.

Instrucción del dueño, literal: *"No insertes ninguna fila para encender picks."*
Este preregistro no enciende nada. Define cuándo se podría, y con qué prueba.

## 0. Qué es lo que se calibra, exactamente

| deporte | model_version a calibrar | mercado | salida cruda |
|---|---|---|---|
| soccer | `soccer_canonical_v2` | 1X2 (3 clases) | `p_home, p_draw, p_away` de `v2.soccer_prediction_v2` |
| baseball | `mlb_one_brain_v2` | Moneyline (2 clases) | `p_home, p_away` de `v2.mlb_learning_snapshot` |

`calibration_version` sigue **nula** para ambos hasta que esta prueba pase.
Medido: en `public.calibradores` no existe hoy **ninguna** fila para estos dos
`model_version`. Las 18 filas que hay son de `mlb_totales_normal_v1`,
`soccer_1x2_poisson_v1` y `nfl_totales_normal_v1`, y ninguna tiene
`apto_para_lock=true`.

## 1. Fuente de la muestra, y por qué no cualquier tabla sirve

La muestra tiene que ser la del **cerebro autorizado**, capturada **antes** del
evento. Dos tablas que parecían servir y no sirven:

- `public.predicciones_modelo` (1,560 soccer + 540 baseball ya calificados,
  42 y 43 días, todos con `capturado_at < kickoff`). **No sirve.** La escribe
  `capturar_predicciones(12)` desde `predecir_partido()`, que enruta a
  `predecir_mlb()` (el motor `mlb_runtime_*`, declarado RETADOR_DECLARADO) y a
  `construir_dossier_partido()->prediccion_propia` (un Poisson propio sobre
  `ratings_espn` / `ligamx_partidos`). Ninguno de los dos es el cerebro
  autorizado. Esas probabilidades no pueden calibrar a otro modelo.
- La etiqueta anterior `crossleague_v1` (179 eventos jugados). **No se puede
  agrupar.** `v2.modelo_linaje` ya midió el parecido sobre los 159 partidos con
  predicción bajo las dos etiquetas: 91 idénticas dentro de 0.05 pp, pero
  **68 cambiaron** y una cambió **16.3 pp**. Un calibrador ajustado sobre la
  salida vieja se aplicaría a números distintos.

Fuentes válidas, entonces:

- soccer: `v2.soccer_prediction_v2` donde `model_version='soccer_canonical_v2'`
  y `temporal_safe` y `computed_at < kickoff`.
- baseball: `v2.mlb_learning_snapshot` donde `model_version='mlb_one_brain_v2'`
  y `temporal_safe` y `captured_at < kickoff`.

Una predicción por evento: la **última** anterior al saque (`DISTINCT ON
(espn_event_id) ... ORDER BY computed_at DESC`), que es la misma regla de corte
que usa la vista de publicación y la que `feature_asof_de_pick` ya espeja.

## 2. Umbral de muestra mínima (criterio de bloqueo, fijado ANTES)

Un calibrador ajustado con poca muestra no calibra: memoriza. El umbral se fija
por número de parámetros del método, no por lo que haya disponible hoy.

| deporte | método | params | n_fit mínimo | n_oos mínimo | n total mínimo |
|---|---|---|---|---|---|
| soccer | vector scaling (3 escalas + 3 sesgos) | 6 | **300** eventos jugados | **150** eventos jugados | **450** |
| baseball | Platt (1 escala + 1 sesgo) | 2 | **200** eventos jugados | **100** eventos jugados | **300** |

Además, en los dos casos:
- la ventana de OOS es **estrictamente posterior** en el tiempo a la de ajuste
  (corte temporal, no aleatorio);
- todos los eventos de las dos ventanas tienen que venir de **la misma**
  `model_version`, sin reconstrucción del motor en medio;
- cada evento entra **una sola vez**.

**Si no se llega al umbral, la prueba NO se corre.** No se corre con menos y se
reporta "no concluyente": eso sería exactamente el gesto que el dueño prohibió.

## 3. Hipótesis primaria (una por deporte)

> El vector de probabilidad calibrado tiene un Brier OOS **estrictamente menor**
> que el crudo, y la diferencia pareada es significativa.

Estadístico: diferencia pareada por evento `brier_cal(i) - brier_raw(i)`, media
y **IC95 por error estándar de la media** (n ≥ 100 en todos los casos por el
umbral). Multiclase: Brier = suma sobre las clases de `(p_k - y_k)^2`.

## 4. Criterio de aceptación (fijado ANTES, los tres a la vez)

1. **Mejora**: `media(brier_cal - brier_raw) < 0` y el **límite superior del
   IC95 también < 0**. Que cruce cero es rechazo, igual que en la reproducción
   de NFL, donde el IC95 [-0.03873, +0.00088] cruzó cero y NFL quedó apagada.
2. **Calibración**: brecha máxima entre probabilidad predicha y frecuencia
   observada, por decil con ≥ 20 eventos, **≤ 5.0 pp** en OOS para el calibrado,
   y estrictamente menor que la del crudo.
3. **Sin degradación de log loss**: `logloss_cal ≤ logloss_raw` en OOS.

Si los tres se cumplen → se sella `calibration_version` con `apto_para_lock=true`
y la fila queda en `public.calibradores` con sus dos ventanas y sus métricas.

Si **cualquiera** falla → **no hay `calibration_version`**. El modelo sigue
`SIN_CALIBRATION_VERSION`. Consecuencia declarada de antemano:

- soccer: sigue publicando su probabilidad **cruda**, que es lo que hace hoy;
  no cambia nada.
- baseball: sigue **sin picks monetizables**. `v_mlb_canonical_release_authority_v1`
  ya tiene `money_authorized=false`; no se toca.

## 5. Qué se puede mostrar si NO pasa

Predicción **informativa** únicamente, y sólo si está separada explícitamente de
EV, Kelly, stake, parlay y recomendación — con la misma marca que ya lleva el
hueco de diagnóstico del editorial (`es_pick=false`, `no_decide=true`).

## 6. Lo que esta prueba NO hace

- No usa precio, ni no-vig, ni implícita, en ningún paso: ni como insumo, ni
  como objetivo, ni como criterio de aceptación.
- No agrupa etiquetas de modelo distintas.
- No mira ningún dato posterior al saque de cada evento para ajustar.
- No inserta ninguna fila en `public.calibradores` si no pasa.

## 7. Estado medido al momento de escribir esto (2026-09-18)

Se mide la muestra **disponible**, que no es un resultado de la prueba.

| deporte | model_version | eventos con predicción | eventos **ya jugados** | días de captura |
|---|---|---|---|---|
| soccer | `soccer_canonical_v2` | 318 (suma de 6 `calibration_status`) | **≤ 73** | 3 (15→18 sep) |
| baseball | `mlb_one_brain_v2` | 39 | **23** | 1 (17→18 sep) |

Contra el umbral de la sección 2:

- soccer: 73 de 450. **NO ALCANZA.**
- baseball: 23 de 300. **NO ALCANZA.**

**Veredicto preregistrado: la prueba no se corre para ninguno de los dos.**
Ambos quedan `SIN_CALIBRATION_VERSION`. MLB sigue sin picks monetizables.

El gate `public.gate_calibrador_muestra_suficiente()` mide esta tabla sola y
pasa a `LISTO` el día que se llegue al umbral, sin que nadie redefina el diseño
después de ver los datos.
