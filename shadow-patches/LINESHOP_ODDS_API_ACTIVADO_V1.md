# Line shopping ACTIVADO con The Odds API (multi-casa)

Fecha: 2026-11-08. El dueño autorizó el feed de pago ("si hazlo") y agregó el secreto `ODDS_API_KEY`.

## Qué quedó funcionando
- **Secreto `ODDS_API_KEY`** configurado por el dueño en Supabase (no pasó por el chat).
- **Función `ingestar-odds-multicasa`**: jala moneyline (h2h) de varias casas US desde The Odds API
  para NFL/NBA/NHL. Primera corrida real: 197 filas, **9 casas** (DraftKings, FanDuel, BetMGM,
  BetRivers, Bovada, BetOnline.ag, BetUS, LowVig.ag, MyBookie.ag). Reporta `cuota_restante`.
- **Tabla `reto_odds_multicasa_v1`** (RLS on): upsert por (oddsapi_event_id, bookmaker).
- **Vista `v_reto_lineshop_v1`**: por juego próximo, mejor precio por lado + **qué casa lo paga** +
  n_casas + devig consenso. (Solo datos capturados en las últimas 12 h.)
- **Vista `v_reto_pick_precio_v1`**: empareja nuestros picks NBA/NHL/NFL al ganador con el mejor
  precio disponible (match por nombre de equipo + ventana de 12 h al kickoff). Verificado: los
  nombres machean limpio (p.ej. "Gana San Jose Sharks → 2.15 en BetOnline/Bovada/LowVig").
- **Cron `ingestar-odds-multicasa-am`** (jobid 597, `48 12 * * *` = 6:48am CDMX): refresca momios
  justo antes del email de 7am. 1×/día = ~3 créditos/día (~90/mes), holgado para el tier gratis (500/mes).
- **Email `mejores-picks-diario` v3**: cada pick NBA/NHL/NFL al ganador ahora muestra
  "🏷️ Mejor precio X — Casa". Prueba: send 200, 5 picks con precio. DINERO OFF (es el precio/línea,
  no EV/stake/Kelly).

## Costo / cuota
- Tier gratis The Odds API = 500 requests/mes. Cada corrida = 3 créditos (3 deportes × 1 región × 1 mercado).
- 1×/día → ~90/mes. Para subir a 2-3×/día (momios más frescos) conviene vigilar `cuota_restante` o
  subir de plan. La función la reporta en cada corrida.

## Honesto
Esto es lo que convierte el CLV+ que ya teníamos en ganancia real: entrar al mejor precio disponible.
No se tocó modelo/gate/récord. Fútbol se puede añadir luego (regiones eu/uk, más casas pero más cuota) —
decisión de presupuesto del dueño.
