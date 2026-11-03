# DOSSIER FULL-DATA COVERAGE — distribución sobre el universo próximo (§12–§14)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
estado: `READ_ONLY_VERIFIED` (prod, sin mutación). Universo = agenda soccer `fecha>now()` = **241**.
Nota: el manifest `v2.fn_soccer_dossier_manifest` (iss030) está STAGED (no desplegado); esta
matriz se computa READ-ONLY directamente sobre las tablas fuente físicas, con la MISMA
semántica temporal (as_of<=decision; aquí decision≈now() por ser eventos próximos).

## Matriz de cobertura por fuente (VERIFICADO)
| fuente | rol | universo | available | valid_asof | clasificación dominante |
|---|---|---|---|---|---|
| feat_goal_rate_home/away, sample | MODEL_ACTIVE | 241 | 203 | 203 | MODEL_ACTIVE (los 203 supported; alteran P_RETO) |
| total_line (v_momios_confiables) | MARKET/CONTEXT | 241 | **143** | **143** | 143 con línea real; 98 → O/U fail-closed |
| arbitro | CONTEXT_ONLY | 241 | 3 | 3 | 238 missing |
| alineaciones | CONTEXT_ONLY | 241 | 1 | 1 | 240 missing (llegan ~1h antes) |
| xg_forward | CONTEXT/AVAILABLE_NOT_USED | 241 | 0 | 0 | 241 missing (no hay xG forward para próximos) |
| h2h (bt_h2h) | CONTEXT/AVAILABLE_NOT_USED | 241 | 0 | 0 | NO_ASOF + 0 filas para próximos |
| descanso (bt_descanso) | CONTEXT/AVAILABLE_NOT_USED | 241 | 0 | 0 | NO_ASOF |
| forma (bt_forma) | CONTEXT/AVAILABLE_NOT_USED | 241 | 0 | 0 | NO_ASOF (sin ts por fila) |
| clima, venue, tendencias, lesiones(no-LigaMX) | AVAILABLE_NOT_USED | 241 | 0* | 0 | sin key de evento / sin as_of demostrable |

(*) clima/venue/tendencias no están keyeadas por espn_event_id de forma fiable → NO_ASOF/missing (iss030 los marca AVAILABLE_NOT_USED, nunca MODEL_ACTIVE).

## Lectura honesta (§13)
- Lo único que **altera P_RETO** son las tasas de gol AS-OF + muestra (MODEL_ACTIVE) — 203 eventos.
- Todo lo demás es **CONTEXT_ONLY** o **AVAILABLE_NOT_USED**. Para el universo próximo la
  mayoría del contexto está *missing* o *NO_ASOF*. Correcto por diseño: "prefiero una verdad
  incompleta a una P contaminada" (§13). Ninguna fuente de contexto empuja la probabilidad.
- total_line: 143/241 con línea real confiable (as_of<=decision). Los 98 sin línea → O/U
  fail-closed (sin `default 2.5`).

## Chequeos de consistencia (§14) — 0 anomalías por construcción
- MODEL_ACTIVE ⟺ used_in_p_reto=true: sólo las features del modelo; el resto CONTEXT con
  used_in_p_reto=false. No hay `MODEL_ACTIVE && used_in_p_reto=false` ni el inverso.
- `data_asof > decision` ⇒ FUTURE_INVALID/AVAILABLE_NOT_USED (iss030 marca post_decision_capture).
- Sin timestamp defensible ⇒ NO_ASOF/AVAILABLE_NOT_USED (h2h/descanso/forma/clima/venue).
- Cada fuente usa su PROPIO reloj (no se reusa model.data_asof como asof de lesiones/clima/etc.).
- Zero-row guard: universo=241>0.

## Gate
`DOSSIER_COVERAGE_GATE = PASS (read-only, staged manifest)`: la distribución es coherente y
fail-closed; ninguna fuente de contexto altera P_RETO. Efectivo en superficie tras deploy de
iss030+iss033 en branch. Query: `shadow-patches/reports/BLOQUE_dossier_coverage_2026-09-09_query.sql`.
