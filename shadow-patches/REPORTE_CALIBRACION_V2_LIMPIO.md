# Calibration V2 limpio — sin pretemporada

11-sep-2026 · `cal_v2_limpio` · responde a `AUDIT_NO_PASS` comentario `5641203225`

> **Sigue NO-PASS.** `P_CAL` desconectado, `es_lock = false`. Nada en pantallas.

---

## 0. El blocker que no había visto

`historico_partidos_espn` **tiene** la columna `tipo_temporada` y yo **nunca la
filtré**. Todos los backtests mezclaban Spring Training con temporada regular.

| | regular/playoffs | pretemporada |
|---|---|---|
| MLB | 6,470 | **853** |
| NFL | 1,693 | **293** |

Y la contaminación no era uniforme por año en MLB:

| año | regular | pretemporada |
|---|---|---|
| 2023 | 2,511 | 15 |
| 2024 | 1,796 | **296** |
| 2025 | **119** | 94 |
| 2026 | 2,044 | **448** |

## 1. Qué le pasó al resultado al limpiarlo — **se debilitó**

Este es el dato que más importa del reporte.

| | V1.2 (contaminado) | **V2 limpio** |
|---|---|---|
| partidos holdout MLB | 2,377 | **1,932** |
| Brier RAW | 0.242715 | 0.238421 |
| Brier CAL | 0.238846 | **0.235484** |
| mejora media | 0.003900 | **0.003058** |
| **IC95 inferior** | **0.001838** | **0.000477** |
| IC95 superior | 0.005914 | 0.005778 |
| remuestreos a favor | 100.0% | **98.9%** |

**La pretemporada estaba inflando el efecto.** El límite inferior del IC95 se
acercó 4× a cero. Sigue siendo significativo, pero por mucho menos margen del
que reporté.

## 2. Walk-forward por temporadas, base limpia

| fold | partidos | Brier RAW | Brier Platt | ECE RAW | ECE Platt | veredicto |
|---|---|---|---|---|---|---|
| MLB temp. 2024 | 1,687 | 0.248347 | **0.241815** | 0.101307 | **0.064096** | Platt gana |
| NFL temp. 2022 | 239 | 0.238266 | **0.227650** | 0.104550 | **0.021416** | Platt gana |
| NFL temp. 2023 | 239 | **0.232611** | 0.257187 | **0.072559** | 0.171028 | Platt **no** gana |

NFL sigue **1-1** entre temporadas, igual que con datos sucios. La conclusión no
cambió: **`identity`, `P_CAL = P_RAW`**.

## 3. Holdout, confirmación única

### MLB temporada 2026 — 1,932 partidos, 679 pushes

| | RAW | CAL (Platt) |
|---|---|---|
| Brier | 0.238421 | **0.235484** |
| LogLoss | 0.669731 | **0.663547** |
| ECE | 0.056652 | **0.012997** |
| volado | 0.250000 | |

Bootstrap cluster = partido, 1000 remuestreos:
**media 0.003058, IC95 [0.000477, 0.005778], 98.9% a favor, significativo.**

### NFL temporada 2025 — 238 partidos, 37 pushes, método `identity`

| | RAW |
|---|---|
| Brier | **0.226115** |
| LogLoss | 0.643530 |
| ECE | 0.045459 |
| volado | 0.250000 |

## 4. Los otros dos blockers

**Folds y bootstrap ahora son SQL ejecutable**, no comandos manuales:
`public.bootstrap_mejora_por_partido(model, params, desde, hasta, reps)` y la
tabla `calib_fits`, ambos en `iss087_sin_pretemporada.sql`.

**Calibradores viejos invalidados.** `cal_v1_2026_09_11` y `cal_v2_simulacion`
quedaron con `elegido = false`, `invalidado = true` y motivo escrito. Ninguno de
los contaminados sigue elegido. `cal_v2_limpio` es el vigente.

## 5. MLB 2025 — no lo pude recuperar

119 juegos regulares de ~2,430. **Falta el 95%.**

Busqué mecanismo de recuperación: no hay función de backfill histórico en la
base, y de las 135 edge functions ninguna es de carga histórica de MLB
(`sync-scores-global` y `get-espn-matches` son de partidos actuales;
`detalle-espn-backfill` es de detalle, no de temporadas completas).

**No disparé edge functions a ciegas.** Recuperar 2025 es una corrida de ingesta
contra ESPN y necesita tu decisión sobre qué función usar o si hay que escribirla.

Mientras tanto el split real es: entrenar 2023-2024, probar 2026, con un año de
hueco en medio. Es un split válido y hasta más duro, pero hay que decirlo así.

## 6. NFL bueno, verificado otra vez

`modelo_version_activa('football')` = `nfl-2026.09.2`, PRODUCCION, separado de
`nfl_ml_poisson_v1` (MODEL_REJECTED). Intacto.

## 7. Lo que sigue faltando

Soccer 1X2 multiclase · isotónico · Fantasy MAE/RMSE/coverage · líneas reales
(169 de 6,022 en MLB, 0 de 1,443 en NFL) · migrar los 8 llamadores de
`zona_realidad/2` · conectar `P_CAL`.

## 8. Mi lectura

Limpiar la pretemporada **le quitó fuerza al resultado de MLB**, no se la dio.
IC95 inferior de 0.000477 sobre 1,932 partidos es significativo por poco, y con
un Brier de 0.2355 contra 0.25. Es señal real y chica.

NFL sigue en **0.2261** RAW sobre 238 partidos — el mejor número después del
fútbol — pero con el calibrador 1-1 entre temporadas y una muestra chica.

Sigo sin recomendar promover ninguno de los dos.
