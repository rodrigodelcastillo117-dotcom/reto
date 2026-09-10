# STAGED_MIGRATION_DAG — orden de aplicación de artefactos SOCCER (§35)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
**NO ejecutar bajo freeze.** Todo en `shadow-patches/prepared/`; nada en `supabase/migrations/`.
Aplicar primero en Supabase branch aislado; prod sólo tras autorización de cutover.
Toda la SQL cualifica esquema; DDL idempotente donde aplica (CREATE OR REPLACE / IF NOT EXISTS).

## Dependencias externas (prod, ya existen — sólo lectura)
`v2.fn_score_dist`, `public.v_liga_promedios_futbol`, `public.v_momios_confiables`,
`public.agenda_espn`, `public.historico_partidos_espn`, `v2.liga_alias`,
`v2.competition_catalog`, `v2.model_registry`, `public.is_truly_final`, `public.live_scores`,
`public.calcular_bankroll_actual(__base)`, `public.resolver_evento_canonico`,
`public.v_prediccion_reto_futbol`, `public.v_futpro_v2`.

## DAG (orden topológico)
| paso | artefacto | prerequisitos | crea / reemplaza | tests | rollback |
|---|---|---|---|---|---|
| 1 | iss032_real_total_line_contract | v_momios_confiables | `v2.fn_real_total_line`, `v2.v_real_line_audit` | real_line audit 77/77 | DROP FUNCTION/VIEW (nuevos) |
| 2 | iss027_champions_crossleague_model | historico, liga catalogs | `v2.liga_fuerza`, `v2.crossleague_params`, `v2.crossleague_competencias`, `v2.fn_crossleague_features`, `v2.fn_crossleague_p_reto` | lab/champions_crossleague_v1 | DROP objetos v2 nuevos |
| 2b | iss037_crossleague_phi_versioned_snapshot | iss027 (liga_fuerza) | `v2.liga_fuerza_version` (PK incl. cutoff, append-only), `v2.fn_seal_liga_fuerza_snapshot`, `v2.fn_crossleague_active_cutoff`, `v2.fn_crossleague_phi_asof` | iss037_phi_replay_test (2 cutoffs, fail-close, append-only) | DROP tabla/funciones nuevas |
| 3 | iss033_temporal_reproducible_builder | iss032 (fn_real_total_line), model_registry, fn_score_dist, v_liga_promedios | `v2.model_config`, `v2.fn_soccer_features_asof`, `v2.feature_snapshot`, `v2.soccer_prediction_v2_staged`, `v2.build_soccer_prediction_v2_staged`, (`v2.v_soccer_canonical` al descomentar) | iss033 adversarial replay + agenda_universe_regression | DROP funciones/tablas nuevas (staged, sin datos prod) |
| 4 | iss029_domestic_leagues_approval | iss033 (model_config/registry) | INSERT approval **sólo Grecia 197** (comentado) | BLOQUE2b (validación) | DELETE de la fila de registro Grecia |
| 5 | iss030_soccer_dossier_manifest | iss032, v_futpro_v2, tablas fuente | `v2.dossier_source_catalog`, `v2.fn_soccer_dossier_manifest` | iss030 manifest test + dossier coverage | DROP función/catalog nuevos |
| 6 | iss036_daily_canonical_selector | **iss033** (soccer_prediction_v2_staged) | `v2.v_soccer_daily_candidates`, `v2.v_soccer_daily_canonical` | DAILY_NO_FIXED_LINE (branch) | DROP VIEWs nuevas |
| 7 | iss031_parlay_leg_canonical_identity | resolver_evento_canonico | `v2.fn_leg_canonical_event_id`, `v2.fn_parlay_identidad_propuesta`, `v2.v_parlay_identity_audit` | parlay a3135134 identity | DROP objetos v2; backfill es dry-run |
| 8 | iss028_soccer_grading_root_guard | is_truly_final, live_scores, pa_score_snapshot | REEMPLAZA `guard_no_early_loss`, `guard_pa_evidencia_obligatoria` | iss028 grading guard test | restaurar defs previas (guardadas en rollback/) |
| 9 | iss034_parlay_gapA_final_leg_loss | is_truly_final, live_scores | crea `v2.fn_leg_is_final`; REEMPLAZA `auto_cerrar_parlay_si_leg_perdido`, `cerrar_parlays_con_pata_perdida` | iss034 C1/C2 + extra C3/C4/C5 | restaurar defs previas |
| 9b | iss034b_parlay_grading_trigger_set | iss034 (auto_cerrar, fn_leg_is_final), iss000 (live_scores, marcadores_archivo, ligamx_*, evento_id_map, slug_equipo, is_truly_final) | stub `public.mundial_partidos`; CREATE OR REPLACE (verbatim prod) `is_postponed_or_cancelled`, `buscar_marcador`, `buscar_marcador_v2`, `bloquear_calificacion_parlay_con_legs_futuros`, `protect_parlays_premature_grading`; instala triggers `trg_auto_cerrar_parlay`, `protect_parlays_premature`, `trg_bloquear_calificacion_parlay_legs_futuros` en `public.parlays` | iss034_extra C3/C4/C5 (requiere el set COMPLETO de triggers) | rollback/iss034b_parlay_grading_trigger_set_rollback.sql (defs prod verbatim) |
| 10 | iss035_bankroll_idempotence | calcular_bankroll_actual | REEMPLAZA `actualizar_bankroll_post_al_calificar`, `_parlay` | iss035 idempotence test | restaurar defs previas |

