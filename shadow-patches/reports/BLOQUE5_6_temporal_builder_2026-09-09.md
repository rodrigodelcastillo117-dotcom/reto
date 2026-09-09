# BLOQUE 5/6 — Builder temporalmente reproducible + contrato canónico · EVIDENCIA (STAGED)

Corrige AUDIT_NO_PASS comment 5606845587 (el finding #7 NO estaba resuelto).
Artefacto: `shadow-patches/prepared/iss033_temporal_reproducible_builder.sql`.
Test: `shadow-patches/tests/iss033_temporal_replay_test.sql`. NO aplicar bajo freeze.

## Problema confirmado en el builder de PROD (v2.build_soccer_prediction_v2)
- `temporal_safe` = literal `true`.
- features desde el agregado MÓVIL `v_goles_equipo_futbol` (contra `now()`).
- `data_asof = greatest(ultimo_partido)` (fecha deportiva, no disponibilidad).
- floor `>=8`, model/version/feature_version/calibration HARDCODEADOS.
- INNER JOIN `liga_alias`+`competition_catalog enabled=true` → no soportados DESAPARECEN.
- `v_futpro_v2` re-une el agregado actual → inputs mostrados cambian post-predicción.

## Prueba del defecto (read-only, Barcelona LaLiga, decision 2026-05-01)
| feature | valor | fuente |
|---|---|---|
| home GF **AS-OF** (fecha<decision) | **2.774** | 31 juegos, max fuente 2026-04-22 (< decision) |
| home GF **MÓVIL** (producción, now) | **2.816** | ultimo_partido 2026-09-06 |
| juegos de Barça POSTERIORES a decision incluidos por el móvil | **4** | contaminación temporal |

El agregado móvil NO es reproducible (2.774→2.816 según cuándo corre); el as-of sí.

## Fix (iss033) — 12 puntos del audit
1. `build_soccer_prediction_v2_staged(p_decision_time)`: decision_time EXPLÍCITO; sin now() como autoridad.
2. `fn_soccer_features_asof(...)`: features desde partidos FINAL con `fecha < decision_time` (ventana registry).
3. sample_home/away también AS OF decision_time.
4. `temporal_safe` = `max_source_event_time <= decision_time` (calculado, nunca literal).
5. `v2.feature_snapshot` persiste vector + `feature_data_asof` + `max_source_event_time` + feature_version (reproducibilidad).
6. `v2.model_config` registry-driven: sample_floor/window/model/feature_version/calibration/publish (elimina literales, incl. `>=8`).
7. AGENDA = universo: LEFT JOIN a alias/catálogo/registry; unsupported/unmapped → visible con `P_RETO=NULL`, `NO_MODEL/DATA_INCOMPLETE` + razón (nunca desaparece).
8. Contrato `v2.v_soccer_canonical` 1 fila/evento: `p_reto_*`, **btts_yes + btts_no explícitos del mismo snapshot** (soccer_prediction_v2 ya guarda btts_no), O/U con `over_line`+`line_asof` (fn_real_total_line), decision_time, provenance, missing_reason.
9. La vista canónica NO re-une `v_goles_equipo_futbol` — inputs congelados en el snapshot.
10. Dossier: sólo filas usadas Y temporalmente demostradas = MODEL_ACTIVE; `ultimo_partido` por sí solo NO basta.

## Tests (iss033_temporal_replay_test.sql, tx ROLLBACK)
11. **Adversarial**: insertar un partido 9-0 POSTERIOR a decision_time NO cambia el feature as-of ni P_RETO (fecha<decision lo excluye por construcción). PASS esperado.
12. **Replay**: dos cómputos as-of dan vector idéntico; `max_source_event_time <= decision`. PASS esperado.
Pendiente: correr en Supabase branch (bajo freeze no se aplica la función en prod).

## FULL_DATA_SOCCER_ANALYSIS_GATE — NO declarado PASS
Falta correr en branch los tests temporales positivos + adversariales de verdad, y
migrar el builder de producción a la versión as-of. Queda staged.

## Operaciones que requerirán autorización posterior
1. Ejecutar iss033 (config + fn_soccer_features_asof + feature_snapshot + build_staged + v_soccer_canonical) en un branch; correr tests.
2. Reemplazar `build_soccer_prediction_v2` por la versión as-of + snapshot; recomponer `v_futpro_v2` para NO re-unir el agregado móvil.
3. Exponer `btts_no` explícito en la superficie pública.
