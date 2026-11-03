# Fix: agenda NBA contaminada con juegos de MLB (ids cruzados)

Fecha: 2026-10-20. Detectado en la auditoría de pantallas pedida por el usuario.

## Síntoma
En "Lo más probable hoy" aparecía **"Tampa Bay Rays vs Cleveland Guardians" como
deporte NBA**, duplicado, con pick "Gana Tampa Bay Rays" (59.8%) y "Menos de 228.5
pts" (66.1%). Son equipos de **MLB**, no NBA.

## Causa raíz
`reto_nba_agenda_v1` contenía juegos de **MLB playoffs** (Rays, Guardians, Brewers;
season_type=3). Los `espn_team_id` de MLB **colisionan** con ids de equipos NBA
(Rays=30, Guardians=5, Brewers=8 también existen como ids NBA), así que el join con
`nba_rating_prod` (partidos>=15) tenía éxito y producía picks NBA falsos. 16 de 84
filas futuras de la agenda NBA eran no-NBA; 1 se filtró a las vistas (la de ids
totalmente colisionados). El filtro por id NO sirve porque los ids se repiten entre
deportes: la única llave confiable es el **nombre del equipo**.

## Arreglo (defensa en profundidad)
1. **Vistas de servicio** `v_reto_nba_mercados_v1` y `v_reto_nba_totales_v1`: la CTE
   de agenda ahora exige que `home_nombre` y `away_nombre` estén en el set de nombres
   NBA reales (de `historico_partidos_espn` endpoint basketball/nba).
2. **Limpieza**: `delete` de las filas no-NBA de `reto_nba_agenda_v1` (16).
3. **Blindaje de ingestión**: `absorber_agenda_nba_v1()` y `absorber_agenda_nhl_v1()`
   ahora solo insertan eventos cuyos dos equipos (por displayName) estén en el set de
   nombres del deporte correcto. Evita recontaminación sea cual sea la fuente del
   cruce en el scoreboard de ESPN.
4. **Récord**: borrados los 2 snapshots contaminados de `reto_pick_snapshot_v1`
   (nba Rays/Guardians) para no ensuciar el grade/record.

## Verificación
- mejores picks: 0 duplicados, 0 filas con equipos no-NBA, 0 Rays/Guardians.
- v_reto_nba_mercados_v1 / v_reto_nba_totales_v1: 0 equipos no-NBA.
- reto_nhl_agenda_v1: 0 no-NHL (ya estaba limpia).
- snapshots: 0 contaminados en todos los deportes.

## Nota
La agenda NHL creada en esta sesión nunca se contaminó; el blindaje se agregó como
prevención simétrica.
