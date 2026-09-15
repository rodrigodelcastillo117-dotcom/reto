# MLB — evidencia EJECUTADA del contrato de decisión (iss052)

`RELEASE_GATE=HOLD` · `PROD_FREEZE=ON` · `LOVABLE_FREEZE=ON` · prod sólo-lectura · sin cutover.

Rama desechable: `mlb-decision-contract` (`ysuaktkawnljflrvozmk`), padre `wpiztubmmmzclhlprgpd`.
Época de decisión: **2026-09-10 22:50:00+00**. Época de réplica: **2026-07-20 12:00:00+00**.

---

## 1. Lo que estaba roto en iss016 (re-verificado leyendo el archivo, no de memoria)

| # | Defecto | Evidencia en iss016 |
|---|---------|---------------------|
| 1 | Snapshots **post-primer-pitcheo** | `snapshot_mlb_predicciones()` selecciona `ae.fecha BETWEEN now() - interval '3 hours' AND now() + interval '4 days'` |
| 2 | Lectura canónica sin gate temporal | `v_prediccion_reto_mlb` hace `DISTINCT ON (espn_event_id) … ORDER BY snapshot_at DESC` sin `snapshot_at < scheduled_at` |
| 3 | No era inmutable | se documenta append-only, no existe guard de UPDATE/DELETE |
| 4 | Sin sello de procedencia | sin `decision_time`, sin hash de features, sin `model_version`, sin `calibration_version`, sin `data_asof` |
| 5 | Mercados no salen de UNA distribución | persiste λ y `total_esperado`, **no** la distribución |
| 6 | Lectura dependiente del reloj | `scheduled_at >= now() - interval '6 hours'` |

1+2 juntos son el STOP-SHIP: el modelo podía "predecir" un juego ya en curso y esa fila se servía como P_RETO.

## 2. El arreglo es ESTRUCTURAL, no un ajuste de ventana

Se pidió explícitamente no parchear la ventana de −3h. No se parcheó:

```sql
constraint mlb_pred_snapshot_pre_first_pitch check (decision_time < scheduled_at)
```

La base de datos **se niega a almacenar** una decisión que no sea estrictamente pre-primer-pitcheo.
Ninguna ventana, ningún cron y ningún caller futuro puede reintroducir los defectos 1 ni 2.

## 3. Gate adversarial ejecutado — 27/27 PASS

| Etapa | Resultado medido |
|-------|------------------|
| S0_EPOCH_SANITY | `odds_after_decision=0 fixtures_already_started=0` |
| S1_UNIVERSE | `snapshots=30 post_first_pitch=0 ready_and_asof_proven=30` |
| **S2_POST_FIRST_PITCH_REJECTED** | `check_violation` (insert 25 min después del primer pitcheo) |
| **S2B_AT_FIRST_PITCH_REJECTED** | `check_violation` (`decision_time = scheduled_at` también se rechaza) |
| S3_STARTED_GAMES_EXCLUDED | `snapshots_at_later_epoch=28 started_games_present=0` |
| S4_UPDATE_BLOCKED | `blocked` |
| S4B_DELETE_BLOCKED | `blocked` |
| S4C_CONFIG_DRIFT_BLOCKED | `blocked readiness_floor_still=0.60` |
| S5_COHERENCE | `gated=30 incoherent=0` |
| S5B_INDEPENDENT_RECOMPUTE | `mismatches=0` |
| S5C_PUSH_SEMANTICS | `violations=0 whole_line_events=3` |
| S5D_MATRIX_SUMS_100 | `rows_not_summing_100=0` |
| S6_NO_MARKET_DIAGNOSTIC | `no_market=20 of_which_suppressed=0` |
| S7_REPLAY_IDEMPOTENT | `md5=c7b96e054e014575277b8fe2c6d791ab rows_after_replay=30` |
| S8_ASOF_IS_REAL | `identical_lambdas=0 early_asof=2026-07-14 dec_asof=2026-08-30` |
| S8B_NO_FUTURE_LEAK | `pred_leaks=0 feature_leaks=0` |
| S9_CLOCK_INDEPENDENT_READ | `pick_at_early=2026-07-20 12:00 pick_at_dec=2026-09-10 22:50` |
| S9B_NO_NOW_IN_CANONICAL | `functions_using_now=0` |
| S10_ONE_PRETO | `identity_violations=0 post_first_pitch_violations=0` |
| S11_CANDIDATES | `legs=64 events=26 ineligible_leaked=0` |
| S11B_LEG_PROB_TRACEABLE | `untraceable_legs=0` |
| S12_WF_NO_OUTCOMES | `verdict=INSUFFICIENT_HISTORY n=0` |
| **S12B_WF_ARITHMETIC** | `brier=0.21000 coinflip=0.25000 skill=0.16000 n=4` — idéntico al cálculo a mano |
| **S13_NO_PROMOTION_ON_NOISE** | `verdict=NO_SKILL_VS_MARKET t=1.000 mean_gain=+0.10000 brier_market=0.31000` |
| S14_POST_START_ODDS_IGNORED | `REVIEW_REQUIRED → REVIEW_REQUIRED` (momio envenenado a 1.01 ignorado) |
| S15_CORRUPTION_DETECTED | `verdict=CORRUPT_SNAPSHOT_TABLE violation_view_rows=1` |
| S15B_INVARIANT_RESTORED | `violations=0 constraint_present=1` |

