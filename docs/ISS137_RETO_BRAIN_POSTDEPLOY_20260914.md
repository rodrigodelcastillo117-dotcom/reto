# ISS137 — RETO Brain world-class core — postdeploy

Verified in production on 2026-09-14 UTC.

## Changes
- Added `public.v_reto_brain_release_authority_v1` separating RELEASE AUTHORITY from LIVE MONITORING.
- Added `public.v_reto_brain_prediction_timeline_v1` with normalized 0..1 probabilities, model/feature identity, timestamps, diagnostic no-vig references and prediction fingerprints.
- Added `public.v_reto_brain_event_audit_v1` with previous-snapshot deltas and graded outcomes.
- Added `public.v_reto_brain_scorecard_v1` for trust/model scorecards.
- Added fast `public.v_reto_brain_invariant_leaks_v1` + `public.v_reto_brain_health_v1`.
- Added immutability trigger on prediction fields of `v2.model_learning_observation`.
- Disabled legacy cron `recalibrate-model-weights-monday` (5-game/70%-WR heuristic weight mutation).
- Disabled legacy cron `recalcular-competencia-modelo` (could substitute market probability for model probability).
- Retired Edge Function `recalibrate-model-weights`: version 66, JWT required, HTTP 410 fail-closed, zero writes.

## Verification
- Authenticated role can read Brain authority/timeline/health.
- Adversarial UPDATE of stored model probability was blocked by immutability trigger.
- Real `v2.run_model_learning_cycle()` completed after the guard was installed.
- Cycle result: gates=105; NFL next week captured=16; current future week captured=1; observations total=3565; calibration challengers=15.
- Post-cycle Brain health:
  - authority_rows=36
  - scientific_ready_rows=21
  - product_release_rows=19
  - money_authorized_rows=0
  - timeline_rows=25039
  - graded_learning_rows=3565
  - invariant_failures=0
  - status=PASS
- `v_reto_brain_invariant_leaks_v1` returned 0 rows.

## Notes
- Soccer historical/OOS release authority remains distinct from the smaller live 2026 monitoring sample.
- NBA/WNBA can be scientifically promising without being product/money authorized.
- NFL/NHL/MLB/Tennis remain fail-closed where their release evidence is insufficient.
- Market/no-vig is diagnostic/economic context only and never becomes P_RETO.
