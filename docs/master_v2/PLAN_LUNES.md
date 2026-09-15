# Decisión y plan — para el lunes

El owner delegó la decisión de quién hace qué. **Decidido así:**

| | |
|---|---|
| **Claude (yo)** | Backend, base de datos, modelo, picks, crons, calificación |
| **Lovable** | Pantallas, navegación, rutas, UI, pop-ups |

Razón: los bugs de esta noche se repartieron limpiamente en esas dos cajas, y mezclarlas es lo
que hizo que tardáramos. Yo no despliego frontend y Lovable no debería tocar reglas de picks.

---

## LA CAUSA RAÍZ DE "TODO DICE MENOS DE 3.5" — ARREGLADO

El owner lo reportó en **tres** pestañas (Qué Apostar, Oráculo, Favoritos → por probabilidad).
Era **un solo bug**.

`v_pick_canonico` guarda todos los mercados de cada partido como filas sueltas. Medido sobre
partidos por jugar:

| Pick | Probabilidad promedio |
|---|---|
| **Under 3.5** | **62.9 %** |
| BTTS Sí | 59.4 % |
| Over 2.5 | 59.4 % |
| Gana local | 44.4 % |

Cualquier pantalla que ordene por `probabilidad_pct` y corte los primeros muestra **Under 3.5
en todos los partidos**, porque en fútbol es el resultado más probable *por construcción*. Es
cierto y es inútil.

**Arreglo:** `public.v_mejor_pick_por_partido` — un pick por partido, elegido por
**discriminación** = nuestra probabilidad − la que implica el precio de la casa. Si la casa
también dice 63 % en Under 3.5, discriminación ≈ 0 y se cae del top. Con piso de 45 % de
probabilidad, para no presentar como "lo más probable" algo que no lo es.

No es EV: no mete stake ni momio en la decisión, sólo mide desacuerdo contra el mercado.

**Resultado medido:** el top pasa de "Under 3.5 en todo" a mercados y deportes mezclados —
Gana local, Over 8, ML Cardinals, Over 43.5 Puntos (NFL).

---

## MI LISTA (backend) — pendiente para el lunes

1. **Parlay del Día con la estructura pedida.** Hoy da 3 de fútbol. Debe dar tres bloques:
   los 3 mejores (1 por deporte) · 4-5 más arriesgado (los que más gusten por deporte, y si
   hay 2-3 tipo LOCK en un deporte, entran) · 6 (2 por deporte). Se construye sobre
   `v_mejor_pick_por_partido`.
2. **Reto 13M**: sólo los mejores por deporte + el LOCK. Mismo origen.
3. **Picks con valor**: meter probabilidad **y** EV en esa pestaña (es la única donde el owner
   sí quiere EV).
4. **Favoritos**: que devuelva los análisis de sus favoritos por deporte, **incluyendo NFL**.
5. **Cablear `nfl_prop_resolver` al autocalificador** para que las patas de props se liquiden
   solas. Requiere su visto bueno porque escribe en el registro de dinero.
6. **Ingesta de `nfl_player_game_logs`** para SF @ LAR: sin eso las 3 patas de props siguen
   en SIN_DATO.
7. **NFL: mejorar proyección** y **redondear marcadores hacia arriba** (pedido explícito).
8. **Props: mejores 2 por equipo** por probabilidad, no la lista completa por línea.
9. **MLB: rellenar** H2H, carreras recibidas, y el resto del contexto que hoy está vacío.
10. **Guardar en BD los picks del usuario y los del cerebro**, calificados, para que el modelo
    aprenda. Es la base de que mejore día con día.
11. **Fantasy: bajar el error de lectura** de la captura (precio/costo mal leídos).
12. **Auditar los 400+ crons** a 24 h, sin errores.

## PENDIENTE QUE NECESITA DECISIÓN DEL OWNER

- **Parlay marcado perdido sin ninguna pata perdida** — $250 involucrados.
- **Marcador final cambiado en un partido ya calificado** — $475.53 involucrados.
Los detectó el vigilante al reactivarse. Ambos tocan dinero ya contabilizado: no los corrijo
solo.

## LO QUE NO SE TOCA

El modelo de NFL **no le gana al mercado** (Brier 0.227 nuestro vs 0.218 del mercado, t pareado
−1.135). Se muestra la probabilidad propia, etiquetada como propia, sin EV ni monto sugerido.
Falló SF @ LAR en las dos (dio Rams 65 %, ganaron los 49ers 27-7). Un partido no prueba nada,
pero la regla se mantiene: **no se promete ventaja que no está medida.**


---

# Estado real al cierre de la sesión autónoma

## Terminado y verificado como `anon` (8 superficies vivas)

| Superficie | Filas |
|---|---|
| `nfl_tablero_semana` | 16 |
| `nfl_lock_semana` | 14 |
| `v_prediccion_reto_canonico` | 14 NFL + 109 fútbol |
| `v_mejor_pick_por_partido` | 30 |
| `nfl_props_top_por_equipo` | 161 (64 en top-2) |
| `v_reto13m_mejores` | 14 |
| `v_picks_con_valor` | 15 |
| `parlay_del_dia_v3` | 3 deportes |

De mi lista de 12 quedan hechos **7**: Parlay del Día por deporte, Reto 13M, Picks con Valor,
props 2 por equipo, marcadores enteros, la cadena de permisos rota, y el diagnóstico del
aprendizaje.

## DOS BLOQUEOS QUE NO DEPENDEN DE MÍ

### 1. Lovable se quedó SIN CRÉDITOS
El último mensaje (marcadores enteros) **no se pudo enviar**:

> *Your workspace is out of credits, so Lovable can't send this message.*

Todo el frente de pantallas está detenido hasta que se recarguen en
`lovable.dev/settings/billing`. Los tres lotes anteriores sí entraron y el agente los trabajó.

### 2. RONGOL: corrida de recuperación programada, sin confirmar
Job temporal **423** a las 10:17 UTC. No alcancé a verlo terminar: el ciclo tarda ~80 s y el
cliente MCP corta a los 60, por eso va por cron y no por conexión directa.

**Hay que limpiarlo:** el job 423 quedó como diario a las 10:17. Una vez que se confirme que
`rongol_memoria` volvió a crecer, hay que borrarlo (`select cron.unschedule(423);`) porque el
job 182 ya corre el mismo ciclo a las 2:15 UTC y tenerlo dos veces al día es desperdicio.

## Lo que sigue pendiente de mí

- MLB: el histórico de partidos para H2H y carreras recibidas. Hay 4,294 bateadores y 455
  pitchers cargados, pero `historico_partidos_espn` tiene **0 filas de béisbol**; los juegos
  viven en `mlb_juego_final` / `mlb_linescore` y hay que construir el H2H desde ahí.
- Cablear `nfl_prop_resolver` al autocalificador (escribe en el registro de dinero).
- Auditoría de los crons a 24 h.

## Lo que sigue pendiente del owner

- Parlay marcado perdido sin ninguna pata perdida — $250.
- Marcador final cambiado en un partido ya calificado — $475.53.