S12B y S13 son los importantes: las métricas se comparan contra valores **calculados a mano**, no contra
lo que el código devuelva. S13 en particular fija un defecto que tenía mi propio borrador (ver §5).

## 4. VEREDICTO DE SKILL — medido en PROD sobre el corpus completo, sólo-lectura

Corregí una afirmación anterior mía. Dije que MLB "no se puede calibrar" apoyándome en
`mlb_modelo_snapshot` (83 filas, hace UPSERT) y `marcadores_archivo` (166 finales). **Eso estaba
incompleto**: existe `public.lab_mlb_wf` con **1,053 juegos temporalmente válidos** (2026-05-20 →
08-30) con resultados, features y probabilidades, y `public.mlb_linescore` (129,019 filas) cubre
**1,053/1,053** de esos eventos. Sí se puede medir. Y medido, el resultado es:

**Moneyline, 1,053 juegos:**

| Métrica | Valor |
|---------|-------|
| Brier modelo | **0.24750** |
| Brier volado (0.5) | 0.25000 |
| Skill vs volado | **+1.00 %** |
| Rango de probabilidad | sólo 0.3762 … 0.6540 |
| DISCOVERY (519) / VALIDATION (260) / FINAL (274) | 0.24785 / 0.24826 / 0.24612 |

**Cara a cara contra el mercado, los 153 juegos que sí traen momios confiables:**

| Métrica | Valor |
|---------|-------|
| Brier modelo | 0.24497 |
| Brier mercado no-vig | 0.24723 |
| Ganancia pareada media | +0.00226 |
| Desv. est. | 0.05194 |
| Error estándar | 0.00420 |
| **t** | **0.538** |

`t = 0.538` **no es significativo**. La lectura honesta es **NO HAY SKILL DEMOSTRADO VS MERCADO**,
no "le gana al mercado". `public.lab_mlb_split_seal` dice lo mismo desde el otro lado: el universo
completo de 1,053 es DEVELOPMENT (ya inspeccionado globalmente), así que ningún SKILL_PASS es
admisible sin un FINAL_TEST_FORWARD estrictamente posterior a 2026-08-30.

→ `calibration_status` se queda en **UNVALIDATED**. El contrato existe; el modelo no está aprobado.

## 5. Defecto que encontré en mi PROPIO borrador

Mi primera versión de `fn_mlb_walk_forward` promovía con `skill_vs_market > 0`:

```sql
elsif skill_vs_market > 0 then verdict := 'BEATS_MARKET_PENDING_REVIEW';
```

La medición de arriba demuestra que esa barra se dispara con ruido: +0.00226 con t=0.538. Las
diferencias de Brier sobre resultados binarios tienen desviación estándar ~20× el tamaño del efecto
a esta muestra. **Un delta positivo sin dividir entre el error estándar no es evidencia.** Reescrito
para exigir un estadístico t (`p_min_t` = 2.0) y, además, para distinguir
`SKILL_IN_DEVELOPMENT_ONLY` (dentro del universo sellado, no promueve) de
`FORWARD_SKILL_PENDING_GOVERNANCE`. La etapa S13 del gate fija este comportamiento con un fixture
donde el modelo **sí** gana en Brier crudo (+0.10) pero t=1.0 → `NO_SKILL_VS_MARKET`.

