# RETO 13M — Final clean-bootstrap order

**Status:** package-only / DO NOT CUT OVER PRODUCTION.

This is the deterministic order for an independent disposable-branch verification of the final closeout candidate. Every stage is fail-stop: a failed assertion stops the run; later stages must not be executed to manufacture a PASS.

## A. SOCCER canonical chain

Apply these schema/runtime artifacts in order:

1. `shadow-patches/prepared/iss000_soccer_branch_baseline.sql`
2. `shadow-patches/prepared/iss029_domestic_leagues_approval.sql`
3. `shadow-patches/prepared/iss039_competition_provider_id_mapping.sql`
4. `shadow-patches/prepared/iss027_champions_crossleague_model.sql`
5. `shadow-patches/prepared/iss037_crossleague_phi_versioned_snapshot.sql`
6. `shadow-patches/prepared/iss041_soccer_joint_matrix_single_source.sql`
7. `shadow-patches/prepared/iss033_temporal_reproducible_builder.sql`
8. `shadow-patches/prepared/iss051_soccer_crossleague_staged_orchestrator.sql`
9. `shadow-patches/prepared/iss042_soccer_joint_coherence_gate.sql`
10. `shadow-patches/prepared/iss043_model_market_discrepancy_gate.sql`
11. `shadow-patches/prepared/iss045_gate_topological_exclusion.sql`
12. `shadow-patches/prepared/iss045b_gate_v5_hardening.sql`
13. `shadow-patches/prepared/iss045c_soccer_market_diagnostic_only.sql`
14. `shadow-patches/prepared/iss030_soccer_dossier_manifest.sql`
15. `shadow-patches/prepared/iss124_soccer_dossier_canonical_identity.sql`
16. `shadow-patches/prepared/iss125_crossleague_v11_recovered_runtime.sql`
17. `shadow-patches/prepared/iss032_real_total_line_contract.sql`
18. `shadow-patches/prepared/iss025_soccer_manifest_contract_hardening.sql`

`iss045c` is a required authority repair discovered by the independent clean-branch gate: `disc_flag` / no-vig discrepancy remains visible as diagnostic/economic context, but it cannot veto canonical SOCCER candidate publication. Canonical eligibility is model readiness + internal distribution coherence only.

**Important clean-bootstrap distinction:** `shadow-patches/prepared/iss026_soccer_universe_failclosed_validation.sql` is a read-only acceptance script for the legacy/public `public.v_prediccion_reto_futbol` compatibility surface. It is **not** a schema/runtime migration and must not be applied as one on an empty disposable branch. On a clean branch that legacy public view is intentionally absent, so treating ISS026 as migration produces a false bootstrap failure (`42P01 relation public.v_prediccion_reto_futbol does not exist`). Run ISS026 only when that compatibility surface exists. The clean-branch canonical acceptance authority is the staged/candidate/dossier gate suite below.

Data/tests, in this order:
- `shadow-patches/tests/seed_soccer_branch_data.sql`
- `shadow-patches/tests/seed_soccer_crossleague_data.sql`
- `shadow-patches/tests/seed_soccer_owner_fixtures.sql`
- `shadow-patches/tests/run_soccer_final_branch_gate.sql`
- `shadow-patches/tests/iss125_soccer_realpath_6_fixture_gate.sql`
- component adversarials under `shadow-patches/tests/iss033_*`, `iss042_*`, `iss043_*`, `iss124_*`.
- conditional public-compatibility validation: `shadow-patches/prepared/iss026_soccer_universe_failclosed_validation.sql` **only if** `public.v_prediccion_reto_futbol` exists.

Acceptance: the six owner fixtures traverse builder -> staged -> event gate -> candidates -> dossier; one canonical distribution / one P_RETO; unsupported competitions fail closed; market/no-vig is diagnostic/economic context only and cannot replace or veto canonical P_RETO.

## B. result-event / WASTED

Apply after SOCCER PASS:
1. `shadow-patches/prepared/iss126a_result_events_v1_recovered.sql`
2. `shadow-patches/prepared/iss126_wasted_result_event_v2.sql`
3. `shadow-patches/prepared/iss127_wasted_push_single_authority_cutover.sql`
4. existing grading-root/parlay guards only where their dependencies are explicitly satisfied.

Test:
- `shadow-patches/tests/iss126_wasted_result_event_gate.sql`

