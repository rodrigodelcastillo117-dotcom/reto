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
- `analisis_partidos` se purgaba a **36 horas** (no a 2 dias) y dejaba a `pick_learning_data` sin
  ninguna prediccion (#173). CERRADO el 3-sep: era `oraculo-cron`. Ver la seccion de RETENCION.
- `live_scores` se purga a 24 h y deja 68 picks del Oraculo sin marcador (#181).
En ambos, el proceso que limpia no sabe quien mas necesitaba el dato. **Conviene revisar de una vez
TODOS los DELETE programados de `limpieza-nocturna` y ver quien mas consume lo que borran**, en vez
de ir tapando caso por caso.

**DIRECTRIZ DE DISENO acordada el 3-sep-2026 para cuando se aborde #181.**
NO condicionar la purga a que todos los consumidores den el visto bueno (`calificado = true`).
Suena correcto y tiene un filo: **si un consumidor nunca termina, la tabla crece sin techo**. Los 45
picks de liga `"Unknown"` son ese caso — llevan desde el 11-ago sin calificar y no se van a calificar
solos; un DELETE que espere su visto bueno los conservaria para siempre, y `live_scores` se
convertiria en archivo historico por accidente.
**La regla es CAPTURA AL VUELO EN EL CONSUMIDOR:** cada funcion copia la foto que necesita a su
propia tabla de dominio en el instante en que el evento se declara final, en vez de obligar a la
tabla de paso a retener. Asi la purga sigue siendo simple, por tiempo y determinista, y ningun
proceso depende de la retencion de otro.
Ya hay precedente vivo en la casa: `clv_tracking` guarda el CLV en su propia fila y no lo recalcula
desde `radar_odds_snapshots` cada vez.

### CORRECCION IMPORTANTE (3-sep, mismo dia): `analisis_partidos` NO se purga a 2 dias
**Lo escribi mal en #173 y en su commit.** El sintoma era real — solo hay analisis del 2 y 3 de
septiembre — pero **la causa que le atribui es falsa**. Medido leyendo el cron completo:
```sql
-- Retencion ampliada de 14 a 90 dias: el post-mortem necesita el analisis
-- original para comparar prediccion vs resultado. El JSON es texto liviano.
DELETE FROM analisis_partidos WHERE created_at < now() - interval '90 days';
```
**La retencion configurada es de 90 dias, no 2**, y ese DELETE ha borrado **0 filas** (nada tiene 90
dias). Tambien: `espn_data_json` (lo que pesa) se libera aparte a los 7 dias, y `analisis_json` —el
que necesita el aprendizaje— se conserva.

**PERO SI HAY UN BORRADOR ACTIVO, Y NO ES ESE.** `pg_stat_user_tables` reporta **34 filas borradas**
en `analisis_partidos`, y `pg_stat_statements` lo identifica: una llamada **via PostgREST**, no SQL:
```
WITH pgrst_source AS (DELETE FROM "public"."analisis_partidos"
                      WHERE "created_at" < $1 RETURNING "id") ...
```
Es decir, **una edge function (o el cliente) borra por fecha con su PROPIO umbral**, mucho mas corto
que los 90 dias del cron. Verificado que no esta en ninguna funcion SQL (0 coincidencias con
`delete...analisis_partidos`) ni en ningun otro cron.

**QUE CAMBIA ESTO:**
1. El frente de "arquitectura de almacenamiento para IA" (extraer variables antes de la purga)
   **puede no hacer falta**: con 90 dias de retencion el analisis vive de sobra para que el trigger
   lo alcance. Primero hay que encontrar y evaluar el borrador de PostgREST.
2. La tabla ocupa **1.9 MB con 165 filas**. El costo de almacenamiento no es el problema que
   parecia: a ~12 KB por analisis, 90 dias de retencion son decenas de MB, no gigas.
3. **Queda por identificar cual edge function hace ese DELETE.** Hay 129 y no se puede grepear el
   contenido desde SQL; toca revisarlas por nombre o mirar los logs de PostgREST.

### RETENCION DE `analisis_partidos` — CERRADO (3-sep). El borrador fantasma tenia nombre

**Culpable: `oraculo-cron` v146, rama `corrida === "europa"`.** Borraba a **36 horas** via
PostgREST, con la etiqueta "CLEANUP: First run of the day (europa) cleans old cache":

```ts
if (corrida === "europa") {
  await supabase.from("analisis_partidos").delete()
    .lt("created_at", new Date(now.getTime() - 36 * 60 * 60 * 1000).toISOString())
```

**Cadena de evidencia:**
- `pg_stat_statements`: el DELETE no viene de SQL sino de PostgREST.
- Edge log: `DELETE /rest/v1/analisis_partidos?created_at=lt.2026-09-01T23:30:01.433Z`,
  `Deno/2.1.4 SupabaseEdgeRuntime`, a las `11:30:01.441`.
- `function_edge_logs`: `oraculo-cron` invocada a `11:30:01.310` — **131 ms antes**.
- El codigo v146 cuadra al segundo: 11:30 menos 36h = `2026-09-01T23:30`.

**La medicion que cambio la prioridad:** la tabla tenia **1.73 dias de historia** (165 filas, piso
`2026-09-02 00:45`). Ese piso ES la huella del borrador: la app no es joven, la tabla es una ventana
rodante que se recorta sola. La corrida del 3-sep reporto `Cleaned 0` **por coincidencia** (el corte
cayo 75 min antes de la fila mas vieja); la del 4-sep habria matado **136 de 165 filas (82%)**.

**El agravante:** leen esta tabla **20 funciones y 4 vistas**, entre ellas
`capture_pick_to_ai_learning` — la misma que acabamos de desinfectar en #173. Le arreglamos las dos
cargas contaminadas y su fuente se evaporaba cada 36h. Por eso `ai_learning` quedo inerte con 401
filas y todos los campos en cero: **ningun backfill de aprendizaje podia mirar mas de dia y medio
atras.** Los horarios lo rematan: `limpieza-nocturna` (11:00 UTC, 90 dias) corre 30 minutos antes
que `oraculo-europa` (11:30 UTC, 36 horas), o sea la politica oficial llega a una tabla ya vaciada.

**PASO 1 — Contencion en SQL (aplicada 3-sep):** `trg_analisis_retencion_90d`, un `BEFORE DELETE`
que hace cumplir los 90 dias en la tabla misma, sin importar quien borre ni por que ruta:

```sql
if OLD.created_at > now() - interval '90 days' then
  return null;  -- cancela el borrado en SILENCIO
end if;
return OLD;
```

`return null` en vez de `raise exception` es deliberado: `oraculo-cron` no revisa el resultado del
borrado, asi que un error tumbaria toda la corrida `europa` y Premier, Bundesliga y Serie A se
quedarian sin analizar. Con `return null` la corrida sigue igual y el log dira `Cleaned 0`.

**Las dos ramas probadas contra la tabla real, con reversion forzada** (`raise exception` al final
del bloque, la transaccion nunca se confirma — la tabla quedo identica antes y despues):

| Prueba | DELETE reproducido | Resultado | Esperado |
|---|---|---|---|
| El que `oraculo-cron` intentaria el 04-sep | `created_at < 2026-09-02 23:30` | **0 filas** | 0 |
| El legitimo de `limpieza-nocturna` | fila envejecida a 100 dias | **1 fila** | 1 |

La segunda prueba importaba tanto como la primera: sin ella se podia haber dejado una tabla
imborrable para siempre, cambiando una fuga de datos por una fuga de disco.

**PASO 2 — Correccion estructural (enviada a Lovable 3-sep, `umsg_01m1m8c7`):** dos cambios en
`supabase/functions/oraculo-cron/index.ts`: (a) eliminar el bloque `.delete()` completo; (b) caducar
el cache en la **LECTURA** agregando `.gte("created_at", now - 36h)` a la consulta que llena
`cachedIds`. El comportamiento del Oraculo no cambia en nada: un analisis de mas de 36h deja de
contar como cache valido y el partido se re-analiza, **identico a cuando la fila se borraba**. Mismo
gasto de LLM, mismo tier gate, mismo cap tier-2. La diferencia es que la fila sobrevive.

**EL PATRON, tercera vez (#157, #181 y esta):** una funcion que limpia sin saber quien mas consume
el dato. El autor trato `analisis_partidos` como *su* cache de trabajo (`cachedIds`, para no
re-analizar). Nunca supo que tambien es insumo de entrenamiento. Su "36h" es correcto para un cache
y catastrofico para un historico. **Directriz: un solo lugar decide retencion; nadie borra el
insumo de otro proceso, y quien caduca un cache lo caduca en la lectura, no borrando.**

**Residual:** el efecto sobre `pick_learning_data` (20 de 383 picks cruzan con un analisis) debe
volver a medirse en ~1 semana, cuando la tabla acumule historia de verdad. Hasta ahora era
imposible: el trigger dispara al calificar el pick, dias despues del analisis, y el analisis ya no
existia. Costo de almacenamiento medido: ~12 KB por analisis, 1.9 MB por 165 filas — 90 dias son
decenas de MB, no gigas. No es un problema.

**No se pudo determinar si es sistemático:** solo n=4 cruces útiles (2 bien, 2 invertidos), y de 49
análisis con momio, 15 (31%) discrepan del mercado sobre quién es favorito — alto pero no prueba.
En los 8 análisis de MLB del 2-sep las etiquetas SÍ cuadran (7 de 8 coinciden con el mercado).

**Regla:** cuando un bloque diga `inferred_from_`, no creerle sin cruzarlo contra la aritmética del EV.

### #181 — CAUSA RAIZ REAL: los picks nacen con ID de API-Football, no de ESPN

**CORRECCION DE MI PROPIO DIAGNOSTICO (dos veces el mismo dia).** Escribi que
`limpieza-nocturna` borraba el marcador y dejaba los picks colgados. **Es falso**, y la medicion
que lo desmonta es de una linea:

| Grupo | Picks | Llegaron a `marcadores_archivo` | % |
|---|---|---|---|
| Ya calificados (desde 11-ago) | 561 | 561 | **100.0%** |
| Pendientes | 88 | 2 | **2.3%** |

Si el borrado fuera la causa, los 561 calificados mostrarian el mismo hueco: estan sujetos
exactamente al mismo `limpieza-nocturna`. No lo muestran. **El archivo funciona.**

**LA CAUSA REAL.** Los 88 pendientes, agrupados por la FORMA del `espn_event_id`:

| Forma del ID | Picks | Eventos | En archivo | Corners | liga='Unknown' |
|---|---|---|---|---|---|
| `af:` (ID de API-Football) | **56** | 37 | **0** | 19 de 20 | 42 de 45 |
| numerico (ID de ESPN) | 24 | 20 | 2 | 1 | 0 |
| otro formato | 8 | 8 | 0 | 0 | 3 |

Un ID `af:1492358` **jamas** va a cruzar con `live_scores`, `marcadores_archivo`,
`historico_partidos_espn` ni `detalle_partido_espn`: todas estan llaveadas por ID de ESPN.
Esos picks **nacieron incalificables**. Y la mortalidad es total:

| Dia | Picks creados | Con ID `af:` | `af:` calificados |
|---|---|---|---|
| 3-sep | 9 | 2 | **0** |
| 29-ago | 72 | 10 | **0** |
| 24-ago | 12 | 3 | **0** |
| 22-ago | 48 | 6 | **0** |
| 21-ago | 9 | 4 | **0** |

**31 picks con ID `af:` en 14 dias. 31 siguen pendientes. CERO calificados, ni uno, nunca.**
Y sigue pasando: 2 de los 9 picks de hoy traen `af:`.

Esto explica de golpe las tres "causas" que crei distintas:
- Los 20 de **Corners**: 19 traen `af:`. No era el mercado — era el ID. `detalle-espn-backfill`
  enumera desde `historico_partidos_espn`, y un `af:` nunca esta ahi.
- Los 45 de **`liga='Unknown'`**: 42 traen `af:`. La liga no se resuelve porque el evento no es de
  ESPN. La etiqueta 'Unknown' es sintoma, no causa (y 148 picks 'Unknown' con ID de ESPN
  se calificaron al 100%).
- Los **64 huerfanos** sin fila en ninguna tabla: son los `af:` mas los de "otro formato".

**Es #66 otra vez** ("Los picks recomendados traen IDs de API-Football, no de ESPN"), marcado como
cerrado. El arreglo no cubrio esta ruta, o se reabrio.

**LO QUE NO SE DEBE CONSTRUIR (y estuve a punto):** la captura al vuelo del marcador al pitazo
final, mas el encolamiento a `detalle-espn-backfill`. Para 56 de 88 picks **no habria hecho nada**:
no hay pitazo que capturar porque el evento no existe en ninguna tabla de ESPN. Habriamos declarado
#181 resuelto con el 64% de los picks igual de muertos. La medicion "100% vs 2.3%" es la que salvo
el diseno.

**ORDEN CORRECTO DE TRABAJO (pendiente de decidir):**
1. Encontrar QUE generador emite `af:` y cerrarlo en origen (es la fuga viva, 2 picks hoy).
2. Decidir si los `af:` historicos se traducen a ID de ESPN (hay `evento_id_map`, sin medir todavia)
   o se marcan `sin_dato`. Nunca adivinar un resultado.
3. Solo despues, la captura al vuelo — que sigue siendo correcta, pero para los 24 con ID de ESPN.

**Sin tocar:** el archivador `archivar_marcadores` (cron `archivar-marcadores`, `40 * * * *`) y el
calificador v15 estan sanos. v15 ya lee `live_scores` U `marcadores_archivo` priorizando por estado.
No hay nada que arreglarles.

### #182 GRAVE (integridad del historial): los córners se califican contra los GOLES

Encontrado mientras media el rescate de #181. **Es mas grave que #181.**

`grade-oraculo-picks` normaliza el texto del pick y aplica una sola regex de totales:

```js
desc = desc.replace(/menos de/g,'under');
const underM = desc.match(/under\s*(\d+\.?\d*)/i);   // "corners under 11" TAMBIEN casa
if (underM) { const line = ...; if (total > line) return 'perdido'; ... }
//                                    ^^^^^ total = home_score + away_score = GOLES
```

No hay ninguna guarda de mercado. Un pick "Corners Under 11" entra por la rama de totales y se
compara contra los **goles** del partido. Como las lineas de corners (7-12) casi siempre estan por
encima del total de goles (0-4), casi todo "Under" se lee como ganado.

**Medido contra el dato real de corners** (`detalle_partido_espn`, 79 picks verificables):

| | Picks | % |
|---|---|---|
| Calificados verificables | 79 | 100% |
| Bien calificados | 31 | 39.2% |
| **MAL calificados** | **48** | **60.8%** |
| Dice GANO y en realidad perdio | 23 | |
| Dice PERDIO y en realidad gano | 20 | |
| Eran push (nulo) y se marcaron ganado/perdido | 5 | |

Ejemplos con el dato real enfrente:

| Partido | Pick | Goles | Corners reales | Se marco | Era |
|---|---|---|---|---|---|
| NY Red Bulls vs Nashville | Under 9 | 1 | **17** | ganado | **perdido** |
| Augsburg vs Schalke | Under 8 | 3 | **14** | ganado | **perdido** |
| Monaco vs Marseille | Under 9 | 2 | **12** | ganado | **perdido** |
| Fiorentina vs Frosinone | Under 10 | 3 | **13** | ganado | **perdido** |
| NY Red Bulls vs Philadelphia | Over 7 | 4 | **11** | perdido | **ganado** |
| Famalicao vs Gil Vicente | Under 9 | 0 | 9 | ganado | **nulo (push)** |

**Alcance:** 135 picks de corners ya calificados (68 ganado, 61 perdido, 6 nulo), desde el 4-mayo.
Ese historial falso alimenta el track record, la calibracion y `pick_learning_data`.

**Lo que casi hago mal (segunda vez el mismo dia).** Iba a proponer normalizar los IDs `af:` -> `af_`
para desatorar #181. Eso habria mandado **13 picks de corners mas** por esta misma rama rota, y
habria escrito 13 resultados falsos nuevos mientras celebrabamos el arreglo. **Cualquier
normalizacion de IDs debe excluir el mercado de Corners hasta que el calificador tenga guarda.**

**PASO 1 APLICADO (3-sep, v19 en produccion).** Guarda de mercado por LISTA BLANCA:

```ts
const MERCADOS_CALIFICABLES_CON_MARCADOR = new Set([
  'Over/Under','Moneyline','BTTS','Handicap','Double Chance','Draw No Bet',
]);
const TEXTO_DE_PROP = /\bcorner|esquina|\btarjetas?\b|\bamarillas?\b|\bcards?\b/i;
function mercadoEsCalificable(mercado, texto){
  if(!MERCADOS_CALIFICABLES_CON_MARCADOR.has(String(mercado||'')))return false;
  if(TEXTO_DE_PROP.test(norm(texto||'')))return false;   // norm() quita acentos
  return true;
}
```

Lista BLANCA y no negra a proposito: un mercado nuevo queda vetado por omision en vez de
calificarse mal en silencio. `Corners`, `Otro` y `Resultado Exacto` quedan fuera: el calificador
no tiene logica para ninguno.

**Las cuatro trampas que la medicion previa evito:**
1. **La columna `mercado` sola no basta**: 1 pick de corners vive con `mercado='Over/Under'`.
2. **El texto solo tampoco basta**: 3 de 154 con `mercado='Corners'` no dicen "corner".
3. **`card` habria vetado 47 Moneyline sanos**: todos son *St. Louis **Card**inals*. Por eso
   `\bcards?\b` con frontera de palabra (en JS si funciona; en Postgres no — eso fue #50).
   Y NADA de `roja`: **Estrella Roja** es un equipo.
4. **Acentos**: hay 3 picks que dicen "C**ó**rners" y `\bcorner` NO casa con eso. Se resolvio
   pasando el texto por el `norm()` que ya existia en el archivo.

**Se queda 'pendiente', NO 'sin_dato'**: `oraculo_calibracion` y las 3 vistas `ai_performance_*`
filtran por `resultado <> 'pendiente'`, asi que un valor nuevo entraria a esas metricas como
resultado consumado. Cambiar el vocabulario es un paso aparte, con auditoria de lectores.

**Verificacion:** diff puramente aditivo (45 lineas, 0 eliminadas, llaves balanceadas); 18 de 18
pruebas unitarias con textos REALES de la base; desplegada con `verify_jwt: false` explicito
(jobid 55, el cron de cada 15 min, NO manda Authorization — si se voltea a true la calificacion
muere en silencio); leida de vuelta desde produccion; y dos corridas post-deploy (19:07:01 del
cron y 19:07:37 manual) con HTTP 200 y `errors: 0`.

**Pillado en el acto:** el log de las 18:37, mientras trabajabamos en esto:
`[ORÁCULO/oraculo_picks_tracking] Neom SC vs Al Khaleej | Corners Under 11 | 3-0 → ganado`.
Ese 3-0 son GOLES. La hemorragia estaba activa.

**Caveat honesto:** la guarda todavia NO se ha ejercitado en produccion — ninguno de los 19 corners
pendientes tiene marcador final disponible ahora mismo (el unico que lo tenia, el del Neom, ya se
califico mal a las 18:37 bajo v18). Esta probada por inspeccion del codigo desplegado y por las 18
pruebas, no por un evento real todavia. El Paso 2 la va a ejercitar: 13 de los 37 picks que
desatora son de corners.

**Pendiente:** Paso 2 (normalizar `af:` -> `af_`, solo mercados de la lista blanca), Paso 3 (cerrar
el emisor de `af:`), Paso 4 (recalificar los 79 corners verificables contra `detalle_partido_espn`).

### #181 — CAUSA RAIZ CONFIRMADA: `af:` contra `af_`, un solo caracter

`evento_id_map` NO rescata nada: 0 de 37 cruzan, en ninguna de las dos formas. Pero el rescate
existe y es exacto — **el ID esta bien, la puntuacion no**:

| Tabla | IDs `af:` | IDs `af_` |
|---|---|---|
| `live_scores` | 0 | 261 |
| `marcadores_archivo` | 0 | 592 |
| `evento_id_map` | 0 | 134 |
| `picks` (apuestas reales del usuario) | 0 | 5 |
| **`oraculo_picks_tracking`** | **56** | 0 |
| **`analisis_partidos`** | **6** | 0 |

`af_` es la convencion de la casa. Solo las dos salidas del Oraculo escriben `af:`. Por eso las
apuestas reales del usuario SI se califican y las del Oraculo no.

Con la sustitucion `af:` -> `af_`, **37 de los 56 picks pendientes encuentran fila FINAL con
marcador** en `marcadores_archivo`. Los otros 19 siguen sin rastro. La prueba cruzada por
nombre+fecha da 24 de 37 eventos, cero ambiguos, coherente con la sustitucion (25 eventos).

**Pendiente:** cerrar el emisor de `af:` (2 picks hoy) y normalizar el historial — **excluyendo
Corners** por #182.

### #181 PASO 2 EJECUTADO: normalizacion `af:` -> `af_` (3-sep)

56 filas normalizadas, 0 quedaron con `af:`. Los picks pendientes que cruzan con un marcador final
saltaron de **1 a 38**. Calificador disparado: **28 calificados, 0 errores**.

| Mercado | Siguen pendientes | Ganados | Perdidos | Nulos |
|---|---|---|---|---|
| **Corners** | **19** | **0** | **0** | **0** |
| BTTS | 7 | 4 | 8 | 0 |
| Over/Under | 5 | 3 | 8 | 0 |
| Double Chance | 1 | 0 | 0 | 1 |

**LA GUARDA v19 (#182) PROBADA EN PRODUCCION.** 13 corners tenian marcador final disponible y
**ninguno se califico**. Log textual:

```
[ORÁCULO/oraculo_picks_tracking] SIN CALIFICAR (mercado no resoluble con marcador):
  Corners | [💰 PICK DE VALOR] Corners Under 8
```

Sin la guarda, esos 13 habrian entrado por la rama de goles y escrito 13 resultados falsos nuevos.

**OJO con las CTE:** el primer intento midio "antes y despues" en la misma sentencia y devolvio el
estado PREVIO en los conteos de despues. En una sola sentencia, los subqueries leen la instantanea
anterior al CTE que hace el UPDATE. Hay que volver a consultar en una sentencia aparte.

### #186 GRAVE: se califica contra un 0-0 IMPOSIBLE (MLB desde mayo)

Encontrado al auditar los 28 calificados del Paso 2 — apareció Titans vs Bears entre ellos y el
partido estaba congelado en `scheduled 0-0`.

| Veredicto | Liga | Picks | Ganado | Perdido | Desde |
|---|---|---|---|---|---|
| **IMPOSIBLE** | MLB | **15** | 4 | 11 | 23-may |
| **IMPOSIBLE** | NFL | **3** | 0 | 3 | 3-sep |
| plausible (futbol) | varias | 65 | — | — | — |

**Un partido de MLB no puede terminar 0-0** (se juegan entradas extra hasta que alguien gane) y uno
de NFL tampoco. Son **18 resultados falsos**. Los 65 de futbol son legitimos: ahi el 0-0 existe.

**Mi reverso NO sirvio y hay que decirlo:** puse los 3 de NFL en `pendiente` a las ~19:36 y el cron
(`7-59/15`) los re-califico a las **19:37:01**, un minuto despues, contra el mismo 0-0. **Mientras la
fila diga `final 0-0`, revertir el pick es inutil.** El arreglo va en el calificador, no en el dato.

**Guarda propuesta (NO aplicada, falta diff y luz verde):** en `grade-oraculo-picks`, no calificar
cuando el marcador final sea 0-0 y el deporte no admita 0-0 (NFL/MLB/NBA/NHL). Futbol se queda
calificable. Requiere agregar `liga` al select del pick o `deporte` al SEL de live_scores.

### #186 CERRADO: guarda v20 (plausibilidad 0-0) + los 18 revertidos

**v20 desplegada** con `verify_jwt: false` explicito. Diff aditivo, 17 de 17 pruebas unitarias.

```ts
const LIGAS_SIN_CERO_A_CERO    = /\b(nfl|mlb|nba|nhl)\b/i;
const DEPORTES_SIN_CERO_A_CERO = /americano|american football|beisbol|baseball|basquet|basketball|hockey/i;
function marcadorEsImposible(hs, as_, liga, deporte){
  if(hs !== 0 || as_ !== 0) return false;
  return LIGAS_SIN_CERO_A_CERO.test(norm(liga||'')) || DEPORTES_SIN_CERO_A_CERO.test(norm(deporte||''));
}
```

**Tres trampas que la medicion evito:**
1. **`deporte` solo habria atrapado 3 de 18.** Catorce picks de MLB no tienen deporte ni en
   `live_scores` ni en `marcadores_archivo`. Por eso `liga` es la señal principal (18 de 18).
2. **`⚾ Béisbol` lleva ACENTO.** Mi primera consulta busco `beis` y dio CERO contra un valor que si
   era beisbol. Se resuelve con `norm()`, misma trampa que "Córners" en la v19.
3. **"Copa América" no debe casar con "americano".** Probado explicitamente: no casa.

**Decision de diseño, al reves que la v19:** aqui es LISTA NEGRA, no blanca. Solo veta con
identificacion POSITIVA; un 0-0 sin señal se sigue calificando. Bloquear todo dejaria colgados los
65 empates a cero legitimos del futbol. El default seguro aqui es PERMITIR.

**Ademas:** hubo que agregar `deporte` al SEL de marcadores y `liga` a los dos selects de picks —
el calificador no pedia ninguno de los dos.

**PROBADO EN PRODUCCION.** Revertidos los 18 (15 MLB + 3 NFL) y disparado el calificador:
`graded: 0, errors: 0`. Log textual:

```
[ORÁCULO/oraculo_picks_tracking] SIN CALIFICAR (0-0 imposible en MLB): Under 8 Carreras
[ORÁCULO/oraculo_picks_tracking] SIN CALIFICAR (0-0 imposible en NFL): Over 37.5 Puntos
```

Veinte minutos antes, ese mismo cron los habia reescrito 60 segundos despues del reverso.

### #185 CAUSA RAIZ DE LOS ZOMBIS: el rescate YA EXISTE, cubre 4 ligas de 511

Leido `sync-ligamx/index.ts` (v73, `verify_jwt: false`, vive en Lovable). **`runLive` ya implementa
exactamente el rescate propuesto**: busca filas en `live`, pide `/fixtures?id=` una por una y cierra
con el marcador real. Pero esta acotado por dos filtros:

```ts
.in("liga_id", LIGA_IDS)                                   // solo 262, 848, 16, 253
.gte("fecha_utc", new Date(Date.now() - 6*3600_000)...)    // solo ultimas 6 horas
```

`LIGAS` son cuatro: Liga MX, Leagues Cup, Concachampions y MLS. Y `runLive` pide
`/fixtures?live=262-848-16-253`, asi que una liga fuera de esa lista **nunca recibe actualizacion en
vivo**. Por eso el partido de la Saudi Pro League quedo en el minuto 52.

| Cobertura | Filas | Marcadas `live` | Zombis | Ligas |
|---|---|---|---|---|
| **CUBIERTA por runLive** | 972 | **0** | **0** | 4 |
| **NO CUBIERTA** | 16,245 | 96 | **64** | **511** |

**Cero zombis donde el mecanismo aplica; los 64 estan en las 511 ligas que no cubre.** El mecanismo
funciona perfecto — simplemente no alcanza.

**NO es cuestion de ampliar la lista a 511 ligas:** pedir el feed en vivo de 511 ligas quemaria la
cuota de API-Football, y por eso alguien puso ese limite (los comentarios del codigo lo dicen). El
arreglo correcto es un rescate DIRIGIDO por `/fixtures?id=` para los eventos que importan
(los que tienen picks encima), sin importar la liga. Como los 64 zombis tienen **cero picks**, el
volumen es minimo.

### #183 TENIS: dos escrituras contradictorias y una apuesta ganada que casi no se cobra

**El caso.** Pick del usuario: Cerundolo Ganador vs Struff, 3,774 de apuesta. Cerundolo gano 3-2.
El pick llevaba 12 horas en `pendiente`. Causa: `live_scores` decia `status='live'` y
`status_detail='Final'` **en la misma fila**. El calificador exige `status='final'`.

**Alcance:** 10 partidos del US Open ese dia (7 WTA, 3 ATP), todos con marcador de sets completo.

**EL CULPABLE NO ERA EL ABSORBEDOR.** Empece a parchar `absorber_tenis_espn` y la medicion movio
el objetivo: el revert lo hace **`get-espn-matches`**, invocada por el cron `refresh-live-scores`
(`2-59/3`, **cada 3 minutos**). Evidencia por reloj:

| Momento | Evento |
|---|---|
| 19:17:00.409 | el pick se califica GANADO |
| **19:17:01.834** | **las 10 filas vuelven a 'live'** |
| 19:20:00 / 19:20:04.569 | corre el cron / revierte otra vez |

**La apuesta gano la carrera por 1.4 segundos.** `get-espn-matches` escribe las dos columnas en la
misma operacion y se contradice: `'Final'` en el detalle, `'live'` en el estado. Eso cierra los dos
hilos abiertos (quien revierte y quien escribe `status_detail`): son el mismo.

**CAPA 1 APLICADA: `trg_final_pegajoso`** (universal, todos los deportes). Bloquea
`final -> live/scheduled/pre/sin_confirmar`; **permite `final -> postponed`** (anula apuestas, no las
reabre); conserva el resto del UPDATE. Escotilla auditable:
`set local app.permitir_reabrir_final = 'on'`.
Vocabulario medido antes de escribirla: sin_confirmar 774, scheduled 686, pre 669, final 500,
live 38, postponed 1.
**PROBADA EN VIVO:** tras liberar los 10 partidos, `refresh-live-scores` escribio a las 19:26:01 y
los 10 siguieron en `final`.

**CAPA 2 PENDIENTE:** el diff de tenis en `get-espn-matches` (Lovable). Reglas: (1) nunca retroceder
de final; (2) si el detalle dice Final, el estado dice final; (3) un jugador con **3 sets ganados**
-> final (piso seguro: al mejor de 3 nunca se alcanza, asi que jamas cierra un partido vivo);
(4) `liga like 'WTA%'` con 2 sets -> final (WTA es siempre al mejor de 3; ATP no puede usarla por
los Grand Slam de 5 sets).

### #184 PUSH: un timeout de 5 segundos mataba TODAS las notificaciones

El usuario nunca recibio el aviso de su pick ganado. La cadena entera funcionaba menos el ultimo
salto: fila en `notificaciones` creada, `trg_notificacion_push` ACTIVO y disparado
(`push_disparada = true`), suscripcion activa registrada ese mismo dia. Pero:

```
Timeout of 5000 ms reached. Total time: 5000.178 ms (DNS time: 5000.178 ms)
```

**Los 5 segundos completos se iban resolviendo el DNS.** Medido en 2 horas de trafico real de pg_net:

| Resultado | Peticiones | Murieron en DNS |
|---|---|---|
| OK | 1,529 | 0 |
| **Timeout 5 s** (exclusivo de este trigger) | **30** | 10 |
| Timeout 30 s | 5 | 3 |
| Timeout 60 s | 1 | 1 |

Ninguna otra llamada del sistema usaba 5,000 ms. Sintoma acumulado: `push_log` con **5 intentos en
toda su historia**, el ultimo del 1-sep.

**APLICADO:** `timeout_milliseconds := 5000 -> 30000` por patron quirurgico con guarda de
ocurrencia unica. Verificado: no queda rastro del 5 s y conserva las dos guardas originales
(suscripcion activa y veto de parlays para no duplicar el push).

### #185 API-FOOTBALL: 64 partidos zombi que nunca cerraron

Encontrado al revisar por que un partido en vivo mostraba el minuto 52 cuando iba en el 68.
De 98 filas con `status='live'` en `ligamx_partidos`:

| Antiguedad | Partidos | Promedio sin refrescar |
|---|---|---|
| Menos de 2h (plausible) | 34 | 16 min |
| 6 a 24h (imposible) | 17 | 17 horas |
| **Mas de 24h (zombi)** | **47** | **75 horas** |

Misma enfermedad del tenis — *un partido que nunca llega a final* — en otra tuberia.

**Riesgo dimensionado antes de tocar nada (lo importante):**

| Medicion | Resultado |
|---|---|
| Picks del usuario pendientes sobre zombis | **0** |
| Picks del usuario totales | **0** |
| Picks del Oraculo pendientes | **0** |
| Filas de CLV | **0** |
| Espejados a `live_scores` | 3 |
| **Se ven "en vivo" en la app** | **0** |
| **Ya archivados con marcador FALSO** | **6** |
| Minuto promedio congelado | 47 |

**Cero exposicion de dinero.** El daño real son las **6 filas ya archivadas con un marcador de media
cancha** como si fuera final: eso alimenta calibracion e historico. Ligas afectadas: todas
secundarias (Copa Paulista, Liga Femenina, MLS Next Pro, USL, Primera B, Serie D, reservas).

**NO cerrar los 64 con el marcador congelado**: 62 de 64 estan congelados antes del minuto 85, asi
que marcarlos `final` inyectaria 62 resultados falsos al historico. Primero traer el marcador real
de API-Football (64 llamadas por id, barato), despues cerrar.

**Rezago aparte:** los 34 genuinamente vivos van ~16 min atrasados. `ligamx-live-2min` corrio 6
veces en 30 min, todas exitosas, y el presupuesto de API-Football permite llamar. El cron dispara y
el dato no llega: sin diagnosticar todavia.

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

---

## #187 DINERO: un pick GANADO se califico como PERDIDO. Seis copias del mismo razonamiento

**Reportado por el usuario en vivo.** Pick: Al Qadisiyah Resultado Final, $870 @1.90,
Al Diriyah 0-2 Al-Qadisiyah FC. La visita gano. El calificador lo marco `perdido`, -$870.
Corregido a `ganado`, +$783.00.

### La cadena completa

1. `evaluar_leg_parlay_v1` tenia el razonamiento "a que lado apunta este pick" escrito
   **SEIS veces**, con 18 llamadas inline a `match_team`. Cada copia de una epoca distinta:
   - 2 bloques con piso `confidence >= 0.9` (los de tenis)
   - 3 bloques con guarda `IS DISTINCT FROM` (tenis x2 + avance)
   - **3 bloques con NINGUNA de las dos**: moneyline, doble oportunidad y hándicap
2. `match_team('Al Diriyah')` y `match_team('Al-Qadisiyah FC')` devolvian **AMBOS**
   `Al Qadisiyah`. La rama de moneyline comparaba pick vs local primero y ganaba por orden:
   **devolvia el resultado del LOCAL sin importar a quien apuntara el pick.**
3. Causa del alias envenenado: **`Al Diriyah` no existia en `team_aliases`**. Sin fila exacta
   cayo a la capa 3 de `match_team`, que acepta cualquier similitud > 0.3 **sin exigir
   separacion con el segundo candidato** (la capa 1c si la exige). Aterrizo en `Al Qadisiyah`
   con confianza **0.333**.

### El bug cortaba en los dos sentidos
Con el local ganando 2-0, el mismo pick a la visita salia **`ganado`**. No solo restaba
dinero: fabricaba victorias falsas que envenenan el track record y la calibracion.

### Por que un parche no servia
Ponerle guardas a mano a los 3 bloques sueltos dejaba vivas las seis copias. El problema
no era una guarda faltante: era **la ausencia de la abstraccion**.

### Solucion aplicada
- **`public.lado_del_pick(pick, home, away, liga) -> 'local' | 'visita' | NULL`**: unica
  fuente de verdad. Capa 1 alias con **exclusividad obligatoria** (local y visitante deben
  resolver a nombres distintos) y **contraste contra el puntaje por tokens** (si las dos
  senales se contradicen, NO se adivina). Capa 2 tokens con ganador estricto. Capa 3 NULL.
- `evaluar_leg_parlay_v1` reescrita: 18 llamadas a `match_team` -> **6 llamadas al
  resolvedor**. De 15,452 a 13,571 caracteres.
- Respaldo del comportamiento viejo en `evaluar_leg_parlay_v1_pre20260903`.
- 7 alias nuevos en `team_aliases`: `Al Diriyah` (no existia), `Al Qadsiah` (grafia de ESPN)
  y `Al-Qadisiyah FC` (grafia de API-Football) — las tres formas del mismo club.

### MEDIDO, no supuesto
- **NO existe piso de confianza que sirva**: el alias envenenado venia a 0.333 y alias
  legitimos vienen a 0.467 (Napoles->Napoli), 0.626 (Aris) y 0.700 (PSG). Un piso alto tira
  los buenos, uno bajo deja pasar el malo. **La defensa es la exclusividad, no el piso.**
- Corpus de **354 patas** (picks + patas de parlay, contra el marcador real):
  **1 cambia** (la del usuario, perdido -> ganado), 0 pierden cobertura, 0 ganado->perdido.
- Primer intento con piso 0.9: perdia 5 patas legitimas (Napoles, PSG, Inter Milan). El
  corpus lo cazo antes de tocar produccion.
- Segundo error propio: mi regex esperaba un espacio simple donde el codigo tenia salto de
  linea, y dejo un resto `AND v_pick_espn IS DISTINCT FROM v_away_espn` con la variable ya
  sin asignar. `NULL IS DISTINCT FROM NULL` es FALSE -> 3 patas de "Se clasifica" muertas.
  Tambien lo cazo el corpus.

### HALLAZGO SISTEMICO PENDIENTE
**1,246 de 1,877 equipos vistos en 30 dias (66%) NO tienen fila exacta en `team_aliases`.**
Cada uno puede producir la misma colision difusa. El resolvedor ya los protege (devuelve
NULL en vez de adivinar), pero un pick sobre ellos se queda `no_evaluable` en vez de
calificar. Falta poblar el vocabulario.

### Segundo frente: el duplicado del partido
El mismo partido existia DOS veces: `401900372` (ESPN, `Saudi Pro League`, fresco) y
`af_1603010` (API-Football, `Pro League`, congelado 21 min en el 82').
**La hipotesis de que faltaba el slug `ksa.1` era FALSA**: `get-espn-matches` no tiene
catalogo fijo, lo lee de `ligas_master`, y `soccer/ksa.1` ya estaba activa. El duplicado se
creo porque el escaner no pudo cruzar el boleto con el evento de ESPN: **el club se llama de
tres formas distintas** (`Al Qadsiah` en ESPN, `Al-Qadisiyah FC` en API-Football,
`Al Qadisiyah` en el boleto) y ninguna estaba en `team_aliases`. Con los 7 alias nuevos,
`lado_del_pick` ya resuelve `visita` contra las dos filas.

### Tercer frente: PENDIENTE (frontend)
`ActivePicksTab.tsx` tiene el mismo defecto estructural: el razonamiento de "que lado" esta
escrito **6 veces** (`split(/\s+/).filter(w => w.length > 2)` en 12 lineas). Con
`Al-Qadisiyah FC` el token queda `al-qadisiyah` y nunca casa con `Al Qadisiyah` del pick ->
`getPickStatus` devuelve `"pending"` -> paleta ambar. **El rojo que vio el usuario nunca
significo "vas perdiendo": significaba "no se".** Afecta a 217 de 3,046 nombres de equipo.
Falta: un solo helper de tokenizacion usado en las 12 lineas.

## Leccion nueva
12. **Cuando una funcion tiene el mismo razonamiento escrito N veces, contar cuantas copias
    tienen cada guarda.** 3 con guarda y 3 sin ella no es un bug: es la firma de que falta
    una abstraccion, y garantiza que el bug volvera por otra copia.
13. **Antes de cambiar una funcion de dinero, correrla contra TODO el historico y comparar
    veredicto viejo vs nuevo.** Ese corpus caza tanto el bug ajeno como el propio: aqui
    encontro dos errores mios antes de que tocaran produccion.
14. **Un piso de confianza no defiende contra una coincidencia difusa: la exclusividad si.**
    Medir la distribucion real de confianzas antes de elegir un umbral; aqui el dato malo y
    los buenos estaban entrelazados y NINGUN umbral los separaba.

---

## #188 Vocabulario: sembrados los 50 equipos de mas peso. El hueco NO era exotico

Medido: de los 50 equipos sin alias con mas volumen, **26 son la plantilla completa de MLB**
(Yankees, Dodgers, Braves, Mets...) con 130-166 picks del Oraculo cada uno. Le siguen NHL,
WNBA y MLS. El hueco no era una cola larga de clubes raros: **las ligas americanas nunca se
sembraron en `team_aliases`**. Hoy funcionaban por suerte — sus nombres son limpios y
distintos, asi que la capa de tokens los resolvia sola. Dependian de la suerte.

Sembrados los 50 con mapeo IDENTIDAD (`bookie_name = espn_name`), que solo puede ayudar:
entra por la capa 1a exacta a confianza 1.0 y evita que las capas difusas se activen.

**Verificado despues de sembrar**: corpus de 354 patas, **0 cambios**. Agregar filas a
`team_aliases` mueve el espacio de busqueda de las capas 3 y 4 (trigram), asi que el corpus
NO es opcional aqui.

Quedan **2,510 de 3,039** equipos vistos en 120 dias sin alias exacto.

## #189 Las 771 filas `sin_confirmar` son basura de tenis, NO partidos por cerrar

El plan inicial era marcarlas `final`. **La medicion lo desmonto:**

```
sin_confirmar   771 filas   761 con 0-0   picks vivos: 0   ultimo toque: 9-jun
scheduled       216 filas   212 sin marcador                picks vivos: 7
pre               4 filas                                    picks vivos: 0
postponed         1 fila                                     picks vivos: 0
```

Marcarlas `final` habria creado **761 partidos que "terminaron 0-0"**, y el calificador
resolveria Over/Under como under, moneyline como empate y BTTS como no. Es el bug #186
exacto, multiplicado por 761. Y no habia nada que ganar: **cero picks vivos encima**.

Que son en realidad: TODAS son tenis (Ilkley, Hertogenbosch, Davis Cup, W15 Madrid,
M25 Varnamo...), todas del 9-10 de junio, sin tocarse desde entonces. Es una sola corrida
de ingesta que escribio cada partido del cuadro como `sin_confirmar 0-0`. Enlaza con #120.
**Se borran, no se cierran.**

## Leccion nueva
15. **"Destrabar" un estado atorado NO es empujarlo al estado terminal.** Antes de mover un
    estado, medir DOS cosas: que contiene la fila (761 de 771 traian 0-0) y quien depende de
    ella (cero picks vivos). Si no hay dependiente, no hay nada que destrabar; y si el
    contenido es falso, empujarlo a terminal convierte basura inerte en dato activo que
    envenena calificaciones.
16. **Sembrar alias exige re-correr el corpus.** `match_team` tiene capas de trigram: cada
    fila nueva cambia el vecindario de TODAS las busquedas difusas, no solo la del equipo
    sembrado.

---

## #190 Rotacion de llaves: los 5 crons con JWT pegado eran `anon`, no `service_role`

Al abrir el panel se vio el cuadro real. **La suposicion de que faltaba rotar la
`service_role` era incompleta.**

### Lo medido
- La llave que usan los 56 crons es `sb_secret_...irMwr` = la nombrada **`backend`** en el
  panel. Las otras dos (`default`, `regeneratedapikey`) no tienen uso detectable.
- **5 crons activos traian un JWT pegado dentro del comando**, y al decodificar el payload
  los cinco resultaron ser **`anon`**, no `service_role`:
  145 recalibrate-model-weights-monday, 148 pre-analizar-fut-diario,
  216 sync-fixtures-index (cada 30 min!), 245 nfl-player-stats-enrich-diario,
  323 autopsia-picks-nocturna.
- **EL FRENTE MAS PELIGROSO**: `.env` de Lovable trae
  `VITE_SUPABASE_PUBLISHABLE_KEY="eyJhbGciOi..."` — el nombre dice PUBLISHABLE pero el
  contenido es el **JWT `anon` heredado**. El boton "Disable JWT-based API keys" apaga
  `anon` Y `service_role` a la vez: presionarlo habria dejado la app sin cargar nada,
  para todos, al instante.

### Aplicado
Los 5 crons migrados a la convencion unica de los otros 51:
`headers := jsonb_build_object('Authorization', 'Bearer ' || public.sk(), 'Content-Type', 'application/json')`
Verificado: **0 crons con JWT pegado, 56 con public.sk()**.

Cambio extra declarado: `pre-analizar-fut-diario` tenia `timeout_milliseconds := 1000`
(UN segundo, misma clase que el push de #184). Subido a 30000.

### Caso curioso: el cron 323 leia la llave de OTRO cron
`'Bearer '||(select (regexp_match(command,'Bearer (eyJ...)'))[1] from cron.job where jobid=20)`
El cron 20 ya no tiene Bearer JWT, asi que esa subconsulta devolvia NULL y la cabecera
salia nula. **NO estaba roto**: `ai_autopsias` tiene 1,212 filas y la ultima es de hoy.
Funcionaba porque esa edge function no exige autenticacion. Funcionaba por accidente.

### Secuencia pendiente (pasos 2 y 4)
2. Cambiar el `.env` de Lovable al publishable real `sb_publishable_...` + que Lovable
   haga `rg SUPABASE_ANON_KEY supabase/functions/` para cerrar el ultimo hueco.
3. Desplegar frontend.
4. **EL USUARIO** presiona "Disable JWT-based API keys".

Medido para el paso 3: 129 edge functions, 24 con `verify_jwt=true`. Las de cron ya van
por `public.sk()`; las del navegador van con la sesion del usuario. Ninguna de esas dos
familias depende del JWT heredado. Falta solo el grep de `SUPABASE_ANON_KEY`.

## Leccion nueva
17. **El nombre de una variable de entorno no dice que contiene.**
    `VITE_SUPABASE_PUBLISHABLE_KEY` guardaba un JWT `anon`. Antes de revocar cualquier
    credencial, leer el VALOR de cada consumidor, no su etiqueta.
18. **Decodificar el payload de un JWT dice su rol sin exponer el secreto.** El
    `role` vive en el segundo segmento en base64; la firma queda intacta. Sirve para
    auditar sin que la llave entre nunca al contexto.

---

## #191 BLOQUEADOR del paso 4: `isServiceToken()` solo entiende JWT, no la llave nueva

Cazado por un rastro de 401 cada 15 minutos en `net._http_response`.

### La cadena
1. `reanalisis-alineaciones` (jobid 341, `3-59/15`) llama a
   `disparar_reanalisis_prepartido()`, que **SI manda bien** la cabecera:
   `'Authorization','Bearer '||public.sk()`.
2. `public.sk()` devuelve la llave nueva `sb_secret_...`.
3. `analizar-partido` la rechaza con `{"error":"No autorizado"}` (401) desde su PROPIO
   codigo, no desde la puerta de enlace.

### La causa exacta
```ts
function isServiceToken(token: string): boolean {
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (service && token === service) return true;      // el JWT heredado
  try {
    const payload = JSON.parse(atob(token.split(".")[1]));
    return payload?.role === "service_role";          // decodifica un JWT
  } catch { return false; }
}
```
Las DOS ramas asumen JWT. Una llave `sb_secret_` no es igual a la variable
`SUPABASE_SERVICE_ROLE_KEY` (que guarda el JWT viejo) y no tiene segmentos que
decodificar: el `atob` truena, cae al catch, devuelve false, `requireCaller` lanza
`unauthorized`.

### Por que bloquea el paso 4
`requireCaller` es un helper COMPARTIDO. Cada edge function que lo importe rechaza a
los crons igual. Al apagar los JWT heredados, `SUPABASE_SERVICE_ROLE_KEY` deja de ser
valida y la primera rama tampoco sirve: quedan TODAS esas funciones inalcanzables para
los crons. Falta medir cuantas la importan.

### El arreglo NO es `token.startsWith("sb_secret_")`
Eso aceptaria cualquier cadena con ese prefijo — un hoyo de seguridad. Tiene que
comparar contra el VALOR conocido de la llave, desde una variable de entorno.

### Efecto colateral ya medido
El reanalisis prepartido con alineaciones (#69, #136) lleva rebotando en 401 cada 15
minutos. Se "arreglo" dos veces y volvio a morir por una causa distinta cada vez.

## Otros hallazgos de la misma barrida
- **25 de 67 crons activos que hacen HTTP no declaran `timeout_milliseconds`** y heredan
  los **5 segundos por omision de pg_net**. Es la version sistemica del #184: aquel push
  era una instancia. Medido: 46 timeouts de 5 s en 24 h (2.6% de 1,749 respuestas).
- **818 respuestas 404 `"No stats found"` en 24 h** contra una API externa. No es fallo
  nuestro, pero son 818 llamadas desperdiciadas al dia.
- Verificado que la migracion de los 5 crons funciona: `sync-fixtures-index` corrio a las
  20:54:00 con la llave nueva y devolvio HTTP **200** con
  `{"ok":true,"ligas_consultadas":55,"eventos":605,"guardados":605}`.

## Leccion nueva
19. **`succeeded` en pg_cron NO significa que la peticion funciono.** Solo dice que se
    despacho. La verdad esta en `net._http_response.status_code`. Verificar ahi SIEMPRE.
20. **Un helper de autenticacion compartido concentra el riesgo de una rotacion de
    llaves.** Antes de rotar, buscar quien decide "esto es una llamada interna" y
    confirmar que entienda el formato nuevo.

---

## #192 Auditoria completa: SIETE dependencias del JWT heredado. El paso 4 sigue bloqueado

Lovable corrio `rg -n "SUPABASE_ANON_KEY|ANON_KEY|eyJhbGciOi" supabase/functions/ src/`.
Con eso la lista quedo cerrada.

### Se rompen si se apagan los JWT heredados (7)
| # | donde | como depende |
|---|---|---|
| 1 | `_shared/auth.ts` `isServiceToken()` | no entiende `sb_secret_`; rechaza a TODOS los crons (#191) |
| 2 | `oraculo-diario/index.ts:12` | `Deno.env.get("SUPABASE_ANON_KEY")!` |
| 3 | `oraculo-cron/index.ts:12` | `Deno.env.get("SUPABASE_ANON_KEY")!` |
| 4 | `analizar-partido/index.ts:3821-3822` | JWT anon escrito a mano |
| 5 | `WrappedStories.tsx:5` | JWT anon escrito a mano |
| 6 | `LiveDayTab.tsx:27` | JWT anon escrito a mano |
| 7 | `AnalysisTab.tsx:523-524 y 566-567` | JWT anon escrito a mano, DOS veces |

### Falsos positivos (no tocar)
`sharp-api.ts`, `reto13m-api.ts` y `ShareAnalysisButton.tsx` declaran una variable LOCAL
llamada `SUPABASE_ANON_KEY` pero la llenan con `VITE_SUPABASE_PUBLISHABLE_KEY`. El nombre
engana; la dependencia no existe. Es el mismo patron que `VITE_SUPABASE_PUBLISHABLE_KEY`
guardando un JWT: **el nombre no dice el contenido**.

### Sospecha por confirmar
En `AnalysisTab.tsx:566` el payload en base64 dice `cm9sZCI6ImFub24i` (`rold":"anon"`)
mientras el de la linea 523 dice `cm9sZSI6ImFub24i` (`role":"anon"`). Si eso es literal,
ese JWT esta CORRUPTO y esa llamada ya venia fallando. Verificar antes de migrarla.

### Ya hecho en este paso
- `.env` migrado a `sb_publishable_2dJSFM1GRifrxzJdLqRJvQ_QZn75jkg` (VERIFICADO por mi,
  leyendo el archivo, no el reporte).
- `client.ts` ahora lee `import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY`; **tenia el JWT
  escrito a mano** y se quito. Ese respaldo habria hecho que el fallo apareciera solo en
  algunos usuarios.
- `bunx tsgo --noEmit` limpio; vista previa carga.

---

## #193 CERRADO el 401: eran DOS llaves distintas, no un bug de codigo

La especificacion inicial decia "arregla `isServiceToken()` comparando contra
`SUPABASE_SERVICE_ROLE_KEY`". **Habria reescrito codigo de autenticacion sano y los 401
habrian seguido igual.** Una sonda temporal de 3 minutos desmonto TRES de los siete
puntos del plan.

### Lo que revelo la sonda (solo formato y longitud, nunca valores)
```
SUPABASE_SERVICE_ROLE_KEY: existe, largo 41, formato "sb_secret_"      <- YA es la nueva
SUPABASE_ANON_KEY:         existe, largo 46, formato "sb_publishable_" <- YA es la nueva
SUPABASE_SECRET_KEY:       no existe
```
**Supabase ya habia migrado las variables de entorno solo.** Los nombres siguen diciendo
SERVICE_ROLE y ANON, pero adentro viven las llaves nuevas. Por eso `oraculo-diario` y
`oraculo-cron` NUNCA estuvieron en riesgo: falsos positivos.

### La causa real
Hay TRES llaves secretas en el proyecto. Los dos lados usaban distintas:
| quien | llave |
|---|---|
| los 56 crons, via `public.sk()` (vault, `service_role_key`) | `sb_secret_...irMwr` = "backend" |
| las edge functions, via `SUPABASE_SERVICE_ROLE_KEY` | `sb_secret_...Jak1k` = "default" |

`token === service` comparaba `irMwr` contra `Jak1k`. Fallaba, caia al `atob`, tronaba,
y devolvia 401. **Cero lineas de codigo malas.**

### Arreglo
El usuario apunto el vault a la llave "default" desde SU propio SQL Editor
(`vault.update_secret`), sin que la llave pasara nunca por el chat.
Verificado: `substr(public.sk(),11,5)` = `Jak1k`.

### Verificado SIN esperar al cron
Llamada forzada a `analizar-partido` con `Bearer public.sk()` y cuerpo vacio:
```
HTTP 400 {"error":"espn_event_id or apifootball_fixture_id, and liga are required"}
```
Error de VALIDACION, no de autenticacion. La peticion paso `isServiceToken()`.
Antes devolvia `401 {"error":"No autorizado"}`.

### Tambien verificado contra produccion (no contra el reporte de nadie)
- `analizar-partido` v492, desplegada 21:05:56: **0 ocurrencias de `eyJhbGciOi`**,
  2 usos de la variable de entorno, `verify_jwt: false` intacto.
- `.env` y `client.ts`: sin JWT. El cliente TENIA uno escrito a mano como respaldo.

### Pendiente de limpieza
Borrar del panel la sonda `probe-envvars-tmp` (ya neutralizada, devuelve 410).

## Leccion nueva
21. **Una sonda temporal cuesta menos que un arreglo equivocado.** Tres minutos de
    medicion desmontaron 3 de 7 puntos y evitaron reescribir autenticacion sana.
22. **Editar un archivo de edge function en el repositorio NO la despliega.** Verificar
    siempre contra la funcion VIVA (`get_edge_function`), no contra el repo ni contra el
    reporte de quien la edito.
23. **Cuando un proyecto tiene varias llaves del mismo tipo, "la llave correcta" es una
    pregunta empirica.** Aqui habia tres `sb_secret_` y cada lado uso una distinta.

---

## #194 La pestaña RETO 13M no cargaba: underflow de exp(), NO la migracion de llaves

El usuario abrio la app despues del publish y la pestaña RETO 13M mostro
"No se pudo cargar". Estabamos a un clic de apagar las llaves heredadas.

### Lo que se descarto primero, midiendo
- **El porton de Supabase SI acepta la llave publishable como `Authorization: Bearer`**:
  llamada a `leaderboard-roi` con la publishable → **HTTP 200**. La hipotesis de que la
  publishable no servia como Bearer era FALSA.
- `mi-track-record` con la publishable da 401, pero eso es correcto: pide el token de
  sesion del usuario y yo no mande ninguno.
- Los dos helpers nuevos de `ActivePicksTab` (`teamWords`, `normalizeComparable`) estan a
  nivel de modulo, asi que se izan: no hay error de orden.

### La causa real
`reto_13m_estado()` → `reto_probabilidad_meta()` → `ERROR 22003: value out of range: underflow`

```sql
v_p_meta := exp(public.log_phi((-v_b + v_mu*v_apuestas)/v_raiz))   -- SIN tope
          + exp(greatest(least(v_l2, 0), -700));                    -- CON tope
```
La segunda `exp()` de la MISMA sentencia esta acotada a -700; a la primera se le olvido.
Medido con los datos reales del usuario:
```
argumento          = -39.9052
log_phi(-39.9052)  = -800.82
exp(-800.82)       → underflow (el limite de float8 esta cerca de -745)
```
En PostgreSQL `exp()` sobre float8 NO devuelve cero al desbordar por abajo: lanza error.

### Arreglo
Mismo tope que ya tenia la exp() de al lado, en las dos ramas (meta y piso).
`exp(-700) = 9.9e-305`: cero a efectos de una probabilidad, asi que no cambia ningun
numero mostrado; solo evita el crash. Aplicado con guarda de ocurrencias (1 y 1).
Verificado: `reto_13m_estado('rodelcast')` ya devuelve el resumen completo.

### PENDIENTE relacionado (no urgente)
Ese `mu` y ese `sigma` salen de **2 picks** en `reto_picks_mostrados`. De ahi salen
`ritmo_semanal_pct: 453.40` y `semanas_para_la_meta: 4`. Con n=2 eso no mide nada y la
pantalla lo presenta como si midiera. Mismo patron que las lecciones 8 y 10.

## Leccion nueva
24. **Cuando una sentencia tiene la misma operacion dos veces y solo una lleva guarda,
    la que no la lleva es el bug esperando fecha.** Aqui las dos `exp()` estaban en la
    MISMA asignacion, una acotada y la otra no.
25. **Un fallo que aparece justo despues de un cambio grande no viene necesariamente de
    ese cambio.** Habriamos revertido la migracion de llaves por un underflow de
    coma flotante que llevaba tiempo esperando el dato adecuado.

---

## #195 BOTON PRESIONADO. Migracion de llaves CERRADA y verificada

Verificacion a los 25 minutos del clic en "Disable legacy API keys":
```
respuestas 2xx ................... 187
401 reales ....................... 0   (los 2 que aparecen son mis propias pruebas)
crons fallidos ................... 0
filas de marcador tocadas en 10min 471   -> la ingesta sigue viva
picks pendientes ................. 0
```
Tambien medido despues del apagado, con la llave publishable:
- `/auth/v1/settings` -> **200**
- `rpc apodos_por_reclamar` -> **200**, devuelve `[]`
- `leaderboard-roi` -> **200**

**#63 y #190 quedan cerrados.** La llave heredada ya no existe y nada depende de ella.

### Falsa alarma: "Servidor lento o caido"
El banner de `LoginScreen.tsx` sale con `authDegraded || servidorLento`, y `servidorLento`
se prende cuando `supabase.rpc("apodos_por_reclamar")` **da error O tarda mas de 8s**.
Esa RPC responde 200 y tiene los permisos correctos (SECURITY DEFINER, anon con EXECUTE).
Era la instancia de la app que el usuario tenia abierta ANTES del clic: su sondeo quedo
atrapado en la transicion. **El mensaje culpa al "servicio de cuentas" cuando lo unico que
sabe es que UNA rpc no contesto en 8 segundos.** Mal diagnostico por mensaje generico.

---

## #196 Cuatro arreglos de pantalla reportados por el usuario (MEDIDOS)

**1. "Casa" / "Fuera" en LOS ULTIMOS PARTIDOS** -> quiere emojis 🏠 y ✈️. Cosmetico.

**2. CLIMA muestra "46 ft"** -> es `altitud_ft`, un campo de las vistas de **MLB y NFL**
(`v_juego_clima`, `v_juego_clima_nfl`). En un partido de la Superliga danesa la pantalla
esta leyendo la fuente equivocada. **El clima de futbol SI existe y esta fresco**:
`futbol_clima_hora` tiene 8,976 filas, 48 estadios, 7,920 de las ultimas 24 h y pronostico
hasta el 9-sep, con temp_f, viento_mph, viento_dir, humedad y lluvia_mm.
Es el mismo patron del #97: **dos vocabularios para la misma idea** y la pantalla toma el
que no es. Residual del #144.

**3. FAVORITOS muestra partidos ya terminados.** El dato esta BIEN:
```
401874523  F.C. Kobenhavn - FC Nordsjaelland   final FT
401879020  KAA Gent - OH Leuven                final FT
401900372  Al Diriyah - Al Qadsiah             final FT
```
Las tarjetas hasta dicen "post" en la esquina. **La pantalla no los filtra.** Frontend.

**4. Alerta "el modelo opina de un equipo que no conoce" (Manchester United vs Sabah FK)**
-> **NO es un bug: es la guarda del #108 funcionando.** Verificado: no existe ningun pick
en `oraculo_picks_tracking` para ese partido. El modelo formo una opinion, la guarda la
detuvo, y nada salio. La alerta es el sistema avisando, no fallando.

## Leccion nueva
26. **Un mensaje de error generico manda a diagnosticar al lugar equivocado.**
    "El servicio de cuentas no esta respondiendo" en realidad significaba "una rpc tardo
    mas de 8s". Estuvimos a punto de revertir la migracion de llaves por eso.

---

## #197 REVERTIDO el apagado de llaves heredadas: dejaba al usuario FUERA de su cuenta

Al presionar "Disable legacy API keys" la app dejo de reconocer la sesion del usuario y
lo mando a la pantalla de "Tu cuenta esta creada. Falta elegir tu apodo", como si fuera
nuevo. El usuario rehabilito las llaves y volvio a entrar. Nada se perdio: el perfil
`rodelcast` sigue intacto con su cuenta ligada y bankroll inicial 5,000.

### La causa
```
usuarios -- permisos por rol
authenticated  SELECT, INSERT, UPDATE, DELETE
service_role   idem
anon           NINGUNO
```
Las politicas RLS estan bien: `"Users read own profile" SELECT {authenticated}
user_id = auth.uid()`. El problema es que la peticion **dejaba de llegar como
`authenticated` y llegaba como `anon`**: al apagar los JWT heredados, **las sesiones de
usuario YA ABIERTAS dejan de ser validas** — el token fue emitido bajo el esquema viejo,
el proyecto ya no lo reconoce, y PostgREST degrada la peticion a anonimo. De ahi el
`permission denied for table usuarios`, el perfil no encontrado y el `needsProfile=true`.

### EL HUECO FUE MIO
Verifique, uno por uno y contra produccion:
- los 56 crons con la llave nueva -> 200
- las edge functions y su `verify_jwt`
- el `.env` y el `client.ts` del frontend
- el porton con la llave publishable (`leaderboard-roi` -> 200)
- `/auth/v1/settings` -> 200
- `rpc apodos_por_reclamar` -> 200

**Nunca probe que una SESION DE USUARIO YA EXISTENTE siguiera siendo valida.** Probe todas
las credenciales de maquina y ninguna de persona. Ese era el unico camino que el usuario
iba a recorrer.

### Riesgo evitado por poco
La pantalla ofrecia "CREAR MI CUENTA" con el apodo vacio. Si el usuario la hubiera usado,
`registrar_perfil` le habria creado un SEGUNDO perfil y partido su historial y su bankroll
en dos. Se le advirtio a tiempo.

### Camino correcto para completar la migracion (PENDIENTE)
1. (hecho) Rehabilitar las heredadas para recuperar el acceso.
2. Cerrar sesion DESDE DENTRO de la app y volver a entrar: el token se reemite bajo el
   esquema nuevo.
3. **Verificar con esa sesion nueva** que la peticion llega como `authenticated` y que
   `usuarios` responde.
4. Solo entonces apagar las heredadas otra vez.
Ojo: esto aplica a TODOS los usuarios con sesion abierta, no solo al dueno.

### Estado tras revertir (verificado)
```
llave de los crons ......... Jak1k (la alineada)
crons fallidos 15min ....... 0
respuestas 2xx 15min ....... 88
401 reales ................. 0  (los 2 del log son mis pruebas sin sesion)
marcadores tocados 10min ... 681
perfiles ................... 3, intactos
```

## Leccion nueva
27. **Probar credenciales de MAQUINA no prueba credenciales de PERSONA.** Verifique seis
    caminos distintos con llaves de servicio y publishable, y el unico que importaba para
    el usuario -su sesion ya abierta- no lo probe nunca. Antes de rotar credenciales,
    la lista de verificacion tiene que incluir "una sesion de usuario existente sigue
    entrando", no solo "los servicios se hablan entre si".
28. **Una pantalla de recuperacion puede ser mas peligrosa que el fallo.** El fallo dejaba
    al usuario fuera; el boton "CREAR MI CUENTA" que la app le ofrecia habria partido su
    historial en dos. Cuando algo falla en autenticacion, revisar QUE le esta ofreciendo
    la interfaz al usuario en ese estado.

---

## #198 Los cuatro puntos de pantalla: tres mandados a Lovable, uno resultó no ser bug

### 1. "Casa"/"Fuera" -> 🏠 / ✈️
Cosmetico. Mandado a Lovable con `aria-label` para no perder accesibilidad.

### 2. CLIMA mostraba "46 ft" — CAUSA MEDIDA
Son 46 PIES: el campo `altitud_ft` de las vistas de **MLB y NFL**
(`v_juego_clima`, `v_juego_clima_nfl`), leido en un partido de la Superliga danesa.
El clima de futbol vive en `futbol_clima_hora` (estadio, hora_utc, temp_f, viento_mph,
viento_dir, humedad, lluvia_mm) y **nadie lo pedia**. Mismo patron del #97: dos
vocabularios para la misma idea y la pantalla toma el que no es.

**Creada `public.v_futbol_clima_partido`** para que el frontend tenga UNA fuente:
cruza `live_scores -> partido_sede -> futbol_clima_hora` tomando la hora mas cercana al
saque (+/- 90 min), expone `altitud_ft` por separado y marca `hay_clima` booleano.
Devuelve NULL cuando no hay dato, para que la pantalla diga "sin dato" en vez de inventar.

**MEDIDO al construirla — la cobertura es el problema de verdad:**
```
partidos de futbol proximos 7 dias .... 235
con sede conocida ..................... 142
CON CLIMA .............................  42  (17.9%)
estadios en el recolector .............  48 de 213 conocidos (23%)
```
La plomeria queda resuelta; **la cobertura es otro trabajo**: el recolector de clima solo
cubre 48 estadios. "Sin dato" va a ser el estado COMUN, no la excepcion, y asi se le dijo
a Lovable para que lo diseñe como estado normal y no como error.

### 3. FAVORITOS mostraba partidos terminados
El dato esta BIEN (`final`/`FT` los tres); la pantalla no filtra. Instruccion explicita:
**filtrar por ESTADO, no por reloj** — un partido puede empezar tarde o irse a tiempo
extra y desapareceria estando vivo. Conjunto explicito de estados terminales porque en
esta base el campo tiene varias grafias.

### 4. "El modelo opina de un equipo que no conoce" — NO ES BUG
`modelo_opina_sin_datos | Manchester United vs Sabah FK`. **Es la guarda del #108
funcionando.** Verificado: no existe NINGUN pick en `oraculo_picks_tracking` para ese
partido. El modelo formo una opinion, la guarda la detuvo, y nada salio. La alerta es el
sistema avisando, no fallando.

## PENDIENTE nuevo
**Cobertura del clima de futbol: 48 de 213 estadios.** Ampliar el recolector, o al menos
priorizar los estadios de las ligas donde de verdad se apuesta.

## Leccion nueva
29. **Antes de arreglar una pantalla que muestra el dato equivocado, medir cuanto dato
    BUENO hay.** Aqui la fuente correcta existe y esta fresca, pero solo cubre el 17.9%
    de los partidos: si no se mide, se arregla la lectura y el usuario ve "sin dato" en 8
    de cada 10 partidos sin entender por que.

---

## #199 "+445.8%/sem" y "0.1 anios a la meta": la pantalla extrapola desde 1.2 DIAS

El usuario dijo "siento que esos datos estan mal". **Tiene razon y el numero lo prueba.**

```
reto_picks_mostrados ....... 2 filas en total, 1 calificada
dias en el reto ............ 1.2  (0.17 semanas)
bankroll ................... 5,000 -> 6,653.83  (+33%)
```
`ritmo_semanal_pct` compone ese +33% de 1.2 dias a una tasa semanal:
`1.33077^(1/0.17) - 1 = 437%`. Aritmeticamente correcto, **estadisticamente vacio**.
De ahi salen los tres numeros de la pantalla:
- RITMO REAL **+445.8%/sem** (necesario: 15.5%)
- TIEMPO A LA META **0.1 anios**
- ATRASO **+29.9%** — ademas MAL ETIQUETADO: +29.9% significa ir ADELANTADO, no atrasado.

Es el mismo defecto que ya cazamos tres veces (#106 muestra de 2 partidos, #148 n=5
retractado, #8 "no se concluye con muestra chica") pero **en la pantalla principal, donde
mas influye en la decision de apostar**. Un usuario que ve "+445%/sem" sube el tamano de
sus apuestas.

### Arreglo propuesto (PENDIENTE, no aplicado)
Piso de muestra ANTES de extrapolar: si `semanas < 2` o `picks_calificados < 20`, no
mostrar tasa; mostrar "muestra insuficiente para medir ritmo (1 de 20 picks)". Y renombrar
ATRASO a "vs RITMO NECESARIO" con signo explicito.

---

## #200 Por que solo 1 pick hoy: el RETO tiene NUEVE ligas y el tenis NO esta

Medido en `reto_13m_estado`:
```
ligas_incluidas = Premier League, La Liga, Serie A, Bundesliga, Ligue 1,
                  UEFA Champions League, NFL, MLB, Liga MX
conteo = 1 listo, 5 en espera, 1 descartado
cobertura = 168 partidos de ligas top en 7 dias; 13 en 24h, 12 con precio (92%)
```
**ATP y WTA no se miden a proposito**: no estan en la lista. No es un fallo, es el alcance
del reto. Los 5 "en espera" no son falta de partidos: les falta el dato que decide
(alineacion o abridor confirmado).

---

## #201 Inventario para la hoja de ruta propuesta (MEDIDO)
```
detalle_partido_espn ....... 19,526 filas   -> props (corners/tarjetas) es viable
radar_odds_snapshots ....... 71,890 filas, 587 eventos -> CLV instantaneo es viable
historico_partidos_espn .... 31,928 filas   -> fuerza de calendario es viable
reto_picks_mostrados ....... 2 filas, 1 calificada -> AUTO-TUNING NO ES VIABLE
```
**El regresor de auto-calibracion (XGBoost) sobre `calibration_error` es exactamente el
error que combatimos toda la noche**: alimentar un modelo con n=1 y publicar su salida con
autoridad. Es la misma familia del #107 (BET en 25 de 25 por falta de datos), #108 (equipo
desconocido tratado como promedio), #179 y #180 (un LLM escribiendo reglas numericas desde
n=3). Se pospone hasta tener muestra, y la muestra se junta sola con el tiempo.

## Leccion nueva
30. **El mismo defecto de muestra chica duele mas segun DONDE se muestra.** Lo habiamos
    cazado en tendencias y en alertas; aqui estaba en la pantalla principal, en letras
    grandes, donde influye directo en cuanto dinero se arriesga.

---

## #207 Llegaban TRES push por el mismo evento. Eran tres emisores vivos a la vez

Foto del usuario (4-sep, 12:23, Tommy Paul 1-1 Bublik, US Open): tres avisos del MISMO
set, con un minuto de diferencia. Rastreado uno por uno:

| # | Emisor | Cron | Titulo que mandaba |
|---|--------|------|--------------------|
| 1 | `check-score-updates` (edge, v39) manda push DIRECTO | 37, cada 2 min | `🎾 Tommy Paul vs Alexander Bublik` / `1 – 1` / `🎾 SET 2 para Alexander Bublik` |
| 2 | `detectar_cambios_marcador()` -> `enviar_alerta()` | 242, cada 3 min | `🎾 SET: Tommy Paul 1-1 Alexander Bublik` / `ATP Tour` |
| 3 | `procesar_notificaciones_marcador()` (puente #155) -> trigger `trg_notificacion_push` | 407, cada minuto | `Tommy Paul 1 - 1 Alexander Bublik` / `Alexander Bublik +1.5 Sets · 3rd` |

**El #3 lo puse yo ayer, sobre una premisa falsa.** En #155 conclui que
`score_notifications` no tenia consumidor. Falso: la MISMA edge function que escribe esa
tabla manda el push por su cuenta, en la misma pasada. El puente no destapo un canal
muerto, agrego una tercera copia de un canal que ya iba doble desde #80.

### Quien sobrevive y por que
Gana `check-score-updates`: es el unico con apodos cortos (`equipos_cortos_lote`), circulos
de avance del parlay, enlace directo al pick, semantica por deporte (TD vs gol de campo,
un grand slam en UN aviso y no cuatro) y la guarda de coherencia de sets del #85.

### Cambios aplicados (2 funciones, cirugia con candados)
```diff
 trigger_enviar_push_notificacion()
-  IF NEW.tipo IN ('parlay_ganado','parlay_perdido') THEN
+  IF NEW.tipo IN ('parlay_ganado','parlay_perdido')
+     OR (NEW.tipo = 'marcador' AND NEW.data->>'origen' = 'score_notifications') THEN
```
Mismo patron que ya existia para parlays: la fila se queda para la campana dentro de la
app, lo que se retira es el push. La guarda apunta al `origen` que solo escribe el puente,
asi que ningun otro tipo de aviso se toca.

```diff
 detectar_cambios_marcador()
-      IF v_avisar THEN
+      IF false AND v_avisar THEN
         PERFORM enviar_alerta(r.apodo, 'marcador', v_clave, ...);
```
Reversible quitando el `false AND`.

### Lo que NO se toco, y por que
El bloque de FINAL de `detectar_cambios_marcador` **se conserva**. Medido a 30 dias:

```
finales que aviso la ruta SQL ....... 28
finales que vio la edge function .... 15
en las dos ......................... 10
solo la SQL ........................ 18   <- se perderian si la apago
solo la edge ........................ 5
```
Apagarla habria dejado sin aviso de final 18 de 33 partidos. El `¡Arrancó!` tambien se
queda: la edge function no manda inicio, y ese si esta descontado contra
`alertar_inicio_partidos` por la llave de `alertas_enviadas`.

### Residual conocido (NO cerrado)
Al FINAL de un partido todavia pueden llegar **dos** avisos, en los 10 de 33 casos donde
las dos rutas ven el mismo cierre. El arreglo propuesto es que la ruta SQL espere ~6
minutos y solo mande si `score_notifications` no registro ya ese final; asi se matan los 10
duplicados sin perder los 18 que solo ella ve. Es un cambio aparte, no se hizo hoy.

Tambien medido de paso: la notificacion del Oraculo salio **3 veces identica** el 4-sep a
las 18:00:18 (tres filas en `notificaciones` con 130 ms de diferencia). Es una triplicacion
distinta, del lado del que INSERTA, no del que manda. Queda abierta.

### Verificacion (10 de 10)
```
T1 guarda del puente puesta ....... true    M1 marcador apagado ........... true
T2 parlays siguen guardados ....... true    M2 FINAL sigue vivo ........... true
T3 el push del resto sigue ........ true    M3 INICIO sigue vivo .......... true
C1/C2/C3 los tres crons activos ... true    M4 memoria sigue guardandose .. true
```

## Leccion nueva
31. **"Nadie lee esta tabla" no se prueba buscando lectores en la base de datos.** El
    consumidor de `score_notifications` no era una funcion SQL ni un cron: era la misma
    edge function que la escribia, mandando el push por su cuenta tres lineas mas abajo.
    Buscar escritores/lectores solo en `pg_proc` deja fuera todo el codigo de las edge
    functions. Es la misma familia de error que `push_log` (#155): confundir "no encuentro
    quien lo use" con "nadie lo usa".