## 6. Debilidad real del modelo que el gate expuso

De los 10 fixtures con mercado, **4 quedaron suprimidos** como `REVIEW_REQUIRED`:

| Partido | Modelo local | Mercado no-vig | Gap |
|---------|--------------|----------------|-----|
| Atlanta Braves vs Philadelphia Phillies | 44.9 | 61.6 | **−16.7** |
| Toronto Blue Jays vs Baltimore Orioles | 41.2 | 53.6 | −12.4 |
| New York Yankees vs Colorado Rockies | 59.7 | 72.0 | −12.3 |
| Chicago White Sox vs Pittsburgh Pirates | 59.6 | 51.1 | +8.5 (total_gap +14.3) |

El patrón es consistente y diagnosticable: **el modelo comprime las probabilidades hacia 50 %**
porque λ sale sólo de tasas de carreras por equipo y **no tiene término de pitcher abridor**. Eso
coincide con el rango 0.376–0.654 medido en prod. El gate hace su trabajo (las suprime), pero la
conclusión es que este modelo necesita un término de abridor antes de valer algo.

## 7. Lo que NO se probó / limitaciones honestas

- **Independencia local/visitante**: `fn_mlb_run_dist` trata las carreras de ambos equipos como
  independientes. Es una aproximación (parque, clima, umpire las correlacionan) y está escrita en el
  `provenance` de cada snapshot. No fue validada.
- **Entradas extra**: la masa de empate en regulación se elimina por renormalización y se reporta
  como `p_tie_regulation` (9.5–11.6 % en los fixtures reales). Modelar extra innings es trabajo
  pendiente.
- **El corpus histórico de 1,053 juegos no se replicó en la rama.** La medición de skill se tomó en
  prod a escala completa; la rama prueba que la *función* calcula bien contra fixtures calculables a
  mano. Mover 2,078 observaciones acumuladas para re-derivar un número ya medido habría costado sin
  probar nada nuevo.
- **`mlb_linescore.cargado_at` no sirve como tiempo de disponibilidad**: las 129,019 filas se
  cargaron en un solo lote el 2026-09-03 entre 02:36 y 06:48Z. Por eso el log de observaciones usa
  `fecha del juego + 4 h` como `observed_at`, y por eso un replay de una decisión anterior al
  2026-09-03 sigue siendo sospechoso desde el lado de la disponibilidad.
- **`v_momios_confiables` también está contaminado**: 159 de 1,114 snapshots de estos eventos están
  en o después del primer pitcheo. Toda lectura de mercado en iss052 está acotada por
  `snapshot_at <= decision_time`; S14 lo prueba con un momio envenenado.

## 8. Hallazgo colateral en iss032

`v2.fn_real_total_line` referencia `v_momios_confiables` **sin calificar el esquema** dentro de una
función `stable`. Depende de `search_path`. Se aplicó en la rama **verbatim del repo** (no lo
"arreglé" en silencio) para que rama y repo coincidan byte a byte; queda reportado como fragilidad.

## 9. Reproducción

```
shadow-patches/prepared/iss052_mlb_decision_snapshot_contract.sql   -- el contrato
shadow-patches/tests/seed_mlb_realpath_data.sql                     -- datos reales de prod
shadow-patches/tests/run_mlb_contract_gate.sql                      -- gate adversarial (27 etapas)
```

Dependencias mínimas aplicadas antes de iss052: `v2.fn_total_weights` (iss041),
`v2.fn_matrix_market` (iss042), `v2.fn_novig_2way` (iss043), `v2.fn_real_total_line` (iss032),
más `public.agenda_espn` y `public.v_momios_confiables` (iss000).

Las 30 fixtures sembradas se verificaron byte a byte contra prod:
`md5(espn_event_id|fecha|home_espn_id|away_espn_id) = d556db66d72d41f66322a67b61a88d1e`.

**iss016 queda SUPERSEDED y NO debe aplicarse en cutover.**
