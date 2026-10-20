# Fútbol: reconciliación a una sola fuente canónica + mercado O/U retirado

Fecha: 2026-10-20. Gatillo: el usuario pidió picks de Liga MX de hoy; se dieron picks
de "Más de 2.5 goles" que NO aparecían en la app. Causa: se leyó la fuente vieja en vez
de la canónica. Al investigar salió un bug real de consistencia.

## Lo que se encontró (medido)
- La app publica fútbol desde `v_futpro_publication_v3` (canónico, `selector_authoritative`,
  `canonical_pick_status`). Pero `v_reto_mejores_picks_v1` ("Lo más probable hoy") leía la
  fuente VIEJA `reto_soccer_pick_cache` → **dos fuentes distintas para el mismo partido**.
- El scorecard de evidencia por mercado (`v_evidencia_mercado_soccer`, evaluado hoy 21:16):
  - **ganador (1X2)**: soccer_canonical_v2, 499 partidos, 52.1%, IC95 bajo cero →
    MEJOR_QUE_ADIVINAR_CONCLUYENTE. **Validado, publica.**
  - **btts (ambos anotan)**: 58.9%, IC95 bajo cero → **Validado, publica.**
  - **total (Over/Under goles)**: **RETIRADO el 17-sep**. Se probaron p_over calibrado y
    lambda+Poisson sobre 152 partidos; ambos CONCLUYENTEMENTE peores que adivinar (Brier
    0.544/0.542 vs 0.50, IC95 entero sobre cero). Regla de la casa: nada publicado puede
    ser peor que adivinar → retirado.
- O sea el "Más de 2.5 goles" que se mostró venía de la caché vieja de un mercado retirado.
  Por eso no sale en la app (correcto) y por eso NO se debe resucitar.

## Arreglo (backend)
1. `v_reto_mejores_picks_v1`: la rama de fútbol ahora lee `v_futpro_publication_v3`
   (`mejor_pick`/`mejor_pick_prob`, `canonical_pick_status='READY'`, `kickoff>now`,
   prob≥55). Elimina el O/U retirado y UNIFICA la fuente con la tarjeta de FutPro.
2. `reto_snapshot_capturar_v1()`: quitada la rama `soccer OU25` (mercado retirado) para no
   calificarlo en el récord. Borrados 212 snapshots futuros `soccer/OU25`. Se conserva ML y
   BTTS de fútbol.

## Frontend (Lovable)
- Tarjeta de fútbol: muestra los 2 mercados validados (Ganador + Ambos anotan) con su %,
  destaca el de MAYOR probabilidad (= `mejor_pick` de v3). Nunca muestra Over/Under de goles.
  Todo desde v3.

## Nota honesta al usuario
No hay "3 picks" en fútbol: hay 2 validados. El 3º (goles O/U) se retiró a propósito por
perder contra un volado. La app ahora habla con una sola voz (v3) en todas sus superficies.
