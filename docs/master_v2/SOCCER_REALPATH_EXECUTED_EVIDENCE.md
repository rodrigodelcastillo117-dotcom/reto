# SOCCER REAL PATH — EXECUTED EVIDENCE (branch `soccer-realpath-v6`)

Branch: Supabase `soccer-realpath-v6` = project `jnercwjlyeiocrdmtdpc` (parent `wpiztubmmmzclhlprgpd`).
Decision epoch: **2026-09-10 12:00:00+00**. Gates held: `P0=SOCCER · RELEASE_GATE=HOLD ·
PROD_FREEZE=ON · LOVABLE_FREEZE=ON`. **Every production call in this run was SELECT-only.**

## Root cause of the previous STOP-SHIP (both causes were real, and independent)

1. **Config/wiring.** `build_soccer_prediction_v2_staged` (iss033) derived approval only from
   `v2.model_registry` for `reto_dc_v2`, which holds **domestic** ligas. UCL approval lives in a
   separate authority (`v2.crossleague_competencias`) and the crossleague model was never wired
   into the staged builder, so every UCL event fail-closed as *"Competencia no aprobada para el
   modelo"* — a config reason. `v2.competition_catalog` was additionally never seeded by the chain.
2. **Wrong decision epoch.** `401915422` (PSV–Shakhtar) and `401915444` (Fenerbahce–Roma) kick off
   **16:45:00+00**, and the previous runner's epoch was **17:00:00+00**. The builder universe is
   `agenda_espn.fecha > decision_time`, so those two were **correctly excluded** — the builder was
   right and the decision time was wrong. This is why they had "NO ROW staged".

Fix: `iss051` routes approved crossleague competitions through the crossleague model inside the
same staged contract; the epoch moves to 12:00Z. The universe filter is **not** loosened — stage A
below proves a post-kickoff epoch still excludes those two fixtures.

## Measured six-fixture table (real path: builder -> staged -> v_soccer_event_gate -> candidates)

| event | match | route | status | samples H/A | P(H/D/A) | BTTS Y/N | line | O/P/U | gate | cands |
|---|---|---|---|---|---|---|---|---|---|---|
| 401915422 | PSV Eindhoven vs Shakhtar Donetsk | CROSSLEAGUE | DATA_INCOMPLETE | 51 / **0** | — | — | 3.5 | — | — | 0 |
| 401915440 | Slavia Prague vs Lens | CROSSLEAGUE | DATA_INCOMPLETE | **0** / 46 | — | — | 2.5 | — | — | 0 |
| 401915441 | Como vs RB Leipzig | CROSSLEAGUE | READY_UNVALIDATED | 50 / 44 | 57.9 / 20.9 / 21.3 | 53.9 / 46.1 | 3.5 HALF | 33.3 / 0.0 / 66.7 | OK, eligible | 7 |
| 401915442 | Manchester United vs Sabah FK | CROSSLEAGUE | DATA_INCOMPLETE | 50 / **0** | — | — | 4.5 | — | — | 0 |
| 401915443 | Bayern Munich vs Bodo/Glimt | CROSSLEAGUE | READY_UNVALIDATED | 46 / 49 | 67.7 / 15.8 / 16.5 | 66.4 / 33.6 | 4.5 HALF | 35.8 / 0.0 / 64.2 | **QUALITY_DOWNGRADE, suppressed** | 0 |
| 401915444 | Fenerbahce vs AS Roma | CROSSLEAGUE | READY_UNVALIDATED | 48 / 50 | 36.6 / 23.5 / 39.9 | 56.2 / 43.9 | 2.5 HALF | 53.4 / 0.0 / 46.6 | OK, eligible | 7 |

* **6/6 route to CROSSLEAGUE** — the config blocker is gone; no fixture fail-closes for a config reason.
* The three fail-closes are a **real data** reason: the away/home team has **zero** domestic FINAL
  matches in the 540d window (Shakhtar, Slavia Prague, Sabah FK), under a domestic sample floor of 15
  that comes from the validated fit (`floor_optimo=15`, validation_v2.json).
* Suppression happens **after** a real prediction exists (Bayern), never because the builder was empty.
* Every READY row carries `score_dist`, true top-5, 1X2, BTTS, real-line O/U with `p_push`/`ou_line_type`,
  `temporal_safe=true`, a linked `feature_snapshot_id`, and sealed-phi provenance
  (`phi_training_cutoff = 2026-09-09T00:00:00+00`).

## Universe counts (237 events processed, nothing disappears)

