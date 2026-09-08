# TOP_PICK_ACCURACY_V1 — Reporte de investigación (LAB/SHADOW, read-only)

**Fecha:** 2026-09-08 · **Prod:** solo SELECT/read-only · **NO DEPLOY · NO DDL · NO cambios de motor · NO autorización de modelos.**
**Gobernanza intacta:** `CURRENT_AUTHORIZED_MODELS=NONE`, MLB `economic_authorized=FALSE`, `stake=$0`. Bloque ISS-003/009 no tocado.

## VEREDICTO
```
TOP_PICK_ACCURACY_V1 = INSUFFICIENT_EVIDENCE
```
La evidencia histórica propia **no soporta** hoy un selector de "mejores picks por probabilidad real de acierto":
la probabilidad histórica está **mal calibrada y no es monótona** frente al hit-rate, y un selector por P-alta
**no mejora el acierto de forma consistente out-of-sample** y **destruye ROI**. No se fabrica un selector.
Sí queda un candidato a vigilar (BTTS soccer) con muestra insuficiente, y una **especificación de captura forward**
para poder construir V1 con evidencia en el futuro.

---

## 1. TOP_PICK_FEATURE_INVENTORY
Fuente histórica canónica de decisiones+resultado: **`oraculo_picks_tracking`** (3560 filas; ~abr–sep 2026; fuente dominante `ai_pro`).

| Campo | Estado | Nota |
|---|---|---|
| espn_event_id, liga, home, away, mercado, pick_nombre/pick_desc | AVAILABLE | identidad del pick |
| probabilidad_real (P) | AVAILABLE (escala 0–1) | ver §4: es P **sin calibrar fiable** en este histórico |
| ev_estimado (EV) | AVAILABLE_BUT_LEAKY | outliers extremos (máx +8050%); usar con recorte |
| odds_apertura (precio a la decisión) | AVAILABLE | 3510/3560; base para ROI honesto |
| odds_cierre, clv_pct | AVAILABLE (parcial, n≈846) | CLV solo desde que se arregló su captura |
| resultado (ganado/perdido/nulo/pendiente), score_final, retorno | AVAILABLE (post-evento) | y=outcome |
| created_at (decisión), match_date (evento), updated_at, clv_registrado_at | AVAILABLE | base de temporalidad |
| odds_source, fuente, pick_tipo, clasificacion | AVAILABLE | provenance ligera |
| **features_input_json / features_json** | **MISSING (100% NULL)** | features pre-evento NO persistidos |
| **data_completeness_pct (data readiness)** | **MISSING (100% NULL)** | readiness NO persistido |
| **deporte** (por evento, histórico) | **MISSING** | `live_scores` no cubre el histórico → no mapea |
| model_version / MODEL_SKILL / modelo_confiable / calibracion_confiable / edge_confiable | MISSING en esta tabla | viven en el motor canónico, no en el tracker |
| lineup status / injuries / availability / freshness | MISSING | nunca se guardó por pick |
| rest / form / matchup / xG / SP / bullpen / park / venue | MISSING | idem — no reconstruibles por pick a T-decisión |

**Consecuencia:** solo hay como señales pre-evento reales por pick: **P, EV, odds_apertura, mercado, clasificacion, fuente, pick_tipo**. El resto del concepto (contexto, lineup, data-readiness, signal-agreement) **no es reconstruible del histórico**.

