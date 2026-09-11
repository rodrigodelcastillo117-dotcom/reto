# shadow-patches/ejecutables/

SQL **ejecutable**, no prosa.

## Por qué existe esta carpeta

El auditor levantó un NO-PASS (issue #4, comentario `5639091011`) con este
blocker, y tenía razón:

> el commit `aae30a79...` contiene un archivo `iss084` que es sólo
> documentación/comentarios, no el SQL ejecutable que modificó producción. Eso
> significa que ahora mismo la calibración viva no es reproducible desde Git.

Correcto. `shadow-patches/prepared/iss082`, `iss083` e `iss084` son prosa:
documentan lo que se hizo pero **no lo reconstruyen**. Los cambios se aplicaron
con comandos sueltos por MCP.

## Qué hay aquí

| archivo | qué reconstruye |
|---|---|
| `iss082_candado_owner.sql` | Los 21 grupos de cambios del candado del dueño: `v_pick_canonico`, `v_mejor_pick_por_partido`, `picks_premium`, `v_picks_con_valor`, `v_mejores_picks_mlb`, `v_picks_para_parlay`, `v_oraculo_picks_activos`, `v_picks_premium`, `v_super_pick`, `v_picks_futbol_calc`, `parlay_del_dia_v3`, `refrescar_destacados`, `destacados_del_dia`, `mejor_oportunidad_hoy`, `mejor_oportunidad_hoy_v2__base`, `mejor_pick_hoy`, `veredicto_lote__base`, `rongol_seleccionar_dia`, `tg_filtrar_pick_del_dia`, `seleccionar_picks_seguro_valor`, `generar_parlay_seguro`, `enrich_oraculo_prob_with_momio`, `favoritos_bien_pagados`, `reto_13m_estado__base` |
| `iss083_calibracion_por_deporte.sql` | `zonas_confiables.deporte`, PK `(deporte, mercado, tramo)`, `zona_realidad/3`, candados de las vistas de RETO 13M |
| `iss084_backtest_particion_temporal.sql` | `modelo_backtest.deporte`, `normal_cdf`, `dispersion_totales`, `prob_total_sobre`, parche de totales a `motor_mlb`, tablas de backtest |
| `iss084b_reconstruir_backtests.sql` | **El poblado de los backtests.** Sin esto `zonas_confiables` no se regenera de cero |
| `iss085_muestra_independiente.sql` | Conteo por partidos independientes, retiro de la palabra "calibrado", salida del EV del camino de selección |
| `MANIFIESTO.txt` | md5 de los 33 objetos, como estaban en producción |
| `verificar.sql` | Saca los md5 actuales para hacer diff contra el manifiesto |
| `verificar_invariantes.sql` | Las 6 reglas duras como `assert`. Sirve aunque el SQL cambie de forma |

## Orden de ejecución

```
iss082 → iss083 → iss084 → iss084b → iss085
```

Después:

```
verificar.sql             # diff contra MANIFIESTO.txt
verificar_invariantes.sql # debe imprimir "OK: 6 invariantes se cumplen"
```

## Limitación, dicha claramente

Estos archivos reconstruyen **desde el estado inmediatamente anterior** (el de
las migraciones previas), no desde una base vacía. Casi todo son cirugías de
texto con **aserción de aparición única**: si la base no está en el estado
esperado, revientan con excepción en vez de aplicar algo distinto en silencio.
Correrlos dos veces falla a propósito en la primera aserción.

Eso los hace auto-verificables, que es más de lo que da un volcado ciego, pero
**no equivale a un `pg_dump` completo**. Un bootstrap desde cero sigue siendo
deuda abierta.

## Prueba de que sí reconstruye

`iss084b` sección A se ejecutó contra producción y regeneró
`backtest_mlb_totales` **idéntico** al estado previo:

| | antes | después de reconstruir |
|---|---|---|
| filas | 48,176 | 48,176 |
| partidos | 6,022 | 6,022 |
| suma de probabilidades | 24088.0000 | 24088.0000 |
| Brier | 0.245182 | 0.245182 |

## Lo que NO cierra

Este trabajo es sólo el blocker de reproducibilidad. Siguen abiertos del
NO-PASS (comentario `5639251406` fija el plan):

1. Semántica de línea entera: sólo se probaron líneas `.5`. Un `Over 8` puede
   hacer **PUSH** y no se calibra con evidencia de `Over 8.5`.
2. Validación fuera de muestra de la curva (train histórico → test futuro).
3. `model_version` + `calibration_version` en la llave.
4. NFL totals → `MODEL_REJECTED`.
5. 1X2 de fútbol → calibración multiclase (Home+Draw+Away = 100%).
6. Fantasy → MAE/RMSE/bias/coverage, no Brier.
7. Los 8 llamadores de `zona_realidad/2` siguen sin migrar a la versión con
   deporte.
