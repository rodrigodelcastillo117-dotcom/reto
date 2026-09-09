# CLAUDE_REPORT_BACKEND_SOCCER_CLOSURE

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie`
frontend: NOT TOUCHED (SINGLE_WRITER: ChatGPT owns Remix/Lovable/reto13)
gates globales: `SOCCER_GATE=FAIL` · `RELEASE_GATE=HOLD` · `PROD_FREEZE=ON` · `FULL_DATA_SOCCER_ANALYSIS_GATE=FAIL`
Todo STAGED bajo `shadow-patches/`. NO deploy, NO prod mutation, NO schema change aplicado.
NO se declara SOCCER cerrado (§56: los gates de frontend los controla ChatGPT).

## Bloques — IMPLEMENTATION + TEST + EVIDENCE + STAGED ARTIFACT
| Bloque | Estado | Artefacto | Evidencia |
|---|---|---|---|
| 1 Cross-league | APPROVABLE_STAGED (UCL/UEL) | iss027 + lab/champions_crossleague_v1 | walk-forward+bootstrap; resto fail-close |
| 2b Ligas domésticas | APPROVABLE_STAGED (**sólo Grecia**) / NOT_APPROVABLE (4) | iss029 + BLOQUE2b report | modelo prod fn_score_dist AS-OF; IC95%, ECE, estabilidad |
| 3 Dossier manifest | STAGED + coverage distribución | iss030 + dossier_coverage report | 241 universo; MODEL_ACTIVE 203, total_line 143, resto missing/NO_ASOF |
| 4 Línea real | GREEN | iss032 | 77/77 snapshot_at<=decision, 0 fabricadas |
| 5 Contrato canónico | STAGED (endurecido) | iss033 (v_soccer_canonical) | btts_yes+btts_no explícitos; sin agregado móvil |
| 6 Análisis backend | STAGED (limpio, separado) | iss023 | P_RETO único; 0 recalc; 0 legacy en soccer |
| 6b Builder temporal | STAGED (endurecido) | iss033 | replay adversarial 5/5; F1/F2/F3/F7 corregidos |
| 7 Identidad/scanner | STAGED (backend) | iss031 | parlay a3135134: af_ resueltos por resolver fuerte |
| 8 Grading GAP A | STAGED + guard universal en prod | iss028 + iss034 | todas las rutas gateadas por is_truly_final |
| 8 Bankroll GAP B | PASS (diseño) + fix cache | iss035 | SUM idempotente; 3× 5035.00 |
| Daily canónico | STAGED | iss036 | reemplaza v_reto13m_daily (sin 2.5 fijo, sin btts-no complemento) |
| Agenda universo | STAGED (diseño PASS) | iss033 LEFT JOIN + regresión | 241/241 (0 drops) vs 38 desaparecidos hoy |

## GATE MATRIX (§54) — PASS/FAIL/BLOCKED/NOT_RUN/STAGED_ONLY
| gate | estado | evidencia |
|---|---|---|
| TEMPORAL_LEAKAGE_GATE | PASS | as-of fecha<decision; 0 live/futuro en fit |
| HISTORICAL_REPLAY_GATE | PASS | replay adversarial A==B 5/5; determinista |
| FEATURE_SNAPSHOT_GATE | STAGED_ONLY | F1 corregido (snap persistido); validar en branch |
| REGISTRY_GATE | STAGED_ONLY (PARCIAL) | model_config presente; literal de versión aceptable |
| EVENT_IDENTITY_GATE | STAGED_ONLY | iss031 resolver fuerte |
| COMPETITION_IDENTITY_GATE | STAGED_ONLY | liga_id ESPN canónico; alias/catalog |
| AGENDA_UNIVERSE_GATE | STAGED_ONLY (diseño PASS) | 241==241 LEFT JOIN; prod aún INNER JOIN |
| DUPLICATE_EVENT_GATE | STAGED_ONLY | iss031 collapse por event id |
| 1X2_INVARIANT_GATE | PASS (tol 0.1) | 383 vectores; redondeo 1 decimal |
| BTTS_INVARIANT_GATE | PASS | yes+no=100 exacto (383) |
| OU_INVARIANT_GATE | PASS | over+under=100 exacto (383) |
| REAL_LINE_GATE | PASS | 77/77 provider real |
| LINE_TEMPORAL_GATE | PASS | snapshot_at<=decision |
| CROSS_LEAGUE_VALIDATION_GATE | APPROVABLE_STAGED | UCL/UEL OOS |
| CROSS_LEAGUE_REPLAY_GATE | **FAIL** | φ (liga_fuerza) sin versión/cutoff — pendiente snapshot versionado |
| DOMESTIC_VALIDATION_GATE | APPROVABLE_STAGED (1/5 Grecia) | BLOQUE 2b |
| DOSSIER_SCHEMA_GATE | STAGED_ONLY | iss030 emite todas las fuentes |
| DOSSIER_TEMPORAL_GATE | STAGED_ONLY | as_of<=decision; NO_DECISION_TIME fail-close |
| DOSSIER_COVERAGE_GATE | PASS (read-only, staged) | distribución sobre 241; 0 anomalías |
| MODEL_ACTIVE_ROLE_GATE | STAGED_ONLY | features as-of; prod aún usa agregado móvil |
| CANONICAL_CONTRACT_GATE | STAGED_ONLY | 1 fila/evento; btts_no explícito |
| ANALYSIS_NO_RECALC_GATE | PASS (soccer) | iss023 no recalcula P |
| ANALYSIS_NO_LEGACY_GATE | PASS (soccer hot path) | 0 fuentes de P en competencia |
| DAILY_NO_FIXED_LINE_GATE | STAGED_ONLY | iss036 O/U a línea real; sin 2.5 |
| GRADING_FINAL_ONLY_GATE | PASS | guard universal is_truly_final |
| EARLY_PAYOUT_GATE | STAGED_ONLY | iss028 PA evidencia obligatoria |
| PARLAY_EARLY_LOSS_GATE | PASS | guard + iss034 |
| BANKROLL_IDEMPOTENCE_GATE | PASS | SUM state-based idempotente |
| BACKEND_TEST_GATE | STAGED_ONLY | tests en shadow-patches/tests |
| BRANCH_EXECUTION_GATE | NOT_RUN | requiere Supabase branch (autorización/coste) |
| CUTOVER_READINESS_GATE | STAGED_ONLY | runbook + DAG preparados |
| FULL_DATA_SOCCER_ANALYSIS_GATE | **FAIL** | falta: branch execution + migrar builder prod a as-of |

## Estados precisos (§42)
- READ_ONLY_VERIFIED: BLOQUE 2b, replay adversarial, invariantes, agenda universo, dossier
  coverage, bankroll idempotencia, predictive-source audit, grading routes.
- STAGED_NOT_EXECUTED: iss027..iss036 (SQL), tests SQL.
- NOT_RUN: ejecución en Supabase branch (BRANCH_EXECUTION_GATE).
- PROD_NOT_CUTOVER: v_futpro_v2 sigue con INNER JOIN + agregado móvil; v_reto13m_daily
  contaminada; grading/bankroll con defs previas (guard universal ya protege).

## Blockers exactos (requieren autorización)
1. Crear Supabase branch (posible coste) → ejecutar iss027..036 + tests (BRANCH_EXECUTION_GATE).
2. CROSS_LEAGUE_REPLAY_GATE: versionar `liga_fuerza` (phi_model_version/phi_training_cutoff).
3. Cutover: migrar `build_soccer_prediction_v2` a as-of + recomponer `v_futpro_v2`
   (exponer btts_no; dejar de re-unir agregado móvil).
4. Reemplazo de funciones grading/bankroll (iss028/034/035) + approval Grecia (iss029).

## Operaciones que requerirán autorización de deploy
Ver `shadow-patches/SOCCER_CUTOVER_RUNBOOK.md` y `shadow-patches/STAGED_MIGRATION_DAG.md`.
NO Sudamericana. NO frontend. NO NFL/MLB/Tennis. NO PROD MUTATION bajo freeze.