## P0 COHERENCE + DISCREPANCY GATE (issue #4 · 5618913334) — branch-only, HOLD
| paso | artefacto | prerequisitos | crea / reemplaza | tests | rollback |
|---|---|---|---|---|---|
| C1 | iss041_soccer_joint_matrix_single_source | iss000 (fn_score_dist) | REEMPLAZA `v2.fn_dist_from_lambda` + `v2.fn_score_dist` (matriz única autoritativa: emite matriz completa, renormaliza a 100, escalares DERIVADOS de las celdas; DC rho/lambda intactos) | iss042 gate (6 cards pre-fix FAIL / post-fix PASS) | CREATE OR REPLACE defs prod verbatim (capturadas read-only) |
| C2 | iss042_soccer_joint_coherence_gate | iss041 | `v2.fn_matrix_market`, `v2.fn_soccer_coherence_gate` (1X2/BTTS/CS/OU@línea real/AH±1.5/exact top-k, tol 0.2pp) | tests/iss042_coherence_gate_test.sql | DROP funciones nuevas |
| C3 | iss043_model_market_discrepancy_gate | iss000 (odds en v_momios/v_futpro) | `v2.fn_novig_1x2`, `v2.fn_novig_2way`, `v2.fn_model_market_discrepancy` (no-vig SOLO diagnóstico, nunca P_RETO; QUALITY_DOWNGRADE/REVIEW + suppress) | tests/iss043_discrepancy_gate_test.sql | DROP funciones nuevas |
| C4 | iss044_regime_crossleague_backtest (read-only, NO migración) | prod historico | — (análisis) | reports/iss044_regime_crossleague_backtest_readonly.md | n/a |
- Branch de validación: `soccer-coherence-gate` (ref kmasawoljjyfmxadbvou). Orden real aplicado:
  iss000 (subset core) → iss000b (fn_dist prod-verbatim pre-fix, para reproducir bug) → fixtures →
  iss041 (fix) → iss042 → iss043. Todo en tx/branch; prod SOLO lectura.

## Notas de dependencia
- iss036 REQUIERE iss033 (lee `soccer_prediction_v2_staged`). No aplicar 6 antes de 3.
- iss029 aplica el INSERT de aprobación de Grecia **sólo** tras BLOQUE 2b (ya validado);
  el resto de ligas permanece fail-closed (sin fila).
- Pasos 8-10 REEMPLAZAN funciones de prod: capturar `pg_get_functiondef` ANTES (rollback/).
- iss034b va INMEDIATAMENTE DESPUÉS de iss034. iss034_extra (C3/C4/C5) NO instala triggers
  propios: iss034b es lo que lo hace ejecutable (set completo de triggers en parlays +
  helpers de prod capturados read-only). Sus defs se copiaron a rollback/ (versión prod).
- Pasos 1-7 son aditivos (objetos v2 nuevos): rollback = DROP.

## Colisiones / overlaps detectados
- Numeración: existen dos familias `issNN_*` (una de sesiones previas: iss021_soccer_full_data_gate,
  iss023..026, iss027_soccer_cutover_preflight, iss028_soccer_temporal_strict, iss029_soccer_context_asof).
  Los archivos con sufijo temático distinto NO colisionan en objeto de BD (nombres de función
  distintos). Verificar en branch que no haya CREATE OR REPLACE de la MISMA firma entre familias.
- iss034 reemplaza `auto_cerrar_parlay_si_leg_perdido`; el guard universal
  `protect_parlays_premature_grading` (prod) NO se toca (defensa en profundidad intacta).

## Zero-row / seguridad (§36)
- Ningún DROP CASCADE. Ningún UPDATE destructivo de datos. Ningún backfill sin plan tx.
- iss031 backfill = dry-run (no muta hasta autorización).
- Todos los tests corren en tx con ROLLBACK.