Acceptance includes exact event identity, one settlement authority, push, idempotence/no double settlement, corners never grading from goals, same-city ML identity, safe CLV side parsing and fail-closed odds normalization.

## C. MLB

Apply after WASTED PASS:
1. `shadow-patches/prepared/iss052_mlb_decision_snapshot_contract.sql`
2. `shadow-patches/prepared/iss050_mlb_dossier_manifest.sql`
3. `shadow-patches/prepared/iss128_mlb_forward_validation_failclose.sql`

Data/tests:
- `shadow-patches/tests/seed_mlb_realpath_data.sql`
- `shadow-patches/tests/run_mlb_contract_gate.sql`

Acceptance: own-model decision snapshot, temporal freeze, unique-game/time-sliced OOS validation, no price-band probability authority, fail closed if validation is insufficient.

## D. NFL

Apply after MLB PASS:
1. `shadow-patches/prepared/iss053a_nfl_points_shape_bootstrap.sql`
2. `shadow-patches/prepared/iss054_nfl_brain_decision_snapshot.sql`
3. `shadow-patches/prepared/iss055_nfl_qb_continuidad.sql`
4. `shadow-patches/prepared/iss049_nfl_dossier_manifest.sql`
5. `shadow-patches/prepared/iss057_rls_nfl_lesiones_depth.sql`
6. `shadow-patches/prepared/iss062_no_bet_con_datos_malos.sql`
7. `shadow-patches/prepared/iss129_nfl_validation_release_gate.sql`
8. `shadow-patches/prepared/iss129b_nfl_rpc_release_gate.sql`
9. `shadow-patches/prepared/iss129c_nfl_public_surface_failclose.sql`

Tests:
- `shadow-patches/tests/run_nfl_backtest_2025.sql`
- `shadow-patches/tests/iss049_nfl_dossier_manifest_test.sql`

Acceptance: own model only; temporally frozen snapshots; QB/injury/depth provenance; OOS calibration/validation; all publication/RPC surfaces fail closed when the release gate is not satisfied.

## E. NFL Fantasy

Apply after NFL PASS:
1. `shadow-patches/prepared/iss130_nfl_fantasy_safe_closeout.sql`
2. `shadow-patches/prepared/iss130b_fantasy_b1_rq80_authority_v2.sql`
3. `shadow-patches/prepared/iss130c_fantasy_v2_hardening.sql`
4. `shadow-patches/prepared/iss131_fantasy_weighted_lineup_v2.sql`

Acceptance: own projection authority requires roster/scoring context plus immutable snapshot/version/as_of lineage and OOS evidence; otherwise native projections/rankings/Start-Sit fail closed. External projections may remain context only when explicitly labeled.

## F. GLOBAL TOP_ONLY — LAST predictive read contract

Apply only after all sport candidate contracts above pass independently:
1. `shadow-patches/prepared/iss132_global_top_only_failclosed.sql`

This **supersedes** the final-selector semantics of older `iss064`, `iss078`, `iss080` and any one-per-sport/filler path. Do not re-enable those semantics after ISS132.

Acceptance:
- P_RETO copied verbatim from canonical sport candidates.
- zero quota/filler; zero rows is legal.
- one candidate per event.
- one cross-sport global ordering.
- no odds/no-vig/EV/Kelly/CLV input to canonical selection.
- `v_pick_del_dia_canonical` is exact alias of `v_reto13m_top_only`.

## G. Preflight / read switch / post-switch verification

1. Run `shadow-patches/deploy/reto13m_final_preflight_readonly.sql` and preserve its output as rollback evidence.
2. Independent auditor confirms every block above against the exact implementation SHA.
3. Only after explicit release authorization, switch consumers to canonical read contracts in dependency order: sport candidates first, GLOBAL TOP_ONLY second, Pick del Día alias last.
4. Cron changes are NOT part of this package. Any cron-stability fix must be reviewed/deployed separately so scheduler changes cannot silently alter model semantics.
5. Run post-switch read-only smoke: object existence, temporal invariants, P_RETO invariance, 0/1 top-only cardinality, exact alias equality, and browser/E2E consumer equality.

## Hard stop conditions

Abort and retain prior production read contracts on any: missing dependency, temporal violation, probability outside [0,1], different P_RETO across canonical surfaces for the same identity, unexpected sport quota/filler, failed rollback snapshot, non-exact candidate branch, or missing independent browser/E2E verification.