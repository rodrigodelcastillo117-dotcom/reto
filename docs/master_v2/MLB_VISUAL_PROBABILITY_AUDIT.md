# MLB — AUDITORÍA DE CONSISTENCIA VISUAL Y PROBABILÍSTICA

**Veredicto corto: los números son matemáticamente correctos. La presentación no lo es.**

Nada se cambió en producción. Sin rollback. Fix preparado en rama/lab.

---

## 1. Procedencia exacta de cada número

Trazado sobre las definiciones vivas replicadas en laboratorio fiel.

| Valor mostrado | Origen real | Distribución |
|---|---|---|
| **P(Under 8.5) = 52 %** | `predecir_mlb` → `totales_nb(λ_h+λ_a, 5.0, …)` | **Binomial Negativa (r=5)** |
| **Carreras esperadas 9.06** | `predecir_mlb` → `round(lam_h + lam_a, 2)` | media, **compartida** por ambas |
| **Marcador probable 5-4** | `predecir_mlb` → `matriz_poisson(lam_h, lam_a, …)` → `marcador_mas_probable` | **Poisson independientes** |
| momio justo 1.94 | `totales_nb` → `momio_justo_under` | NB |
| EV +0.5 % | `calcular_ev(P, cuota)` | consistente con P de NB |

`predecir_mlb` **sobreescribe** los totales de `motor_mlb`:

```sql
mtz := jsonb_set(mtz, '{totales}', totales_nb(lam_h + lam_a, 5.0, …
-- comentario del propio código:
-- "Brier 0.22420 contra 0.23199 del Poisson. En linea 6.5 el error era de 12 puntos."
```

El cambio a NB **está justificado y medido** — mejora el Brier. No es un error del modelo.

## 2. Verificación numérica

Llamada real a la función de producción, replicada en lab:

```
totales_nb(9.06, 5.0, [8.5]) →
  under_pct = 51.7   over_pct = 48.3   suma = 100.0
  momio_justo_under = 1.94   momio_justo_over = 2.07
```

`51.7 → 52 %` **coincide exactamente** con lo mostrado. Y `1.94` es el mismo 1.94 del copy.

Reconstrucción de la grilla Poisson de `motor_mlb` con λ_total = 9.06:

```
P(Under 8.5) = 44.78 %   P(Over 8.5) = 55.22 %   suma = 100.0000 %
E[total] = 9.060                                  moda = depende del reparto
```

**La P(Under) es independiente del reparto λ_local/λ_visita** (la suma de Poissons independientes es Poisson(λ_total)). Verificado con cuatro repartos distintos: los cuatro dan 44.78 %.

### Comparación de las dos distribuciones con la MISMA media

| | media | varianza | P(X≤8) | mediana | moda |
|---|---|---|---|---|---|
| Poisson(9.06) | 9.060 | 9.06 | **44.78 %** | 9 | 9 |
| **NB(9.06, r=5)** | 9.060 | **25.48** | **51.67 %** | **8** | 7 |

**Aquí está la explicación de la aparente contradicción.** La NB está sesgada a la derecha: varianza 25.5 frente a 9.1, **media 9.06 pero mediana 8**. Una distribución así puede perfectamente tener media por encima de 8.5 y aun así más del 50 % de la masa en 8 o menos. **No hay incoherencia matemática: hay asimetría.**


## 2-bis. Confirmación directa con las funciones de producción

`predecir_mlb` **no llama a `motor_mlb`**: calcula sus propios `lam_h`/`lam_a` (con factores de clima y alineación), y en la MISMA invocación produce ambas cosas:

```sql
matriz_poisson(lam_h, lam_a, ARRAY[6.5,7.5,8.5,9.5,10.5,11.5], false, 20);  -- línea 158
mtz := jsonb_set(mtz, '{totales}', totales_nb(lam_h + lam_a, 5.0, ...       -- línea 168
'total_esperado', round(lam_h + lam_a, 2),                                   -- línea 288
```

Ejecutadas directamente con los mismos λ:

```
matriz_poisson(5.03, 4.03) -> under_85 = 44.8 %   (Poisson)
totales_nb(9.06, 5.0)      -> under_85 = 51.7 %   (Binomial Negativa)
```

**Misma corrida, mismo parámetro de media, dos distribuciones, 6.9 puntos de diferencia.** `predecir_mlb` sobreescribe `{totales}` con la NB pero conserva `marcador_mas_probable` de la matriz Poisson. Eso es exactamente `CROSS_MODEL_PRESENTATION = YES`, ahora con las dos funciones ejecutadas lado a lado.

