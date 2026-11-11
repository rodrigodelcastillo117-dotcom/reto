# BLOQUE 1 — Champions / Cross-League Model · EVIDENCIA

## Estado
`CROSS_LEAGUE_V1 = APPROVABLE_STAGED / FINAL_VALIDATION_PENDING`
NO "cerrado/validado". STAGED, sin deploy. Rama `claude/reto-13m-espn-matches-3uknie`.
Artefacto: `shadow-patches/prepared/iss027_champions_crossleague_model.sql`.
Código+evidencia reproducible: `lab/champions_crossleague_v1/`
(`fit_crossleague.py`, `validate_v2.py`, `validation_v2.json`, `EVIDENCE_*`).

## Modelo
Dixon-Coles Poisson con **fuerza de liga φ identificable** (ref Premier=0, ridge=10),
fuerza de equipo = tasas de gol domésticas en ventana móvil **estrictamente anterior**
al kickoff, ventaja de local γ explícita, corrección ρ de marcadores bajos.
**floor doméstico=15** (elegido por VALIDACIÓN, ver FL). NO usa odds/mercado.

## (L) LEAKAGE GATE — PASS
- Entrenamiento = SÓLO partidos FINAL (score no nulo); **0 filas fechadas hoy/futuro**;
  max fecha del fit = 2026-09-08. Verificado por SQL sobre `historico_partidos_espn`
  y por asserts en `validate_v2.py::leakage_asserts`.
- Los 3 partidos LIVE de hoy (Barça-Feyenoord, Liverpool-Atlético, Stuttgart-Viking,
  2026-09-09) **NO están en el histórico** → imposible que entren al fit.
- Features de cada equipo con `data_asof` estrictamente < kickoff (verificado:
  Barça 09-06, Feyenoord 09-05, Liverpool 09-04, Atlético 09-05, Stuttgart 09-04,
  Viking 09-04; todos < 09-09 16:45). Un marcador live nunca entra al fit ni al feature.

## (B) BASELINE FUERTE
Mismo Dixon-Coles, mismas features, misma regularización; **única diferencia = quitar φ
de liga**. Toda comparación abajo es cross-league(φ) vs este baseline.

## (WF) WALK-FORWARD por fold (floor=5, ridge=10) — MIXTO (honesto)
| test desde | n_train | n_val | n_test | Brier | LogLoss | ΔBrier | ΔLogLoss | CI ΔBrier |
|---|---|---|---|---|---|---|---|---|
| 2025-02-01 | 212 | 163 | 144 | 0.6031 | 1.0042 | +0.0074 | +0.0132 | [-0.017,+0.034] |
| 2025-08-01 | 375 | 144 | 186 | 0.5929 | 0.9946 | **+0.0242** | +0.0311 | **[+0.004,+0.044]** |
| 2026-03-01 | 519 | 210 |  92 | 0.6156 | 1.0254 | -0.0080 | -0.0117 | [-0.049,+0.032] |

Un fold significativamente positivo; dos con CI que cruza 0 (uno leve negativo, n=92).
Señal real pero NO uniforme entre folds → por eso APPROVABLE_STAGED, no VALIDADO.

## (C) POR COMPETENCIA en test (cut 2025-02-01) — decisivo
| Competencia | n | Brier | LogLoss | ΔBrier vs base | ECE | Veredicto |
|---|---|---|---|---|---|---|
| UCL | 207 | 0.6069 | 1.0118 | **+0.0166** | 0.018 | **APROBABLE** |
| UEL | 136 | 0.5979 | 1.0006 | **+0.0285** | 0.028 | **APROBABLE** |
| Concacaf | 54 | 0.6045 | 1.0058 | -0.0051 | 0.119 | fail-close |
| Conference | 32 | 0.6121 | 1.0233 | -0.0113 | 0.037 | fail-close |
| FIFA CWC | 21 | 0.5324 | 0.9062 | -0.0116 | 0.166 | fail-close (n chico) |
| AFC Elite | 1 | — | — | — | — | fail-close (n=1) |
| Libertadores | 0 | — | — | — | — | fail-close (sin test usable) |

**El beneficio cross-league se concentra en UCL y UEL** (mejora OOS + bien calibrados).
Regla respetada: no se aprueba una competencia por el promedio global. Sólo UCL+UEL.

## (ID) IDENTIFICABILIDAD φ — ref liga=39 fija a 0
φ por fold (estabilidad de las ligas débiles):
- fold<2025-02: Grecia -0.33, Turquía -0.28, Eredivisie -0.22 … Liga MX +0.18
- fold<2025-08: Grecia -0.36, MLS -0.35, Turquía -0.31 …
- fold<2026-03: Escocia -0.42, Eredivisie -0.38, Grecia -0.37 …
Ligas débiles estables en signo/orden; mid-table con más varianza (esperado con la muestra).

## (FL) SAMPLE FLOOR — elegido por VALIDACIÓN (no test)
| floor | n_train | n_val | val Brier | val LogLoss |
|---|---|---|---|---|
| 5 | 232 | 143 | 0.6335 | 1.0518 |
| 8 | 206 | 140 | 0.6371 | 1.0561 |
| 10 | 189 | 138 | 0.6292 | 1.0463 |
| **15** | 136 | 135 | **0.6186** | **1.0301** |
→ **floor óptimo = 15**. El modelo final y el SQL usan floor=15 (n_train=722).

## Prueba prematch de los 3 partidos (snapshot congelado, floor=15)
Features con `data_asof < kickoff` (probado). Los 3 son UCL (competencia aprobada).
| Partido | Local | Empate | Visita | O2.5 | BTTS |
|---|---|---|---|---|---|
| Barcelona–Feyenoord | 79.4% | 11.8% | 8.8% | 76.0% | 57.9% |
| Liverpool–Atlético | 54.1% | 21.3% | 24.6% | 58.0% | 57.2% |
| Stuttgart–Viking | 56.9% | 19.1% | 24.0% | 69.2% | 65.7% |
(Sin usar resultados en vivo como evidencia — sólo demostración de que el modelo
publica prematch para competencias aprobadas.)

## VERDICTO
`CROSS_LEAGUE_V1 = APPROVABLE_STAGED / FINAL_VALIDATION_PENDING`.
Defendible OOS **sólo para UCL y UEL** (mejora significativa + buena calibración).
Guardas en SQL: competencia aprobada (UCL/UEL), liga servible (≥20 cruzados),
muestra doméstica ≥15/equipo, data_asof ≤ decision_time, Sudamericana sin pick.
NO se enciende hasta: (a) validación final con más temporadas para estabilizar los
folds, (b) ejecución humana de iss027, (c) approval en `v2.model_registry` (bajo freeze: no aplicar).

## Operaciones que requerirán autorización de deploy posterior
1. Ejecutar `iss027` (crea tablas + funciones cross-league).
2. Integrar `fn_crossleague_p_reto` en `v2.build_soccer_prediction_v2` para competencias cruzadas.
3. Approval en `v2.model_registry` SÓLO UCL(2) + UEL(3).
