# ISS-023 — Respuesta al AUDIT EXTERNO P0 (FAIL) → SOCCER_V2_BACKEND_CLEAN_CANDIDATE

> Auditor externo (GitHub + Supabase prod + Lovable) marcó **FAIL P0**: el "V2" de fútbol seguía copiando P_RETO del cerebro legacy y el marcador era un segundo cerebro. Correcto. Reconstruido el contrato para que **una sola distribución** sea la única fuente. No se avanza a MLB hasta pasar esto.

## Causa raíz confirmada
`v2.rebuild_soccer_snapshot()` leía `analisis_partidos.analisis_json.probabilidades (home_win/draw/away_win)` → p_raw → **P_RETO** (probabilidad legacy disfrazada de V2), clasificando READY por `engine_mode/confianza` viejos, sin muestra/validación. Y `v2.soccer_score_dist` producía 1X2/BTTS/O-U/marcador por OTRO camino (tasas DC) → dos cerebros: 98 partidos con P_HOME divergente >5pp (máx 23.7).

## Reconstrucción aplicada (prod `wpiztubmmmzclhlprgpd`)
1. **`v2.fn_score_dist`** — distribución conjunta Dixon-Coles; `over_line` ahora OPCIONAL (si no hay línea real → `p_over` NULL; **cero 2.5 hardcodeado**). De UNA matriz: 1X2, BTTS, O/U(línea real), `predicted_score=argmax`, `exp_goals_total`.
2. **`v2.soccer_prediction_v2`** (tabla nueva, **inmutable/versionada**, sin TRUNCATE) + `v2.build_soccer_prediction_v2()`:
   - Fuente predictiva ÚNICA: tasas de goles reales (`v_goles_equipo_futbol`) + medias de liga (`v_liga_promedios_futbol`) + **línea O/U real** (`v_momios_confiables` por `espn_event_id`). **Cero lecturas de `analisis_partidos.probabilidades`.**
   - P_RETO = 1X2 de la MISMA distribución. Marcador, BTTS, O/U(línea real) = misma distribución.
   - Metadatos: model_name/version, feature_version, calibration_status=UNVALIDATED, data_asof, prediction_time, sample_home/away, temporal_safe, provenance, línea+fuente, odds reales (home/draw/away, over/under, bookmaker, captured_at), score_dist inmutable.
   - Fail-closed: `model_status = READY_UNVALIDATED` solo si dist computable + ambas muestras ≥8 + temporal_safe; si no `DATA_INCOMPLETE` (sin número, con razón).
3. **`public.v_futpro_v2`** reescrita: lee SOLO `v2.soccer_prediction_v2` (última por evento). `snapshot_id = canonical_event_id = espn_event_id` (ID estable, ya no alterna UUID/espn). Publica P_RETO/marcador/mercados solo cuando READY. Escudos por `espn_event_id`. Odds reales expuestas como informativas (nunca como P_RETO). Sin narrative legacy.
4. **Cron**: desprogramado el destructivo `v2_rebuild_soccer_snapshot` (TRUNCATE, jobid 418); programado `v2_build_soccer_prediction` (aditivo, jobid 419, `15 */3 * * *`).

## Evidencia de compuertas (medido en prod)
| Gate | Meta | Resultado |
|---|---|---|
| LEGACY_PREDICTIVE_DEPENDENCIES | 0 | **0** (v_futpro_v2 → soccer_prediction_v2 → goal_rates + odds; nunca analisis_partidos.probabilidades) |
| SINGLE_JOINT_DISTRIBUTION | PASS | **PASS** (todo de `fn_score_dist`) |
| SCORE/P_RETO wrong-team mismatches | 0 | **0** (los 70 marcadores-empate bajo favorito son argmax legítimo de la misma dist; 0 apuntan al equipo equivocado) |
| HARD_CODED_TOTAL_LINES | 0 | **0** (línea real de libro; `over_without_line=0`; Barça 4.5, Stuttgart 3.5, otros 2.5 reales) |
| TEMPORAL_VIOLATIONS | 0 | **0** |
| STABLE_CANONICAL_EVENT_IDS | PASS | **PASS** (espn_event_id) |
| IMMUTABLE_PREDICTION_SNAPSHOTS | PASS | **PASS** (tabla versionada; cron destructivo apagado) |
| ILLEGITIMATE_P_RETO | 0 | P_RETO solo con muestra≥8 + temporal_safe; Stuttgart/Viking y Barça ahora del modelo, no legacy |

Ejemplos: Barcelona–Feyenoord **73.9/14.9/11.1**, marcador 2-1 (8.5%), línea real 4.5 — todo de la misma distribución (antes P_RETO legacy 53.2/24.0/22.8). Stuttgart–Viking ya no publica el 43.7 legacy de Viking.

## Pendiente para SOCCER FINAL (no bloquean CLEAN_CANDIDATE de backend, sí el "Soccer final")
- **Estado/live/final + marcador en vivo** en el contrato (hoy solo `event_status` de agenda).
- **Análisis V2 limpio**: `v_analisis_v2` queda **CUARENTENADO** (lee resumen/momentum/conclusiones legacy de `analisis_partidos`). **Sacar de la ALLOWLIST.** Reconstruir solo con datos factuales con provenance (forma, H2H, lesiones, clima) — nunca conclusiones del cerebro viejo.
- **Stuttgart cross-league trust**: el modelo publica por muestra; si se quiere fail-closed por baja confianza cross-liga (Bundesliga vs Noruega), es refinamiento de confianza del modelo (#149/#206), no contaminación.
- **Calibración validada** para pasar de READY_UNVALIDATED a validado.
- **Logos**: 34/221 sin al menos un escudo → fallback neutro (nunca escudo de otro club).

## Seguridad (DISEÑO — NO ejecutar sin auditar policies)
Advisory: 113 tablas sin RLS + views públicas con grants > SELECT. Hardening propuesto (a auditar antes de correr):
```sql
-- Bridges públicas: solo lectura
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.v_futpro_v2, public.v_analisis_v2 FROM anon, authenticated;  -- (v_futpro_v2 ya aplicado)
GRANT SELECT ON public.v_futpro_v2 TO anon, authenticated;
-- RLS en tablas v2 (definir policies de SELECT público de solo-lectura antes de activar)
ALTER TABLE v2.competition_catalog ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.soccer_prediction_v2 ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.liga_alias ENABLE ROW LEVEL SECURITY;
ALTER TABLE v2.team_logo ENABLE ROW LEVEL SECURITY;
-- + policy "select público" por tabla. Auditar acceso del anon antes de activar en prod.
```

## Congelación
`reto13` (repo/app legacy) CONGELADO: cero trabajo V2 ahí. Todo desarrollo nuevo en el remix-cuarentena `d243f279` y en `v2.*`.

## Orden bloqueado
FUT (este candidato) → auditoría externa → MLB → auditoría → NFL → auditoría → Fantasy. **No se toca MLB hasta que el auditor apruebe SOCCER_V2_BACKEND_CLEAN_CANDIDATE.**
