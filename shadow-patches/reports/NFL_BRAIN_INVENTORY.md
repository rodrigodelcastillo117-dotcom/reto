# NFL_BRAIN_INVENTORY — read-only prep for FASE 1 (NFL_BRAIN_FINAL)

Status: **PREP ONLY**. SOCCER still P0 / RELEASE_GATE=HOLD / PROD_FREEZE=ON; do NOT change
the NFL model, schema, or data, and do NOT touch prod until the auditor releases SOCCER.
Captured READ-ONLY from prod `wpiztubmmmzclhlprgpd` on 2026-09-10 (SELECT / catalog reads only).
No prod mutation. Complements the ChatGPT fail-close shadow contracts on
`chatgpt/nfl-fantasy-parallel` (not duplicated here).

North star: `ONE BRAIN · ONE CANONICAL EVENT · ONE P_RETO · ONE DOSSIER · MANY VIEWS`.
sportsbook / no-vig / FPI-implied / EV are NEVER P_RETO.

Headline finding (arithmetically confirmed in `shadow-patches/nfl/nfl_game_card_v1.sql`,
NF-01, and re-verified here): **NFL has no independent own-probability model today.** The
served "probabilities" are the sportsbook no-vig price (`nfl_partidos.p_home/p_away`). The
only own signal is an ESPN-FPI *opinion* that speaks in 17/272 current games. `nfl_predecir`
itself stamps `es_modelo=false, nota_modelo='NFL no tiene modelo independiente de probabilidad'`.
So the correct FASE-1 start state is `P_RETO=NULL, MODEL_STATUS=NO_OWN_MODEL`.

## 1) Prediction functions found (candidate brains — MUST unify to ONE canonical)
Measured via `length(pg_get_functiondef(oid))` and body inspection.
| function | body | role (measured) | disposition for FASE 1 |
|---|---|---|---|
| `public.nfl_predecir()` | 9469 | **the pick writer** — sole `INSERT INTO nfl_predicciones` (ON CONFLICT by event). Builds market no-vig markets (`fuente='mercado'`) + FPI opinion (`fuente='modelo'`) + points context. | **canonical serving path** — certify; it is where P_RETO must live once an own model exists |
| `public.nfl_opinion_modelo(event)` | 2734 | own opinion from ESPN FPI (`nfl_fpi`); opines only when disagreement ≥2.14pt (2σ). Called by `nfl_predecir`. | this is today's closest thing to an "own model" — but FPI-derived, not a from-scratch model; keep as a challenger input, never as P_RETO alone |
| `public.pred_nfl_espn(event)` | 2746 | points model from matview `mv_fuerza_nfl_espn` (σ=14.32, measured wind −3.14pt). Called by `nfl_predecir` as **context only**; self-declares Brier 0.246 vs market 0.213 (worse than market). | keep as CONTEXT/challenger; MUST NOT become P_RETO until it beats market out-of-sample |
| `public.motor_nfl(home,away,meses,peso)` | 4790 | STABLE team-strength engine reusing SOCCER `equipo_perfil`/`liga_base`; self-labelled "Motor sin calibrar". **NOT called by `nfl_predecir`.** Reached only by `motor_del_partido` and `veredicto_vivo` (both STABLE, read-only). | **PARALLEL/LEGACY BRAIN — quarantine.** Feeds a generic dispatcher + a live-verdict path that can show NFL probabilities that diverge from the served picks. |
| `public.nfl_spread_por_fpi(event)` | 1499 | FPI→spread diagnostic (STABLE, read-only) | diagnostic; keep, label as market/FPI context |
| `public.nfl_prob_del_spread(spread)` | 747 | IMMUTABLE spread→prob (logistic k=0.13, calibrated on 2025 272 games) | helper only |
| `public.correr_backtest_nfl(linea,peso)` | 3005 | writes `backtest_resultados` (deporte='football/nfl'); same Normal-margin math as `motor_nfl` | **lab-only** — must never feed prod P_RETO |
| `public.nfl_calibrar_sd()` | 1305 | writes `nfl_parametros` (sd_margen, umbral_brecha) from `nfl_partidos` market lines | calibration util; note it calibrates off market lines, not own model |
| `public.nfl_mejor_pick(event)` | 3962 | market line-incoherence diagnostic (ML-implied vs spread-implied) | diagnostic; feeds `nfl_picks_premium`/`nfl_game_card_v1`, not a probability model |
| `public.nfl_dossier(event)` | 6289 | narrative dossier assembler | dossier surface (analogue of the soccer/MLB dossier) |

