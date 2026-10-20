# Mercado validado — Tenis Over/Under de juegos totales (v1)

Supabase prod: `wpiztubmmmzclhlprgpd`. Fecha: 2026-10-20. Dinero OFF (producto de picks/research, sin apuesta real).

## Resumen

Se habilitó el mercado **OU de juegos totales** para `tenis_atp` y `tenis_wta`, con el
mismo estándar que NBA/MLB OU: validación fuera de muestra (OOS) **antes** de publicar,
datos reales de ESPN (nada fabricado), piso de confianza ≥60%.

**Decisión: PUBLICADO.** Supera el baseline (50% contra línea mediana) de forma estable y
calibrada. Ver caveat importante abajo.

## 1. Bloqueo original y cómo se resolvió

`tenis_partidos_v1` solo guardaba el conteo de sets (`sets_winner`/`sets_loser`), no los
juegos por set. Resultaba imposible modelar/validar juegos totales.

Ya existía la infraestructura de linescores (`tenis_linescore`, PK
`(espn_event_id, competitor_id, period)`, alimentada por el cron live `tenis-linescore`
cada 15 min) pero solo cubría ~2 meses (desde 2026-08-24).

**Backfill histórico** (server-side, misma arquitectura que `tenis-hist-parse`):
- Nuevas funciones `tenis_ls_hist_pedir(desde,hasta)` y `tenis_ls_hist_parse()` que piden
  el scoreboard mensual de ESPN (`dates=YYYYMM`) y extraen
  `events[].groupings[].competitions[].competitors[].linescores[]`. El número de set sale
  de `WITH ORDINALITY` (el feed mensual no trae campo `period`).
- Se corrió el backfill 2021-09 → 2026-10.
- **Resultado: 45,167 de 45,442 partidos (99.4%) con linescores**, ~240k filas,
  rango 2021-09 → 2026-10.
- Cron de respaldo diario `tenis-ls-hist-mensual` (06:50) re-pide el mes actual y el
  anterior y parsea, por si el cron live perdiera algún final.

Nota de datos: el campo `format.regulation.periods` de ESPN es **ruidoso** (marca partidos
bo3 como bo5 y viceversa). El best-of se deriva por torneo: **bo5 = individuales
masculinos de los 4 Grand Slams**; todo lo demás bo3.

## 2. Validación OOS (walk-forward)

Script: `shadow-patches/sql/` + notebooks en la sesión. Metodología:
- **Elo secuencial causal** (K=32) sobre los partidos con linescore → cercanía Elo `p_fav`.
- **Ritmo rodante por jugador** (últimos 20 partidos, causal): promedio de
  *games-per-set* y de *juegos totales*. Features simétricas: `gps_sum`, `gps_min`,
  `gps_max`, `tot_sum`, más `bo` y `p_fav`.
- **Línea = mediana del periodo de entrenamiento por (tour, bo)**: ATP bo3=22, bo5=30,
  WTA bo3=20.
- **Modelo**: regresión logística `P(juegos > línea)`, ajustada solo en train.
- **Holdout temporal** (cutoff 2025-07-01) + **walk-forward por trimestre** (9 trimestres,
  2024-07 → 2026-10), reentrenando con todo lo anterior.
- Filtro cold-start: ambos jugadores con ≥5 partidos previos con linescore.

### Resultados (tramo de confianza ≥60%, walk-forward agregado)

| Tour | n picks | acierto ≥60% | Estabilidad |
|------|--------:|-------------:|-------------|
| ATP  | 494     | **66.2%**    | 9/9 trimestres ≥59% |
| WTA  | 523     | **65.2%**    | 8/9 trimestres ≥59% (uno 50% con n=16) |

- **Calibrado** (holdout): bin 0.60–0.65 → real 0.659 (ATP) / 0.627 (WTA); ligeramente
  subconfiante en ATP (lo realizado ≥ lo afirmado).
- Línea bien centrada: tasa de "over" en test ~50% (no es truco de "siempre over"),
  push ~7%.
- ATP funciona en bo3 (63.3%) **y** bo5 (71.1%); no es solo Grand Slams.
- El edge viene de las features de ritmo rodante; un baseline solo con `bo`+`p_fav` ni
  siquiera genera picks de confianza en ATP.
- Comparable/superior a los OU ya publicados (NBA 65.7%, MLB 61.0%).

### CAVEAT HONESTO (declarado en `reto_modelo_validacion_v1.metodo`)

Esto vence una **línea MEDIANA ESTÁTICA**, no una línea real y afilada de casa de apuestas.
Es exactamente el mismo estándar con que se validaron y publicaron NBA y MLB OU, pero
contra un sportsbook real (que ajusta la línea por partido) el edge probablemente se
encoge. Es un producto de modelo-vs-mediana, no una afirmación de ganarle al mercado.

## 3. Objetos creados / modificados en Supabase

Ver `shadow-patches/sql/tenis_totales_ou_v1.sql`. Resumen:
- `public._carga_tenis_lshist` (staging), `tenis_ls_hist_pedir`, `tenis_ls_hist_parse`.
- Cron `tenis-ls-hist-mensual`.
- `public.tenis_totales_modelo_v1` (coeficientes logísticos crudos por tour + líneas).
- Vista `public.v_reto_tenis_totales_v1` (picks OU de partidos próximos).
- `reto_snapshot_capturar_v1()`: bloque OU tenis (piso ≥60).
- `v_reto_mejores_picks_v1`: bloque OU tenis (piso ≥60).
- `v_reto_pick_grade_v1`: califica OU tenis con juegos totales reales (push=NULL en empate).
- `reto_modelo_validacion_v1`: filas `tenis_atp/OU` (66.2%) y `tenis_wta/OU` (65.2%).

## 4. Frontend

El frontend (Lovable "Remix of Reto 13M") renderiza mercados de forma genérica. El ícono
🎾 y las etiquetas ATP/WTA ya existen. `pick_titulo` ("Más de 22 juegos") es autodescriptivo.
No requiere cambios.

## 5. Reversión

Para despublicar sin perder datos: quitar los bloques OU de tenis de
`reto_snapshot_capturar_v1()` y `v_reto_mejores_picks_v1`, o borrar las filas OU de
`reto_pick_snapshot_v1` donde `deporte like 'tenis%'`. Los linescores del backfill son
datos reales y conviene conservarlos (enriquecen `v_tenis_marcador_v1`).
