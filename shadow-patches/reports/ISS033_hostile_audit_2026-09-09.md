# ISS033 — AUDITORÍA HOSTIL DE PRODUCCIÓN SIMULADA (§6) + REPLAY ADVERSARIAL (§7)

artefacto: `shadow-patches/prepared/iss033_temporal_reproducible_builder.sql`
estado: `STAGED_NOT_EXECUTED` (endurecido tras esta auditoría) · PROD_FREEZE=ON
método: revisión línea-por-línea + verificación READ-ONLY contra prod (sin mutación).

## Resumen
La auditoría hostil encontró **3 defectos reales que habrían roto el builder en branch**
(F1, F2, F7) y varios findings de gobernanza (F3, F4, F5, F6). F1/F2/F3/F5/F7 corregidos
en el archivo staged; F4/F6 documentados como gates. El replay adversarial (§7) **PASA**.

## Checklist §6 (A–S)
| # | comprobación | veredicto | evidencia |
|---|---|---|---|
| A | sólo FINAL/COMPLETED | PASS | historico_partidos_espn: 42,538 filas, **0 con score null**; tabla es FINAL-only por construcción (no hay status LIVE). |
| B | kickoff < decision_time | PASS | `fecha` ES `timestamptz` (kickoff real, no día); filtro `fecha < decision` estricto. |
| C | target excluido explícitamente | **FIXED (F3)** | antes sólo por `fecha<decision`; ahora `p_exclude_event_id` excluye el event_id target aunque aparezca en histórico con fecha defectuosa. |
| D | home/away mismo cutoff | PASS | ambos CTE usan `fecha<decision and fecha>=decision-window`. |
| E | GF/GA local/visita mismo cutoff | PASS | idem WHERE. |
| F | φ cross-league replay | **FAIL (F4)** → gate | iss033 es sólo dominio (fn_score_dist). El path cross-league (iss027) usa `v2.liga_fuerza` SIN training_cutoff/version → no replayable. `CROSS_LEAGUE_REPLAY_GATE=FAIL`. |
| G | config registry-driven | PARTIAL | `v2.model_config` da sample_floor/window/feature_version/calibration; `model_version='dc-2026.09.1'` es literal de selección (aceptable). |
| H | temporal_safe calculado | PASS (F6 nota) | `max_source_event_time<=decision`; **near-tautológico** dado el filtro `fecha<decision` (sólo detecta el caso null). Guarda real de disponibilidad = F5. |
| I | agenda es universo (LEFT JOIN) | PASS | agenda LEFT JOIN alias/catalog/registry; no soportados quedan con competition_id null → model_status NO_MODEL. |
| J | unsupported no desaparece | PASS | todos LEFT JOIN. |
| K | sin re-join a agregado móvil | PASS | contrato canónico lee `soccer_prediction_v2_staged`, no `v_goles_equipo_futbol`. |
| L | inputs = snapshot congelado | **FIXED (F1)** | la tabla `feature_snapshot` existía pero **el builder nunca la llenaba**; ahora se persiste vía CTE data-modifying y se guarda `feature_snapshot_id` en la predicción. |
| M | btts_yes+btts_no misma dist | PASS | ambos de `fn_score_dist` (misma jsonb). Keys verificadas: incluye btts_yes y btts_no. |
| N | nunca btts_no=100-btts_yes | PASS | builder toma `d->>'btts_no'`. |
| O | O/U línea real | PASS | `fn_real_total_line` (v_momios_confiables). |
| P | line_asof<=decision | PASS | iss032 filtra snapshot_at<=decision (BLOQUE 4 GREEN 77/77). |
| Q | sin fallback 2.5 | PASS | fn_real_total_line fail-closes → over_line null → p_over/p_under null. |
| R | sin nearest line silenciosa | PASS | iss032. |
| S | sin alternate como provider | PASS | iss032. |

## Defectos encontrados y corregidos
- **F1 (crítico) — snapshot no persistido.** `v2.feature_snapshot` se creaba pero el
  builder **nunca insertaba**. `snapshot_tbl_exists=0` en prod (staged, nunca corrido),
  y aunque se corriera, quedaría vacío. FIX: CTE `snap` (INSERT ... ON CONFLICT DO
  UPDATE RETURNING) + `feature_snapshot_id` en la fila de predicción. `FEATURE_SNAPSHOT_GATE`
  pasa de FAIL a STAGED_ONLY (a validar en branch).
- **F2 (crítico) — tabla destino inexistente.** El builder hacía `insert into
  v2.soccer_prediction_v2_staged` pero **la tabla nunca se creaba** (`staged_tbl_exists=0`).
  Habría fallado en branch. FIX: `CREATE TABLE IF NOT EXISTS` con PK (event, decision, model_version).
