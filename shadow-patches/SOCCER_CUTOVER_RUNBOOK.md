# SOCCER_CUTOVER_RUNBOOK (§51) — PREPARAR, NO EJECUTAR

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON · RELEASE_GATE=HOLD
**Este runbook NO se ejecuta.** Requiere autorización explícita de deploy + gates verdes en branch.

## PRECHECKS
- backend HEAD esperado: (ver `git rev-parse HEAD` de la rama; último commit del cierre).
- frontend Lovable/Remix sincronizado a su SHA exacto (ChatGPT owns) — NO por Claude.
- Supabase branch aislado con iss027..iss036 aplicados en el orden del DAG y **todos los
  tests verdes** (`BRANCH_EXECUTION_GATE`).
- Snapshot/backup lógico de las funciones que se REEMPLAZAN (pasos 8-10 del DAG):
  guardar `pg_get_functiondef` de `auto_cerrar_parlay_si_leg_perdido`,
  `cerrar_parlays_con_pata_perdida`, `actualizar_bankroll_post_al_calificar`,
  `actualizar_bankroll_post_parlay`, `guard_no_early_loss`, `guard_pa_evidencia_obligatoria`.
- Gate matrix (ver report de cierre) sin FAIL bloqueante para soccer.

## APPLY ORDER (en tx de cutover, por dependencia — ver STAGED_MIGRATION_DAG.md)
1 iss032 → 2 iss027 → 3 iss033 → 4 iss029 (solo Grecia) → 5 iss030 → 6 iss036 →
7 iss031 → 8 iss028 → 9 iss034 → 10 iss035.
Tras el paso 3, ejecutar `build_soccer_prediction_v2_staged(now())` para poblar la
superficie canónica; luego repuntar `v_futpro_v2`/`analisis_futbol_reto_core`/daily a esa
superficie (descomentar `v_soccer_canonical`).

## POSTCHECKS (mismos invariantes que en branch)
- `canonical_surface_event_count == agenda_universe_event_count` (0 drops) — agenda universo.
- 1X2 Σ=100 (tol 0.1) · BTTS yes+no=100 · O/U over+under=100 sobre la línea real.
- real_line: cada O/U con `line_asof<=decision`, provider real, 0 fabricadas; sin default 2.5.
- temporal: 0 filas con `max_source_event_time>decision`; feature_snapshot poblado.
- unsupported/veto (AFC CL, EFL Cup, Sudamericana, Scottish Cup, Coppa Italia) VISIBLES con
  P_RETO=NULL + model_status/reason (no desaparecen).
- daily: 0 filas O/U con línea ≠ real; 0 BTTS-no reconstruido por complemento.
- grading: parlay LIVE 'perdido' no cierra; sólo pata FINAL perdida cierra.
- bankroll: `calcular_bankroll_actual` idéntico tras re-grade/retry.
- analysis: `legacy_event_probability_sources=0` en payloads soccer.

## ROLLBACK
- Pasos 1-7 (aditivos): `DROP` de los objetos v2 nuevos (sin datos de prod que perder).
- Pasos 8-10 (reemplazos): restaurar las defs previas guardadas en PRECHECKS.
- iss029: `DELETE` de la fila de aprobación de Grecia en `v2.model_registry`.
- Ningún `DROP CASCADE`; ningún borrado de datos de usuario.

## FRONTEND SYNC (ChatGPT / Lovable — NO Claude)
- backend expone el contrato canónico exacto (SHA); Lovable consume a su SHA exacto.
- superficies que hoy leen v_pick_canonico como P (destacados, mejor_oportunidad,
  v_oraculo_canonico, reto_13m_estado_canonico) deben repuntar a la superficie canónica.
- daily debe consumir `v2.v_soccer_daily_canonical` (no `v_reto13m_daily`).
- smoke autenticado: cards, P_RETO, modal análisis, cross-screen, sin O/U con línea falsa.

## OPERACIONES QUE REQUIEREN AUTORIZACIÓN (no ejecutar sin ella)
- `apply_migration` iss027..iss036 (branch primero, luego prod).
- Reemplazo de funciones prod (grading/bankroll) — pasos 8-10.
- INSERT de aprobación Grecia en model_registry.
- Creación de Supabase branch (si implica coste/confirm_cost).
- NO Sudamericana (veto). NO frontend. NO NFL/MLB/Tennis.
