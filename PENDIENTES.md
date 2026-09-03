# RETO 13M — Pendientes

**Corte: 3 de septiembre de 2026.** Todo lo que quedó abierto, con el detalle necesario para
retomarlo sin volver a investigar. Las tareas cerradas ese día no aparecen aquí.

---

## LA REGLA QUE RIGE TODO

> **El LLM escribe lo cualitativo. Todo número que multiplique dinero se calcula en vivo desde
> SQL al momento de leer.**

Nació de encontrar siete puntos de pantalla donde un modelo de lenguaje inventaba fracciones de
Kelly, con errores de hasta 12×. El patrón correcto ya existía en el código (`ev_estimado` sí se
sobrescribe desde el motor); Kelly era el único campo de dinero sin dueño en TypeScript.

**Corolario:** un Kelly calculado NO se guarda dentro del análisis. El análisis se congela al
generarse y los momios se mueven; un Kelly guardado a las 00:45 estará desfasado a las 19:00.
El dimensionamiento vive solo en los RPC que recalculan al leer: `mejor_oportunidad_hoy`,
`construir_parlay_v2`, `pick_del_dia`.

---

## PRIMERO MAÑANA

### #172 — Cerrar el frente de penales y de partidos congelados
El 3-sep un parlay de $200 estuvo dos días sin calificar. Eran **tres** fallas encadenadas;
la primera ya quedó arreglada, las otras dos se repiten en el próximo partido de copa.

**Los tres puntos, en orden:**

1. **Persistencia de penales.** Capturar el `shootoutScore` de ESPN y guardarlo en
   `live_scores.score_detail_json`. **El formato ya está estrenado con datos reales**
   (evento `401914296`):
   ```json
   {"definido_en":"penales","penales":{"home":4,"away":5},
    "ganador_penales":"away","equipo_que_avanza":"CF Monterrey",
    "marcador_reglamentario":{"home":2,"away":2},"fuente":"..."}
   ```
   Con ese dato, la rama de empate de `evaluar_leg_parlay_v1` deja de devolver
   `no_evaluable` y califica sola.

2. **Cierre de partidos abandonados.** Job que fuerce el cierre de partidos congelados
   más de 30 min en `period=5` o con `SIN SEÑAL`. América-Monterrey se quedó en
   `status='live'` desde las 06:12 UTC y hubo que cerrarlo a mano.

3. **Alerta de falla silenciosa.** Avisar cuando una pata siga `no_evaluable` más de 2h
   después de terminado el partido. **Y también cuando un parlay quede en
   `confianza_calificacion = 'BLOQUEADO_PREMATURO'`** — ese estado significa que el sistema
   quiso cerrar y no pudo, hoy no avisa a nadie, y es justo el que dejó el de $200 colgado.
   Antes de construirla: **contar cuántos parlays viejos están en ese estado ahora mismo.**

---

## CERRADO EL 3-SEP (no rehacer)

- **#171** — `analizar-partido` v486 y `construir-parlay-ai` v255. Los prompts ya no emiten
  tamaño de apuesta. md5 verificado, `verify_jwt` intacto en `false`.
- **#178** — `p_apuesta: null` en `evaluar_parlay`: la simulación de ruina ya no corre sobre
  un monto inventado por un LLM. Alcance histórico: 3 de 127 parlays.
- **#177** — `calibracion_curva` neutralizada: cron 237 `active=false` y la RPC devuelve cero
  filas conservando sus 7 columnas. **No borrar la tabla ni la función todavía**: hay
  navegadores con el bundle viejo que la siguen llamando. Borrar cuando `edge_logs` lleve
  días en cero. La instrucción vive en el `COMMENT ON FUNCTION`.
- **#172 punto 1** — mercado "Se clasifica" agregado a `evaluar_leg_parlay_v1`. Ninguna de las
  22 funciones de calificación lo conocía. 9 pruebas verdes, 5 de regresión.
- **Purga #179** — las 18 auto-lecciones con mandatos de Kelly borradas. Quedan las 60
  escritas a mano, y ninguna de esas menciona Kelly.
