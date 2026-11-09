# Watchdog de tareas automáticas (te avisa solo si algo falla)

Fecha: 2026-11-09. Gatillo: "mejora la robustez" (proteger todo lo que construimos). DINERO OFF.

## Qué
Un vigilante que revisa cada 6h las tareas CRÍTICAS del sistema y **solo te manda email si algo está mal**.
Si todo corre bien, no molesta. Protege incluso al propio email de picks (si esa tarea falla, el watchdog
lo detecta).

## Tareas vigiladas
mejores-picks-diario-7am, ingestar-odds-multicasa-am, ingestar-odds-soccer-am,
reto-clv-snapshot-diario, reto-recalibrar-auto-semanal, reto-recalibrar-platt-semanal.

## Qué cuenta como problema
Tarea inactiva · último estado != succeeded · fallos en 24h · nunca corrió ·
lleva demasiado sin correr para su cadencia (diarias >26h, semanales >180h).

## Piezas
- **Función `reto_cron_salud_v1()`** (SECURITY DEFINER, solo service_role; `supabase/sql/reto_cron_salud_v1.sql`):
  estado de cada tarea vigilada. Acotada a 14 días → rápida (~0.6s, antes topaba el statement_timeout).
- **Edge function `vigilar-crons`**: llama la función, filtra problemas y, si hay, manda un email a rodelcast
  listando qué tarea y por qué. Si no hay, no envía nada.
- **Cron `reto-vigilar-crons-6h`** (jobid 606, cada 6h, timeout 20s para tolerar arranque en frío).

## Validación
Primera corrida: revisó 6 tareas, 0 problemas, 0 emails. Todo verde.
