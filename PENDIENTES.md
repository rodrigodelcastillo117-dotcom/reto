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

## PLAN POR FASES (acordado 3-sep)

Ordenado por riesgo real de dinero y por la unica fecha dura de la lista: **NFL arranca el 9-10 de septiembre.**

### FASE 1 — Blindaje y fugas de dinero (hoy / manana)
1. **#172 red de seguridad.** Ponerle cron a `completar_metadatos_live()` cada 30 min y bajar su
   ventana a 45 min **solo para partidos en estado vivo** (hoy es de 2 dias y no la corre nadie).
   Mas la alerta por `confianza_calificacion='BLOQUEADO_PREMATURO' AND resultado='pendiente'`
   — el segundo filtro es obligatorio: el marcador sobrevive a la liquidacion y sin el la alerta
   arranca con un falso positivo (el parlay de $250 del 9-ago, ya cerrado).
2. **#147. CERRADO el 3-sep.** Ver seccion DINERO.
3. **Verificacion #179/#180** despues de las 05:25 UTC: que el cron 324 regenerara pocas lecciones
   y ninguna con numeros de ajuste ni Kelly.

### FASE 2 — Datos y NFL (4-6 sep)
1. **#93 NOVATOS. CERRADO el 3-sep** (ver seccion NFL). Historico: CORRECCION MEDIDA: los snaps NO faltan. `nfl_snaps` tiene 7,887 filas de la
   temporada 2025 (semanas 1-22, cargadas el 1-sep desde nflverse) y el cron `nfl-snaps-martes`
   (martes 12:13 UTC) ya existe y jalara 2026 conforme se juegue. Los snaps de 2026 no pueden
   precargarse porque la temporada no ha empezado.
   **El hueco real es `nfl_novatos`: 1 sola fila, sin cron y sin funcion que la llene.** Un novato
   sin historico cae al promedio de posicion. Esto SI es precargable y hay que construirlo.
2. **#118.** Verificar la agenda sembrada y decidir con que evidencia se encienden los picks.
3. **#157.** Separar estrictamente los snapshots de antes y de durante el partido: protege el CLV
   y el EV historico con el que despues calibramos.
4. **#172 punto 1.** Mapear la tanda de penales de la API hacia `score_detail_json`. El formato ya
   quedo estrenado con datos reales en el evento 401914296.
5. **#173 ACOTADO.** NO es fuga de banca: la aritmetica lo descarta (EV almacenado +14.1% cuadra
   con 0.296 x 3.85 - 1; si usara la invertida seria +57.9%). El alcance correcto es auditar si
   `capture_pick_to_ai_learning` arrastra la inversion a la tabla de entrenamiento.

### FASE 3 — Enjambre y calibracion (7-9 sep)
1. **#175.** Conectar los 14 crons a `bitacora_aprendizaje`. Escribir primero, decidir despues.
2. **Veto unificado por Brier con n>=200**, en sustitucion del veto por ROI.
3. **#140 y #158.** Etiqueta de probabilidad en la tarjeta y chip GANA en vivo.
4. **#176 CON GUARDA.** NO es un swap de 5 minutos. `calibrar_prob_motor` devuelve NULL fuera del
   rango medido (futbol >70%, beisbol >62%) y un NULL tira filas en silencio por un `WHERE`: es el
   mecanismo exacto de #57 y #114, que dejaron a MLB y NFL sin un solo pick durante semanas.
   La reruta va con `coalesce(calibrar_prob_motor(...), prob_cruda)` y conteo antes/despues.
   Exposicion medida: el techo de 45.4% toco 1 pick en 25 horas (`calibrar_prob_motor` = 31 llamadas,
   `calibrar_probabilidad` = 1, `construir_parlay_v2` = 0, `get_oportunidades_hoy` = 0).

### FASE 4 — Post-kickoff
#120, #113, #36 (datos sucios) · #174, #135, #145, #133 (modelo) · #126, #155, #70, #67, #42
(pantalla) · #63, #105, #38 (seguridad) · #98, #100 (operacion).

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

### #147 — CERRADO el 3-sep-2026. La premisa era falsa y el diagnostico real era otro
**Lo que creiamos:** el EV se calculaba con DraftKings y se apostaba en PlayDoIt, y ademas
`momio_real_de_mercado()` hacia line shopping (`order by m desc`) entre ~11 casas.

**Lo que la medicion encontro (194 picks con precio de la cartelera del 3-sep):**

