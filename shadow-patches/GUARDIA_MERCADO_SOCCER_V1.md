# Guardia de sensatez de mercado para picks de futbol (ganador)

Fecha: 2026-10-20. Gatillo: el usuario detectó que el modelo ponía a **Stuttgart
favorito sobre Atlético Madrid** (Champions). Dinero/EV/Kelly siguen OFF — los
momios se usan SOLO como control de calidad para no publicar picks que el mercado
contradice.

## Diagnóstico (con datos)
- Modelo vs mercado en 106 partidos próximos con momios: sesgo local promedio
  **+0.3 pts** → NO hay sesgo local sistemático (la recalibración previa de
  home_adv sostuvo). El problema no es la localía.
- Causa real: el motor es de **goles** (Poisson). Subvalora equipos elite de pocos
  goles (Atlético de Simeone) y puede sobrevalorar locales anotadores. Confunde
  "anota mucho" con "es mejor".
- Caso Stuttgart–Atlético (DraftKings, normalizado): mercado Atlético ~41% vs
  Stuttgart ~34%; el modelo lo tenía al revés (Stuttgart 47.9 vs Atlético 30.3).
- Roma–Slovan Bratislava: el modelo da **NULL** (Slovan, liga eslovaca, no está en
  las ligas cubiertas por el modelo cruzado). Es abstención honesta, no bug.

## Validación de la guardia (igual que futbol, OOS)
Picks históricos de ganador de soccer con momios (join a resultados):
- Donde el modelo **contradice** al mercado (favorito del modelo = perdedor claro
  del mercado, brecha >8 pts): **29.2%** de acierto (n=89).
- Resto: **55.7%** (n=566).
→ Contradecir fuerte al mercado es señal validada de pick malo. Suprimirlos mejora.

## Implementación (sin tocar el cerebro canónico)
- `public.v_reto_soccer_market_check_v1` (nueva): por `espn_event_id`, `mercado_difiere`
  = el favorito del modelo (p_home/p_away/p_draw argmax local|visita) es el perdedor
  claro del mercado (implícita normalizada del rival > la del pick +8). Lee momios de
  `v2.soccer_prediction_v2` (última fila por evento).
- `public.v_reto_soccer_pick_v1` (vista de servicio, antes passthrough del cache):
  LEFT JOIN al chequeo; cuando `mercado_difiere`, **anula `ganador_pick`/`ganador_pct`**
  y el `mejor_pick_*` si es tipo ML/DOBLE_OPORTUNIDAD. Expone columna `mercado_difiere`.
  Las barras 1X2 (local/empate/visita) quedan visibles (salida honesta del modelo),
  pero la app ya no afirma un favorito falso. 16 juegos próximos marcados.
- `public.v_reto_mejores_picks_v1`: la rama soccer excluye picks ML/DOBLE_OPORTUNIDAD
  cuyo evento tenga `mercado_difiere`.
- Efecto en autograde: el snapshot lee `ganador_pick` (ahora NULL en contradichos),
  así que no se registran esos picks malos.

## Frontend (Lovable)
- `fetchMercadoCheck()` + `useMercadoCheck()` (Set de espn_event_id contradichos).
- Match card de FutPro: cuando el evento está en el set, no muestra "leve favorito /
  Gana X"; muestra "⚠️ Sin pick confiable — el mercado no coincide" y oculta el mejor
  pick. Barras 1X2 siguen visibles.

## Pendiente / límite honesto
- La guardia solo aplica a partidos con momios capturados (~la mitad del slate).
  Sin momios, no hay referencia; se deja el pick del modelo tal cual.
- Arreglo profundo (no hecho): reentrenar el motor de goles con un prior de calidad
  de equipo (resultados/puntos, no solo goles) para no subvalorar defensivos elite.
  Requiere validación OOS como futbol. Queda como mejora futura.
