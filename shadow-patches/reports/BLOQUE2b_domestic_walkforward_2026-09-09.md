# BLOQUE 2b — VALIDACIÓN FINAL STAGED DE LIGAS DOMÉSTICAS (modelo EXACTO de producción)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie`
estado: `READ_ONLY_VERIFIED` (Supabase read-only, sin mutación) · PROD_FREEZE=ON
ligas: Bélgica/Jupiler=144 · Noruega/Eliteserien=103 · Grecia/Super League=197 ·
Dinamarca/Superliga=119 · Escocia/Premiership=179

## 0. Qué modelo se evaluó (parity con producción, §68)
NO se usó una reimplementación de laboratorio. Se evaluó **la función de scoring de
producción `v2.fn_score_dist`** directamente, alimentada con features **AS-OF**
idénticas al builder staged `v2.fn_soccer_features_asof` (iss033):

- FINAL only, `fecha < decision_time` (aquí decision_time = fecha del partido; el
  partido target queda excluido por el `<` estricto).
- split producción: GF/GC del LOCAL como local; GF/GC del VISITANTE como visitante.
- ventana 540 días (registry `window_days`).
- league means (`league_mean_home/away`) calculadas **AS-OF** (misma ventana), no
  el agregado móvil global → sin fuga (§66).
- sample floor `>=8` (registry `sample_floor`).
- deterministic Dixon-Coles → **toda predicción es OOS por construcción** (no hay
  fitting de parámetros por liga; el modelo no "vio" el partido).

Por tanto `MODEL_IMPLEMENTATION_PARITY_GATE = PASS` por diseño: lo evaluado ES la
función de producción, no un proxy.

## 1. Baselines (§10)
- **BASELINE A** — tasas base empíricas de la competencia, calculadas AS-OF con el
  mismo cutoff por partido (P(H)/P(D)/P(A) en la ventana previa). Es el baseline
  honesto: "predecir la frecuencia histórica reciente de la liga".
- Métrica primaria: **ganancia de Brier pareada** = Brier(baseline) − Brier(modelo)
  por partido; media + IC95% analítico (media ± 1.96·SE, SE = sd/√n). Determinista
  (§69), sin RNG.

## 2. Discriminación OOS — ganancia de Brier vs Baseline A (VERIFICADO)
| liga | n | gain_mean | IC95% low | IC95% high | ¿IC>0? |
|---|---|---|---|---|---|
| 197 Grecia    | 409 | **+0.0477** | +0.0144 | +0.0811 | **SÍ (significativo)** |
| 119 Dinamarca | 465 | +0.0126 | −0.0155 | +0.0406 | no (cruza 0) |
| 103 Noruega   | 530 | +0.0116 | −0.0156 | +0.0388 | no (cruza 0) |
| 179 Escocia   | 331 | +0.0039 | −0.0371 | +0.0450 | no (~empate) |
| 144 Bélgica   | 777 | −0.0113 | −0.0365 | +0.0140 | no (**peor** que base) |

Sólo **Grecia** vence a la tasa base AS-OF con IC enteramente > 0.

## 3. Calibración / discriminación absoluta (VERIFICADO)
| liga | n | acc | Brier(modelo) | LogLoss | ECE (10 bins) |
|---|---|---|---|---|---|
| 197 Grecia    | 409 | 0.5355 | 0.5998 | 1.0201 | **0.0508** (mejor calibrada) |
| 103 Noruega   | 530 | 0.5038 | 0.6167 | 1.0389 | 0.0999 |
| 119 Dinamarca | 465 | 0.4946 | 0.6420 | 1.0657 | 0.0914 |
| 179 Escocia   | 331 | 0.4955 | 0.6406 | 1.1010 | 0.1571 (mal calibrada) |
| 144 Bélgica   | 777 | 0.4595 | 0.6652 | 1.1150 | 0.1577 (peor calibrada) |

Grecia: mejor accuracy, mejor Brier, mejor ECE — consistente con la ganancia.
Bélgica/Escocia: ECE ~0.157 (sobreconfianza) además de no discriminar.