| Medida | Valor |
|---|---|
| Casas distintas que ganaban la subasta | **1** (DraftKings) |
| Picks donde el ancla cambio de casa al arreglarlo | **0** |
| Cobertura antes / despues | **194 / 194** |
| Eventos donde Pinnacle publica precio (36h) | **0 de 157** |

El `order by m desc` **nunca comparo casas**. Lo que hacia era quedarse con la MEJOR foto de las
ultimas 24 horas del MISMO libro: `radar_odds_snapshots` guarda hasta 12 snapshots por evento y
casa, y `odds_espn` (proveedor = `draftkings`) y `badrino_partidos` (`casa_odds` = `draftkings`)
son dos puertas mas al mismo DraftKings. **Era una subasta contra el tiempo, no contra el mercado.**

Peor caso medido, y estaba aprobado en la cartelera:
```
ML Kansas City Royals (vs Miami)
  precio usado : 2.060  <- foto de AYER 18:15
  precio real  : 1.847  <- DraftKings HOY 16:12   (+11.50% de sobreprecio)
  EV mostrado  : +1.1%     EV real: -9.3%
```

**ARREGLO 1 — `momio_real_de_mercado()`.** El `order by m desc` se sustituyo por una cadena de
prioridad por identidad de casa + la foto mas reciente:
`1. pinnacle -> 2. draftkings (radar, odds_espn o badrino) -> 3. cualquier otra casa`, y dentro de
cada escalon `snapshot_at desc`. **El tercer escalon es obligatorio**: sin el, un evento sin
Pinnacle ni DK devuelve NULL y eso es el apagon silencioso de #57/#114 por otra puerta.
Ademas se le puso guarda de en vivo a `odds_espn` (34 filas traen proveedor
`draftkings - live odds`), que era la misma fuga que radar ya bloqueaba con `fase <> 'en_vivo'`.

**ARREGLO 2 — el piso.** `v_pick_canonico.es_pick` pasa de `ev_pct > 0` a `ev_pct >= 2.5`.
El 2.5 **no es criterio, es la brecha medida DraftKings -> PlayDoIt (+2.46%, n=14)**: el unico
margen que queda por absorber una vez anclado el precio.
**NO subirlo a 6%.** Ese numero cubria ademas el sobreprecio del line shopping (+3.01%), que el
Arreglo 1 ya erradico; cobrarlo ahora seria cobrar dos veces la misma comision y costaba 12 picks
positivos reales. Barrido completo sobre los 194: piso 0 -> 62, 1% -> 58, 2.5% -> 54, 4% -> 46,
6% -> 42, 8% -> 36.

**Efecto en produccion (mismo dia, misma cartelera):** 445 picks, 194 con precio,
`es_pick` **50 -> 43**, EV minimo aprobado 3.2%, 10 ligas y los 2 deportes activos siguen con picks
(futbol 38, MLB 5). Ningun deporte se apago.

**RESIDUAL de #147 — la segunda tuberia de precio.** `refrescar_destacados()` (pantalla
DESTACADOS) NO usa `momio_real_de_mercado`: usa `v_momios_confiables`. Revisado: **no tiene la
fuga de la subasta** (ya hace `distinct on (espn_event_id) ... order by snapshot_at desc`), pero
si tiene dos cosas por decidir, cada una medible por separado:
1. su piso de aprobacion sigue en `ev_pct > 0`, no en 2.5;
2. no filtra en vivo — ni `fase` de radar ni el `proveedor` `'live odds'` de ESPN — y su ventana
   es de 18 horas, asi que un precio capturado con el partido corriendo si puede entrar.

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

### #93 — NFL: el hueco de datos del depth chart, cerrado el 3-sep-2026
**La premisa original era falsa.** No hacia falta una tabla estatica con la clase de draft 2026
(~257 nombres). Medido: de los **247** jugadores del depth chart 2026, **237 ya tenian historico
de temporada regular**. El hueco real eran 10, y el mismo sintoma escondia TRES causas distintas.

**HERRAMIENTA — `v_nfl_sin_historico`.** Vista derivada, `security_invoker = true`, cerrada a
`anon`/`authenticated`. Cruza el depth chart vigente contra el historico y devuelve quien NO tiene
un solo partido de temporada regular, con la EVIDENCIA (partidos_regular, partidos_pretemporada,
en_nfl_pateadores, declarado_novato) y una `causa` que **solo dice novato si alguien lo declaro en
`nfl_novatos`**. La temporada sale de `max(temporada)` del propio depth chart: no hay que tocarla
cada agosto.

