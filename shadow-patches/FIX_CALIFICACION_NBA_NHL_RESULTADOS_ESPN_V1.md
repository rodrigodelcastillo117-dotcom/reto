# FIX crítico: calificación de NBA/NHL (archivo estable de resultados ESPN)

Fecha: 2026-11-03. Bug encontrado: picks de NBA (0/95) y NHL (0/67) NUNCA se
calificaban (NFL sí, 42/42). Sin calificar → sin récord, sin acierto histórico, y el
Motor nunca aprende el peso de esos deportes.

## Causa raíz (medida)
- El calificador `v_reto_pick_grade_v1` lee resultados de `historico_partidos_espn`.
- Para NBA, historico **se quedó congelado en 2026-10-17** (21 juegos); los finales
  recientes no se absorben ahí. 0 de 95 IDs de picks NBA aparecen en historico.
- Los marcadores sí existen en `live_scores` pero esa tabla se **purga** (solo 31/95
  NBA, 17/67 NHL seguían ahí).

## Arreglo (fuente de verdad = ESPN, archivo permanente)
1. **`public.reto_resultados_v1`** (tabla, RLS on): archivo permanente de finales por
   `espn_event_id` (deporte, home/away score, fecha). No se purga.
2. **Edge function `ingestar-resultados-espn`**: baja el scoreboard de ESPN
   (basketball/nba, hockey/nhl, football/nfl, baseball/mlb) para una ventana de días,
   extrae finales (status completed + scores por homeAway) y upsert. Backfill corrido
   (days_back=30): NBA 173, NHL 201, NFL 72, MLB 27 finales.
3. **Cron `reto-resultados-ingestar`** (`23 * * * *`, days_back=3): mantiene el archivo
   al día.
4. **`v_reto_pick_grade_v1`**: la rama NBA/NHL/NFL/MLB ahora lee de `reto_resultados_v1`
   (soccer/tenis se quedan en su fuente, que ya funcionaba).

## Resultado (verificado)
- Califican ahora: NBA 95 (58.9% acierto ML), NHL 67 (56.7%), NFL 42 (54.8%).
- `v_reto_mejores_picks_v1` ya muestra acierto histórico real de NBA/NHL por tramo, con
  la guarda de muestra chica (NHL ALTA n=6 → null honesto).
- **Pesos del Motor aprenden** NBA/NHL desde la historia real (snapshot × momio de cierre
  de-vig × resultado): NBA w=0 (Brier modelo 0.259 vs mercado 0.225 → el cierre le gana),
  NHL w=0 (0.261 vs 0.227). Honesto: en NBA/NHL ML tampoco le ganamos al cierre todavía,
  aunque el CLV sea positivo (el cierre es más preciso que el modelo). Solo NFL w=0.395.
- `v_reto_prob_real_v2` ahora lee los pesos por deporte dinámicamente (se actualizan solos
  conforme llega más historia).

Dinero OFF; sin cambios de modelo/gate. Desbloquea el récord y el aprendizaje de NBA/NHL.
