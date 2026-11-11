# Experimento medido: ¿cuánto aporta el mercado sobre el modelo? (v1)

Supabase prod `wpiztubmmmzclhlprgpd`. 2026-11-11. Dinero OFF. Experimento OFFLINE: no
tocó el cerebro ni producción (tablas temporales creadas y borradas).

## Pregunta
¿Cuánto accuracy deja el mercado sobre la mesa vs un modelo propio? Medido comparando, sobre
juegos ya resueltos con cierre de mercado real (radar_odds_snapshots) + resultado
(historico_partidos_espn): Elo propio (desde resultados) vs cierre de-vigado vs blend simple.

## Resultado

**MLB moneyline (n=302):**
| | Brier | Accuracy |
|---|---|---|
| Elo (K=5, ventaja local +24) | 0.2345 | 61.6% |
| Cierre de mercado | 0.2349 | 59.3% |
| Blend (promedio) | 0.2343 | 60.6% |
→ El mercado NO aporta sobre un Elo simple. El béisbol es demasiado aleatorio (local gana 54%).

**NFL (n=135):**
| | Brier | Accuracy |
|---|---|---|
| Elo (K=20, ventaja local +48) | 0.2249 | 63.0% |
| **Cierre de mercado** | **0.2162** | **68.1%** |
| Blend | 0.2170 | 68.1% |
→ El mercado SÍ aporta fuerte: +5.1pp acc, Brier -0.0087. Incluso supera al cerebro NFL
   (nfl_hybrid_ml_v1, live ~64%). El blend ≈ mercado: en NFL conviene pesar mucho el mercado.

NBA/NHL: casi sin cierre en la DB (5/18 eventos) para medir; por predecibilidad se esperan
más cerca de NFL que de MLB.

## Conclusión honesta
"Cuánto deja el mercado sobre la mesa" DEPENDE del deporte: ~0 en MLB, ~+5pp en NFL. No es
una verdad única. Caveats: muestras chicas (direccional), Elo baseline (no el cerebro).

## Decisión (del dueño, NO ejecutada)
Blendear el mercado en el cerebro cambiaría su filosofía sellada "P_RETO sin odds/EV/Kelly".
La evidencia dice que valdría la pena en NFL (y probablemente NBA/NHL), NO en MLB. Si se hace,
hacerlo por-deporte y con pesos validados, no global.