Action FASE 1: prove exactly ONE path serves the NFL number and mark it `NO_OWN_MODEL` until
a real own model exists; quarantine `motor_nfl` and its dispatcher/live consumers so no screen
can show a second, uncalibrated NFL probability.

## 2) Snapshot / provenance / champion-challenger (partially built)
- `nfl_predicciones` (writer `nfl_predecir`) — current per-event surface; **PK per event, each run overwrites** (no as-of history in this table).
- `nfl_predicciones_historial` (writer `nfl_capturar_prediccion`, 652 rows/2026) — immutable per-run snapshot for CLV/opening-vs-closing. Critically it now records **`fuente`** per snapshot (measured: 33 model vs 619 market/null) — so a naive "grade the model" would otherwise grade the market against itself.
- `nfl_odds_snapshots` (1080 rows, 2 books, `snapshot_at`+`created_at`+`casa`, coverage 2026-08-29 → 2026-09-10) — opening/current line snapshots with source + timestamp. This is the market-provenance source.
- `v_nfl_movimiento_linea` — derives opening (`apertura`) vs closing (`cierre`) pick/ML/spread/total from the historial = the walk-forward/CLV harness analogue.
- Backtest/lab: `backtest_resultados` (1437 NFL rows) via `correr_backtest_nfl`; `nfl_backtest` table exists but is **empty (0 rows)**.
- **Gap vs MLB:** no dedicated NFL champion-vs-challenger shadow table (MLB has `mlb_shadow_predicciones`). The FPI opinion and `pred_nfl_espn` are the natural challengers but there is no immutable model/version/features_as_of snapshot table for an *own* model yet.

## 3) Temporal-safe feature sources available before kickoff (with 2026 population)
Populated for current 2026 season:
- Schedule + market: `nfl_partidos` (300/2026, wk≤18), `nfl_odds_snapshots` (fresh, 2 books), `v_momios_nfl`, `v_nfl_movimiento_linea`.
- Team strength: `nfl_fpi` (32/2026, all teams) + `nfl_fpi_historico`; `mv_fuerza_nfl_espn` (32 rows — **matview, appears carried from 2025; verify/refresh before use**).
- Injuries / actives: `nfl_lesiones_semana` (2008/2026, wk1) + `nfl_aplicar_lesiones()`; `nfl_depth_chart` (247/2026); QB-compromised + out counts denormalized on `nfl_partidos`.
- Weather / roof: `nfl_clima_hora` (1.5M rows), `clima_partido_nfl()` (measured wind −3.14pt), `nfl_estadios` (roof), `v_juego_clima_nfl`.
- Context / H2H / rest: `nfl_h2h`, `nfl_calendario_equipo`, `nfl_bye_weeks` + `nfl_equipo_en_bye()`, `record_nfl()`, `nfl_standings`.
- Draft/ADP: `nfl_adp` (278/2026).

**NOT populated for 2026 (biggest current-season gaps — do NOT recycle 2025 as current):**
- `nfl_snaps` → 0/2026 (7887 rows are 2025). Snap share is empty for the live season.
- `nfl_uso_jugador` → 0/2026 (422 rows 2025). Usage/target-share empty.
- `nfl_uso_avanzado` → **0 rows total** (schema has target_share, rz_targets_20/10, rz_acarreos, separacion_yardas — all empty).
- `nfl_defense_logs` → 0/2026, `nfl_kicker_logs` → 0/2026, `nfl_equipo_totales` → 0/2026, `nfl_defensa_fantasy` → 0/2026.
- Red zone: only `nfl_zona_roja_2025` (250 rows, 2025-named) — no 2026 red-zone source.
- `nfl_defense_vs_position` → 128/2026 present but at wk1 this is baseline/carryover, not live-season signal.