`SAME_ANALYSIS_RUN = YES` · `SAME_MEAN_PARAMETER = YES` · `SAME_DISTRIBUTION = NO`.

## 2-ter. `expected_runs − línea` NO es una señal válida (CT-7)

La regla del atajo y la regla real **discrepan en 6 de 8 casos** probados:

| μ | línea | media − línea dice | CDF de la NB dice | P(Under) |
|---|---|---|---|---|
| 8.20 | 7.5 | OVER | **UNDER** | 50.1 % |
| 10.10 | 9.5 | OVER | **UNDER** | 51.7 % |
| … | | | | (6 de 8 discrepan) |

Si ambas reglas coincidieran siempre, el atajo sería inocuo. Al discrepar, **cualquier superficie que muestre `media − línea` como señal de Over/Under está afirmando algo que el motor no calcula.** El texto observado *"carreras esperadas 9.06 vs línea 8.5 · sin señal (+0.56)"* no se genera en la base de datos: se construye en el frontend, así que la corrección es un item del contrato de producto, no un patch SQL.

**CT-7 queda como test permanente** para impedir que esa semántica reaparezca.

## 3. Lo que sí está mal

**El marcador probable 5-4 sale de la grilla Poisson; la P(Under)=52 % sale de la NB.** Son dos distribuciones distintas presentadas como una sola inferencia. La NB, para ese mismo partido, tiene moda de total en **7**, no en 9 (=5+4).

Y el texto *"carreras esperadas 9.06 vs línea 8.5 · sin señal (+0.56)"* llama **señal** a `media − línea`, cuando la decisión del total la toma la **CDF acumulada** de la NB. Bajo la NB, `media − línea = +0.56` apunta a Over mientras la acumulada dice Under 52 %. Ambas cifras son correctas; el encuadre invita a leer una contradicción que no existe.

Comprobado también: la moda 5-4 **sí es alcanzable** con λ_local≈5.03, λ_visita≈4.03 (suma 9.06). No la acuso de incorrecta.

## 4. Copy

**"bien calibrado"** conviviendo con `MODEL_VERSION_PROVENANCE_MISSING` es insostenible. La calibración procede de `calibracion_coef`, seleccionada con doble cota temporal, y **solo se aplica dentro del rango medido [43.2 %, 62.2 %]**; fuera, `calibrar_prob_motor` devuelve NULL y la tarjeta debería decir "sin calibrar". Pero esa calibración se midió sobre un tramo histórico, **no sobre el `model_version` que produjo la P actual** — que es precisamente lo que falta. Reemplazo propuesto: **"Referencia histórica del tramo (N=…, medida hasta …)"**, nunca "bien calibrado" como propiedad del pick actual.

**"aguanta"** aparece con `economically_eligible = false`. Prohibido. Reemplazo descriptivo, no prescriptivo: *"La cuota disponible (1.94) coincide con el precio de referencia del modelo. Este mercado no está autorizado como apuesta."*

**"Ventaja del modelo · +0.5 % EV"**: con provenance ausente no puede llamarse ventaja del modelo. Propuesto: **"Diferencia frente al precio de referencia"**. El número no se oculta ni se cambia; se corrige lo que afirma.

## 5. PARTE B — "MEJORES PICKS" es un ranking de EV

```
SURFACE                   = ⭐ MEJORES PICKS MLB DE HOY
SOURCE_OBJECT             = public.mejor_oportunidad_hoy(p_limite)
CANDIDATE_FILTER          = CTE `filtrado` (usa es_pick)
ORDER_BY                  = f.ev_cal DESC  LIMIT p_limite
USES_P_DECISION           = solo como insumo del EV, no en el orden
USES_EV                   = SÍ — es el único criterio de orden
USES_MODEL_SKILL          = NO
USES_ACCURACY_EVIDENCE    = NO
USES_DATA_READINESS       = NO
USES_ECONOMIC_ELIGIBILITY  = parcial (es_pick en el filtro, no en el orden)
USES_ECONOMIC_AUTHORITY   = NO (no llama economic_eligibility_v1)

PRODUCT_SEMANTIC_BUG      = CONFIRMED
```

El título promete "los mejores picks" y el usuario razonable entiende *"lo que más probablemente acierte"*. La superficie entrega **lo que tiene mayor EV calibrado**, que es una pregunta distinta. Un EV de +7.8 % a cuota 2.20 implica P≈49 %: **perderá más veces de las que gane**. El encabezado "no es quién gana — es dónde la casa paga de más" intenta explicarlo, pero compite contra la palabra "MEJORES" y contra tres filas con EV en verde.