## 4. Estabilidad por temporada (VERIFICADO, gain = Brier(base A) − Brier(modelo))
| liga | 2023 | 2024 | 2025 | 2026 | patrón |
|---|---|---|---|---|---|
| 197 Grecia    | — | −0.0515 (n65) | +0.0744 (n199) | +0.0556 (n145) | 2 recientes fuertes + |
| 103 Noruega   | — | −0.0189 (n195) | +0.0512 (n209) | +0.0026 (n107) | signo alterna |
| 119 Dinamarca | — | +0.0374 (n162) | +0.0024 (n181) | −0.0048 (n118) | decae a empate/neg |
| 144 Bélgica   | +0.1382 (n30) | −0.0159 (n282) | −0.0384 (n282) | +0.0131 (n183) | neg en muestras grandes |
| 179 Escocia   | — | — | −0.0171 (n191) | +0.0340 (n138) | signo alterna |

- Grecia: 2024 negativo pero n=65 (ventana AS-OF aún delgada al inicio del histórico);
  2025 y 2026 fuertemente positivos y grandes. Señal estable en las 2 temporadas
  con historia AS-OF completa.
- Noruega/Escocia: el signo se invierte entre temporadas → inestable.
- Dinamarca: tendencia descendente hacia empate/negativo.
- Bélgica: el único año positivo grande fue el 2023 con n=30; en 2024–2025 (n=282
  cada uno) el modelo es peor que la base.

## 5. ¿Calibración rescata a Noruega/Dinamarca? (§9, §11)
No. Grecia YA está bien calibrada (ECE 0.0508) — no necesita capa. Para
Noruega/Dinamarca el problema NO es calibración sino **falta de discriminación**
(la ganancia de ranking no es significativa; IC cruza 0). Una capa Platt/isotónica
mejora la fiabilidad pero **no crea discriminación** donde el orden no separa señal
de ruido (coincide con el hallazgo del issue #191: "Platt NO sirve; el skill
negativo es falta de información, no de calibración"). Por tanto no se aplica
calibración para forzar aprobación. `FAIL-CLOSE`.

## 6. DECISIÓN FINAL POR LIGA (staged; NO `approved=true` en prod)
| liga | decisión | razón |
|---|---|---|
| 197 Grecia    | **APPROVABLE_STAGED** | única con IC>0 (+0.0477), mejor ECE (0.0508), estable en 2025/2026 |
| 103 Noruega   | **NOT_APPROVABLE** | IC cruza 0; signo alterna por temporada |
| 119 Dinamarca | **NOT_APPROVABLE** | IC cruza 0; decae a empate/negativo |
| 179 Escocia   | **NOT_APPROVABLE** | empate (+0.0039); ECE 0.157; signo alterna |
| 144 Bélgica   | **NOT_APPROVABLE** | peor que base (−0.0113); peor ECE (0.157) |

## 7. REVERSIÓN HONESTA vs BLOQUE 2 (lab-fit) — §42, §2
El BLOQUE 2 previo (fit de laboratorio) daba 3 ligas APPROVABLE (Bélgica entre las
más fuertes). Al evaluar con el **modelo EXACTO de producción** (Dixon-Coles
determinista sobre features AS-OF), esa conclusión **se cae**: sólo Grecia sobrevive.
El fit de laboratorio medía un modelo distinto al que iría a producción → su
validación no aplicaba. Esta es la corrección que pedía §68 (parity lab→producción).

## 8. Leakage / integridad
- 0 partidos LIVE/futuros en el fit: `fecha < decision` estricto + FINAL only.
- league means AS-OF (no futuro) → `DOMESTIC_FEATURE_REPLAY` respetado (§66).
- Zero-row guard (§61): cada liga con n≥331 partidos usable → no hay 0/0.

## 9. Estado de gates
- `DOMESTIC_VALIDATION_GATE = APPROVABLE_STAGED (1 de 5: Grecia)` — el resto FAIL_CLOSED.
- `MODEL_IMPLEMENTATION_PARITY_GATE = PASS` (se evaluó la función de producción).
- Ninguna liga se marca `approved=true`. Cutover requiere autorización externa.

## 10. Reproducir (read-only)
Consultas guardadas en `shadow-patches/reports/BLOQUE2b_queries.sql`. Todas contra
`public.historico_partidos_espn` + `v2.fn_score_dist` (producción). Sin DDL, sin mutación.
