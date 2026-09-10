# Remix Reto 13M — NFL Fantasy showcase audit — 2026-09-10

Branch: `chatgpt/reto13m-closeout`
Disposable Supabase branch: `nfl-dossier-parity` / `oakxebiyashfsiforukq`
Production mutation: NONE.

## Implemented/staged

- `iss053_fantasy_roster_persistence.sql` — canonical one-roster-per-user/week cloud persistence contract.
- `iss054_fantasy_weekly_brain_v1.sql` — immutable pre-kickoff weekly PPR projection snapshots.
- `iss055_nfl_player_props_autograde_v1.sql` — NFL-specific player-prop evaluator/autograde from final `nfl_player_game_logs`.

## Executed evidence

### Roster persistence
Two writes for the same `(apodo, season, week)` produced exactly one row and replaced roster contents (`roster_size` 1 -> 2), proving deterministic weekly replacement in the branch.

### Fantasy weekly brain — real SF/LAR Week 1 seed
Decision time `2026-09-10T23:15:00Z`; kickoff `2026-09-11T00:35:00Z`.
Real production-derived player/usage/depth/injury rows were seeded read-only for Puka Nacua, Christian McCaffrey, Brock Purdy and Matthew Stafford.

Output at the decision snapshot:
- Puka Nacua: median 27.2 PPR, floor 18.1, ceiling 38.3, confidence 89.
- Christian McCaffrey: median 23.9, floor 16.5, ceiling 32.9, confidence 91.
- Brock Purdy: median 22.5, floor 13.4, ceiling 33.6, confidence 75.
- Matthew Stafford: median 22.4, floor 16.8, ceiling 29.4, confidence 91.

All four: depth order 1, injury status `active`, availability factor 1.00, `market_used=false`.

Hard invariants:
- temporal violations = 0
- projection band violations = 0
- market-source violations = 0
- same-decision replay inserted = 0
- direct UPDATE of projection snapshot rejected by immutable trigger

Injury adversarial on Puka, branch-only:
- 23:15 active -> 27.2 / PROJECTED
- 23:17 questionable -> 22.8 / PROJECTED, factor .84
- 23:19 out -> 0.0 / OUT, factor 0
Prior snapshots remained immutable.

### NFL player-prop autograde
Historical real fixture: ESPN `401772960`, PIT 26-BAL 24.
Persisted player stats used as settlement authority.

Executed cases:
- Derrick Henry Over 100.5 rushing yards; actual 126 -> WON
- Derrick Henry Under 100.5 -> LOST
- Derrick Henry Over 126 -> PUSH
- Derrick Henry 100+ -> WON
- Lamar Jackson Under 250.5 passing yards; actual 238 -> WON
- Mark Andrews Over 2.5 receptions; actual 2 -> LOST
- unsupported market -> fail-close `no_evaluable`
- non-final event -> `pending`
- Spanish parsing for `Más de ... yardas terrestres`, `Menos de ... yardas de pase`, `Más de ... recepciones` -> correct
- after live branch grading, replay rows = 0

## Current-production Prop Lab sanity examples for SF-LAR
Using existing read-only `public.nfl_prop_jugador`, not the new Fantasy brain and not P_RETO:
- CMC Over 4.5 receptions: P(over)=74.9%, historical mean 6.0, sample 17.
- CMC Over 59.5 rushing yards: P(over)=62.5%, mean 70.7, sample 17.
- Puka Over 91.5 receiving yards: P(over)=61.5%, mean 107.2, sample 16.
- Puka Over 7.5 receptions: P(over)=57.7%, verdict neutral/pass.

These are orientative prop-model outputs from historical distribution and current opponent mapping; not guaranteed picks and not canonical event P_RETO.

## Known limitation before canonical Fantasy cutover
The production frontend still consumes `fantasy_ranking` for its weekly catalog. That surface intentionally marks those rows non-canonical because the new immutable Fantasy brain is staged only. The showcase can use the existing screenshot analysis/optimizer and Prop Lab today, but `fantasy_weekly_v1` must not be labeled production-canonical until its release gate/cutover.