No dedicated EPA/play, success-rate, PROE, pace, explosive-play, pressure/sack, coverage
(man/zone/blitz), or OL/DL-matchup tables were found read-only — those advanced sources
**do not exist** in this schema. Say so plainly: any "EPA/coverage" feature would have to be
built, not queried.

## 4) Pick-serving views (MANY VIEWS — today they do NOT read one canonical model)
- `nfl_picks_premium` — reads **`nfl_partidos`** directly and publishes `p_home/p_away` as `probabilidad` + `momio_justo`, **one row per ML side** (each game → two "premium picks"). This is market no-vig served as a pick. **Market-as-P_RETO risk, live.**
- `v_favorito_nfl` — reads `nfl_partidos`; `favorito_pct = GREATEST(p_home,p_away)*100`, i.e. market no-vig again. (Honestly stamps `fuente='mercado'`.)
- `nfl_tablero` — the one view that LEFT JOINs `nfl_predicciones` (so it can surface the FPI opinion via `mejor_pick`).
- `v_nfl_fpi_vs_mercado` — FPI vs market diagnostic.
FASE 1 must repoint the pick views to the ONE canonical surface (mirroring soccer `v_futpro_v2`);
until an own model exists that surface returns `P_RETO=NULL / MODEL_STATUS=NO_OWN_MODEL`.

## 5) Fantasy (`Equipo`) backend sources (for NFL_FANTASY_EQUIPO_BACKEND) — verified read-only
| source | exists | 2026 populated |
|---|---|---|
| `fantasy_liga_config` | yes | 1 row (2026) |
| `fantasy_roster_semanal` | yes | **0 rows (empty)** |
| `fantasy_start_sit` | yes | 4 rows, wk1/2026 (minimal) |
| `fantasy_adp` | yes | **0 rows** ; `nfl_adp` has 278/2026 |
| `nfl_jugadores` | yes | 999 rows |
| `nfl_uso_jugador` | yes | **0/2026** (2025 only) |
| `nfl_uso_avanzado` | yes | **0 rows total** |
| `nfl_snaps` / `nfl_snaps_resumen` (view) | yes | **0/2026** (2025 only) |
| `nfl_defensa_vs_posicion_ppr` (view over `nfl_player_game_logs`) | yes | driven by game logs; 2026 accrues weekly |
| `nfl_defense_vs_position` | yes | 128/2026 (baseline) |
| injuries `nfl_lesiones_semana` | yes | 2008/2026 |
| depth chart `nfl_depth_chart` | yes | 247/2026 |
| odds `nfl_odds_snapshots` | yes | fresh, 2 books |
| weather `nfl_clima_hora` | yes | 1.5M rows |
Fantasy readiness: config/injuries/depth/odds/weather present; **usage, snaps, advanced-usage,
and the fantasy roster/start-sit tables are essentially empty for 2026** — the Equipo backend
cannot compute usage-driven projections for the live season yet. Helpers present:
`fantasy_semana_nfl()`, `nfl_prop_jugador()`, `nfl_fantasy_meter_k_y_def()`, `refrescar_jugadores_nfl()`,
`match_jugador_nfl()`, `resolver_ids_nfl_datos()`.

## 6) Known open NFL issues (inferred from what was measured — fold into FASE 1)
- **No own model.** Served probabilities are market no-vig; `pred_nfl_espn` self-reports worse Brier than market. → start `NO_OWN_MODEL`.
- **Parallel brain divergence.** `motor_nfl` (uncalibrated, soccer-derived) is live-reachable via `motor_del_partido`/`veredicto_vivo`, independent of the served `nfl_predicciones`. Two NFL numbers can appear on different screens.
- **Market-as-P_RETO in the serving layer.** `nfl_picks_premium` and `v_favorito_nfl` publish the no-vig price as a pick probability.
- **Current-season data holes.** snaps, usage, advanced-usage, defense/kicker logs, team totals, red-zone all empty/2025-only for 2026; `mv_fuerza_nfl_espn` likely stale. Do not backfill by recycling 2025 as if current.
- **Snapshot semantics.** `nfl_predicciones` overwrites per event (no as-of); history lives only in `nfl_predicciones_historial`. An own model needs its own immutable model/version/features_as_of snapshot.
- **O/U worse than a coin flip** (self-documented Brier 0.253 vs 0.250) — totals must not become picks until re-backtested.

