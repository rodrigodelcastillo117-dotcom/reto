# Calendario de selecciones (internacional) en el pipeline ESPN

Fecha: 2026-11-09. Gatillo: "verifica que SÍ se actualizan los partidos... incluyendo internacional". DINERO OFF.

## Diagnóstico
`pedir_agenda_espn()` (cron agenda-espn-pedir, cada 4h) pide a ESPN solo las ligas de `ligas_master`
con `activa=true` y, para fútbol, `api_sports_id` no nulo. Las selecciones YA existían en `ligas_master`
(con su espn_endpoint y api_sports_id) pero estaban `activa=false` → el calendario ESPN no las traía.
Lo internacional solo entraba por el lado de MOMIOS (OddsAPI nations_league), no por calendario/resultados.

## Cambio (solo datos, sin tocar código)
Activé en `ligas_master` las competencias de selección que juegan en ventanas FIFA (recurren ~6×/año):
- id 35  · UEFA Nations League (espn soccer/uefa.nations, api 5)
- id 82  · FIFA Friendlies (soccer/fifa.friendly, api 10)
- id 119 · CONCACAF Nations League (soccer/concacaf.nations.league, api 30) — México

Solo se tocó el flag `activa`; `sync_apifootball` quedó en false (no gastamos API-Football en selecciones,
no las modelamos). Los momios siguen llegando por OddsAPI como antes.

## Validación (en vivo)
Tras activar + `pedir_agenda_espn(8)` + `absorber_agenda_espn()`, el calendario `agenda_espn` ya trae:
- UEFA Nations League: 36 próximos (13-16 nov)
- CONCACAF Nations League: 26 próximos (13-18 nov)
- FIFA Friendlies: 19 próximos (11-16 nov)
De aquí en adelante se actualiza solo (agenda-espn-pedir/absorber cada 4h) y sus resultados se calificarán
por el mismo pipeline que el fútbol de clubes (resultados-soccer-cada-hora, etc.).

## Pendiente opcional (no activado para no ensuciar con ligas fuera de temporada)
Copa América (34), UEFA Euro (117) y sus qualifiers, FIFA World Cup (116), Gold Cup (118), AFCON (121):
quedan `activa=false`. Se pueden encender cuando empiece su ciclo. Hoy no juegan.