| route | status | n |
|---|---|---|
| CROSSLEAGUE | READY_UNVALIDATED | 3 |
| CROSSLEAGUE | DATA_INCOMPLETE (insufficient domestic sample) | 21 |
| DOMESTIC | DATA_INCOMPLETE (insufficient same-competition sample) | 133 |
| NONE | NO_MODEL (competition not approved) | 80 |

`processed = 237 = universe`; `READY + fail-closed = 237`; **identity violations = 0**
(`v2.v_soccer_staged_identity_violations` empty — exactly one P_RETO row per event+decision);
analysis surface = 3 = READY; candidates = 2 events × 7 markets = 14 rows; 0 dirty `gate_reason`.

> HONEST SCOPE: the 133 DOMESTIC fail-closes are because this run loaded the domestic-form closure
> for the **twelve owner-fixture teams only** (429 real matches), not full per-league historico. The
> domestic route is exercised and correct, but it produces no READY rows in this run. Loading full
> per-league historico is a cutover step, not a gate requirement. Regenerate every slice from prod
> read-only with `shadow-patches/tests/gen_soccer_realpath_seed.sql`.

## Executed gate stages

| stage | result | evidence |
|---|---|---|
| A_POST_KICKOFF_UNIVERSE | PASS | epoch 17:00Z staged **0** of the two 16:45Z fixtures — 12:00Z is a genuine pre-kickoff decision, not a loosened filter |
| B_REPLAY_IDEMPOTENCE | PASS | build twice -> identical md5 `023497cc8ac079291820f6c3673b1bf0` |
| C_SEALED_PHI_IMMUNITY | PASS | live `v2.liga_fuerza` phi(Bundesliga) **+5.0** -> staged md5 unchanged; builder reads only the sealed iss037 snapshot |
| D_COHERENCE | PASS | all 3 READY rows: every 1X2/BTTS/O-U/push scalar derives from the persisted `score_dist` within the gate tolerance (0.2pp); top_scores=5; `over_line` == real provider line |
| E_NO_PARALLEL_AUTHORITY | PASS | `fn_crossleague_p_reto` reproduces each staged row **exactly** at the real line (thin delegate of `fn_dist_from_lambda`); no Over-2.5 value on the 3.5/4.5 lines |
| F_ADVERSARIAL | PASS | MATRIX (sum90 / sum>100 / negative / duplicate / bad-key), SCALARS (NULLs, +15pp), PUSH (3.5=HALF, 4.0=WHOLE push>0, 2.25/2.75=QUARTER, 3.1=UNSUPPORTED, over+push+under=100, p_push+15pp), TOP_SCORES (NULL/[]/len1/duplicate/wrong-order/wrong-prob) — all fail-closed |

## Defects found by executing (fixed, and why they mattered)

1. `fn_crossleague_lambda_asof`: the OUT params `phi_model_version` / `phi_training_cutoff` shadowed
   the identically named columns of `v2.liga_fuerza_version` -> runtime *"column reference is
   ambiguous"*. Table-qualified. A static review would not have caught this.
2. Route `NONE` left `model_version` NULL, which violates the staged PRIMARY KEY. Unmodelled events
   now carry an explicit `NO_MODEL` model identity instead of borrowing the domestic `model_version`
   (which would mislabel the row as produced by a model that never ran).
3. Runner assertions on market sums used exact `= 100.0`, which is **stricter than the gate**.
   `btts_yes`/`btts_no` are each rounded to 1dp from a matrix summing to exactly 100, so the pair can
   legitimately read 100.1 (Fenerbahce: 56.2 + 43.9). The runner now uses the gate's own 0.2pp
   tolerance. Flagged as a precision note, not a coherence failure — the contract is `≈ 1`.

## Known limitations / not claimed

* **Not declaring SOCCER PASS.** This is branch evidence for audit.
* `competition_catalog.model_supported` stays **false** for UCL: crossleague support is a separate
  authority. Nothing flipped that flag to make UCL pass.
* The crossleague model remains `CALIBRATION_STATUS=UNVALIDATED`; `P_RETO = P_RAW`.
* Como is `OK/eligible` in this run (not `REVIEW_REQUIRED`). The earlier −13.0pp total_gap came from
  the separate `gate_fixture_soccer_cards` math-unit card, which uses hand-entered lambdas; the real
  crossleague model at the real 3.5 line lands inside tolerance. The fixture card is a unit test, not
  the release proof — which is exactly the substitution the auditor flagged.
* Parlay/grading migrations (iss028/031/034/034b/035/038) are not in the soccer real path and were
  not re-applied after the branch schema reset described below.
