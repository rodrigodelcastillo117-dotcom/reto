# Multideporte — qué acierta, qué falta (2026-10-14)

Ley confirmada con 50k+ juegos en 3 deportes: **el GANADOR/margen se predice; las
LÍNEAS del mercado (spread, total) son eficientes y no se les gana.**

## NFL 🏈 — probado contra la línea REAL de DraftKings
El modelo ya calcula moneyline, spread (`p_home_cover` vs `dk_spread_home`) y total,
y captura los momios DK.
- **Moneyline: EDGE REAL** — récord 64 picks, 67% aciertos, Brier 0.219 < mercado 0.234. ✅
- **Spread (ATS)**: n=46, acierto 52.2% vs break-even 52.4%, corr 0.003 → **sin edge** (línea eficiente).
- **Total**: sin edge (probado, corr 0.07).
→ **Publicado**: `v_reto_nfl_mercados_v1` (solo moneyline + margen esperado, próximos 10 días).
  Spread/total NO se publican.

## MLB ⚾
Modelo en validación forward (marginal). Moneyline honesto cuando pase la muestra (116/120).

## Tenis 🎾 — necesita DATOS
Elo construido pero entrenado con **62 partidos** → acierto ~50% (nivel volado).
El tenis es muy predecible con Elo, pero requiere **ingerir miles de partidos ATP/WTA**
históricos. Proyecto de datos (no hay atajo).

## NBA 🏀 / NHL 🏒 — NO hay data en el sistema
`historico_partidos_espn` solo tiene soccer, baseball y football. CERO juegos NBA/NHL.
Para incluirlos hay que:
1. Extender el cargador ESPN a `basketball/nba` y `hockey/nhl` (endpoints existen).
2. Backfill de temporadas históricas (scores + detalle).
3. Construir modelo de fuerza relativa (NBA/NHL spreads y totales SÍ son más predecibles
   por el alto número de posesiones — a diferencia del soccer).
4. Validar OOS y publicar solo lo que gane.
Es el mayor salto "multideporte", pero es ingeniería de datos, no un toggle.

## Resumen de prioridad
1. ✅ NFL moneyline — listo en backend, falta wire en app + récord. (Edge real.)
2. MLB — cerrar validación.
3. NBA/NHL — ingerir feeds (el gran desbloqueo multideporte).
4. Tenis — ingerir historia ATP/WTA, reactivar Elo.
Nada de spreads/totales/BTTS/córners sin edge probado.
