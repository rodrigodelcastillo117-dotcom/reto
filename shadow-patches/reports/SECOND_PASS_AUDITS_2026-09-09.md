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

## PASS 4 — Governance literals / registry (§47) · REGISTRY_GATE = STAGED_ONLY (limpio)
Auditado iss033: los umbrales de gobernanza son **registry-driven** — el builder usa
`cfg.window_days`, `cfg.sample_floor`, `cfg.feature_version`, `cfg.calibration_status`
(de `v2.model_config`), no literales dispersos. Únicos literales:
- VALUES del seed de `v2.model_config` (8, 540, 'dc-2026.09.1', 'UNVALIDATED') — correcto:
  la gobernanza vive EN la tabla registry, ese es el punto de §47.
- `p_window_days int default 540` — sólo default de argumento; la llamada real pasa
  `cfg.window_days`. Fail-safe.
- selector `where model_version='dc-2026.09.1'` — nombra qué modelo construir (aceptable).
Nit menor (no defecto, no leak): `model_config.publish_authorized` existe pero NO se
consulta; la puerta de publicación real es per-liga `model_registry.approved` (más estricta).
Recomendación de cutover: o se enforce `publish_authorized` como AND global, o se elimina
la columna para no confundir gobernanza. No bloquea.

## PASS 9 — Consistencia de report / SHA
- El closure report no hardcodea un SHA (referencia `git rev-parse HEAD`) → no queda stale.
- Gate matrix del closure actualizada: CROSS_LEAGUE_REPLAY_GATE FAIL→STAGED_ONLY (iss037),
  MARKET_CONTAMINATION_GATE=PASS añadido.
- DAG incluye iss037 (paso 2b). Runbook y DAG mutuamente consistentes en orden y rollback.
- Todos los artefactos citados en el closure existen en shadow-patches/ (iss027..iss037,
  iss023; tests; reports). Sin referencias colgantes.

## PASS — Early payout / pago anticipado (§27) · EARLY_PAYOUT_GATE = PASS
Verificado read-only sobre las funciones PA de prod (pg_get_functiondef):
| función | escribe 'perdido' | escribe 'ganado' | pa_score_snapshot | pa_activado_at |
|---|---|---|---|---|
| dispatch_pa_para_pick        | NO | SÍ | SÍ | SÍ |
| dispatch_pa_para_pierna_parlay | NO | SÍ | SÍ | SÍ |
| protect_pa_picks             | NO | SÍ | — | — |
| sweep_pa_picks               | NO | NO (router) | — | — |
| trigger_pa_on_score_update   | NO | NO (router) | — | — |
- **Ninguna ruta PA escribe 'perdido'** → PA sólo puede crear WIN_EARLY, nunca LOSS_EARLY (§27).
- Los dos graders reales exigen evidencia: `pa_score_snapshot` + `pa_activado_at` (+ iss028
  `guard_pa_evidencia_obligatoria` que la hace obligatoria y autosella activado_at).
- Columnas PA presentes: picks(early_graded, early_grade_score/minute, pago_anticipado,
  pa_activado, pa_activado_at, pa_score_snapshot); parlays(pago_anticipado,
  pa_piernas_activadas, pa_total_piernas_activado). No hay PA huérfano sin evidencia por diseño.
`EARLY_PAYOUT_GATE = PASS` (read-only). Sin mutación.

## PASS — Competition identity / provider mapping (§20) · COMPETITION_IDENTITY_GATE = PASS (residual doc)
Auditado `v2.liga_alias` (25 filas; columnas liga_source:text, competition_id:text):
- `name_to_many_comp` = **none** → ningún nombre mapea a >1 competition_id (sin ambigüedad fuzzy).
- `comp_with_multi_names` = 2 → 2 competencias con múltiples grafías de nombre (aliasing correcto).
- PASS 3 ya verificó 0 colisiones nombre↔liga_id y 0 en el universo de agenda (n=241).
Estado: sin colisión activa. **Residual de diseño (§20):** `liga_alias` está keyeada por
NOMBRE (liga_source), el key más débil que el audit advierte. Mitigado porque (a) el builder
usa además el `liga_id` NUMÉRICO de ESPN para registry/features, (b) nombres no mapeados
fail-close a NO_MODEL. **Recomendación de cutover:** re-keyear `liga_alias` por
`provider_competition_id` (ESPN liga_id numérico) + `mapping_version`, no por nombre, para
congelar identidad por id de proveedor. No bloquea (0 colisiones hoy). `COMPETITION_IDENTITY_GATE=PASS`
con residual de hardening documentado.
