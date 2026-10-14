# Soccer: rescate de BTTS / Over-Under — qué funcionó y qué no (2026-10-14)

Petición: hacer que BTTS y O/U funcionen usando toda la historia. Hice el trabajo
completo con algoritmo real y validación out-of-sample (train/holdout temporal).

## 1. Recalibración lineal (a + b·p) validada OOS
Split temporal 60/40 por kickoff; se ajusta en train, se mide en holdout (datos que
el ajuste nunca vio).

- **BTTS** (holdout n=126): Brier crudo 0.2388 → calibrado **0.2377** vs base 0.2392.
  Le gana a la base por un pelo. Coef final (toda la data): a=0.2222, b=0.6784.
- **Over/Under por línea** (holdout n=119): crudo 0.2545 → calibrado 0.2523 vs
  base **0.2495** · mercado 0.2419. **Sigue sin ganarle a la base.**

## 2. Modelo de goles NUEVO desde cero (ataque/defensa por equipo, por liga)
Ratings de ataque/defensa por equipo sobre historia soccer (`espn_endpoint like 'soccer/%'`),
baselines por liga, Poisson para el total. Entrenado en juegos viejos, probado en
**10,904 partidos** nuevos.

- **Over/Under 2.5**: modelo nuevo Brier **0.2528** vs base **0.2476**. Mejor que el
  modelo viejo (0.2593) pero **todavía no le gana a la base**, con 10 mil juegos.

## Conclusión honesta
El total de goles en soccer (O/U, BTTS) es **casi aleatorio alrededor de la tasa base**.
Ni el modelo actual, ni una recalibración, ni un modelo de ataque/defensa desde cero
le ganan a "predecir la base" de forma significativa fuera de muestra. Es una
propiedad del deporte (alta varianza), no falta de datos. Lo predecible es lo ligado
a la fuerza del equipo: ganador (1X2), **hándicap** y **marcador**.

## Qué se publicó (honesto)
`v_reto_soccer_mercados_v1` (upcoming, 10 días):
- `p_home_handicap_menos15`, `p_away_handicap_menos15` — ✅ le gana a la base (significativo).
- `marcador_probable`, `marcador_prob_pct` — ✅ calibrado (dice 11.4%, pega 10%).
- `p_btts_calibrado` — BTTS con recalibración a=0.2222 b=0.6784. Calibrado, **edge mínimo**:
  se muestra como probabilidad del modelo (info), NO como pick de valor.

## NO publicado
- **Over/Under**: ni el modelo nuevo le gana a la base → no se publica (sería engañoso).
  Ruta si se quiere insistir: Dixon-Coles con corrección de marcadores bajos, ataque/
  defensa separado local/visita, y ponderación por recencia. Expectativa honesta: el
  techo es bajo; probablemente llegue cerca de la base, no por encima del mercado.
