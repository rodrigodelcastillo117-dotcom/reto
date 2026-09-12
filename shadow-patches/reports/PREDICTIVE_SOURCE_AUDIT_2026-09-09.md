# PREDICTIVE-SOURCE AUDIT BACKEND (§32) — soccer hot path vs legacy

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
método: `READ_ONLY_VERIFIED` — barrido de pg_proc + pg_views (public/v2) por referencias a
`v_pick_canonico` / `pred_futbol_espn`. Excluidos backups/zz_/_pre20.

## Resultado clave
El **hot path V2 de SOCCER tiene 0 fuentes de probabilidad en competencia**:
- `v_prediccion_reto_futbol` (P_RETO canónico, Motor B) — autoridad única.
- `analisis_futbol_reto_core` (iss023) — NO referencia legacy (verificado).
- `v_soccer_daily_canonical` (iss036) — lee la superficie canónica; NO referencia legacy.
Ninguno aparece en la lista de objetos que tocan v_pick_canonico/pred_futbol_espn.

## Clasificación de los 17 objetos que SÍ tocan fuentes legacy
| objeto | fuente | clase | acción |
|---|---|---|---|
| analisis_completo_core | pick_canonico + pred_futbol_espn | LEGACY (MLB/NFL; soccer enrutado fuera) | MIGRATION/CUTOVER (no soccer) |
| pred_futbol_espn | (motor legacy) | LEGACY_UNUSED por V2 soccer | CUTOVER_CANDIDATE |
| motor_probabilidades | pred_futbol_espn | LEGACY | CUTOVER_CANDIDATE |
| destacados_del_dia_canonico | pick_canonico | LEGACY superficie predictiva | CUTOVER_CANDIDATE (repuntar a canónico) |
| mejor_oportunidad_hoy / _v2__base | pick_canonico | LEGACY | CUTOVER_CANDIDATE |
| reto_13m_estado_canonico | pick_canonico | LEGACY (feed Reto13M) | reemplazado por iss036 (backend) + frontend ChatGPT |
| reto_picks_hoy__base | pick_canonico | LEGACY carril económico secundario | mantener secundario; no autoridad de P |
| v_oraculo_canonico | pick_canonico | LEGACY (Oráculo) | CUTOVER_CANDIDATE (query sobre canónico) |
| filtro_pick, revisar_apuesta__base, rongol_veto__base | pick_canonico | veto/validación (no autoridad de P) | CONTEXT/VETO — revisar en cutover |
| lab_dq_capturar_v1/_v2, lab_dq_medicion_v1, v_lab_dq_capturas_faltantes | pick_canonico | LAB/DQ instrumentación | TEST_ONLY/MIGRATION_ONLY |
| refrescar_mlb_modelo_snapshot | pick_canonico | MLB | fuera de alcance P0 soccer |

## Gates
- `ANALYSIS_NO_LEGACY_GATE (soccer hot path) = PASS` — 0 fuentes de probabilidad en competencia.
- Inventario legacy entregado para ChatGPT (frontend) y para el cutover runbook. Ningún
  objeto legacy se desactiva ahora (§52: sólo inventario, no cutover bajo freeze).

## Nota para ChatGPT (§29/§49)
Las superficies que aún leen `v_pick_canonico` como probabilidad (destacados,
mejor_oportunidad, v_oraculo_canonico, reto_13m_estado_canonico) deben, en el cutover,
consumir la superficie canónica (v_prediccion_reto_futbol / iss033) — no una P propia.
`reto_picks_hoy` puede permanecer como carril económico **secundario**, nunca como
autoridad de probabilidad de evento.
