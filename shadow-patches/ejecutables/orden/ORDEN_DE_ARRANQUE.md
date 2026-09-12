# Orden de arranque desde una base limpia

Responde al `AUDIT_NO_PASS` #5643661236, bloqueadores 1 y 2.

## El ciclo que había, y por qué era real

`iss096` **parcheaba** `v_pick_canonico`, así que necesitaba que la vista ya
existiera. Pero el baseline final de esa vista **invoca funciones que
`iss095`/`iss096` crean**. Sobre una base virgen no había por dónde empezar: el
baseline estaba en Git, sí, pero el orden no cerraba.

Se rompe separando **definición** de **transformación**:

* Los archivos `iss094/094b/095/096` son el **registro histórico** de cómo se
  transformó producción. Siguen siendo ejecutables y siguen siendo la prueba de
  qué cambió y por qué.
* Los archivos `orden/*` son el **arranque desde cero**. Aquí
  `v_pick_canonico` se **crea una sola vez desde su definición final**, nunca se
  parchea, así que no hay ciclo.

## Secuencia

| paso | archivo | qué hace |
|---|---|---|
| 00 | `iss086_calibration_release_v1_esquema.sql` | esquema de calibración versionada |
| 05 | `iss094_season_type_exacto.sql` | esquema de `season_type` + funciones de datos (ya SIN bootstrap ni assertions) |
| 10 | `iss090_folds_y_metodo.sql` | `normal_cdf`, Platt, isotónica, bootstrap por partido |
| 20 | `iss095_llave_exacta_y_una_matriz.sql` | **las funciones que la cadena necesita**: `modelo_de_pick`, `calibracion_de_pick`, `mercado_apto_para_lock` (llave de 4), `estado_respaldo`, `linea_es_canonica` |
| 25 | `iss096_fuera_el_ev_del_canonico.sql` | `elegibilidad_no_economica_v1`, `model_skill`, `datos_listos`, `identidad_valida`, registro de superficies |
| 30 | `baseline/v_pick_canonico.sql` | **crea `v_pick_canonico` ya limpia, de una sola vez**. Aquí se rompe el ciclo: todas sus funciones existen desde los pasos 20 y 25 |
| 40 | *(dentro de iss095)* | las 4 vistas de superficie |
| 50 | `orden/50_bootstrap.sql` | define y **arranca** la descarga del histórico |
| 60 | `orden/60_espera_bootstrap.sql` | **BLOQUEA** hasta que la descarga termine de verdad |
| 70 | `orden/70_universo.sql` | `calib_lambda` + `calib_eventos` (MLB por `season_type`; NFL aislado) |
| 75 | `iss091_decision_calibracion_v4.sql` | registra la decisión de calibración |
| 80 | `orden/80_assertions.sql` | **recién aquí** se comprueban los datos |
| 90 | `gates_selector.sql` | los 8 gates de máquina |
| 99 | `verificar_checksums_iss094_096.sql` | hashes contra producción |

## Lo que todavía NO permite levantar desde cero absoluto

Hay que decirlo claro, porque es la diferencia entre "ordenado" y "reproducible":

`v_pick_canonico` lee de **vistas preexistentes que nunca estuvieron en Git**:
`picks_recomendados_hoy`, `v_picks_futbol_calibrado`, `v_picks_mlb_modelo`,
`v_radar_odds_fase`, `agenda_espn`, `live_scores`, y las funciones
`prob_recalibrada_lado`, `momio_real_de_mercado`, `sin_acentos`,
`deporte_registry`, `mercado_en_abstencion`, `exact_decision_price`,
`pred_futbol_del_evento`.

Eso es **deuda anterior a este bloque**, no creada por iss094-096. Mientras esos
objetos no estén volcados, el paso 30 falla sobre una base virgen.
**Por eso no declaro `REPRODUCIBLE_FROM_GIT=YES`.** El ciclo ya no existe y el
orden ya cierra; lo que falta es volcar esa capa de origen.
