# Motor de Probabilidad Real v2 (unificado) + Tracker de CLV

Fecha: 2026-11-03. Extensión del motor a todos los mercados con momio en vivo + el
marcador honesto (CLV). Aditivo, dinero OFF, no toca modelos/gates.

## Fuentes de momio encontradas (reales)
- `reto_odds_espn_v1`: moneyline (abre/cierra/actual) + totales, por deporte. NBA 142 /
  NHL 145 / NFL 41 con ML en vivo; con cierre: 40/45/22. Tenis NO está (sin momio → no
  entra; honesto).
- `radar_odds_snapshots`: 1X2 + BTTS (sí/no) + abre/cierra (para BTTS/soccer, pendiente).
- `v_futpro_publication_v3`: 1X2 de soccer (ya usado en v1).

## `v_reto_prob_real_v2` (unificado, una fila por resultado)
Mezcla de-vig(momio) + modelo al peso aprendido por segmento, para:
- Soccer 1X2 (v3, w=0), NBA ML (w=0), NHL ML (w=0), NFL ML (w=0.395 del récord football).
Columnas: deporte, mercado, partido, resultado, prob_mercado_pct, prob_modelo_pct,
w_segmento, prob_real_pct, ventaja_pp. Cobertura hoy: soccer 116 juegos, NHL 11, NBA/NFL 1
(los demás llegan conforme ESPN postee momio de mañana — timing, no bug: 53 NBA próximos,
solo 1 con momio aún). 0 filas con valor (honesto: donde w=0 la prob real = mercado).

## `v_reto_clv_motor_v1` (tracker de CLV)
Sobre nuestros picks de ganador ya registrados (`reto_pick_snapshot_v1`) × apertura/cierre
de `reto_odds_espn_v1`: prob de entrada vs prob de cierre (de-vig), CLV en puntos, y si le
ganó al cierre. Resultado medido:
- NFL: n=22, CLV +3.45pp, 72.7% le gana al cierre.
- NBA: n=39, CLV +2.94pp, 59.0%.
- NHL: n=31, CLV +2.78pp, 51.6%.
CLV **positivo** en los tres (muestras chicas = señal, no prueba). Es el marcador honesto:
le ganamos al cierre > ganar la apuesta.

## Pendiente (mismo patrón, para "de verdad todo")
- **Captura forward universal** para que los pesos de NBA/NHL/BTTS se APRENDAN (hoy en 0
  por falta de récord modelo-vs-mercado). Aislada, sin tocar evidencia_capturar.
- **BTTS** (de radar_odds_snapshots) al motor.
- Tenis: sin momio en la fuente → queda fuera hasta conseguir momio.
- Render en Lovable del motor + CLV.
Grants SELECT a anon/authenticated. Dinero OFF hasta que un segmento pruebe CLV+ con n grande.
