# Tracker de CLV multi-casa (¿le ganamos al mejor precio de cierre?)

Fecha: 2026-11-09. Gatillo: "¿ganamos dinero de verdad?" — la prueba +EV definitiva.

## Qué mide
Si al entrar al precio de nuestra hora (mañana, cuando sale el email) le ganamos al **mejor precio de
cierre** del mercado multi-casa. CLV positivo vs el MEJOR del mercado = prueba sharp de rentabilidad.

## Construido (todo gratis — lee datos ya ingeridos, no gasta cuota API)
- **Tabla `reto_clv_snapshots_v1`** (append-only, RLS on): por evento próximo guarda el mejor precio
  por lado + la prob de-vig (local/empate/visita) + n_casas + `captured_at`.
- **Función `reto_clv_snapshot_capturar_v1()`**: inserta un snapshot del mejor precio de-vig de cada
  evento próximo desde `reto_odds_multicasa_v1`. Primera corrida: 89 snapshots.
- **Cron `reto-clv-snapshot-diario`** (jobid 603, 13:10 UTC = 7:10am CDMX, tras la ingesta matutina).
- **Vista `v_reto_clv_multicasa_v1`**: por evento, primer snapshot (entrada) vs último (cierre),
  con `mov_home_pp`/`mov_away_pp` = cuánto se movió la prob de-vig. Si recomendamos un lado a la
  entrada y el mercado se mueve hacia él (prob sube / momio baja), eso es **+CLV**.

## Limitación honesta (por la decisión de cuota mínima)
Los momios se refrescan ~1×/día (mañana), así que:
- Juegos a **varios días**: tenemos precio día a día → señal de movimiento entrada→cierre real.
- Juegos del **mismo día**: solo 1 snapshot → sin señal (no hay "cierre" distinto a la entrada).
- "Cierre" = último snapshot matutino, no literal pre-partido (eso exigiría un fetch extra = cuota).

Por eso la lectura de CLV es confiable para juegos que vemos con días de anticipación, y débil para
los del mismo día. En ~2-3 semanas habrá suficientes juegos multi-snapshot para un veredicto honesto.

## Siguiente (cuando haya datos)
Vista resumen que cruce el movimiento con nuestros picks graficados y con el resultado real, para
decir sin fe: "siguiendo el email, el CLV promedio es +X pp" — la prueba de si de verdad ganamos.
