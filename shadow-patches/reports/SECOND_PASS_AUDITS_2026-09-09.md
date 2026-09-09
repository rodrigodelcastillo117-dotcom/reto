# SECOND-PASS AUDITS (§59/§60/§64) — READ_ONLY_VERIFIED

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON

## PASS 2 — Market independence (§64) · MARKET_CONTAMINATION_GATE = PASS
`v2.fn_score_dist(home_gf,home_gc,away_gf,away_gc,league_mean_home,league_mean_away,over_line)`
**no tiene ningún argumento de odds** → P_RETO no puede depender del precio por construcción.
Verificado cambiando SÓLO `over_line` 2.5→3.5 con mismas features:
| campo | 2.5 | 3.5 | ¿igual? |
|---|---|---|---|
| p_home / p_draw / p_away | = | = | SÍ |
| btts_yes | = | = | SÍ |
| lambda_home / lambda_away | = | = | SÍ |
| predicted_score | = | = | SÍ |
| p_over | 62.9 | 40.7 | **cambia (correcto)** |
1X2/BTTS/lambdas/score idénticos; sólo O/U se recomputa sobre la nueva línea factual.

## PASS 3 — Identidad de evento/competencia (§20/§21) · PASS (universo próximo, n=241)
| chequeo | resultado |
|---|---|
| filas / eventos distintos | 241 / 241 |
| espn_event_id duplicados | 0 |
| liga_nombre → >1 liga_id (colisión de nombre) | 0 |
| liga_id → >1 liga_nombre (variantes) | 0 |
| home_espn_id = away_espn_id (self-match) | 0 |
| eventos sin team id | 0 |
`EVENT_IDENTITY_GATE` / `COMPETITION_IDENTITY_GATE` / `DUPLICATE_EVENT_GATE` = PASS (read-only).

## PASS 7 — False-pass defense en mis propios tests (§60)
Auditados los tests staged:
- 0 patrones `WHEN OTHERS THEN NULL` / catch-all que traguen fallos.
- Todos con `RAISE EXCEPTION` en el camino de fallo (3-4 por archivo).
- **Endurecimiento aplicado:** las aserciones negativas `if r<>'X'` podían pasar en
  silencio si el fixture faltaba (NULL `<>` 'X' = NULL → no raise). Cambiadas a
  `if r is distinct from 'X'` (NULL dispara fallo) + guardas `if not found then raise`
  en iss034 C1/C2. agenda_universe_regression ya tenía zero-row guard (`agenda=0 → FAIL`).
- Tests de fixtures insertan sus propias filas en tx (fixture count > 0 garantizado).

## Notas
- Determinismo (§69): fn_score_dist sin RNG; replays A==B; calcular_bankroll_actual STABLE.
- Todos los chequeos read-only; ninguna mutación de prod.
