# MLB_BRAIN_INVENTORY — read-only prep for FASE 1 (MLB_BRAIN_FINAL)

Status: **PREP ONLY**. SOCCER still P0 / RELEASE_GATE=HOLD; do NOT change the MLB model
or touch prod until the auditor (issue #4) releases SOCCER. Captured READ-ONLY from prod
`wpiztubmmmzclhlprgpd` on 2026-09-10. No prod mutation.

North star: `ONE BRAIN · ONE CANONICAL EVENT · ONE P_RETO · ONE DOSSIER · MANY VIEWS`.
sportsbook/EV/Kelly/LLM are NEVER P_RETO.

## 1) Prediction functions found (candidate brains — MUST unify to ONE canonical)
| function | role (hypothesis) | disposition to decide in FASE 1 |
|---|---|---|
| `public.predecir_mlb(p_espn_event_id)` | current per-event predictor (tuned in #91/#96: home edge, starter exp 0.30, 10-game sample) | **canonical candidate** — audit as the single brain |
| `public.motor_mlb(home,away,meses,peso_previo)` | lower-level engine (team-strength motor) | likely the compute core behind predecir_mlb — confirm it is called by it, not a parallel path |
| `public.badrino_predecir()` | legacy global predictor (badrino family) | **parallel/legacy brain risk** — verify not writing MLB picks that diverge |
| `public.predecir_partido(p_espn_event_id)` | generic multi-sport dispatcher? | confirm it doesn't recompute MLB separately |
| `public.bt_predecir_mlb(...)`, `public.bt_mlb2(...)`, `public.backtest_mlb(...)` | backtest/param-search (lab) | keep as lab-only; must NOT feed prod P_RETO |

Action FASE 1: prove exactly ONE path produces the MLB P_RETO; quarantine/retire the rest
(mirror the SOCCER "un solo motor" decision, #114/#163).

## 2) Snapshot / provenance / champion-challenger (already partially built)
- `mlb_modelo_snapshot` (+ `refrescar_mlb_modelo_snapshot()`) — model snapshot; verify it stores model/version/features_as_of/provenance and is immutable per prediction.
- `mlb_prob_snapshot` (+ `mlb_snapshot_capturar()`) — probability snapshot (opening/live?).
- `mlb_shadow_predicciones` (+ `mlb_shadow_generar()`) — shadow/challenger predictions → basis for champion-vs-challenger.
- Forward/temporal harness EXISTS: `lab_mlb_forward`, `lab_mlb_fwd_capturar()`, `lab_mlb_fwd_resultado()`, `lab_mlbfwd_freeze()`, `lab_mlbfwd_no_backdate()`, `lab_mlb_wf` (walk-forward), `lab_mlb_split_seal`. → reuse for walk-forward/calibration/Brier/log-loss instead of building new.

## 3) Temporal-safe feature sources available (before first pitch)
- Starter: `mlb_pitcher_temporada`, `mlb_pitcheo_juego`, `mlb_lineup_*` / `mlb_alineacion` (probable/real lineup), `mlb_player_game_logs`.
- Bullpen: `mlb_bullpen_apariciones`, `v_bullpen_calidad`, `mlb_carga_bullpen(team,fecha)` (quality + fatigue).
- Offense: `mlb_bateador_temporada`, `mlb_batter_platoon_splits` (L/R), `mlb_saber_equipo` / `v_mlb_saber` (wRC+/xFIP sabermetrics, #131), `v_mlb_contacto_equipo`/`_juego` (contact quality), `mlb_forma_temporada`/`mlb_forma_hasta()` (recent form).
- Context: `mlb_estadios` (park), `mlb_clima_hora` + `clima_partido_mlb()` (weather/roof), `mlb_umpire_juego`/`umpires_mlb` (#132), `mlb_liga_rpg_hasta()` (league RPG as-of).
- Distribution helpers (lab): `lab_mlb_lam()` (team run lambda), `lab_mlb_ploc()` (Poisson-ish run dist), `mlb_prob_viva()` (live win prob — LIVE only, must NOT feed pregame P_RETO).

## 4) Pick-serving views (MANY VIEWS — must all read the ONE canonical P_RETO)
`v_picks_mlb_modelo`, `v_mejores_picks_mlb`, `v_radar_mlb`, `v_favorito_mlb`.
Per the frontend audit these are on the legacy denylist (currently inert on active routes).
FASE 1 must repoint them to the canonical MLB P_RETO surface (analogous to soccer `v_futpro_v2`).

## 5) Known open MLB issues (from control-plane backlog, to fold into FASE 1)
- #193 O/U 0.55 hardcode beats the Poisson motor (market vetado) — resolve with a validated run-distribution, not a hardcode.
- #174 Poisson overdispersion 2.36x (market vetado) — needs a proper dispersion model before O/U is trustworthy.
- #129/#209 EV shown ≠ EV that sizes — ensure P_RETO is the single sizing input, EV is context only.
- #210 visiting starter cache expires and nobody refreshes — data-readiness/as_of guard needed.
- #135/#150 lineup vs team-average; bullpen fatigue measured = no signal — decide inclusion on measured lift only.

## 6) Proposed FASE 1 gate shape (mirror SOCCER v2, when released)
Canonical `mlb_prediction_v2_staged` + `feature_snapshot`(as_of) + `build_mlb_prediction_v2_staged`;
temporal/no-leakage, P_RETO unique/canonical, run-distribution → ML/total/most-likely-score,
grading/replay/idempotence, opening/current/closing snapshots as context only,
walk-forward + calibration (Brier/log-loss) champion-vs-challenger before promotion.
SYNTHETIC_GATE first; REAL_DATA_GATE only in a data-bearing environment (same limit as SOCCER).

## 7) RESOLVED brain call-graph (read-only, 2026-09-10) — evidence
Measured via `pg_get_functiondef` inspection (lengths + call refs):
- `predecir_mlb` = **the canonical brain** (~22KB body). Self-contained; does NOT call `motor_mlb`.
- `predecir_partido` (dispatcher) → calls `predecir_mlb` for MLB. Not a parallel brain. ✅
- `refrescar_mlb_modelo_snapshot` → writes `mlb_modelo_snapshot` AND inserts MLB/picks rows = the materializer of the canonical output into the pick surfaces.
- `motor_mlb` (~3.5KB) = **standalone legacy engine, NOT in the canonical path** (predecir_mlb doesn't call it). → FASE 1 candidate to quarantine/retire so it can't diverge.
- `badrino_predecir` = unrelated to MLB (no motor/predecir/snapshot/mlb-insert refs). Not a brain risk.
- None of these use Dixon-Coles/`fn_score_dist` (soccer-only), as expected — MLB has its own run model.

FASE 1 canonical path to certify: `predecir_mlb` → `refrescar_mlb_modelo_snapshot` → `mlb_modelo_snapshot` → `v_picks_mlb_modelo`/`v_mejores_picks_mlb`/`v_radar_mlb`. Single P_RETO writer confirmed = predecir_mlb; the "ONE BRAIN" unification mainly needs `motor_mlb` retired/quarantined and the snapshot verified for model/version/features_as_of/provenance immutability.

(Prep note only — no code/model change until SOCCER is released by the auditor.)
