# ISS-020 — SURFACE REWIRE PLAN (decision-agnostic staging)  *** NO CODE APPLIED ***

Gate: RELEASE_GATE=HOLD, NO_DEPLOY, NO_NEW_PROD_SCHEMA_CHANGES, SINGLE_WRITER.
Purpose: capture the EXACT, mechanical rewire for each value/universe surface so that
the moment the auditor freezes the soccer engine (A / B / ensemble), the frontend change
is a one-line source swap through the central adapter — NOT a redesign.

CENTRAL ADAPTER (single point of change): `useMatrizReto` / view `v_prediccion_reto_futbol`.
When the engine is decided, ONE view definition changes; screens below already read the
adapter for the PREDICTION and never hardcode A or B.

WHY NOT REWIRE NOW: today the prediction adapter = Motor A (live in prod) while the value
screens (Oráculo/Parlay/Mi Idea) read Motor B via v_pick_canonico. Flipping the value
screens to the adapter now would DE-FACTO canonize A — forbidden until the bakeoff decision.
So these rewires are STAGED, executed only after the engine is frozen and the adapter points
at the winner.

## Gate #7 — Qué Apostar event universe (AUDIT CONFIRMED BROKEN)
Finding (measured 2026-09-09): agenda_espn soccer next-48h = 40 events; the selector
`destacados_del_dia_canonico(48,NULL,false)` returns only 16 → 25 upcoming soccer events are
NOT in the Qué Apostar universe. So QUE_APOSTAR_EVENT_UNIVERSE_SOURCE = EV/analysis-selected,
NOT canonical.
Rewire (post-decision): Hoy.tsx lists the CANONICAL scheduled universe (all upcoming soccer
events with a prediction from the adapter), showing the most-probable market per event
(mejorMercado); EV/"valor" becomes a SECONDARY filter/tab ("Picks con valor"), never the
universe gate. OLD_EV_SELECTOR_CONTROLS_VISIBLE_EVENTS → NO. Coverage of the universe follows
the chosen engine (A ~33/48h, B ~15/48h) → this is why it is coupled to the A/B decision.

## Gate #8 — Mi Idea (Canasta.tsx)
Current: RPC veredicto_lote / revisar_canasta / buscar_partido (own verdict path).
Rewire (post-decision): resolve user idea → canonical_event_id + market/side/line → read the
SAME P_RETO/analysis from the adapter; the verdict CONTEXTUALIZES the user's idea, it does not
compute its own event probability. MI_IDEA_OWN_EVENT_PROBABILITY → 0.

## Gate #9 — Parlay (ParlayDelDia.tsx / construir_parlay_v2)
Current: construir_parlay_v2 RPC emits leg prob/EV (Motor B lineage).
Rewire (post-decision, value FOLLOWS P_RETO): each leg's BASE probability = canonical P_RETO
from the adapter; the assembler keeps filtering/correlation/joint math but may NOT emit an
alternate leg probability. PARLAY_LEG_P_MISMATCHES → 0. EV/Kelly recomputed FROM P_RETO.

## Gate #10 — Oráculo (OraculoRecomendados / OraculoBanner)
Current: v_oraculo_canonico + v_pick_canonico (Motor B).
Rewire (post-decision): Oráculo = QUERY interface over the canonical matrix only (highest
P_RETO, best ML/BTTS/total, lowest uncertainty, by sport). ORACULO_OWN_PROBABILITY_ENGINE → 0.

## Gate #10b — Pick del Día
Rewire (post-decision): PickDelDia = EXACT alias of Reto13M top-1 canonical candidate
(same EVENT/MARKET/SIDE/LINE/P_RETO/ANALYSIS_HASH/RETO_SCORE). Retire the pick-del-dia edge fn
as a probability source.

## Gates #15/#16 — Dashboard / Cómo Voy (AUDIT)
Route-level separation already largely exists: /numeros (Cómo Voy) + /estadisticas = USER
performance (bankroll/ROI/CLV/exposure); /calibracion = MODEL calibration KPIs. Required:
verify NO screen judges MODEL truth from the user's personal bets; Dashboard = canonical AUDIT
(reads immutable canonical predictions), not a predictor. Model-performance section (Brier/
log-loss/calibration of P_RETO by bucket/sport/market) reads the adapter → shows the DECIDED
engine's calibration after the bakeoff freeze; until then it displays MODEL_STATUS=PENDING.

## Order of execution once engine is frozen
1. Point adapter (v_prediccion_reto_futbol) at the decided engine (A / B / ensemble).
2. Migrate value machinery (EV/Kelly/es_pick, construir_parlay_v2, Oráculo) to consume P_RETO.
3. Rewire universe (Qué Apostar) + Mi Idea + Pick del Día alias.
4. RETO_SCORE_V1 (engine-agnostic structure) consumes final P_RETO + quality/uncertainty.
5. Cross-screen verification: CROSS_SCREEN_P_MISMATCHES = 0 via filaCoherente + one-source read.