**Renombrado propuesto:** *"💰 Oportunidades de valor del modelo"*, con subtítulo *"Mayor diferencia entre nuestro precio y el de la casa. No son los resultados más probables."* Y mostrar siempre P modelo, P mercado, cuota, EV y estado de autorización.

## 6. Fix preparado

`shadow-patches/unified/clasificacion_pick_v1.sql` separa las cuatro clases sin un solo umbral inventado. Aplicado a este caso:

```
prob_source=MODEL · economically_eligible=false · data_readiness=READY
  → MOST_LIKELY / HIGHEST_P_NOT_ECONOMICALLY_ELIGIBLE · authorized_bet=false
```

Que es exactamente **"MUY PROBABLE — MAL PRECIO"**, sin lenguaje de apuesta.

`shadow-patches/unified/contract_tests_v1.sql` — 6 bloques, todos PASS:

| Test | Qué impide | evaluated_rows | violations |
|---|---|---|---|
| CT-1 | no-elegible presentado como apostable | 3 | 0 |
| CT-2 | P de la casa escalando sobre ANALYSIS | 4 | 0 |
| CT-3 | MOST_LIKELY exigiendo EV+; VALUE exigiendo P máxima | 2 | 0 |
| CT-4 | TOP_PICK sin evidencia forward | 3 | 0 |
| CT-5 | under+over≠100 y momio_justo≠1/P | 5 | 0 |
| CT-6 | mezclar moda Poisson con CDF NB (divergencia 6.92 pp documentada) | 1 | 0 |
| **CT-7** | **`expected_runs − línea` como señal de Over/Under** (discrepa en 6/8) | 8 | 0 |
| CT-8 | inventario de copy prescriptivo generado en la BD | 15 | 0 (inventario) |

## 7. Resultado

```
MLB_SAFETY_GATE              = PASS (el gate de ISS-003/009 V2 funciona: economically_eligible=false, stake=0)
MLB_COPY_SEMANTICS           = FAIL ("bien calibrado", "aguanta", "ventaja del modelo", "MEJORES PICKS")
UNDER_8_5_52_PERCENT_SOURCE  = predecir_mlb → totales_nb(λ_total, r=5) — Binomial Negativa
EXPECTED_RUNS_9_06_SOURCE    = predecir_mlb → round(lam_h + lam_a, 2) (media, compartida)
SCORE_5_4_SOURCE             = predecir_mlb → matriz_poisson(lam_h,lam_a) → marcador_mas_probable
SAME_DISTRIBUTION            = NO (NB para totales · Poisson para marcador exacto)
SAME_MODEL_VERSION           = NO VERIFICABLE — MODEL_VERSION_PROVENANCE_MISSING
SAME_ANALYSIS_RUN            = YES — CONFIRMADO: una sola invocación de predecir_mlb
SAME_MEAN_PARAMETER          = YES — CONFIRMADO: totales_nb recibe (lam_h+lam_a), idéntico a total_esperado
UNDER_PROB_RECOMPUTED        = 51.67 % (NB) · 44.78 % (Poisson)
UNDER_PROB_DISPLAYED         = 52 %
DIFFERENCE                   = 0.0 pp vs NB · 7.2 pp vs Poisson
EXPECTED_TOTAL_RECOMPUTED    = 9.060 (coincide)
MODE_SCORE_RECOMPUTED        = 5-4 alcanzable con λ≈5.03/4.03 (coincide) · moda del total NB = 7
PROBABILITY_COHERENCE        = PASS dentro de cada distribución · FAIL en la presentación conjunta
CROSS_MODEL_PRESENTATION     = YES
CALIBRATION_COPY_PROVENANCE  = FAIL (calibración de tramo histórico, no del model_version actual)
AGUANTA_PRESENT              = YES (prohibido con economically_eligible=false)
FIX_PREPARED                 = YES (clasificacion_pick_v1 + contract_tests_v1, shadow)
TESTS                        = 8 bloques · 41 asserts · violations=0 · coverage_status=PASS_NONEMPTY
PRODUCTION_CHANGED           = NO
```

**No cambié P, EV ni el modelo.** La NB está justificada por Brier medido; la asimetría explica la aparente contradicción. Lo que hay que arreglar es qué afirma la pantalla, no qué calcula el motor.
