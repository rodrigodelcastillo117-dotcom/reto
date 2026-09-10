# iss044 — REGIME CROSS-LEAGUE BACKTEST (REAL_DATA_ADVERSARIAL_READONLY)

Issue #4 mandate 5618913334 · DELIVERABLE 4. Read-only vs prod
`wpiztubmmmzclhlprgpd.public.historico_partidos_espn`. NO prod mutation, NO tuning to today.
Walk-forward FEATURES (domestic gf/ga strictly `fecha < kickoff`, 540d window, cross-league
comps excluded per iss027 list). Universe = approved cross-league comps UCL(liga 2)+UEL(liga 3).
Fail-close gates applied: both teams n>=15 domestic + servable φ (crossleague_v1 snapshot).

## Universe
- UCL 515 + UEL 519 finals in historico (2023-09 .. 2026-09).
- After fail-close (n>=15 & φ-servable both sides): 562 matches.
- Temporal split (selection discipline): VALIDATION = fecha < 2025-08-01 (296); OOS TEST = fecha >= 2025-08-01 (266).

## φ-compression test: crossleague_v1 (φ) vs challenger (φ × SCALE, stronger inter-league prior)
Only the inter-league prior spread is varied (SCALE on the (φ_home−φ_away) term); DC/λ math identical.

### VALIDATION (296) — SCALE selection (multiclass Brier / logloss, 1X2)
| SCALE | Brier | logloss |
|------|-------|---------|
| 0.0 (φ off) | 0.6247 | 1.0356 |
| 0.5 | 0.6022 | 1.0049 |
| 1.0 (prod φ) | **0.5916** | **0.9909** |
| 1.5 | 0.5927 | 0.9932 |
| 2.0 | 0.6032 | 1.0118 |
| 2.5 | 0.6203 | 1.0467 |
| 3.0 | 0.6412 | 1.0980 |

Validation optimum = SCALE 1.0 (production φ). φ matters (0.0 clearly worse), but widening beyond
1.0 does NOT help on validation → over-compression hypothesis NOT supported on the training-era window.

### OOS TEST (266) — v1 (SCALE 1.0) vs challenger (SCALE 1.5)
| model | Brier | logloss | avg_pred_fav | fav_hit_rate | bias(overconf) | cal_slope | ECE |
|-------|-------|---------|-------------|-------------|---------------|-----------|-----|
| v1 (1.0) | 0.5710 | 0.9642 | 0.5062 | 0.5451 | −0.0389 | 1.600 | 0.0523 |
| challenger (1.5) | **0.5621** | **0.9546** | 0.5340 | 0.5602 | −0.0261 | **1.182** | **0.0345** |

On the held-out OOS season the challenger WINS: lower Brier/logloss, calibration slope closer to 1,
lower ECE, less bias. v1 slope 1.60 (>>1) = systematic UNDER-confidence / over-compression
(favorite wins 54.5% but model predicts 50.6%).

### OOS per-regime (v1 SCALE 1.0 vs challenger SCALE 1.5)
| dim | regime | n | v1 Brier | ch Brier | v1 logloss | ch logloss | v1 bias | ch bias | v1 slope |
|-----|--------|---|----------|----------|-----------|-----------|---------|---------|----------|
| competition | UCL | 167 | 0.5599 | 0.5523 | 0.9482 | 0.9389 | −0.056 | −0.031 | 1.51 |
| competition | UEL | 99 | 0.5896 | 0.5787 | 0.9911 | 0.9810 | −0.010 | −0.017 | 1.80 |
| strength_gap | <0.10 | 94 | 0.5921 | 0.5885 | 0.9937 | 0.9889 | +0.003 | −0.004 | 2.69 |
| strength_gap | 0.10–0.30 | 150 | 0.5555 | 0.5464 | 0.9433 | 0.9317 | −0.073 | −0.035 | 1.50 |
| strength_gap | >=0.30 | 22 | 0.5864 | 0.5565 | 0.9806 | 0.9635 | +0.013 | −0.064 | 0.72 |
| weak_opp | weak_league_present | 63 | 0.5461 | **0.5202** | 0.9296 | **0.9006** | −0.071 | −0.025 | 0.92 |
| weak_opp | both_strong | 203 | 0.5787 | 0.5751 | 0.9750 | 0.9714 | −0.029 | −0.027 | 2.02 |
| high_total | model xg<3.5 | 253 | 0.5756 | 0.5702 | 0.9705 | 0.9638 | −0.038 | −0.032 | 1.73 |
| high_total | model xg 3.5–4.5 | 13/25 | 0.4814 | 0.4846 | 0.8407 | 0.8654 | −0.060 | +0.032 | 0.48 |
(fav_band / high_total regime membership is model-dependent so n differs across the two models.)

## VERDICT — φ over-compression
CONFIRMED as a real OOS signal in the most recent season, concentrated in the
`weak_league_present` and large `strength_gap` regimes — precisely where the 6 owner cards sit
(Bodo/Glimt, Sabah). v1 calibration slopes are systematically >1 (1.5–2.7) = under-confident /
over-compressed favorite separation. A 1.5× inter-league prior improves OOS Brier/logloss/ECE/
calibration in nearly every regime.

HOWEVER the effect is PERIOD-DEPENDENT: on the earlier validation window SCALE 1.0 is optimal and
1.5 is marginally worse. Selecting 1.5 because it wins the TEST window would be tuning-to-OOS and is
NOT permitted. Challenger is therefore NOT adopted. Recommendation: a proper walk-forward φ re-fit
(re-identify φ per fold with a widened/hierarchical inter-league prior + per-regime recalibration)
before any change to crossleague_v1 φ. No P_RETO changed by this analysis (read-only, diagnostic).

Labels: all numbers above = REAL_DATA_ADVERSARIAL_READONLY. NOT synthetic.