**ERROR CORREGIDO EN LA MISMA SESION (vale la pena recordarlo).** La v1 medía el historico de TODOS
contra `nfl_player_game_logs`, que solo guarda pase/acarreo/recepcion. **Un pateador por diseno
nunca aparece ahi**, asi que la v1 marco 26 falsos positivos con carrera completa: Harrison Butker,
Jake Elliott, Chris Boswell, Ka'imi Fairbairn. La etiqueta era literalmente cierta y completamente
enganosa. La v2 lee la evidencia **segun la posicion**: K/PK desde `nfl_pateadores` +
`nfl_kicker_logs`, el resto desde `nfl_player_game_logs` x `nfl_partidos` (`tipo_temporada = 2`).

**PATEADORES — no faltaba carga, faltaba temporada.** El ingestor `nfl-def-k-sync` ya existia,
apunta al dominio bueno (`sports.core.api.espn.com`) y **no tiene cron**. Corrido para 2025:
200 OK, 32 defensas + 29 pateadores, 11 s, idempotente. Bass y Sanders seguian faltando, y NO era
el `continue` por `fgm === 0`: preguntando a ESPN directo, **404 en la temporada regular 2025 de
ambos**, con perfil 200 y posicion PK. **No jugaron esa temporada.** Corrido para 2024 (12 s):
entraron con dato oficial de ESPN, sin colisionar con 2025 (`onConflict: espn_athlete_id,temporada`):

| Pateador | Temporada | Juegos | FG | FG% | PAT | fantasy_ppj |
|---|---|---|---|---|---|---|
| Tyler Bass (BUF)    | 2024 | 17 | 24/29 | 82.8 | 59 | 8.59 |
| Jason Sanders (NYJ) | 2024 | 17 | 37/41 | 90.2 | 26 | 9.76 |

**LOS 3 NOVATOS PATEADORES NO SE SEMBRARON EN `nfl_pateadores`.** Un registro base con
`juegos=0, fgm=0, fantasy_ppj=0` no es dato faltante: es un pateador que segun la base **falla
todo**, y las funciones de fantasy lo leerian como efectividad 0%. Peor que la ausencia. Los cinco
sin historial profesional se sembraron en `nfl_novatos`, que existe justo para eso, y
`fantasy_limitaciones()` ya avisa de ellos.

**SIEMBRA — 5 filas, derivadas, no tecleadas.** El INSERT sale de `v_nfl_sin_historico`
(equipo, posicion, id vienen del depth chart de ESPN), asi que no hay forma de errar un dato.
`ronda`, `pick_global` y `universidad` quedan **NULL a proposito**: no estan verificados contra el
draft oficial y no se inventan. `verificado = false` en los cinco; la fila de Fernando Mendoza,
confirmada por el usuario, quedo intacta gracias al `on conflict do nothing`.
RB Jeremiyah Love (ARI) · RB Jadarian Price (SEA) · K Trey Smack (GB) · K Dominic Zvada (NYG) ·
K Drew Stevens (WSH).

**ESTADO FINAL:** el hueco pasa de **10 a 8**, y **`pateador_sin_carga` queda en 0**. Los 8 que
restan son los 6 novatos declarados (el modelo sabe que no sabe) y 2 `solo_pretemporada`:
Deshaun Watson (CLE, QB1) y Jonathon Brooks (CAR, RB2).

**LO QUE SIGUE ABIERTO, Y ES LO QUE LE FALTA AL NOMBRE DE ESTA TAREA:**
1. **`nfl-def-k-sync` NO tiene cron.** Es la causa de que quedara a medias. Sin el, la estadistica
   de pateadores y defensas de 2026 no entrara sola conforme se juegue la temporada.
2. **Watson y Brooks.** Decision tomada el 3-sep: se quedan como `solo_pretemporada`. Darles
   historico exige cargar `nfl_player_game_logs` de 2024, que SI toca la base del motor y el
   baseline de calibracion, a dias del arranque. `nfl_pateadores` era distinto: es una tabla
   aislada de fantasy, sus unicos lectores son `nfl_fantasy_meter_k_y_def` y las funciones
   `fantasy_*`, y no roza el motor de apuestas.
3. La base solo tiene **2025 regular y 2026 pretemporada** en `nfl_player_game_logs`. No hay 2024
   ni anterior. Cualquier plan que diga "jalar temporadas anteriores" choca con esto primero.

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
