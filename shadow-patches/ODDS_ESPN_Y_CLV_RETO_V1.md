# Odds de ESPN + CLV del sistema reto (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. 2026-10-20. Dinero OFF.

## Corrección honesta

Dije que NBA/NHL no tenían cuotas accesibles. **Estaba equivocado.** Verificado contra
ESPN en vivo:

| Deporte | ¿ESPN tiene odds? | Evidencia |
|---|---|---|
| NBA | **SÍ** | core API, DraftKings, apertura + actual (ML, spread, O/U) |
| NHL | **SÍ** | core API, DraftKings, apertura + **cierre** (ej. O/U 5.5→6.5) |
| MLB/NFL | **SÍ** | mismo endpoint core |
| Tenis | **NO** | endpoint existe pero vacío (probado 60 partidos ATP/WTA, 0 con odds) |

Endpoint: `sports.core.api.espn.com/v2/sports/{liga}/events/{eid}/competitions/{cid}/odds`.
Trae `open`, `close` y `current` con momios decimales. **No se necesita feed pagado** para
NBA/NHL/MLB/NFL. El tenis sí queda sin medición de mercado (ESPN no lo publica).

## Qué se construyó (server-side, pg_net, patrón tenis_ls)

- `reto_odds_espn_v1` — tabla: por (evento, proveedor) guarda ML y total de **apertura,
  cierre y actual**.
- `reto_odds_pedir_scoreboard()` → pide scoreboards de NBA/NHL/MLB/NFL (hoy..+3d, 1 req/día).
- `reto_odds_parse_sb_pedir_odds()` → de cada evento pide su endpoint de odds.
- `reto_odds_parse_odds()` → parsea a la tabla (open se fija una vez, close toma el último).
- Cron **`reto-odds-espn`** cada 20 min: parsea ciclo previo, pide odds, pide scoreboards.
- `v_reto_clv_espn_v1` — CLV del sistema reto para GANADOR de NBA/NHL/MLB/NFL:
  `clv_pp` = cuánto subió la prob implícita de-vigada del lado elegido, de apertura a cierre.
  Positivo sostenido = el modelo le gana al cierre.

## Estado al cierre de esta sesión (honesto)

- Ciclo manual corrido: **30 eventos con odds** (NBA 18, NHL 11, NFL 1), apertura capturada,
  **movimiento de línea real detectado** (16/18 NBA, 8/11 NHL open→actual).
- `v_reto_clv_espn_v1` hoy devuelve **0 filas con CLV**: todos los picks son de juegos
  **futuros** (20–28 oct); el `close` se llena cerca del saque. El CLV empieza a poblarse
  **hoy** conforme cierran los partidos y crece con el cron.
- Tenis: sigue sin CLV (ESPN no da odds). El tenis O/U publicado queda validado solo vs
  mediana, con su edge de mercado **desconocido** por falta de datos — y así etiquetado.

## Lo que esto desbloquea

Por primera vez el **producto estrella** (no el sistema `oraculo` paralelo) tiene un circuito
honesto de feedback de mercado para sus 4 deportes grandes. En unas semanas
`v_reto_clv_espn_v1` dirá, con número, si NBA/NHL/MLB/NFL le ganan al cierre. Esa es la
prueba que separa "acierta a una mediana" de "le gana al mercado".

## Pendiente (no hecho)

- Guardar el **momio de entrada** real en `reto_pick_snapshot_v1` al capturar el pick, para
  CLV realizado exacto (hoy el proxy usa apertura ESPN como entrada).
- Un backfill de odds de juegos ya jugados no aplica: los picks reto NBA/NHL son todos
  recientes/futuros; no hay picks pasados resueltos que medir.
