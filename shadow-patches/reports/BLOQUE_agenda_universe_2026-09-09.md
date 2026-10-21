# AGENDA = UNIVERSO — diagnóstico + prueba de 0 drops (§19, AUDIT_NO_PASS 5606930539)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
estado: `READ_ONLY_VERIFIED` (prod, sin mutación) + fix `STAGED_NOT_EXECUTED` (iss033)

## Hallazgo (reproducido)
`v_futpro_v2` (superficie canónica actual) hace INNER JOIN contra `v2.liga_alias` +
`v2.competition_catalog enabled=true`; los eventos no mapeados / no habilitados
**desaparecen** en lugar de quedar visibles fail-closed.

| métrica | valor (2026-09-09, ventana `fecha>now()`) |
|---|---|
| agenda_espn soccer (universo) | **241** |
| en v_futpro_v2 | 203 |
| **desaparecidos** | **38** |

(El auditor midió 254/215/39 minutos antes; la diferencia es sólo el corrimiento de
la ventana temporal. El defecto es el mismo.)

### Desaparecidos por liga (VERIFICADO)
| liga_id | liga | n | alias | catálogo |
|---|---|---|---|---|
| 17 | AFC Champions League | 16 | no | — |
| 48 | EFL Cup | 10 | no | — |
| 11 | Copa Sudamericana | 6 | sí | **disabled (VETO)** |
| 181 | Scottish League Cup | 4 | no | — |
| 137 | Coppa Italia | 2 | no | — |

Nota: Copa Sudamericana es VETO (no dar pick) pero **debe seguir VISIBLE** con
`P_RETO=NULL` + `model_status` explícito, no desaparecer (§19).

## Prueba del fix (agenda LEFT JOIN = universo) — VERIFICADO
Reemplazando los INNER JOIN por LEFT JOIN (diseño de `iss033.build_soccer_prediction_v2_staged`):

| métrica | valor |
|---|---|
| agenda_universe | 241 |
| universe_after_leftjoins | **241** |
| supported_mapped (elegible modelo) | 203 |
| no_model_unmapped (NO_MODEL) | 32 |
| mapped_not_enabled (veto/deshabilitado, visible) | 6 |
| **zero_drops** | **true** |

203 + 32 + 6 = 241 → **0 drops silenciosos**. Los 38 eventos quedan visibles:
32 como `NO_MODEL`/`UNSUPPORTED_COMPETITION`, 6 (Sudamericana) como visible-vetado
(`model_status_reason`='Competencia no aprobada para el modelo'), con `P_RETO=NULL`.

## Regresión permanente (parte de FULL_DATA_SOCCER_ANALYSIS_GATE)
Invariante: `canonical_surface_event_count == agenda_universe_event_count` (0 drops).
- Hoy, read-only (diseño LEFT JOIN): **PASS** (241==241).
- Post-deploy en branch (sobre `soccer_prediction_v2_staged`): STAGED — ver
  `shadow-patches/tests/agenda_universe_regression.sql`.

## Estado de gate
`AGENDA_UNIVERSE_GATE`: diseño PASS (read-only 241==241); efectivo en prod = FAIL
hasta cutover del builder iss033 (v_futpro_v2 sigue con INNER JOIN). No prod mutation.
