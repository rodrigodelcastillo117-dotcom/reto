# Endurecimiento de seguridad/rendimiento (lote seguro del advisor)

Fecha: 2026-11-03. El usuario pidió "haz todo" sobre el lote 🟢 SEGURO del advisor.
Todo verificado, sin romper la superficie de lectura de la app (vistas SECURITY DEFINER
y RPCs del front intactos: tablero_del_dia, reto_lo_mejor_editorial_v2, futpro_terminal_v2,
fantasy_reporte_semana, salud_datos siguen anon-ejecutables; mejores_picks 237, futpro 271).

## APLICADO
1. **RLS initplan (17 políticas):** se reescribió `auth.uid()` / `auth.role()` /
   `has_role(auth.uid(),…)` a `(select auth.…())` en 17 políticas de tablas de usuario
   (ajustes_cuenta, alertas_enviadas, alertas_sistema, config_staking, equipos_favoritos,
   espn_api_failures, limites_usuario, notificaciones, reportes_errores ×4,
   reto_user_entitlement_v1, sharp_money_alerts, user_patterns, user_roles). Idéntico en
   comportamiento; se evalúa 1 vez por query en vez de 1 vez por fila. Verificado en el
   texto almacenado.
2. **Revocado EXECUTE anónimo de 14 funciones internas** (ETL/gobernanza/backtest):
   mlb_backfill_aplicar/cosechar, mlb_bootstrap_arrancar/paso/tick, correr_backtest(×2)/
   _motor_real/_nfl, procesar_odds_espn, sync_nfl_desde_cdn, podar_radar_odds_snapshots,
   registrar_eventos_no_jugados, aplicar_calibrador_autorizado. El permiso venía de un
   grant a **PUBLIC** (`=X/postgres`), así que se revocó de PUBLIC; `service_role` y
   `postgres` conservan su grant explícito (crons/edge functions no se afectan — ninguna
   la llama por SQL directo). Verificado: 0 ejecutables por anon ahora.
3. **RLS habilitado en 58 tablas internas** (backups `_bk_*`/respaldo*, staging
   `_carga_*`/`*_pendiente`, backtest `bt_*`, experimentos `iss*`, `calib_*`, `_nrfi_*`,
   `tmp_*`, `_sched_req`). service_role/crons las siguen escribiendo (bypassean RLS);
   solo se cierra la lectura directa anónima. Verificado: 0 de esas sin RLS.

## RETENIDO A PROPÓSITO (con motivo)
- **Consolidar políticas permisivas duplicadas (26):** es solo perf menor (WARN), y
  fusionar mal cambia el control de acceso (expone u oculta datos). Requiere análisis
  por tabla del intent real; el riesgo supera el beneficio. No se tocó.
- **Blindaje masivo de search_path (313 funciones):** `SET search_path=''` rompe cualquier
  función que use nombres sin calificar (muy común). No se puede verificar 313 cuerpos a
  ciegas; hacerlo en lote es peligroso. Pendiente de hacer por lotes verificados si se pide.
- **Borrados (320 índices sin uso + tablas basura):** irreversibles; "sin uso" depende de
  stats desde el último reset. Se harán uno por uno con respaldo solo con confirmación
  explícita del borrado.
- **Protección de contraseña filtrada (HaveIBeenPwned):** es config de Auth (dashboard),
  no se puede por SQL/MCP. 1 clic del dueño: Authentication → Password.

Dinero OFF; sin cambios de modelo/gate/picks.