- **F7 (crítico) — record var en FROM.** `from calc c, cfg, lateral(...)`: `cfg` es una
  variable `record` de plpgsql; usarla como tabla en FROM es inválido → error en runtime.
  Sus campos ya se usan como escalares. FIX: eliminada `cfg` del FROM; `lateral` pasa a
  `cross join lateral`.
- **F3 — target no excluido explícitamente.** FIX: parámetro `p_exclude_event_id`.
- **F5 — disponibilidad vs fecha deportiva.** `historico` tiene `cargado_at` (timestamptz).
  Para PRODUCCIÓN HACIA ADELANTE conviene `cargado_at<=decision`; para REPLAY histórico
  `cargado_at` es tiempo de backfill (bulk, posterior) → inutilizable. FIX: parámetro
  `p_enforce_availability` (default false=replay). `max_source_event_time` sigue siendo
  el kickoff máximo. Residual documentado: ingesta forward debe estampar `available_at`.
- **F6 — temporal_safe near-tautológico.** Documentado; la garantía real de no-fuga la da
  el filtro `fecha<decision` + F3 + (forward) F5.

## Invariantes de modelo (VERIFICADO, 383 vectores as-of reales)
- 1X2: `max|Σ−100| = 0.10` → PASS con tolerancia ±0.1 (fn_score_dist redondea a 1 decimal;
  3 valores redondeados pueden sumar 99.9/100.1). `1X2_INVARIANT_GATE=PASS(tol 0.1)`.
- BTTS: `max|yes+no−100| = 0.00` → `BTTS_INVARIANT_GATE=PASS`.
- O/U: `max|over+under−100| = 0.00` → `OU_INVARIANT_GATE=PASS`.

## Replay adversarial §7 (VERIFICADO, read-only, 5 perfiles)
Test: computa features AS-OF (A); inyecta 3 partidos sintéticos POSTERIORES a decision
(goleadas 9-0/0-8/7-1); recomputa AS-OF (B); computa agregado MÓVIL contaminado.
Invariante: **A == B** (as-of inmune) y **MÓVIL ≠ A** (el filtro importa).

| perfil | liga | decision | A home_gf | B home_gf | móvil home_gf | as-of inmune | móvil contaminado |
|---|---|---|---|---|---|---|---|
| LaLiga | 140 | 2025-05-25 | 1.7931 | 1.7931 | 1.9016 | ✅ | ✅ |
| Grecia | 197 | 2025-05-22 | 1.0000 | 1.0000 | 1.8000 | ✅ | ✅ |
| UCL | 2 | 2025-05-31 | 2.0909 | 2.0909 | 2.9231 | ✅ | ✅ |
| UEL | 3 | 2025-05-21 | 2.2857 | 2.2857 | 3.3000 | ✅ | ✅ |
| Bélgica | 144 | 2025-08-03 | 1.4231 | 1.4231 | 1.6667 | ✅ | ✅ |

5/5: as-of idéntico tras inyectar goleadas post-decision; móvil contaminado en 5/5.
Reproduce el bug original (Barcelona móvil 2.816 vs as-of 2.774). Como A==B, `fn_score_dist(A)==fn_score_dist(B)` trivialmente (determinista, sin RNG → §69). `TEMPORAL_GATE=PASS` para el builder as-of. Query: `shadow-patches/tests/iss033_adversarial_replay_readonly.sql`.

## Gates resultantes
| gate | estado |
|---|---|
| TEMPORAL_LEAKAGE_GATE (builder as-of) | PASS (read-only) |
| HISTORICAL_REPLAY_GATE (dominio) | PASS (A==B, determinista) |
| FEATURE_SNAPSHOT_GATE | STAGED_ONLY (F1 corregido; validar en branch) |
| 1X2 / BTTS / O/U INVARIANT | PASS |
| CROSS_LEAGUE_REPLAY_GATE | **FAIL** (F4: φ sin versión/cutoff — pendiente snapshot de fuerza versionado) |
| REGISTRY_GATE | PARTIAL (model_config presente; literal de versión aceptable) |
| BRANCH_EXECUTION_GATE | NOT_RUN (requiere Supabase branch) |

## Residuales / próximos
1. F4: crear snapshot de `liga_fuerza` versionado (`phi_model_version`, `phi_training_cutoff`)
   para replay cross-league → sube CROSS_LEAGUE_REPLAY_GATE.
2. Ejecutar iss033 en Supabase branch (no en prod) para validar F1/F2/F7 en vivo.
3. Ingesta forward debe estampar `available_at` real para activar `p_enforce_availability`.
