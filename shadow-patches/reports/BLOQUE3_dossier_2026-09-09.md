# BLOQUE 3 — Full-Data Prematch Dossier Manifest · EVIDENCIA (STAGED)

Artefacto: `shadow-patches/prepared/iss030_soccer_dossier_manifest.sql`
(`v2.dossier_source_catalog` + `v2.fn_soccer_dossier_manifest(event, decision_time)`).
Test: `shadow-patches/tests/iss030_dossier_manifest_test.sql`. NO aplicar bajo freeze.

## Inventario REAL de fuentes (verificado en prod, no fabricado)
Cada fuente clasificada individualmente. `data_asof` sólo si existe POR FILA.

| Fuente | tabla | key | timestamp (data_asof) | role_class |
|---|---|---|---|---|
| modelo_p_reto | v_futpro_v2 | espn_event_id | data_asof ✓ | MODEL |
| xg_forward | lab_soccer_xg_forward | match_id | available_at ✓ (+usable_pre_kickoff) | CONTEXT |
| alineaciones | alineaciones_espn | espn_event_id | capturado_at ✓ (+minutos_antes) | CONTEXT |
| arbitro | futbol_arbitro_partido | espn_event_id | cargado_at ✓ | CONTEXT |
| h2h | bt_h2h | espn_event_id | fecha (proxy) | CONTEXT |
| descanso | bt_descanso | espn_event_id | fecha (proxy) | CONTEXT |
| standings | soccer_standings | liga_id+team_id | updated_at ✓ | CONTEXT |
| tendencias | tendencias_externas | (no fiable por event) | capturado_at | CONTEXT→missing |
| forma | bt_forma | espn_event_id | **NINGUNO** → as_of NO demostrable | CONTEXT |
| clima | futbol_clima_hora | estadio+hora | **NINGUNO** + sin key evento | CONTEXT |
| lesiones | sólo ligamx_lesiones | equipo | updated_at (SÓLO LigaMX) | CONTEXT |
| venue | futbol_estadios/altitud | estadio | estático | CONTEXT |
| total_line | momios_mercado.total_linea | espn_event_id | actualizado ✓ | MARKET |
| odds_mercado | momios_mercado | espn_event_id | actualizado ✓ | MARKET |
| odds_pro | odds_pro_snapshots | espn_event_id | created_at ✓ | MARKET |

**Hallazgos honestos:** `forma` y `clima` NO tienen data_asof por fila → jamás
MODEL_ACTIVE, se marcan con missing_reason explícito. Lesiones/alineaciones con
as_of confiable existen bien sólo para LigaMX; el resto queda missing.

## Manifiesto real (Liverpool–Atlético 401915446, decision_time=15:15 = computed_at)
| source | available | data_asof | freshness | role | temporally_safe |
|---|---|---|---|---|---|
| modelo_p_reto | false | 2026-05-05 | STALE | AVAILABLE_NOT_USED | (fail-closed UCL) |
| alineaciones | true | 18:07 | **FUTURE_INVALID** | AVAILABLE_NOT_USED | false |
| arbitro | true | 15:17 | **FUTURE_INVALID** | AVAILABLE_NOT_USED | false |
| descanso/forma/h2h/total_line/xg | false | — | NO_ASOF | AVAILABLE_NOT_USED | false |

El gate temporal FUNCIONA: alineaciones (18:07) y árbitro (15:17) llegaron DESPUÉS
del decision_time (15:15) → marcados FUTURE_INVALID y **no usados**. Cero MODEL_ACTIVE
(UCL sin modelo cruzado desplegado), cero as_of inventado, cero reuso del timestamp
del modelo.

## Test (iss030_dossier_manifest_test.sql, tx ROLLBACK) — invariantes
INV1 role válido · INV2 nada MODEL_ACTIVE con as_of>decision o sin as_of · INV3
used_in_p_reto sólo si MODEL_ACTIVE · INV4 temporally_safe=false ⇒ no CONTEXT/MODEL ·
INV5 FUTURE_INVALID ⇒ no usada. Pendiente correr en Supabase branch (freeze).

## Operaciones que requerirán autorización posterior
1. Ejecutar iss030 (catálogo + función) en prod.
2. Cablear `total_line`/`btts` explícitos en el contrato canónico (BLOQUE 4/5).
3. Ampliar cobertura de lesiones/alineaciones fuera de LigaMX (ingesta, aparte).
