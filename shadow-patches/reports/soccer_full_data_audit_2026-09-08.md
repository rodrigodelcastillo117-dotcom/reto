# Soccer full-data audit — 2026-09-08

Status: **READ-ONLY PROD AUDIT**. No production mutation was performed.
Project: `wpiztubmmmzclhlprgpd`.

## North star

`P_RETO` is the single event probability. All other data is either model-active upstream or context. Context does not silently nudge `P_RETO` unless validated out-of-sample and temporally safe.

## Hard defects found in current production analysis core

`analisis_completo_core` currently:

1. builds soccer summary probabilities from `pred_futbol_espn(p_event)` instead of canonical `P_RETO`;
2. hardcodes soccer `v_linea := 2.5`;
3. reads `v_pick_canonico` probability / economic eligibility / EV in the primary summary;
4. can traverse heavy unrelated value/cross-sport work; a read-only completeness audit timed out with an execution stack reaching MLB work while auditing soccer.

ISS-023 stages a soccer-only replacement path that has no `v_pick_canonico`, `destacados`, `pred_futbol_espn`, MLB/NFL, or EV dependency.

## Measured upcoming-48h coverage

Read-only query over `agenda_espn` soccer events from now to +48h:

| Metric | Count |
|---|---:|
| Soccer event universe | 46 |
| Events with Motor B (`fut_predicciones`) row | 18 |
| Motor B rows meeting sample>=20 and generated pre-kickoff | 15 |
| Events with real provider total line pre-decision | 46 |
| Events with venue | 46 |
| Events with confirmed lineup snapshot already available | 0 |
| Events where both teams have pre-decision ESPN ratings | 45 |
| Events where both teams have pre-decision standings | 46 |
| Events where both teams map to API-Football ids | 44 |
| Events with referee loaded pre-decision | 0 |

Interpretation: coverage of context is substantially wider than coverage of the provisional probability model. This is **not** permission to fabricate P for the other events. They remain in the event universe with explicit `NO_MODEL` / `INSUFFICIENT_SAMPLE` states.

## Player-season data caveat

`futbol_jugador_temporada` contains 9,785 rows at audit time, but `equipo_id` is NULL on the measured rows. Therefore those stats cannot currently be assigned to a team safely by `equipo_id`. The full-data contract must report this as a mapping/missingness limitation rather than pretending the data was team-linked. Confirmed lineups can later provide a safe player-id bridge if their roster JSON carries the same player ids.

## Temporal-safety rules staged

- Motor prediction: `generado_at <= kickoff` required.
- Provider line/odds: latest non-live snapshot with `capturado_at <= min(now, kickoff)`.
- Lineups: `capturado_at <= decision_time`.
- Standings: `capturado_at <= decision_time`.
- Ratings: `actualizado <= decision_time`.
- Injuries: `updated_at <= decision_time`.
- Referee: `cargado_at <= decision_time`.
- Recent form / H2H / trends / home-away splits: explicit AS-OF functions or event-date cutoff.
- Weather: current storage has no capture timestamp. It is inventoried but is **not treated as temporally auditable input** until snapshot provenance is added.

## Model-active vs context-only

Measured `lab_feature_inventory_soccer` classification:

- MODEL_ACTIVE: attack/defense, league mean, Dixon-Coles correction; H2H O/U adjustment requires AS-OF verification.
- AVAILABLE_NOT_USED: xG.
- CONTEXT_ONLY today: weather, referee, rest/fatigue, rotation, descriptive BTTS/clean-sheet stats, narrative context.

ISS-023 includes context data in the dossier/manifest while keeping it out of `P_RETO` unless it is part of the already-versioned canonical model.

## Staged files in takeover branch

- `iss018_matriz_futbol_unifica_pipeline_b.sql` — hardened matrix: temporal safety, low-sample rows preserved with P=NULL, real line, model provenance.
- `iss021_soccer_p_reto_resolver_mi_idea.sql` — exact canonical resolver + Mi Idea prediction lane.
- `iss022_parlay_soccer_canonical_legs.sql` — soccer parlay legs use exact P_RETO or fail closed.
- `iss023_soccer_full_data_analysis.sql` — soccer-only full-data dossier + versioned cache dispatch.
- `iss024_soccer_closure_validation.sql` — machine acceptance checks.

Nothing in this report constitutes release approval. `RELEASE_GATE=HOLD`.
