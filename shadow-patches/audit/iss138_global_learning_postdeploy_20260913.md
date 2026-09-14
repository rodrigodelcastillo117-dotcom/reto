# ISS138 — Global continuous learning loop — postdeploy audit

Date: 2026-09-13/14 UTC
Production Supabase: `wpiztubmmmzclhlprgpd`

## Goal
Create one fail-closed learning lifecycle for Reto 13M without changing canonical pick publication authority:

`pregame snapshot -> authoritative FINAL -> scoring -> OOS/calibration gate -> challenger -> evidence-only promotion gate`

Learning evidence NEVER bypasses `v_pick_canonico`, sport-specific release gates, or `v_publication_authority_leaks`.

## Applied Supabase migrations

- `20260914032943 iss138a_global_learning_contracts`
- `20260914033012 iss138b_global_learning_cycle`
- `20260914033034 iss138c_global_learning_gates`
- `20260914033045 iss138d_global_learning_automation`
- `20260914033113 iss138e_fix_soccer_competition_identity`
- `20260914033141 iss138f_fix_learning_gate_numeric_types`
- `20260914033203 iss138g_fix_challenger_variable_ambiguity`
- `20260914033522 iss138h_nfl_week2_provisional_capture`
- `20260914033533 iss138i_mlb_legacy_diagnostic_import`
- `20260914033600 iss138j_global_learning_coverage`

The E/F/G migrations are fixes found by running the complete cycle. Each failed invocation was statement-atomic and rolled back; no partial learning cycle persisted.

## New contracts

- `v2.mlb_learning_snapshot`: immutable, exact-runtime-hash MLB pregame snapshots.
- `v2.model_learning_policy`: per-sport/market sample and evidence requirements.
- `v2.model_learning_observation`: canonical learning ledger; full probability distribution + model version + timestamp + final outcome.
- `v2.v_model_learning_scored`: Brier/log-loss/leader-accuracy scoring.
- `v2.model_learning_gate`: GLOBAL and LEAGUE evidence gates.
- `v2.model_calibration_challenger`: temporal 70/30 calibration challengers.
- `v2.v_model_learning_health`: safety/invariant dashboard.
- `v2.v_model_learning_coverage`: explicit coverage/blocker status for every supported sport/market.

## Automated jobs

- `reto-model-learning-v1` — `17,47 * * * *` — active — runs `v2.run_model_learning_cycle()`.
- `nfl-v2-challenger-capture` — `13 */6 * * *` — active — captures nearest unfinished NFL week plus next week as learning-only snapshots.

## First successful full cycle

Result:

- canonical learning observations after first cycle: `712`
- NFL new settled observations: `13`
- Soccer 1X2 new observations on first load: `232` across three explicit model versions
- MLB exact runtime snapshots captured: `25`
- MLB runtime id: `mlb_runtime_a7fb15853076`
- calibration challengers evaluated: `12`
- model-learning gates computed: `99`

After importing the recent unversioned MLB history as DIAGNOSTIC-ONLY evidence:

- total learning observations: `1004`
- MLB legacy Moneyline diagnostic events: `146`, promotable: `0`
- MLB legacy O/U diagnostic events: `146`, promotable: `0`

## NFL Week 2 adaptation

`v2.capture_nfl_next_week_challenger()` now captures BOTH the nearest unfinished week and the following week.

Verified current capture:

- Week 1 pending: `1` game, status `PROVISIONAL_UNTIL_WEEK_CLOSE`
- Week 2: `16/16` games captured, status `PROVISIONAL_REBUILT_EACH_RUN`

This means Week 2 ratings already incorporate every Week 1 result that is FINAL. The capture is rebuilt after remaining games close. In-progress/pending games are never used as labels.

## Initial versioned evidence

### NFL `nfl-2026.09.2` — 13 final games

Moneyline:
- Brier sum: `0.515646` vs naive `0.500000` vs market `0.420446`
- leader accuracy: `46.15%`
- average confidence: `61.31%`
- max calibration gap: `35.54 pp`
- status: `INSUFFICIENT_SAMPLE`, `OOS 13/64`

Spread:
- Brier `0.642952` vs naive `0.500000`
- leader accuracy `23.08%`

Total:
- Brier `0.641700` vs naive `0.500000` vs market `0.498567`
- leader accuracy `30.77%`

No NFL publication authorization was changed.

### Soccer `crossleague_v1`

1X2:
- `n=129`
- Brier `0.631816` vs naive `0.666667`, market `0.618915`
- leader accuracy `44.96%`
- global gate remains closed: `OOS 129/200`; skill is not yet statistically established by the predeclared gate.

BTTS:
- `n=129`
- Brier `0.506513` vs neutral `0.500000`
- not proven.

O/U:
- `n=125`
- Brier `0.532155` vs neutral `0.500000`, market `0.502093`
- currently weak/overconfident.

### Soccer `dc-2026.09.1`

1X2:
- `n=97`
- Brier `0.704787` vs naive `0.666667`, market `0.623741`
- currently worse than `crossleague_v1` and baseline.

### Calibration challengers

No calibration challenger is currently authorized.
Important findings:
- `crossleague_v1` 1X2: temporal holdout raw Brier `0.587088`; shrink calibration worsened it to `0.605674`. Keep RAW rather than cosmetic recalibration.
- NFL Total: shrink improved holdout `0.642668 -> 0.550787`, but remains worse than neutral `0.500000` and holdout is only 4 games. Not publishable.

## Coverage status

Full-distribution learning ACTIVE:
- NFL Moneyline / Spread / Total
- Soccer 1X2 / BTTS / O/U

Versioned capture ACTIVE, awaiting settled results:
- MLB Moneyline / O/U (`25` pending exact-runtime snapshots)

Explicit blockers — no versioned full-distribution model source yet:
- NBA Moneyline / Spread / Total
- NHL Moneyline / Puckline / Total
- Tennis Moneyline

Legacy/selected-side evidence for these sports must not be treated as a publishable model.

## Safety invariants after deploy

- `total_observations = 1004`
- `temporal_leaks = 0`
- `unversioned_promotable_rows = 0`
- `prediction_gates_pass = 0`
- `money_gates_pass = 0`
- `calibration_challengers_pass = 0`
- `publication_authority_leaks = 0`
- NFL public probability leaks = `0`

PASS means the learning infrastructure is active and fail-closed. It does NOT mean any previously blocked model has earned publication.
