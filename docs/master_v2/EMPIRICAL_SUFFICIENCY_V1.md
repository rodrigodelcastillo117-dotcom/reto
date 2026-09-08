# EMPIRICAL_SUFFICIENCY_V1 — SUFICIENCIA DERIVADA, NO DECRETADA

```
EMPIRICAL_SUFFICIENCY_METHOD = bootstrap percentil del delta de Brier (2000 réplicas)
MIN_N_ARBITRARY              = FALSE
```

---

## 1. Por qué se retira "decidir n mínimo"

Un gate del tipo `n >= 50 => usar_modelo` es un umbral decretado. La pregunta real no es *"¿hay suficientes partidos?"* sino *"¿la diferencia observada sobrevive a su propia incertidumbre?"*.

`shadow-patches/evidencia/evidencia_suficiencia_v1.sql` responde a la segunda. Remuestrea con reemplazo los pares (probabilidad, resultado), calcula por réplica

```
delta = Brier(modelo) − Brier(benchmark)
```

y toma el intervalo percentil [2.5, 97.5].

- IC completamente **por debajo** de 0 → el modelo es mejor, con evidencia
- IC completamente **por encima** de 0 → el benchmark es mejor, con evidencia
- IC que **cruza** 0 → `INSUFFICIENT_EVIDENCE`

El tamaño muestral entra donde corresponde: **por el ancho del intervalo**. No hay mínimo que decretar; emerge.

Sin benchmark de mercado devuelve `NO_BENCHMARK` y **no fabrica comparación** — estado legítimo, no fallo.

## 2. Validación del método

Datos sintéticos con el mismo proceso generador y distinto n:

| n | delta | IC95 | ancho | veredicto |
|---|---|---|---|---|
| 50 | −0.008253 | [−0.018029, 0.001498] | 0.0195 | INSUFFICIENT |
| 300 | 0.001961 | [−0.002989, 0.006990] | 0.0100 | INSUFFICIENT |
| 2000 | −0.000795 | [−0.002751, 0.001077] | 0.0038 | INSUFFICIENT |

El ancho decrece ≈ 1/√n (0.0195 → 0.0038 al multiplicar n por 40; √40 ≈ 6.3, observado 5.1). Correcto.

Y el gate **está vivo**, no es código muerto: con una ventaja grande y n=3000 devuelve `SUFFICIENT / MODEL_BETTER_CI_EXCLUDES_ZERO`, `model_allowed=true`.

### Bug encontrado y corregido durante la validación

La primera versión daba **ancho de IC = 0 para todo n**. Causa: el remuestreo estaba en un `LATERAL` no correlacionado con la réplica, así que el planificador lo evaluaba una sola vez y las 2000 réplicas salían idénticas. Corregido con un producto cartesiano réplicas × n, donde `random()` se evalúa por fila de salida. La función pasó de `STABLE` a `VOLATILE`: usa `random()`, y declararla estable sería mentir sobre su contrato.

## 3. Aplicación a datos REALES

### Qué datos son confiables y cuáles no

| Fuente | Filas | Creación vs partido | Fechas de creación | Confianza |
|---|---|---|---|---|
| `v_picks_medibles` | 2 977 | **2 917 antes (98 %)**, 15 después | **109 distintas** | **ALTA — forward genuino** |
| `modelo_backtest_v2` | 61 321 | **0 antes, 61 321 después** | **1 sola** | **NULA — rerun en lote** |

`modelo_backtest_v2` se generó íntegramente en una sola fecha, con **mediana de 857 días** tras el partido, sobre partidos de 2023-07 a 2024-11. Combinado con el `CONDITIONAL_LEAK` de `predecir_mlb` (selección de caché y odds por "más reciente" sin cota), **es un rerun contaminado por construcción**. No puede usarse como evidencia.

`v_picks_medibles` es lo contrario: predicciones registradas incrementalmente antes de cada partido, a lo largo de 109 días distintos, sobre partidos de 2026-05-04 a 2026-09-08.

### Resultado sobre las predicciones confiables

```
GLOBAL  n=2977  ->  SUFFICIENT / BENCHMARK_BETTER_CI_EXCLUDES_ZERO
  Brier modelo            = 0.258472
  Brier mercado (con vig) = 0.253109
  delta                   = +0.005363          (positivo = modelo PEOR)
  IC95                    = [0.003026, 0.007845]   <- excluye el 0 por completo
```

Por liga, con n ≥ 100:

| Liga | n | delta | IC95 | veredicto |
|---|---|---|---|---|
| MLB | 2080 | +0.002440 | [−0.000040, 0.004771] | INSUFFICIENT (roza el 0) |
| Unknown | 156 | +0.011029 | [−0.000174, 0.022099] | INSUFFICIENT |

### Lectura honesta

**El mercado gana al modelo con significancia estadística sobre 2 977 predicciones registradas en vivo.** Y hay un detalle que refuerza la conclusión: el benchmark usado es `1/momio_mercado`, es decir, la implícita **con vig**. El vig penaliza al mercado (le añade Brier). **Aun handicapeado, gana.** Sin vig la diferencia sería mayor, no menor.

MLB por separado queda `INSUFFICIENT` — el IC roza el cero por el lado bueno (−0.00004), así que no se puede afirmar que MLB sea peor que el mercado, solo que no se ha demostrado que sea mejor. Es exactamente lo que `MODEL_SKILL = INSUFFICIENT` debe significar.

**Esto es evidencia empírica, no postura conservadora, de que `CURRENT_AUTHORIZED_MODELS = NONE` es la posición correcta hoy.**

### Limitaciones declaradas

- El benchmark es la implícita **con vig**; no se pudo devigar porque solo consta el momio del lado apostado. Sesga **en contra** del mercado, así que la conclusión es conservadora.
- Los 15 registros creados después del partido (0.5 %) no se excluyeron; su efecto es despreciable pero está declarado.
- El rango temporal es de ~4 meses. No cubre un ciclo completo de temporada.
- `liga` viene mayoritariamente como `MLB` o `Unknown`; la partición por liga de fútbol no es explotable con esta vista.

## 4. Qué reemplaza en el plan

La acción *"decidir el n mínimo y aplicar liga_evidencia_gate_v1"* se retira. En su lugar:

1. Alimentar `liga_evidencia_gate_v1` con `evidencia_suficiencia_v1` en vez de con un `n` decretado.
2. Para cada liga: recuperar los pares (P modelo, P mercado, resultado) desde predicciones **forward-registradas**, nunca desde reruns.
3. Donde no exista benchmark de mercado, el estado es `NO_BENCHMARK`, no un aprobado por defecto.
