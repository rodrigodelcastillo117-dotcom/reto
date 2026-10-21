# Fix honesto: línea real de totales NBA (no 228.5 fija) + logos de equipos

Fecha: 2026-10-20. Gatillo: el usuario detectó que los totales de puntos NBA se
publicaban con **línea fija 228.5** y un % de confianza, cuando la línea real de la
casa varía por partido (captura del libro: BOS/DET 220.5, PHI/NY 231.5, OKC/SA 231,
ATL/ORL 235.5, MIL/WAS 237.5). Dinero/EV/Kelly siguen OFF.

## El problema de honestidad (no solo la línea)
La validación OOS de NBA O/U (65.7% @ prob≥60) se hizo contra la **línea mediana
fija 228.5** — eso mide "¿este juego será más/menos anotador que el promedio?", NO
"¿le gana a la línea de la casa de ESE juego?". Contra la línea real del libro el
edge es ~50% (el mercado ya sabe qué juegos son anotadores). Además, en inicio de
temporada el modelo da ~219.8 para casi todos los juegos (no discrimina con 20
partidos rodantes de la temporada pasada). Conclusión honesta: **los totales NBA no
son un pick bettable validado contra líneas reales.**

## Arreglo (backend, prod `wpiztubmmmzclhlprgpd`)
1. **Líneas reales de ESPN**: tabla `public.reto_lineas_totales` (espn_event_id,
   deporte, linea, actualizado). Edge function `ingestar-lineas-totales` baja el
   scoreboard de ESPN (nba/nhl/mlb) con User-Agent de navegador (ESPN da 403 sin él)
   y hace upsert de `competitions[0].odds[0].overUnder` por evento. Cron
   `lineas-totales-ingestar` (7,27,47 * * * *). ESPN solo expone momios de juegos
   inminentes, así que la línea aparece conforme se acerca el partido.
2. **`v_reto_nba_totales_v1` reconstruida a INFORMATIVA**: usa la línea REAL
   (`reto_lineas_totales`, join por espn_event_id); columnas: `total_esperado`
   (estimado del modelo), `linea` (real de la casa o null), `lado` (etiqueta
   descriptiva: 'EN LÍNEA' | 'MÁS/MENOS anotador que el mercado' | 'SIN LÍNEA'),
   `pick_titulo` informativo ("Modelo espera X pts · línea de casa Y"),
   `pick_prob_pct` = **NULL siempre** (sin confianza inventada), `diferencia_vs_linea`,
   `informativo`=true.
3. **Quitado de picks**: `v_reto_mejores_picks_v1` ya no incluye la rama NBA OU.
   `reto_modelo_validacion_v1`: borrada la fila (nba,OU,65.7) para que el récord no
   anuncie un edge que no es bettable contra líneas reales.
4. **Récord NBA/NHL ganador**: `reto_snapshot_capturar_v1()` ahora SÍ snapshotea los
   picks de ganador NBA (prob≥55) y NHL (prob≥56) — antes no se capturaban, así que
   el récord no los calificaba. (Los totales NBA NO se snapshotean: ya no son pick.)

## Logos de equipos (NBA/NHL/MLB/soccer)
- `public.v_reto_escudos_v1`: por `espn_event_id`, `home_logo`/`away_logo` =
  `https://a.espncdn.com/i/teamlogos/{nba|nhl|mlb|soccer}/500/{espn_id}.png`, solo
  con ids numéricos positivos (los TBD/-1 de playoffs quedan en null). Cobertura
  NBA 68/68, NHL 66/66, soccer 346/346, MLB 6 (World Series). Verificado que cada
  patrón de URL responde 200 image/png.
- Frontend: hook `useEscudos()` + escudo junto a cada nombre de equipo en las cards,
  con **fallback honesto** (iniciales/placeholder) si el logo es null o falla a
  cargar — nunca el logo de otro equipo.

## Frontend (Lovable "Remix of Reto 13M")
- Totales NBA: bloque "Total de puntos (informativo)" con "Modelo espera X" y
  "Línea de casa Y"; sin %; ganador NBA intacto. 1283/1283 tests verdes.
- Logos: pendiente de confirmar verde tras el cambio.

## Nota de honestidad
La línea de ESPN puede diferir 0.5-1 pt del libro del usuario (cada casa fija la
suya); ambas son líneas reales de mercado, no fabricadas. Lo que se muestra es el
estimado del modelo vs una línea real, como información, sin recomendación de apuesta.
