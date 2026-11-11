# Revisión de la cartelera de mañana + ventana de líneas ampliada

Fecha: 2026-11-03 (para el 4 nov CDMX). El usuario pidió revisar los partidos de mañana
de todos los deportes y dejarlos para el mejor análisis posible.

## Estado de la cartelera de mañana (4 nov CDMX) — revisado juego por juego
- **NBA (14):** todos con pick de ganador + total esperado del modelo + lesiones. 11 con
  pick publicable (≥55%); los 3 restantes son volados honestos (52.5/50.5/54.7%). OK.
- **NHL (4):** todos con pick + total del modelo + lesiones (ahora sí, tras conectar NHL
  a la vista de lesiones). 2 publicables (≥56%); los otros 2 son volados (54/50%). OK.
- **Soccer (13, P0):** 11 READY con pick; **forma en los 13** (100%, por el fix por ID);
  H2H en 3 (el resto son cruces de primera vez de UCL/Europa — honesto). Los 2
  MODEL_UNAVAILABLE son clubes asiáticos (AFC CL) con muestra/φ insuficiente — correcto
  dejarlos sin pick, no se inventa.
- **NFL / Tenis:** no juegan mañana.

## Único hueco real y su arreglo: líneas reales de totales
Las líneas reales de casa (ESPN) salían NULL para mañana. No era falla del ingestor
(corre fresco cada 20 min) sino que `ingestar-lineas-totales` pedía el scoreboard del
**día actual** solamente → las líneas de mañana no entraban hasta que rodara el día.
Arreglo: la edge function ahora pide **hoy + 2 días** (`?dates=YYYYMMDD` en horario del
este, el de ESPN) y deduplica por evento. Resultado al dispararla: ya capturó 2 líneas de
NBA de mañana que antes no entraban; el resto caerá en cuanto ESPN las publique (el cron
cada 20 min ya cubre la ventana de 3 días). Esto alimenta la vista informativa de totales
y el arnés forward (congela mejor la línea de cierre). Dinero OFF; sin cambios de modelo.
