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
3. **#157. CERRADO el 3-sep.** Ver seccion DINERO.
4. **#172. CERRADO el 3-sep.** Ver la seccion de abajo.
5. **#173. CERRADO el 3-sep.** Ver seccion MODELO.

**FASE 2 COMPLETA (3-sep-2026): #93, #157, #172 y #173 cerrados.**

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

### #157 — CERRADO el 3-sep-2026. La separacion ya existia; nadie la usaba
**La tabla NO tiene `is_live`, ni `period`, ni la hora del partido.** Pero `v_radar_odds_fase` ya
cruzaba contra `v_evento_hora` y clasificaba cada foto:
`snapshot_at > hora` -> `en_vivo`, dentro de los 15 min previos -> `cierre`, antes -> `pregame`,
sin hora -> `sin_hora`. El problema nunca fue construirla: era **quien no la usaba**.

**Contaminacion medida** (filas con `espn_event_id`, desde el 6-ago): pregame 10,063 (90.7%),
**en_vivo 643 (5.8%, 215 eventos)**, sin_hora 236, cierre 154.

**Inventario: 25 objetos leen `radar_odds_snapshots` en crudo. UNO solo pasaba por la vista de
fase** (`momio_real_de_mercado`, arreglada el mismo dia en #147).

**EL AGUJERO — la FUENTE 2 de `capturar_clv_pick`.** Cruzaba por `LIKE '%primera palabra%'` (que
puede pegarle a otro partido: "Manchester" casa con City y United) y ordenaba
`snapshot_at >= created_at ORDER BY snapshot_at DESC` **sin ningun techo**. Con el partido ya
empezado tomaba un precio EN VIVO y lo escribia como momio de cierre.
Daño: de las 17 filas auditables de `clv_tracking`, **7 traian un "cierre" capturado en promedio
431 minutos DESPUES del saque** (el peor, 683 min: el partido llevaba 11 horas terminado).

**`capturar_clv_oraculo` NO se toco**: ya tenia techo (`<= match_date + 5 min`), ventana de 10 dias
y cruce por `espn_event_id` con respaldo `norm_equipo`. Estaba bien.

**PARCHE 1 — la consulta.** Mismo criterio que la funcion hermana: techo `hora + 5 min` (tolerancia
por saques que se atrasan), ventana de 10 dias, cruce por id con `norm_equipo` de respaldo, y
`JOIN` duro contra `v_evento_hora` (sin hora de partido NO se calcula CLV: no se puede afirmar que
un precio sea pregame si no se sabe cuando empezo).
**El piso `snapshot_at >= created_at` se quito**: para el CLV importa el ULTIMO precio antes del
saque, no cuando se creo el pick. Medido sobre los 26 picks que caen a esta fuente: con el piso se
resuelven 7, sin el 16. Verificado: **16 de 16 con veredicto pregame, cero en vivo.**

**PARCHE 2 — la escritura, que llevaba semanas rota.** `ON CONFLICT (pick_id)` no correspondia a
ningun indice: la funcion **fallaba SIEMPRE con 42P10 y nunca pudo escribir**. Y `pick_id` no es la
identidad de la fila: con `origen='parlay'` es el id del PARLAY y cada pata mete la suya (hasta 16
filas con el mismo `pick_id`), asi que un indice unico sobre `pick_id` habria colapsado el CLV de
los parlays. Medido sobre las 341 filas: `(pick_id, origen, pick_desc)` deja 24 duplicados;
`(pick_id, espn_event_id, pick_desc)` deja 0.
**El indice correcto YA EXISTIA**: `clv_tracking_unico`, sobre
`(pick_id, COALESCE(pick_desc,''), COALESCE(espn_event_id,''))`. El `COALESCE` es deliberado: sin
el, dos NULL no colisionan y el upsert insertaria duplicados en silencio.

**PARCHE 3 — `pick_desc` faltaba en el INSERT.** Sin el, cada corrida escribia una fila con
`pick_desc` NULL en vez de completar la que ya existia: dos registros del mismo pick, uno con la
descripcion y sin CLV, otro con el CLV y sin descripcion. **Esto explica las 330 filas con
`fuente_cierre` NULL**: picks registrados esperando un CLV que nunca llegaba.
Prueba de idempotencia: dos corridas seguidas -> **1 sola fila**, la legitima, completada.

**SANEAMIENTO.** `clv_tracking` gana `cierre_confiable` y `nota_calidad`. Las 7 contaminadas quedan
en `false` con los minutos exactos de desfase; 18 verificadas pregame en `true`; 316 en NULL (sin
`captured_close_at` o sin hora de partido, no auditables). **No se recalculan ni se borran**: el
precio real de ese momento ya no es recuperable, y un CLV marcado como no confiable informa mejor
que uno borrado o uno inventado.

**GUARDA DE FASE en `v_pick_canonico`.** El bloque que saca `home_ml/draw_ml/away_ml` para
`prob_local_casa_pct` y el chip de favorito leia la tabla cruda. Ahora lee `v_radar_odds_fase` con
`fase <> 'en_vivo'`. Medido: sobre la cartelera de hoy no cambia nada (77/77 iguales, 0 perdidas,
son partidos futuros), pero **sobre los 215 eventos que si tuvieron fotos en vivo cambia el precio
en 182**, y solo 4 se quedan sin precio de casa.

**RESIDUAL:** quedan **21 lectores** de la tabla cruda sin revisar, entre ellos `v_momios_confiables`
(que alimenta DESTACADOS), `v_line_movement` y `detectar_sharp_money`. Varios son de diagnostico y
no les importa la fase. Hay que revisarlos uno por uno, no en bloque.

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

**FALLA 2 — CERRADA el 3-sep-2026, y eran TRES bugs, no uno.**

**(a) ESPN SI publica la tanda, y la funcion la tiraba.** El scoreboard que `get-espn-matches`
consulta cada 3 minutos (cron `refresh-live-scores`, jobid 31) ya trae todo. Verificado contra
`concacaf.leagues.cup?dates=20260902-20260903`:
```
AME: score=2  shootoutScore=4  winner=false
MTY: score=2  shootoutScore=5  winner=true
status.type.name = STATUS_FINAL_PEN     (shortDetail = "FT-Pens")
```
`parseMatch()` leia solo `score` y descartaba el resto del competidor. Cero llamadas nuevas hacian
falta: el dato pasaba por delante cada 3 minutos.
**NOTA:** `site.api.espn.com/.../summary` da **403** (sigue bloqueado, #43/#83). El slug correcto
de la copa es `concacaf.leagues.cup`, y **ya estaba en `ligas_master`** activa y no bloqueada, asi
que no hubo que agregar ninguna liga al radar.

**(b) `"FT-Pens"` no se reconocia como final.** El upsert decidia el estado con
`minute.includes("Final") || minute === "FT" || minute === "AET"`. `"FT-Pens"` **no casa con
ninguna de las tres**: esa es la causa mecanica exacta de que el partido se quedara `live` desde
las 06:12 UTC. Arreglar solo la tanda lo habria dejado colgado igual.
**El estado manda sobre el texto:** la guarda exige `state === "post"` o `completed === true`,
porque `"Pens"` a secas aparece TAMBIEN durante la tanda (`state="in"`) y marcarlo final ahi
calificaria un parlay a medio patear.

**(c) EL MAS GRAVE — `trg_live_scores_ignorar_sin_cambio` cancelaba la escritura EN SILENCIO.**
Ese trigger compara 14 columnas y **`score_detail_json` NO estaba entre ellas**: si solo cambiaba
el detalle, devolvia `null` y el UPDATE se descartaba sin error. Y ese es exactamente el caso de
una tanda: se conoce cuando el partido YA termino y el marcador lleva rato congelado.
**No afectaba solo a los penales: cualquier proceso que intentara enriquecer `score_detail_json`
despues del pitazo final llevaba fallando en silencio.** Se agrego la columna a la lista blanca.
No reabre el derroche de Realtime que motivo el trigger (5M mensajes/mes): la comparacion sigue
siendo POR VALOR, asi que reescribir el mismo json se sigue cancelando.

**LO DESPLEGADO.**
- RPC `guardar_penales_espn(text,int,int,text)`, `security definer`, solo `service_role`.
  **FUSIONA con `||`, no reemplaza** — 981 filas ya traen `score_detail_json` de otras fuentes y
  **719 de ellas son ARREGLOS**, que la RPC deja intactos. Es **idempotente y sin timestamp**: si
  los penales ya estan, devuelve false sin escribir. Un `capturado_at` habria hecho el json
  distinto en cada vuelta y forzado escritura + Realtime cada 3 minutos.
  Probada: tanda nueva `true`, repetida `false`, 0-0 `false`, nulos `false`, arreglo intacto.
- Trigger `live_scores_ignorar_sin_cambio` con `score_detail_json` en la lista blanca.
- `get-espn-matches/index.ts` enviado a Lovable (los 4 cambios, con el detalle de que
  `buildFixturesIndex` usa OTRO vocabulario de estado — escribe `"post"`, no `"final"` — y por eso
  NO lleva la guarda del cambio 2).

**HALLAZGO LATERAL: la ingesta ya existia por otra puerta.** El mismo partido esta DUPLICADO en
`live_scores`: `af_1635864` (API-Football, `status_detail='PEN'`, penales 4-5 **automaticos**) y
`401914296` (ESPN). De 261 filas `af_` todas traen la clave `penales`; de 2,402 filas de ESPN solo
una la tenia, y era la que se escribio a mano. El calificador cruza por el id de ESPN, asi que
nunca miraba la fila buena. El puente `enlazar_espn_apifootball` **solo cubre Liga MX**
(`ligamx_partidos`), y las dos unicas tandas de la base — Leagues Cup y Super Cup griega — quedan
fuera por construccion. Se eligio la ruta ESPN y no espejar la fila `af_`: evita depender de
API-Football y evita cruzar nombres entre bases para copas internacionales.

**Volumen real: 2 tandas en toda la historia de la base.** Es un evento raro, pero cuando ocurre
deja dinero parado dos dias.

**FALLA 3 — ABIERTA.** `protect_parlays_premature_grading` revierte el cierre a `pendiente`
con `BLOQUEADO_PREMATURO` si la pata perdedora tiene el partido sin confirmar como final.
**Eso está bien** — es la guarda contra calificación prematura. El problema es que el partido
se quedó `live` porque el sync perdió la señal, y que ese bloqueo **no avisa a nadie**.

Aplica a Leagues Cup, Copa MX, eliminatorias de Champions y Mundial.

**RESIDUAL de #172:** verificar en la proxima tanda real que el ciclo completo corre solo, de punta
a punta, sin tocar nada a mano.

### #173 — CERRADO el 3-sep-2026. La mina tenia DOS cargas, y estaba inerte
**El diagnostico original sigue en pie:** en `401914297` (Toluca vs Leon) el analisis guardo
`home_win=29.6` y `away_win=41.0` con `agenda_espn` diciendo home=Toluca. Es al reves, y el EV
guardado lo prueba: `0.296 x 3.85 - 1 = +13.96%`, que es el `+14.1%` registrado. El bloque venia
marcado `"_odds_provider": "inferred_from_picks"`: reconstruido hacia atras desde los picks, y ahi
se cruzaron los lados. **Medido: 36 de 165 analisis (22%) traen esa marca.**
(Segundo defecto del mismo analisis, sin cerrar: `goles_esperados` es `{local 1.1, visitante 1.1}`,
simetrico, y con lambdas simetricas el 1X2 no puede salir 29.6/29.4/41.0. Ese 1X2 no salio de esas
lambdas, asi que cualquier BTTS u Over derivado de ellas tampoco es confiable.)

**CARGA 1 — el hardcodeo.** `capture_pick_to_ai_learning()` hacia
`v_predicted_prob := (v_ai->'probabilidades'->>'home_win')::NUMERIC / 100` **para CUALQUIER pick**.
Con un Over 2.5, un BTTS o un "gana visitante", `ai_predicted_prob` era la probabilidad de otro
evento distinto, y `calibration_error` la comparaba contra el resultado del PICK. **327 de 401
picks de la muestra NO son ML.**

**CARGA 2 — el origen.** Mapear bien el lado no salva nada si el bloque viene invertido de fabrica.
Los 36 analisis `inferred_from_picks` quedan **vetados con NULL estricto**, por dos razones
independientes: son circulares (medir calibracion contra un numero derivado de los propios picks es
medir el modelo contra si mismo) y son los que cruzan los lados.

**NO CONTAMINO NADA — pero no porque el sistema lo evitara.** `pick_learning_data`, 401 filas:
`ai_analysis_id` 0, `ai_predicted_prob` 0, `ai_confidence` 0, `ai_edge_total` 0, `ai_veredicto` 0,
`score_compuesto` 0, `calibration_error` 0. Todos vacios. La causa esta abajo, en RETENCION.
**Por eso se arreglo AHORA, con la tabla inerte**: el dia que alguien alargue la retencion, la
funcion habria empezado a meter basura sin que nada avisara.

**EL PARCHE.** Extraccion por lado del pick, NULL estricto cuando no se puede afirmar:
`home_win` / `away_win` / `draw` / `over_prob` / `under_prob`, todas en escala 0-100.
- **Veto a `_odds_provider = 'inferred_from_picks'`** antes de cualquier mapeo.
- **Doble oportunidad, handicap y BTTS van primero y devuelven NULL**: no tienen probabilidad
  propia. El orden importa para que "Empate o Chicago Fire" no se clasifique como empate.
- **En totales se exige que `over_line` del analisis sea LA MISMA linea del pick** (viene en 135 de
  165: 1.5, 2.5, 8, 9, 11.5). Sin linea o con otra, NULL: es el error que costo un +81% de EV
  inventado en `momio_real_de_mercado`.
- Se elimina el fallback a `(v_ai->>'predicted_prob')`: esa clave no existe en ningun analisis.
- Sin ancla `^` en over/under: "Total Mas de 2.5" es un pick real y el ancla lo dejaba sin mapear.

**Verificado** contra los `pick_desc` reales: under 6, home 4, away 4, over 2, draw 1,
NULL-sin-prob-propia 2, NULL-no-mapeado 7. Analisis utilizables tras el veto: **129 de 165**.

**RESIDUAL.** Los 7 sin mapear no contaminan (NULL es seguro) y son de dos clases:
1. **ML con abreviatura**: "BOS Red Sox ML" contra `espn_home_team='Boston Red Sox'`; el LIKE no
   casa. **La tabla de alias de #71/#111 lo resolveria.** No se metio para no ampliar el alcance, y
   porque hoy la funcion esta inerte: el costo es cobertura, no contaminacion.
2. **Picks sin `espn_home_team`/`espn_away_team`**: "Fiorentina Gana", "FK Bodo Glimt 1X2".

**NOTA DE METODO.** Yo mismo reporte primero que `inferred_from_picks` "no existe". Existe, pero
como VALOR de `probabilidades._odds_provider`, no como clave de primer nivel de `analisis_json`:
busque en el nivel equivocado. Al inspeccionar un JSON, listar las claves de primer nivel NO
descarta que el dato viva como valor un nivel abajo.

### #181 — 68 picks del Oraculo sin calificar: la limpieza borra el insumo del calificador
**Detectado el 3-sep-2026** al revisar un aviso de "picks sin calificar". **El dinero del usuario
estaba bien**: un solo pick pendiente en todo el sistema (Cerundolo-Struff, ATP, $3,774) y su
partido **seguia jugandose** — sets 1-2, 4to set, 2.9 h desde el saque, `live_scores` refrescado
hacia 1 minuto. Cero parlays pendientes. El autograder no lo calificaba porque **no habia
terminado**, que es lo correcto.

**Lo que si esta atorado es `oraculo_picks_tracking`**: 88 pendientes, **68 con el partido
terminado hace mas de 6 horas**, algunos desde el **11 de agosto**. No son apuestas, son los picks
publicados con los que se mide el track record.

**CAUSA RAIZ: el dato que el calificador necesita se borra antes de que lo use.**
`limpieza-nocturna` (jobid 32, 11:00 diario) hace:
```sql
DELETE FROM live_scores WHERE status IN ('post','final') AND updated_at < now() - interval '24 hours';
```
Si un pick no se califica dentro de las ~24-35 h posteriores al partido, su marcador desaparece y
**queda pendiente para siempre**. Medido: **65 de los 68 ya no tienen fila en `live_scores`**.

**Desglose por liga:** 45 de los 68 son de liga `"Unknown"` (11 a 26-ago) — nunca tuvieron liga
resuelta, no se calificaron el primer dia, y a las 24 h perdieron el marcador. Los **3 de NFL** son
los unicos que **conservan fila viva** y se pueden calificar hoy.

**HIPOTESIS DESCARTADA (verificada antes de reportarla):** el cron de 15 min (jobid 55) llama a
`grade-oraculo-picks` **sin cabecera Authorization**, lo que parecia un 401 sistematico. Falso:
esa funcion tiene `verify_jwt = false` y acepta la llamada. El cron si corre.

**QUE HACER, en este orden:**
1. Calificar los 3 de NFL, que aun tienen el marcador.
2. Los 65 restantes: **marcarlos `sin_dato`, NO borrarlos ni adivinarlos.** Su marcador ya no existe
   en la base; inventarlo seria justo lo que se lleva toda la sesion evitando.
3. **El arreglo de fondo:** la retencion de `live_scores` (24 h) es mas corta que la ventana en que
   el calificador puede necesitarla. O se alarga, o **el calificador guarda el marcador en
   `oraculo_picks_tracking` en el momento de ver el partido final** (preferible: no depende de la
   retencion de nadie).

**No afecta dinero, pero contamina la metrica publica y es un confundidor directo de #169**
(calibracion sobre picks publicados): 68 picks sin resultado son 68 huecos en el track record.

### PATRON A MIRAR JUNTO — crons de limpieza que borran el insumo de otro proceso
Son ya **dos casos del mismo error de diseno**, encontrados el mismo dia:
- `analisis_partidos` se purga a 2 dias y deja a `pick_learning_data` sin ninguna prediccion (#173).
- `live_scores` se purga a 24 h y deja 68 picks del Oraculo sin marcador (#181).
En ambos, el proceso que limpia no sabe quien mas necesitaba el dato. **Conviene revisar de una vez
TODOS los DELETE programados de `limpieza-nocturna` y ver quien mas consume lo que borran**, en vez
de ir tapando caso por caso.

### RETENCION DE `analisis_partidos` — abierto, a dimensionar aparte
**Este es el motivo real de que `pick_learning_data` este vacia de predicciones**, no el mapeo.
`analisis_partidos` cubre 2 dias (2-sep a 3-sep); `pick_learning_data` cubre 40 (24-jul a 2-sep).
Solo **20 de 383** picks cruzan con un analisis: cuando el trigger dispara al calificar, el analisis
de ese partido ya se purgo.
Ya es SEGURO alargarla (las dos cargas de #173 quedaron desarmadas), pero **antes hay que medir**:
cuanto pesa un `analisis_json`, cuantos se generan al dia, y cuantos dias de ventana hacen falta
para que el trigger alcance a los picks, que se califican dias despues del analisis. Es un frente
operativo con costo de almacenamiento, no una grieta funcional: **no entra en la Fase 2 previa al
kickoff.**

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

**LO QUE SIGUE ABIERTO:**
1. ~~`nfl-def-k-sync` no tiene cron.~~ **FALSO, corregido el 3-sep.** SI lo tiene:
   `nfl-defensas-pateadores` (jobid 346), `41 12 * * 2`, activo, con `{"temporada":2026}` y
   timeout 240 s. Ultima corrida: martes 1-sep 12:41 UTC, `succeeded`. Encaja en la fila de los
   martes sin encimarse (snaps 12:13, derivados 12:30, agenda 12:37, def-k 12:41), que importa por
   #88. **El error fue mio al buscar**: filtre `cron.job` por `command ~* '(pateador|kicker)'` y el
   comando dice `nfl-def-k-sync`, que no contiene ninguna de esas palabras. Buscar por el nombre
   del cron o por el slug de la funcion, no por el tema.
   La automatizacion de la NFL **ya estaba sellada**; lo que faltaba era el dato historico, que es
   lo que se cargo hoy.
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