## 2. TEMPORAL_INTEGRITY_AUDIT = PASS (con exclusiones)
- `created_at < match_date` (decisión antes del evento): **3238 filas** válidas.
- Sentinel `match_date≈created_at` (bug #190 residual): **122 filas** → `EXCLUDE_FROM_V1`.
- `resultado`/`retorno`/`clv` son post-evento (no se usan como feature).
- No hay features pre-evento persistidos, así que no hay riesgo de leakage por lineup/lesión tardía (no existen); pero tampoco hay señal contextual.
- `ev_estimado` con outliers → tratado como AVAILABLE_BUT_LEAKY.
**Regla aplicada en todo el estudio:** `created_at < match_date AND resultado IN ('ganado','perdido') AND odds_apertura>1`.

## 3. HISTORICAL_DECISION_DATASET
- **Grano:** una fila por `oraculo_picks_tracking` (event+market+side+decisión). No se duplica por snapshots (la tabla ya guarda 1 registro por pick).
- **Política canónica de snapshot:** el registro tal como se creó (`created_at`, `odds_apertura`, `probabilidad_real`, `ev_estimado`) = lo que la app efectivamente decidió. No se elige mirando resultados.
- **X** = {P, EV, odds_apertura, mercado, clasificacion, fuente, pick_tipo}. **y** = `resultado='ganado'`.
- **N usable** = 3238 decididos temporalmente válidos (1507 ganados / 1741 perdidos; +161 nulo, +151 pendiente excluidos del hit-rate).

## 4. ACCURACY_BY_P_BUCKET (calibración)
Universo decidido+temporal, ROI a `odds_apertura`, Brier = avg((p−win)²).

| P bucket | N | pred_p | hit_rate | calib_gap | avg_odds | ROI/u | Brier |
|---|---|---|---|---|---|---|---|
| <50 | 1334 | .389 | .430 | +.040 | 2.77 | **+.161** | .248 |
| 50–55 | 112 | .524 | .429 | −.096 | 2.06 | −.124 | .254 |
| 55–60 | 949 | .554 | .504 | −.051 | 1.93 | −.028 | .252 |
| 60–65 | 133 | .622 | .459 | −.164 | 1.90 | −.126 | .275 |
| 65–70 | 59 | .662 | .542 | −.119 | 1.80 | −.032 | .262 |
| 70–75 | 58 | .723 | .569 | −.154 | 1.77 | −.010 | .265 |
| 75–80 | 20 | .767 | **.300** | −.467 | 1.53 | −.555 | .424 |
| 80+ | 68 | .905 | **.544** | −.361 | 1.36 | −.272 | .389 |

**Lectura:** relación P→hit **no monótona**; sobreconfianza severa arriba de 0.60; Brier ≈ trivial o peor. Rankear por P-alta selecciona el peor bucket. Único ROI positivo = longshots (<50), exactamente lo que NO se quiere que domine Top Picks.

## 5. SIGNAL_AGREEMENT_ANALYSIS = DATA_GAP
Requiere señales independientes por pick a T-decisión (modelo/matchup/lineup/contexto/mercado). `features_input_json` está **100% NULL** en el histórico ⇒ **no medible**. No se inventa un patrón de acuerdo.

## 6. ACCURACY_VS_EV_ANALYSIS
- El ROI positivo agregado vive en odds altas (<50% P, odds 2.77) — longshots — no en alta-probabilidad.
- Zona alta-P (favoritos, odds 1.3–1.5): hit-rate real 30–54% con precio caro ⇒ ROI muy negativo.
- No existe una frontera estable "hit-rate alto + economía sana": donde sube el hit-rate cae el precio más rápido. No se impone ningún umbral de EV; simplemente no hay frontera con soporte.

## 7. WALK_FORWARD_RESULTS (mensual, decisión) + 9. TOP_N_BACKTEST (top-cuartil por P)
| mes | N | base_hit | top25%_hit | pred_p | base_ROI | top25%_ROI |
|---|---|---|---|---|---|---|
| 2026-05 | 561 | .460 | .471 | .653 | +.163 | −.154 |
| 2026-06 | 792 | .479 | .475 | .584 | +.063 | −.089 |
| 2026-07 | 591 | .462 | .510 | .619 | −.003 | −.053 |
| 2026-08 | 643 | .463 | .556 | .684 | −.010 | −.037 |
| 2026-09* | 146 | .411 | .444 | .709 | −.056 | −.278 |

Uplift de hit-rate **inconsistente** (nulo may/jun, modesto jul/ago, colapsa sep), sobreconfianza persistente, **ROI del top-cuartil negativo los 5 meses**. El mes más out-of-sample (sep) es el peor. Un selector por P **no** supera de forma fiable el universo base. (*sep parcial.)

## 8. ACCURACY_BY_SPORT_MARKET (deporte histórico mayormente no mapeable)
| deporte | market | N | base_hit | top25%_hit | Δ | avg_odds | base_ROI | calib_gap | Brier | CLV% (n) |
|---|---|---|---|---|---|---|---|---|---|---|
| (desconocido) | Moneyline | 1199 | .428 | .455 | +.027 | 2.63 | +.082 | +.026 | .246 | −4.3 (318) |
| (desconocido) | Over/Under | 1190 | .492 | .525 | +.034 | 1.99 | −.035 | −.066 | .255 | +2.9 (362) |
| (desconocido) | Corners | 119 | .529 | .448 | −.081 | 2.18 | +.276 | −.158 | .357 | +2.1 (21) |
| (desconocido) | BTTS | 103 | .573 | **.720** | **+.147** | 2.47 | **+.393** | +.044 | .256 | +12.1 (29) |
| soccer | Over/Under | 71 | .408 | .412 | +.003 | 2.04 | −.187 | −.157 | .272 | — |

`deporte` sale `(desconocido)` porque `live_scores` (única fuente con `deporte`+`espn_event_id`) no retiene el histórico de estos eventos ⇒ **DATA_GAP de mapeo de deporte histórico**. El mercado es el mejor proxy.

## 10. FAILURE_MODES
1. **Probabilidad no calibrada / no monótona** — coherente con el hilo ISS (calibración apagada/degenerada gran parte del período). El tracker guarda P sin garantía de calibración.
2. **Sobreconfianza en alta-P** — buckets 75–80 y 80+ muy por debajo de lo predicho.
3. **ROI destruido al seleccionar por P** — se compran favoritos sobrevalorados.
4. **Features de contexto ausentes** — imposible medir signal-agreement / data-readiness históricos.
5. **No estacionariedad** — 5 meses con el motor en reparación; no hay régimen estable out-of-sample.
6. **Mapeo de deporte histórico ausente** — no se puede separar limpio por deporte.
7. **Muestra fina en las zonas interesantes** (alta-P, y BTTS) — no permite conclusión.

## 11. TOP_PICK_ACCURACY_V1_DESIGN (condicional — NO construir aún)
Cuando exista evidencia (ver §MINIMAL_CAPTURE), el selector debe ser **ranker/explicador sobre outputs canónicos**, nunca nueva probabilidad:
```
outputs canónicos (P_DECISION, EV_DECISION, es_pick, reason_code)
  → gate temporal + data-readiness (features persistidos a T-decisión)
  → gate de evidencia de modelo (model_version autorizado / MODEL_SKILL)
  → ACCURACY_EVIDENCE = hit-rate histórico out-of-sample del bucket/contexto (calibración medida, no P cruda)
  → orden por evidencia de acierto, EV como 2ª dimensión (economía sana)
  → TOP PICKS (+ explicación)
```
Prohibido: cambiar P_DECISION/EV_DECISION, calcular Kelly/stake, autorizar modelos. Solo seleccionar/rankear/explicar.
**No se propone parametrización** porque la data aún no la determina.

## 12. FRONTEND_PRODUCT_SPEC (gated)
Tres superficies separadas, todas fail-closed respecto a gobernanza (nada aquí autoriza dinero; `stake=$0` mientras NONE):
- **🏆 TOP PICKS** — solo cuando `TOP_PICK_ACCURACY_V1=EVIDENCE_SUPPORTED`. Hoy: **oculto / "sin evidencia suficiente todavía"**.
- **🔥 MÁS PROBABLES** — `P_DECISION DESC` entre modelos/data confiables; puede incluir EV negativo etiquetado "MUY PROBABLE / MAL PRECIO". Se puede mostrar ya como informativo (no accionable).
- **💰 VALUE PICKS** — EV alto económicamente válido, hit-rate menor, claramente etiquetado.
- **TRACK RECORD** — siempre hit-rate + N + avg_odds + ROI + CLV + Brier/calibración juntos; nunca hit-rate aislado.

## TABLA FINAL
| SPORT | MARKET | N | BASE_HIT | TOP_PICK_HIT | DELTA | AVG_ODDS | ROI | CLV | CALIB | STATUS |
|---|---|---|---|---|---|---|---|---|---|---|
| (mixto) | Moneyline | 1199 | .428 | .455 | +.027 | 2.63 | +.082 | −4.3% | +.026 | INSUFFICIENT (no monótono; ROI de longshots) |
| (mixto) | Over/Under | 1190 | .492 | .525 | +.034 | 1.99 | −.035 | +2.9% | −.066 | INSUFFICIENT (uplift débil, ROI≤0) |
| (mixto) | Corners | 119 | .529 | .448 | −.081 | 2.18 | +.276 | +2.1% | −.158 | INSUFFICIENT (selector empeora) |
| (mixto) | BTTS | 103 | .573 | .720 | +.147 | 2.47 | +.393 | +12.1% | +.044 | CANDIDATE — N INSUFICIENTE (cuartil≈26) |
| soccer | Over/Under | 71 | .408 | .412 | +.003 | 2.04 | −.187 | — | −.157 | INSUFFICIENT |
| MLB / NFL / NHL / NBA / Tennis | — | — | — | — | — | — | — | — | — | INSUFFICIENT (sin mapeo de deporte histórico / sin muestra separable) |

## DATA_GAP / IMPACT / MINIMAL_CAPTURE_NEEDED_FORWARD
- **DATA_GAP 1 — features pre-evento por pick.** IMPACT: imposibilita accuracy-evidence contextual y signal-agreement (FASE 5). MINIMAL_CAPTURE_FORWARD: persistir en `oraculo_picks_tracking.features_input_json` a T-decisión: `{model_version, P_RAW, P_DECISION, EV_DECISION, calibracion_confiable, MODEL_SKILL, data_completeness_pct, señales por-deporte disponibles (lineup_status, injuries_count, rest, matchup, SP/bullpen MLB, xG-válido soccer), signal_flags}`. (Forward, en el pipeline de escritura; **no** DDL aquí.)
- **DATA_GAP 2 — data_completeness_pct siempre NULL.** IMPACT: no hay gate de data-readiness histórico. FORWARD: poblar el campo existente al crear el pick.
- **DATA_GAP 3 — deporte por evento histórico.** IMPACT: no separable por deporte (FASE 8). FORWARD: escribir `deporte` en `oraculo_picks_tracking` al crear el pick (columna nueva forward) o preservar `live_scores.deporte`/`agenda_espn` para históricos.
- **DATA_GAP 4 — calibración del P registrado.** IMPACT: la P histórica no rankea acierto. FORWARD: registrar P_DECISION calibrada (autoridad canónica) además de P_RAW, y re-medir calibración hacia adelante (como #56/#139) antes de cualquier selector.
- **DATA_GAP 5 — CLV parcial (n≈846).** IMPACT: economía incompleta. FORWARD: seguir capturando open/close (ya arreglado en #20/#157) hasta cubrir todos los picks.

## CRITERIOS ANTIOVERFIT (cumplidos)
- Sin pesos inventados, sin thresholds elegidos tras ver resultados, sin optimizar a 8/10.
- Walk-forward temporal (no random split); el mes final se dejó como está (no se tuneó).
- No se declara PASS sin N: BTTS queda CANDIDATE por N insuficiente, no PASS.
- Resultado reportado tal cual: `INSUFFICIENT_EVIDENCE`.
