# BLOQUE 3 — Full-Data Prematch Dossier Manifest · EVIDENCIA (STAGED, ENDURECIDO)

Estado: implementado + validado en 2 eventos reales; pendiente correr test en branch.
Artefacto: `shadow-patches/prepared/iss030_soccer_dossier_manifest.sql` (v2).
Reescrito tras AUDIT_NO_PASS (issue #4 comment 5606659045), findings 2-9.

## Cómo se atendió cada finding
2. **Emite todas las fuentes** (no sólo catálogo): modelo + inputs del modelo +
   xg + alineaciones + arbitro + standings + lesiones + h2h + descanso + forma +
   clima + venue + tendencias + total_line + odds_mercado + odds_pro.
3. **decision_time NO cae a kickoff**: si falta prediction_time/computed_at real →
   fila única `NO_DECISION_TIME` fail-closed (nunca kickoff).
4. **Última captura ≤ decision_time** por fuente (`max(ts) FILTER (ts<=dec)`), con
   flag `post_decision_capture` cuando existen capturas posteriores (no borran la válida).
5. **xg** exige `usable_pre_kickoff=true` AND `available_at<=decision`.
6. **h2h.fecha / descanso.fecha / forma / clima** = NO son as_of de ingesta →
   NO_ASOF / AVAILABLE_NOT_USED con razón explícita. **venue** = ref estática sin
   versión → AVAILABLE_NOT_USED (no se inventa as_of).
7. **Inputs MODEL_ACTIVE emitidos** con su propio as_of: `feat_goal_rate_home`,
   `feat_goal_rate_away`, `feat_sample_counts` (provenance `v_goles_equipo_futbol`,
   que tiene `ultimo_partido`; as_of = `v_futpro_v2.data_asof` = corte real de datos
   del modelo). Sin as_of ≤ decision → no MODEL_ACTIVE.
8. **Validado en 2 eventos reales** (abajo).
9. Capturas post-decisión nunca cuentan como cobertura prematch (`post_decision_capture=true`,
   role AVAILABLE_NOT_USED).

## Validación (a) READY doméstico — Moreirense–Benfica (401885470), decision 09-09 18:15
| source | role | data_asof | temporally_safe |
|---|---|---|---|
| modelo_p_reto | **MODEL_ACTIVE** | 2026-09-05 | true |
| feat_goal_rate_home | **MODEL_ACTIVE** | 2026-09-05 | true |
| feat_goal_rate_away | **MODEL_ACTIVE** | 2026-09-05 | true |
| alineaciones | AVAILABLE_NOT_USED | NO_ASOF (sin captura ≤ decision) | false |
| total_line | AVAILABLE_NOT_USED | NO_ASOF | false |

Prueba positiva: el modelo Y sus inputs se exponen como MODEL_ACTIVE con as_of
propio demostrable ≤ decision_time. (Nota BLOQUE 4: la línea real de este evento
viene de `v_momios_confiables`, no de `momios_mercado` — se cablea en BLOQUE 4.)

## Validación (b) fail-closed — Liverpool–Atlético (401915446), cross-league sin modelo
0 MODEL_ACTIVE; alineaciones/árbitro con captura POSTERIOR a decision → FUTURE_INVALID/
post_decision, no usadas. Cero as_of inventado, cero reuso de timestamp del modelo.

## Pendiente
- Correr `iss030_dossier_manifest_test.sql` (ampliar a ambos eventos) en Supabase branch.
- Emitir per-team `ultimo_partido` como as_of alterno de feature (mejora de trazabilidad).