## 7) Proposed FASE 1 gate shape (per NFL_BRAIN_FINAL owner mandate)
Canonical identity `event_id + market + side + line + season/week`. Build ONE own NFL model;
market/no-vig/FPI-implied NEVER P_RETO. Until the own model exists and validates:
`P_RETO=NULL, MODEL_STATUS=NO_OWN_MODEL`, no frontend alternate probability brain.
Outputs when live: own-model P_RETO for supported markets + MODEL_STATUS, data_quality,
uncertainty, model_version, snapshot_at, full provenance; projected home/away points + score
distribution only if the own model generates/validates them.
Required gates: temporal-leakage adversarials; same-event deterministic replay; cross-screen
contract equality (all pick views read the one surface); no-vig cannot become P_RETO; exact
line identity; null fail-close; injuries/weather as-of cutoff; reproducible historical snapshot;
performance/batching. SYNTHETIC_GATE first; REAL_DATA_GATE only in a data-bearing env.

## 8) RESOLVED brain call-graph (read-only, 2026-09-10) — evidence
All edges observed directly in `pg_get_functiondef` bodies; single-writer/orphan checks by
scanning every `public` function body for `motor_nfl` and `INSERT INTO nfl_predicciones*`.

- **Canonical serving path:**
  `nfl_predecir` (9469B) → calls `nfl_opinion_modelo` (2734B) → calls `nfl_prob_del_spread` (747B); reads `nfl_fpi`, `nfl_partidos`.
  `nfl_predecir` → calls `pred_nfl_espn` (2746B, CONTEXT only) → calls `clima_partido_nfl`, `phi_normal`; reads `mv_fuerza_nfl_espn`.
  `nfl_predecir` → calls `nfl_desacuerdo_por_equipo`; **writes `nfl_predicciones` — and is the ONLY function that writes it** (verified: sole `INSERT INTO nfl_predicciones`). ✅
- **Snapshot path:** `nfl_capturar_prediccion` (3349B) reads `nfl_partidos`+`nfl_predicciones`, **sole writer of `nfl_predicciones_historial`** → `v_nfl_movimiento_linea` (opening/closing). ✅
- **Parallel brain (quarantine):** `motor_nfl` (4790B) is STABLE, **not referenced by `nfl_predecir`**. Referenced only by `motor_del_partido` (STABLE dispatcher) and `veredicto_vivo` (STABLE live verdict). It reuses soccer `equipo_perfil`/`liga_base`/`phi` and self-labels "sin calibrar". → own-probability path divorced from the served picks. ⚠️
- **Lab (must not feed prod):** `correr_backtest_nfl` (3005B) → `backtest_resultados` (1437 NFL rows). `nfl_backtest` table empty (0). `nfl_calibrar_sd` (1305B) → `nfl_parametros`.
- **Ops (not a brain):** `espejar_nfl_a_live` (3255B) mirrors `nfl_partidos` → `live_scores`.
- **Serving views bypass the model:** `nfl_picks_premium` and `v_favorito_nfl` read `nfl_partidos` (market no-vig) directly, not `nfl_predicciones`; only `nfl_tablero` joins `nfl_predicciones`. Confirmed via `pg_get_viewdef`.

Single P_RETO writer today = **none is a true model**: `nfl_predecir` is the single writer of
the pick surface but writes market no-vig + FPI opinion, self-stamped `es_modelo=false`.
FASE-1 "ONE BRAIN" work = (a) build the own model behind `nfl_predecir`; (b) quarantine
`motor_nfl` + `motor_del_partido`/`veredicto_vivo` NFL branch; (c) repoint `nfl_picks_premium`
and `v_favorito_nfl` off raw `nfl_partidos`; (d) add an immutable own-model snapshot with
model/version/features_as_of/provenance.

(Prep note only — no code/model/data change until SOCCER is released by the auditor.)