- **`bitacora_aprendizaje`** — tabla creada con RLS forzada, `anon`/`authenticated` sin acceso,
  y `registrar_aprendizaje()` como puerta única de escritura.

---

## DINERO — lo que puede costar pesos

### #169 — Calibración sobre picks publicados: PRIMERO descartar el confundidor
Sobre 2,377 picks de ligas activas el modelo pierde contra una constante:
Brier crudo 0.2549, con `calibrar_prob_motor` 0.2548, tasa base 0.2487. Y 726 de 2,377 (31%)
caen fuera del rango medido.

Las bandas se deforman al subir:

| Dice | Pasa | n | Desvío |
|---|---|---|---|
| 36.3% | 45.8% | 356 | +9.5pp |
| 45.2% | 44.9% | 644 | −0.3pp |
| 55.2% | 49.4% | 972 | −5.8pp |
| 63.5% | 48.5% | 165 | −15.0pp |
| 74.3% | 54.0% | 50 | −20.3pp |
| 84.4% | 58.3% | 24 | −26.1pp |
| 94.6% | 41.2% | 17 | −53.4pp |

**Dos hipótesis predicen la misma tabla. No dar ninguna por buena sin medir:**
- **A) Maldición del ganador.** `calibracion_coef` se ajustó sobre 148,764 selecciones de TODOS
  los partidos; los publicados pasaron un filtro de +EV, o sea justo donde el modelo sobreestima.
  *Prueba falsable:* el sesgo debe CRECER con el EV declarado.
