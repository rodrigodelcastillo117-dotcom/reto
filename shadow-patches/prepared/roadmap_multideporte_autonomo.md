# Roadmap multideporte — modo autónomo (2026-10-14)

Ley base (probada, 50k+ juegos): **ganador/margen se predice; líneas de mercado
(spread, total) son eficientes.** Foco en moneyline/outcome por deporte. Dinero OFF.

## Estado por deporte

| Deporte | Data | Modelo | Mercados publicables | Estado |
|---|---|---|---|---|
| Soccer | 34,566 | 1X2 + handicap + marcador + BTTS | 4 (validados) | ✅ en app |
| NFL | 2,065 | moneyline **le gana al mercado** | moneyline | ✅ backend `v_reto_nfl_mercados_v1`, wire en curso |
| MLB | 11,701 | Dixon-Coles forward | moneyline (en validación 116/120) | ⏳ acumulando muestra |
| Tenis | 10,701 linescore · 438 Elo · 10,988 snapshots | Elo (infra existe) | moneyline (por validar en volumen) | 🔧 rescatable con data actual |
| NBA | **0** | — | — | ❌ falta ingesta completa |
| NHL | **0** | — | — | ❌ falta ingesta completa |

## Mecanismo de ingesta ESPN (descubierto)
`pedir_historico_rango(desde,hasta)` → itera `ligas_master` (where espn_endpoint like
'soccer/%') → `net.http_get` a `site.web.api.espn.com/.../{endpoint}/scoreboard?dates=…`
→ `_carga_historico` → `absorber_historico_espn()` → `historico_partidos_espn`.
Baseball/football/tenis tienen caminos propios. **Catálogo-driven** pero soccer-locked.

## Plan autónomo (prioridad por impacto × factibilidad, sin romper prod)
1. **NFL** — wire moneyline en app + al récord. (En curso; deploy agendado.) ✅ casi
2. **Tenis** — validar el Elo sobre los 10,701 partidos (derivar ganador del linescore:
   competidor con más sets). Si Brier < 0.25 y acierto >52% OOS → publicar moneyline de tenis.
   Data e infra YA existen; es el 3er deporte más cercano.
3. **MLB** — cerrar validación forward (vigilada), publicar moneyline al pasar el gate.
4. **NBA / NHL** — proyecto de ingesta (el grande):
   a. Añadir `basketball/nba`, `hockey/nhl` al catálogo + generalizar el cargador
      (nueva función, SIN tocar la de soccer).
   b. Backfill **medido** de temporadas (rangos chicos, respetando cadencia — no martillar ESPN).
   c. Verificar que `absorber_historico_espn` parsea esos deportes (mismo shape de scoreboard).
   d. Modelo de fuerza relativa + validación OOS. NBA/NHL deberían predecir BIEN
      (muchas posesiones → fuerza del equipo domina).
   e. Publicar solo lo que gane.

## Reglas que se mantienen
- Dinero/EV/Kelly OFF en todo.
- Validar OOS antes de publicar cualquier mercado/deporte (nada mal hecho).
- No totales/spreads/BTTS/córners sin edge probado.
- Backfills medidos; no hammering de APIs externas; cambios de prod aditivos y reversibles.
