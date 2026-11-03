# Mejoras reales y gratis — lesiones NHL + índices de FK

Fecha: 2026-11-03. Continuación de "mejoras reales que no cuesten".

## 1. Alertas de lesión para NHL (dato que ya existía, no estaba conectado)
`lesiones_v1` ya trae lesiones de hockey/nhl (parte de 2,152 filas), pero
`v_reto_lesiones_partido_v1` solo incluía NBA + football/baseball en su CTE `up` →
los picks de NHL salían SIN alerta de lesión. Se agregó la rama NHL
(`reto_nhl_agenda_v1`, endpoint hockey/nhl). Verificado: 57 eventos NHL, 56 con alerta
(294 jugadores "out" disponibles). Ahora `v_reto_mejores_picks_v1` muestra
titulares_fuera/alerta_lesion también para NHL. (Fútbol no: sus lesiones no están en
lesiones_v1, solo Liga MX en tabla aparte; queda como pendiente mayor.)

## 2. Índices de llaves foráneas faltantes (perf, seguro)
Del advisor de rendimiento (unindexed_foreign_keys). Creados IF NOT EXISTS:
batalla_stats(apodo_b), calibradores(model_version), ligamx_alineaciones(team_id),
mlb_shadow_predicciones(clv_real_id), reto_user_entitlement_v1(plan_id),
usuarios(casa_preferida). Mejoran joins y borrados en cascada; sin riesgo.

## Nota
La tabla caliente historico_partidos_espn ya está bien indexada (home/away id + endpoint
+ fecha) → ahí no había índice faltante. Dinero OFF; sin cambios de modelo/gate.
