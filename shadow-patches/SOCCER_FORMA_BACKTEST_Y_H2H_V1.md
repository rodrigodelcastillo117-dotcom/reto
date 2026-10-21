# Fútbol: backtest de forma reciente (rechazado) + Cara a Cara (H2H) real

Fecha: 2026-10-21. Gatillo: el usuario preguntó si mejoraríamos usando la forma en que
vienen los equipos, y notó que la sección "Cara a cara" sale vacía.

## Prueba preregistrada: ¿forma reciente mejora los picks de fútbol? → NO
Backtest walk-forward sobre `historico_partidos_espn` (4 ligas: eng.1, esp.1, ita.1,
mex.1; 4,285 partidos con ≥8 juegos previos por equipo). Mismo modelo Poisson simple,
cambiando SOLO cómo se calcula ataque/defensa:

| Método | Acierto 1X2 | Acierto Ambos Anotan |
|---|---|---|
| Forma PLANA (toda la temporada) | **51.5%** | **55.1%** |
| Forma últimos 10 | 50.2% | 54.5% |
| Forma últimos 5 | 49.0% | 53.0% |

Veredicto: la forma reciente EMPEORA en los dos mercados; entre más corta la ventana,
peor. Mismo patrón que fantasy NFL (recencia = ruido). El modelo canónico ya usa
promedio de temporada: está bien así. NO se cambia.

## Prueba: ¿castigar al "Gana X" de equipos empatadores (caso Chivas)? → NO HACE FALTA
Partidos donde el modelo elige "gana local", partidos por tasa de empate del local:

| Local empatador | n | Prob modelo gana | Real ganó | Real empató |
|---|---|---|---|---|
| Baja (<22%) | 972 | 52.1% | 54.8% | 22.6% |
| Media (22-32%) | 1,650 | 48.3% | 50.2% | 25.5% |
| Alta (>32%) | 601 | 47.0% | 47.4% | 31.1% |

El modelo YA está bien calibrado: a los muy empatadores les da menos prob de ganar
(47%, no 52%) y en la realidad ganan ~47%. Predicho ≈ real en los tres grupos. Un
castigo extra sería redundante. NO se cambia. (Los empatadores sí empatan más, 31% vs
23%; el modelo ya lo refleja.)

## Lo que SÍ se agregó: Cara a Cara (H2H) real
`public.v_reto_soccer_h2h_v1` (CONTEXTO, no publicación): por `espn_event_id` de los
próximos partidos (de v3), enfrentamientos directos históricos desde
`historico_partidos_espn` (cualquier orientación/competencia). Columnas: n,
gana_local/empates/gana_visita (desde la perspectiva del local de ESTE partido),
prom_goles, btts_pct, y `ultimos` (jsonb, últimos 6 con fecha/local/marcador/visita).
Cobertura: 192 partidos próximos con H2H, 164 con 3+ (prom 5.2). Ej. Tigres vs León:
6 enfrentamientos, Tigres 3-2-1, 2.00 goles prom, 50% BTTS.

Frontend: la sección "Cara a cara" lee esta vista; estado honesto "Sin detalle H2H
disponible" cuando no hay fila. "Alineaciones aún no confirmadas" se deja: salen ~1h
antes (honesto). Nada de dinero (OFF).
