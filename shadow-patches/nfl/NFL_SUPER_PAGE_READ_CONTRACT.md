# NFL SUPER PAGE — READ CONTRACT (SHADOW)

Purpose: make NFL `Ver análisis` as dense and orderly as Soccer/MLB without fabricating a model.

## Hero
- exact event identity, teams, logos, kickoff/status
- `MODEL_STATUS=NO_OWN_MODEL`
- `P_RETO=NULL`, projected score/points NULL until a validated own model exists
- disabled winner graph shell; never sportsbook/no-vig as RETO

## Shared accordion order
1. Qué mueve la predicción
2. Forma y rendimiento
3. Matchup profundo
4. Alineaciones y disponibilidad
5. H2H y tendencias
6. Estadio, clima y viaje
7. Mercados y movimiento de línea
8. Riesgos e incertidumbre
9. Conclusión
10. De dónde salen los números

## Data mapping
- Forma: `nfl_partidos`, last 5 completed games strictly before kickoff. W1 may use prior-season games but UI must label prior-season context.
- Strength: temporal `nfl_fpi_historico` snapshot on/before kickoff; exact field names only, no claim of EPA/play if source is merely FPI component.
- QB/depth: `nfl_depth_chart`, exact player/team, capture <= kickoff.
- Injuries: `nfl_lesiones_semana`, exact season/week/team/player, capture <= kickoff.
- H2H: `nfl_h2h`, exact ESPN team IDs, contextual only, sample warning.
- Venue: `nfl_estadios`.
- Weather: `nfl_clima_hora`; because no capture timestamp is exposed, current context only and not eligible for historical model replay.
- Rest: derive from previous completed game before kickoff.
- Travel: coordinate distance may be shown only as approximate proxy.
- Market: `nfl_odds_snapshots`, opening/current/closing + deltas, context only.
- Missing advanced fields (EPA/play, success rate, PROE, pace, OL/DL, route/coverage/blitz): explicit missing_reason until sourced temporally and legally.

## Fantasy
Use `fantasy_player_super_context_v2`. Current-season and prior-season baseline must be visually separated. Historical p25/p50/p75 are observations, not prediction floor/median/ceiling. START/SIT and A-vs-B require canonical `FantasyProjectionSnapshot` before becoming recommendations.

## Gates
- exact identity, no same-team cross-event fallback
- null != zero
- no post-kickoff temporal inputs where capture timestamps exist
- no market-to-P_RETO contamination
- no historical-to-projection relabeling
- same dossier contract reused across NFL/Favoritos/Reto13M/live once model outputs exist
