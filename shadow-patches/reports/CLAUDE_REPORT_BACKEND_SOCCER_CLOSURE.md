# CLAUDE_REPORT_BACKEND_SOCCER_CLOSURE

branch: `claude/reto-13m-espn-matches-3uknie` (repo `reto`)
backend_sha: `9127654`
frontend: NOT TOUCHED (SINGLE_WRITER: ChatGPT owns Remix/Lovable)
gates: `SOCCER_GATE=FAIL` · `RELEASE_GATE=HOLD` · `PROD_FREEZE=ON`
All artifacts STAGED under `shadow-patches/` — NO deploy, NO prod mutation, NO schema change applied.

## Bloques — IMPLEMENTATION + TEST + EVIDENCE + STAGED ARTIFACT
| Bloque | Estado | Artefacto | Test/Evidencia |
|---|---|---|---|
| 1 Cross-league | APPROVABLE_STAGED (UCL/UEL) | iss027 + lab/champions_crossleague_v1 | walk-forward+bootstrap; 3 partidos; 9 gates |
| 2 Ligas domésticas | APPROVABLE_STAGED (3) / NOT_APPROVABLE (2) | iss029 + lab/domestic_leagues_v1 | OOS Brier/LogLoss/ECE/estabilidad; leakage 0 |
| 3 Dossier manifest | IMPLEMENTADO+VALIDADO (falta test en branch) | iss030 v2 + test | 2 eventos reales; findings 2-9 |
| 4 Línea real | GREEN | iss032 | 77/77 con snapshot_at<=decision, 0 fabricadas |
| 5 Contrato canónico | STAGED | iss033 (v_soccer_canonical) | btts_yes+btts_no explícitos; sin agregado móvil |
| 6 Builder temporal | STAGED | iss033 (build_staged + feature_snapshot) | replay + adversarial (branch) |
| 7 Scanner (identidad) | STAGED (backend) | iss031 | parlay a3135134: 63/363 af_ resueltos |
| 8 Grading GAP A | STAGED | iss028 + iss034 | regression parlay LIVE no cierra |
| 8 Grading GAP B | STAGED | iss035 | bankroll idempotente por diseño + cache fix |

## Gates del control plane — PASS/FAIL (evidencia real)
| gate | estado | evidencia |
|---|---|---|
| temporal_leakage_audit (cross-league) | PASS | 0 filas hoy/live en fit; 826 FINAL |
| temporal_leakage_audit (domésticas) | PASS | 0 filas live en 5 ligas |
| event_identity_audit | PASS (fix staged) | 63/363 patas af_ → resolver fuerte agrupa |
| competition/provider_identity | PASS | liga_id ESPN único; v_momios_confiables provider |
| 1X2_invariant | PASS | 116/116 suman 100 (v_futpro_v2) |
| BTTS_invariant | PARTIAL | btts_no existe en soccer_prediction_v2; falta exponerlo público (iss033) |
| O/U_invariant | PASS | 71/71 suman 100 |
| real_line_audit | PASS | 77/77 línea real snapshot_at<=decision; 0 hardcode |
| dossier_completeness | PASS (staged) | iss030 emite todas las fuentes |
| dossier_temporal_audit | PASS (staged) | data_asof<=decision; NO_DECISION_TIME fail-close |
| MODEL_ACTIVE_role_audit | STAGED | inputs as-of (iss033); prod builder aún usa agregado móvil |
| cross_league_validation | APPROVABLE_STAGED | OOS UCL/UEL |
| domestic_league_validation | APPROVABLE_STAGED | 3 ligas |
| scanner_tests | PARCIAL | identidad backend (iss031); edge fn en reto13 (ChatGPT) |
| grading_tests | PASS (staged) | iss028/iss034 regression |
| parlay_early_loss_regression | PASS (staged) | iss034 C1/C2 |
| bankroll_idempotence | PASS (por diseño) + fix cache | iss035 |
| FULL_DATA_SOCCER_ANALYSIS_GATE | **FAIL** | falta: correr tests en branch + migrar builder prod a as-of |

## Blockers (requieren levantar freeze / autorización de deploy)
1. Migrar `v2.build_soccer_prediction_v2` a la versión as-of (iss033) + recomponer
   `v_futpro_v2` para NO re-unir el agregado móvil y exponer `btts_no`.
2. Correr en Supabase branch: iss030/iss033/iss034/iss028 tests (temporal + adversarial).
3. Aplicar iss027/iss029 approvals SOLO tras BLOQUE 2b (walk-forward con modelo de prod).
4. iss031 backfill de identidad de patas + fix de canonizar_legs_parlay.
5. iss032 contrato de línea; iss034/iss035 triggers de grading/bankroll.

## Operaciones exactas que requerirán autorización de deploy posterior
- `apply_migration` de iss027..iss035 (en orden), en branch primero.
- Reemplazo de funciones prod: build_soccer_prediction_v2, auto_cerrar_parlay_si_leg_perdido,
  cerrar_parlays_con_pata_perdida, actualizar_bankroll_post_*.
- INSERTs en v2.model_registry (UCL/UEL + Bélgica/Dinamarca/Escocia) SOLO tras validación final.
- NO Sudamericana. NO frontend. NO NFL/MLB/Tennis.

NO se declara SOCCER cerrado: FULL_DATA_SOCCER_ANALYSIS_GATE = FAIL hasta correr los
tests temporales/adversariales en branch y migrar el builder de producción.
