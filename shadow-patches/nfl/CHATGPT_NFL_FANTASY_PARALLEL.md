# CHATGPT PARALLEL — NFL + FANTASY

Status: SHADOW ONLY / NO DEPLOY / NO PROD MUTATION.

Current branch: `chatgpt/nfl-fantasy-parallel`.

Implemented contracts:

1. `nfl_factual_dossier_v1.sql`
   - exact `espn_event_id`
   - NO_OWN_MODEL, P_RETO NULL
   - injuries/H2H/FPI context
   - opening/current/closing market history
   - coverage object

2. `nfl_super_dossier_v2.sql`
   - extends factual dossier with temporal-safe FPI historical snapshots
   - last-5 form derived only from completed games before kickoff
   - rest days / short-week derivation
   - QB1/QB2 from depth chart as-of kickoff
   - exact week injuries captured at/before kickoff
   - H2H by exact ESPN team IDs
   - venue/altitude/roof
   - travel-distance proxy clearly labelled
   - weather nearest kickoff, explicitly CONTEXT_ONLY_NO_CAPTURE_ASOF because source lacks capture timestamp
   - opening/current/closing ML/spread/total and movement deltas
   - explicit coverage + missing_reason
   - P_RETO/proj points remain NULL until validated own NFL model exists

3. `fantasy_equipo_player_context_v1.sql`
   - exact ESPN player ID
   - next event, injury, usage, advanced usage, snaps, defense-vs-position, game environment
   - canonical projection fields NULL

4. `fantasy_player_super_context_v2.sql`
   - exact player + next season/week/event
   - injury/depth chart current week
   - strict split between current-season usage and prior-season baseline
   - prior-season baseline never relabelled as current
   - opponent-vs-position current vs prior-season baseline split
   - sportsbook/game environment context only
   - projection floor/median/ceiling/uncertainty remain NULL until own fantasy projection brain exists
   - explicit coverage + missing_reason for air yards/aDOT/YPRR/xFP/routes/OL-DL/coverage feeds

Read-only production inventory verified on 2026-09-10:
- NFL injuries 2026 week 1: populated (~2k rows)
- NFL depth chart 2026: populated
- NFL FPI 2026: 32 teams
- NFL H2H: populated
- NFL weather-hour table: populated at large scale
- NFL odds snapshots: populated with opening/current history
- NFL advanced/current-season player usage: not yet populated for 2026 before Week 1; 2025 baseline exists
- NFL standings 2026: not yet populated before Week 1

Hard rules:
- market/no-vig never P_RETO
- missing != zero
- current vs prior-season context must be visibly distinct
- no historical read may consume post-kickoff captured facts when capture timestamps exist
- no frontend-generated projection brain
- same canonical event/player identity across views

Next backend owner action after SOCCER predictive sanity gate: inspect/cherry-pick these contracts, compile on disposable branch, correct any schema drift, then build own NFL model and FantasyProjectionSnapshot separately.