- **B) Motor viejo.** 2,797 de 2,871 filas traen `espn_event_id` que no cruza con nada (IDs de
  API-Football, residuo del bug #66), y la muestra va de abril a septiembre, antes de Dixon-Coles,
  del xG estimado y de la recalibración de #139. *Prueba falsable:* el sesgo debe caer al cortar
  por fecha de cada cambio de motor.

**Paso 1 obligatorio:** correr las dos pruebas. Sesgo por decil de `ev_estimado`, y sesgo por mes
cruzado con las fechas de cambio de motor, **separando MLB del resto** (88% de la muestra es MLB).
**Paso 2, solo si A sobrevive:** ajuste isotónico sobre picks publicados y extender el rango
arriba de 70%. **Si gana B:** no se recalibra nada, se purga o marca la muestra vieja.

### #147 — El EV se calcula con precios de DraftKings pero se apuesta en PlayDoIt
Falta acumular ~30 pares DraftKings/PlayDoIt para sustituir el umbral de 2.0% de EV en Moneyline,
que hoy está puesto por criterio y no por medición.

### #156 residual / #159 — Cartelera de MLB
`v_radar_mlb` tiene tres filtros que hay que revisar. La prohibición de totales ya quedó aplicada
en `filtro_pick`, pero la causa raíz de la cartelera sigue abierta.

### #157 — `radar_odds_snapshots` mezcla precios de antes y de DURANTE el partido
Afecta cualquier medición de CLV y cualquier backtest que use esa tabla. **Al usarla siempre
filtrar `snapshot_at < fecha del partido`.**

### #158 — El chip GANA de MLB enseñaba la probabilidad previa con el partido en vivo

### #140 — La tarjeta enseñaba la probabilidad de la CASA con la etiqueta "justa"

### #123 — Bono: dos convenciones distintas y un parlay de $1,194 por confirmar

---

## CALIFICACIÓN Y DATOS SUCIOS

### #172 — Copa y penales: qué se arregló y qué falta
**Diagnóstico completo del 3-sep. Eran tres fallas, no una.**

**FALLA 1 — ARREGLADA.** El mercado "Se clasifica" **no existía** en el evaluador.
Reproducido antes del parche:
```
evaluar_leg_parlay_v1('Deportivo Toluca Se clasifica', ..., 2,0, 'final','FT') -> no_evaluable
evaluar_leg_parlay_v1('Toluca',                        ..., 2,0, 'final','FT') -> ganado
```
El evaluador servía bien; simplemente no conocía ese mercado. Devolvía `no_evaluable` y la
pata se quedaba `pendiente` **para siempre, en silencio**. Toluca 2-0 León estaba FINAL desde
las 03:11 y seguía sin calificar. Ninguna de las 22 funciones de calificación contenía
`clasific`. Parche aplicado con DO-block y guarda de ocurrencias, resolviendo el equipo con
`match_team()`.

**FALLA 2 — ABIERTA.** La tanda de penales no vive en ningún lado: `live_scores` no tiene
columna y `score_detail_json` estaba en null. Por eso el parche devuelve `no_evaluable`
**a propósito** cuando hay empate: sin el dato NO se inventa un ganador.

**FALLA 3 — ABIERTA.** `protect_parlays_premature_grading` revierte el cierre a `pendiente`
con `BLOQUEADO_PREMATURO` si la pata perdedora tiene el partido sin confirmar como final.
**Eso está bien** — es la guarda contra calificación prematura. El problema es que el partido
se quedó `live` porque el sync perdió la señal, y que ese bloqueo **no avisa a nadie**.

Aplica a Leagues Cup, Copa MX, eliminatorias de Champions y Mundial.

### #173 — El bloque `probabilidades` puede traer local y visitante invertidos
En `401914297` (Toluca vs León) el análisis guardó `home_win=29.6` y `away_win=41.0` con
`agenda_espn` diciendo home=Toluca. **Es al revés:** el EV guardado lo prueba —
`0.296 × 3.85 − 1 = +13.96%`, que es el `+14.1%` registrado. El pick usó 29.6% para León, así que
Toluca tenía 41.0% y era el favorito.

El bloque viene marcado `"_odds_provider": "inferred_from_picks"`: se reconstruyó hacia atrás desde
los picks y ahí se cruzaron los lados.

**Segundo defecto en el mismo análisis:** `goles_esperados` es `{local 1.1, visitante 1.1}`,
simétrico. Con lambdas simétricas el 1X2 tendría que salir simétrico, no 29.6/29.4/41.0. **El 1X2
no salió de esas lambdas.** Cualquier BTTS u Over derivado de ellas no es confiable.

**No se pudo determinar si es sistemático:** solo n=4 cruces útiles (2 bien, 2 invertidos), y de 49
análisis con momio, 15 (31%) discrepan del mercado sobre quién es favorito — alto pero no prueba.
En los 8 análisis de MLB del 2-sep las etiquetas SÍ cuadran (7 de 8 coinciden con el mercado).

**Regla:** cuando un bloque diga `inferred_from_`, no creerle sin cruzarlo contra la aritmética del EV.

### #113 — Marcadores cruzados: tenis congelado en 2-0 y MLB al revés en pantalla

### #120 — Tenis: 112 de 163 partidos de ATP con marcador imposible

### #36 — Verificar el arreglo de caché de análisis y decidir la UI de Batallas

### Partidos mudos en la cola
`procesar-cola-analisis` v4 arregló que la cola mentía (marcaba `completado` en respuestas
`skipped`, dejando mudos a Kobenhavn, Besiktas, Al Hilal y HEBC Hamburg). Ahora existen los
estados `omitido` y `sin_analisis`. **Falta revisar cuántos quedan ahí: son partidos sin análisis
que nadie reintenta.**

---

## MODELO

### #174 — MLB: Poisson sobredisperso 2.36× (mercado vetado). Fútbol limpio: razón 1.025

**Béisbol — el modelo está bien, Poisson es el que falla.** Sobre 1,056 juegos (`bt_mlb_mu`):
- λ total 9.154 vs carreras reales 9.001. Sesgo −0.154: insesgado.
- Curva por quintil monótona: 8.31→8.02, 8.72→8.56, 9.04→9.02, 9.42→9.12, 10.29→10.28.
- **Pero varianza real 21.21 contra media 9.001 → razón 2.36.** Poisson exige 1.0.
  Desviación real 4.61 vs 3.00 que asume Poisson. Las carreras llegan en racimos.

Error de Poisson por línea (n=1,056 cada una):

| Línea | Poisson dice Under | Real | Error |
|---|---|---|---|
| 7.5 | 31.4% | 44.3% | +13.0pp |
| 8.5 | 44.1% | 52.5% | +8.4pp |
| 9.5 | 56.9% | 60.3% | +3.5pp |
| 10.5 | 68.6% | 67.0% | −1.6pp |

Tabla de corrección por (línea − λ), monótona: **+12.8 / +11.2 / +6.3 / +1.5 / −3.6 / −6.2 pp**.

**Validada fuera de muestra** (ajuste mayo-julio, prueba agosto): Brier 0.23204 → 0.22456.
Poisson decía Under 50.8%, corregido 55.0%, real 56.4%.

**Prueba de dinero** (153 juegos con momio pre-partido): Poisson crudo 121 picks ROI −6.74%;
con corrección 127 picks ROI **−3.49%**. **Sigue negativo**, y con n=127 el error estándar del ROI
es ±8.9pp: −3.49% no se distingue de 0% ni de −6.74%.

> **EL VETO DE TOTALES DE MLB SE QUEDA.** Calibrar mejor no es ganar. La corrección arregla la
> honestidad de la probabilidad, no la rentabilidad contra el vig.

**Fútbol — limpio, no tocar nada.** 22,617 partidos: media 2.931 goles, varianza 3.003,
**razón 1.025**. Desviación real 1.733 vs 1.712 de Poisson. Correlación local-visita −0.114
(lo que corrige el `tau` de Dixon-Coles). Over 2.5 real 56.3%, BTTS real 54.6%.
**Over 2.5 y BTTS operan sobre un supuesto válido.**

Si algún día se retoma MLB: binomial negativa con el parámetro de dispersión medido, no la tabla
de tramos (6 cubetas arbitrarias sobre renglones no independientes — cada juego entra 6 veces).

### #125 residual — NBA Over/Under sigue pendiente

### #133 — Llevar clima, sabermetría y contexto a NFL, fútbol y NBA

### #145 — Fútbol: rotación medida (es ruido) y carga de stats por jugador desde ESPN

### #135 — MLB: usar la alineación real en vez del promedio del equipo

### KellyCriterion: probabilidad por verificar
`KellyCriterion.tsx` usa `calculateKelly` con **momio real tecleado por el usuario** (eso está
bien), pero la probabilidad viene de `aiCalificacion.prob_estimada` y **no se ha confirmado si
está calibrada**. Mismo patrón que #164: fórmula correcta, entrada sin verificar.

### `calibracion_curva` — CERRADA el 3-sep
Cron 237 apagado y RPC vaciada. Ver "CERRADO EL 3-SEP" arriba. Queda pendiente **borrar** la
tabla y la función cuando las llamadas desde navegadores viejos lleguen a cero.

---

## EL ENJAMBRE DE APRENDIZAJE

Hallazgo del 3-sep: **el bucle nocturno ya existía, con 14 crons corriendo sin coordinarse.**
No hacía falta darle cerebro al sistema; hacía falta que los que ya tiene dejaran rastro.

**El dato transversal: NINGUNO de los 14 calcula Brier.** Ajustan números sin medir jamás si
la predicción mejora o empeora. Y solo uno tiene candado de origen.

### #175 — Consolidar los 14 crons y conectarlos a la bitácora
| Cron | Cadencia | Escribe en | Piso n | Candado | Brier |
|---|---|---|---|---|---|
| 305 `recalibrar-motor` | lun | `calibracion_coef` | 300 | **sí** | no |
| 126 `recalibrar-isotonica` | dom | `calibracion_isotonica` | 15 | no | no |
| 237 `recalcular-calibracion-curva` | — | — | — | — | **APAGADO** |
| 145 `recalibrate-model-weights` | lun | `model_weights` | **5** | no | no |
| 108 `recalibrar-ev-bayes` | diario | `ev_calibration_bayes` | — | no | no |
| 101 `calibrar-ai-sql-12h` | 2×/día | `ai_calibracion_liga` | — | no | no |
| 54 / 57 | c/6h | `ai_lecciones` | — | no | no |
| 238 `aprendizaje-segmentos` | diario | `aprendizaje_segmentos` | shrinkage | no | no |
| 109 / 78 | diario | `lecciones_aprendidas`, `ai_memory` | — | no | no |
| 24 `reflexion-ai` | diario | `ai_memory` (LLM libre) | **3** | no | no |
| 323 `autopsiar-picks` | c/3h | `ai_autopsias` | — | limpia | — |
| 324 `lecciones-desde-autopsias` | diario | `ai_lecciones` | **30** ✓ | no | no |

**El orden: primero que todos escriban en `bitacora_aprendizaje`, dejar correr una semana, y
recién entonces decidir cuál se apaga.** La tabla y `registrar_aprendizaje()` ya existen.

### #176 — La isotónica tiene el techo aplastado
**Corrección de mi primer diagnóstico:** NO es circular. `recalibrar_isotonica` ajusta ai_pro
contra ai_pro y se lo aplica a ai_pro, que es metodológicamente correcto. El problema es otro,
y es el de #163:

| fuente | anclas | muestra | ancla mín | rango calibrado |
|---|---|---|---|---|
| `ai_pro` | 5 | 2,570 | 75 | 29.9% – **51.1%** |
| `ai_pro:ML` | 5 | 1,109 | 42 | 29.1% – **45.4%** |
| `ai_pro:OU` | 5 | 1,220 | **11** | 18.2% – 72.2% |

Un Moneyline que el LLM declare al 80% sale calibrado a **45.4% como máximo** — por debajo de
momio par. Es la firma de abstención que probamos fatal en #163.

**Hay DOS calibradores corriendo en paralelo y no lo sabíamos:**
```
calibrar_prob_motor   <- calibracion_coef      <- backtest, CON candado   -> 8 lectores
calibrar_probabilidad <- calibracion_isotonica <- en muestra, SIN candado -> 3 lectores
```
Lectores vivos de la isotónica: `construir_parlay_v2`, `track_ai_pro_picks_from_analisis`,
`get_oportunidades_hoy`. **Medir su Brier fuera de muestra contra la tasa base antes de decidir.**
Dato de alivio: `pg_stat_statements` marca **0 llamadas** a `calibrar_probabilidad`.

### #179 / #180 — Tubería cortada, falta vigilar que no vuelva
Las dos edge functions ya están parchadas y las 18 lecciones envenenadas borradas.
**Verificar mañana después de las 05:25 UTC** que el cron 324 regeneró pocas lecciones y
ninguna con números de ajuste ni Kelly.

En `reflexion-ai` quedó un detalle menor: la primera línea del prompt todavía dice
"genera reglas de ajuste" mientras el cuerpo ya dice OBSERVACIÓN TÁCTICA. No es fuga, pero
conviene limpiarlo cuando se toque ese archivo.

### El veto unificado (sustituye al de ROI)
La regla de veto por ROI a n≥50 que propuso Gemini queda **descartada con medición**. Corrida
contra los datos reales, esta noche habría: matado MLB Moneyline con t=−0.75 (ruido puro),
**resucitado MLB Over/Under** (el único que probamos roto con 1,033 picks) y bendecido BTTS
con n=2. Tres decisiones, tres equivocadas.

**El sustituto:** veto por **Brier fuera de muestra contra la tasa base, con n≥200.**

---

## PANTALLA

### #126 — RETO 13M: pantalla nueva y el motor solo produce no-favoritos

### #42 — Acotar columnas del Feed de Comunidad

### #67 — Equipos favoritos con estrella en el menú de LIGA

### #70 — Historial por equipo A-F: construido y bueno, pero la app nunca lo pedía

### #155 — Notificaciones de marcador: dos sistemas mandando lo mismo

### Hueco de tendencias en MLB
`tendencias_partido()` se calcula al vuelo (no hay caché que refrescar). Fútbol: **30 de 31**
partidos con Local/Visita/H2H. **Béisbol: solo 5 de 25** — 20 devuelven "ESPN no tiene historial
suficiente". La pestaña TENDENCIAS está prácticamente vacía en béisbol.

### `tendencias_externas` NO está rota
37 filas de un solo día (30-ago) sobre 3 partidos, fuente 365scores. **Nunca hubo cron ni función
que la escribiera**: fue una carga manual para la medición de #54. No es un pipeline caído.

---

## NFL — el calendario manda

### #118 — NFL listo para el 10-sep: agenda sembrada, picks apagados hasta medir

### #35 — Resolver los deadlocks de `nfl-sync-cdn` en `live_scores` después del 9-sep
**NO tocar ni desactivar el cron `nfl-sync-cdn` ni `sync_nfl_desde_cdn()`** hasta después del
arranque del 9-10 de septiembre, y solo con confirmación explícita.

### #93 — NFL auto-actualización: lesiones LISTO, faltan snaps y novatos

### #87 — FANTASY/NFL: uso, zona roja, K, DEF y depth charts cargados. Solo falta ADP

---

## SEGURIDAD Y PUBLICACIÓN

### #63 — Rotar la service_role key
**Requiere que la generes tú.** Ya salió de los 40 lugares donde estaba.

### #105 — Seguridad: cerradas las 2 vistas de dinero abiertas a internet y 43 respaldos

### #38 — Bloqueantes para publicar: apodo, funciones rotas, correo

---

## OPERACIÓN

### #98 — Cierre del día: lo hecho por deporte y las cadencias reales

### #100 — Cierre: goles al cash out, bullpen apagado, foto de predicción NFL

### Documento maestro
No recoge nada de la jornada del 3-sep.

---

## NOTAS DE MÉTODO

Cosas que costaron caro aprender y conviene no repetir:

1. **`CREATE TABLE ... (LIKE ... INCLUDING ALL)` NO copia RLS ni políticas.** Toda tabla nueva
   necesita `enable row level security`, `force row level security` y `revoke all from anon, authenticated`.
2. **`pg_net` no despacha dentro de la misma transacción.** El patrón que funciona es
   `recoger(); pedir(N);`.
3. **`calibrar_prob_motor` devuelve NULL fuera del rango medido**, y un NULL tira filas en silencio
   a través de un `WHERE`. Fútbol topa en 70%, béisbol en 62%. Siempre `coalesce` + marcar.
4. **La URL del linescore de ESPN sale del propio JSON, nunca se arma a mano.** Pedir
   `.../competitors/{ID_EQUIVOCADO}/linescores` devuelve HTTP 200 con la línea de OTRO jugador.
5. **Cuando un bloque diga `inferred_from_`, cruzarlo contra la aritmética del EV antes de creerle.**
6. **Cada parche lleva pegada una pregunta de control.** Así aparecieron las fugas 4, 5, 6 y 7 de
   Kelly; ninguna estaba en el plan original.
7. **Antes de concluir de una tabla, verificar que no mezcle deportes.** `historico_partidos_espn`
   junta soccer, baseball y football; sin filtrar da 4.12 goles de media.
8. **Con muestra chica no se concluye.** Ese día me equivoqué dos veces por eso: "+2.10 carreras de
   subestimación" salió de n=25 (con n=1,056 el sesgo es −0.15), y leí un favorito al revés por no
   cruzar el bloque contra el EV.
9. **Un mercado que el evaluador no conoce NO falla ruidoso: devuelve `no_evaluable` y la pata
   se queda pendiente para siempre.** Así estuvo dos días un parlay de $200. Cualquier estado
   terminal-que-no-es-terminal necesita alerta por tiempo, no por error.
10. **Antes de culpar al evaluador, probarlo con el mismo marcador y un mercado que sí conozca.**
    Eso separó en un minuto "el evaluador está roto" de "no conoce ese mercado".
11. **Cuando una guarda bloquee algo, la respuesta correcta casi nunca es saltarla.**
    `BLOQUEADO_PREMATURO` tenía razón: el partido seguía `live`. Se arregló dándole el dato real,
    no desactivando la protección.
