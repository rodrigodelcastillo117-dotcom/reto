# ISS293 — Una palabra de SQL tenía los picks sin refrescar desde las 16:47

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-13**

Esto apareció auditando pantallas (ISS292). No lo buscaba, y era lo más grave
del día: **la tubería de candidatos de picks llevaba tres horas muerta.**

---

## 1. Lo que estaba pasando

`gate_cron_sano` dio FAIL con tres renglones. Uno importaba:

```
reto-global-candidate-snapshot-v1  (3/3 ultimas corridas fallaron)
```

Ese cron refresca `mv_reto13m_global_candidate_v2` cada 15 minutos — la vista
materializada de la que salen los candidatos de picks de **todos** los deportes.
Su historia de hoy:

```
14:47   98s  ok
15:02  109s  ok
15:47  110s  ok
16:32  113s  ok
16:47  120s  FALLA   <- cruzo el statement_timeout
17:02  120s  FALLA
...
19:32  120s  FALLA    12 corridas seguidas
```

La vista materializada tiene **16 filas y 120 kB**. Tardaba 110 segundos en
producirlas y nadie lo sabía.

**El defecto no es "qué cambió hoy".** Es que un trabajo cada 15 minutos vivía a
un 6% de variación de su techo, y ese 6% llegó. Lo que cambió hoy es irrelevante:
crecieron 279 filas en la ventana del cruce, 0.5% de la tabla.

## 2. Primero restauré el servicio, declarándolo

Le subí el techo a ese cron a 300s (`set statement_timeout='300000'` en el
comando). **Parche, no arreglo**, y lo dije así: el propio `gate_cron_sano`
advierte *"si esto sube, la respuesta es bajar frecuencias o partir trabajo, NO
subir timeouts"*, y tiene razón. Con la vista creciendo, 300s compra días.

Al final del trabajo **lo retiré**, porque el arreglo real lo volvió innecesario
y porque dejar una muleta escondida haría que el guardia nuevo midiera un margen
falso.

## 3. Medir en vez de adivinar: el plan real, fuera de banda

El cliente MCP muere a los 60s y la vista tarda más. `EXPLAIN` a secas da costos
del planificador, que **no son tiempo** — ya me equivoqué hoy dos veces leyendo
indicadores indirectos.

Construí `v2.capturar_plan(etiqueta, sql)` + `v2.diagnostico_plan`, y lo disparé
con un cron de una sola corrida con su propio techo. El veredicto, por tiempo
**propio** de cada nodo:

| nodo | propio | % | loops | filas/loop |
|---|---|---|---|---|
| **Index Scan `soccer_prediction_v2`** | **256,117 ms** | **63.5%** | **4,557** | **41,663** |
| Nested Loop | 103,269 ms | 25.6% | 49 | 66 |
| Unique | 26,909 ms | 6.7% | 4,557 | 736 |
| Subquery Scan | 6,908 ms | 1.7% | 4,557 | 450 |

**96% del tiempo es un solo escaneo de `soccer_prediction_v2` repetido 4,557
veces**, y cada vez se lleva 41,663 de las 51,883 filas de la tabla: el 80%. Sin
condición de índice y sin filtro — recorrido completo, 4,557 veces.

*(Advertencia honesta sobre ese número: `EXPLAIN ANALYZE` con 349 nodos instrumenta
cada fila e infla el total a 404s. Sirven las proporciones entre nodos, no el
absoluto.)*

## 4. La causa: un CTE que PostgreSQL inlinea solo

En `public.v_futpro_v2`:

```sql
pred AS (
  SELECT DISTINCT ON (s.espn_event_id) <40 columnas>
    FROM v2.soccer_prediction_v2 s
   ORDER BY s.espn_event_id, s.computed_at DESC
)
...
LEFT JOIN pred p ON p.espn_event_id = u.espn_event_id
```

Desde PostgreSQL 12, **un CTE referenciado una sola vez se inlinea por defecto.**
`pred` se usa una vez, así que se inlinea, el planificador lo pone del lado
interno de un Nested Loop, y lo re-ejecuta por cada fila externa.

`pred` **no está correlacionada**: su resultado es idéntico las 4,557 veces.

### Por qué nadie lo había visto

```
v_futpro_v2 medida SOLA:                     178 ms,  276 filas
v_futpro_v2 DENTRO del arbol de candidatos:  el desastre de arriba
```

Medida sola, la vista elige un Hash Join y va bien. El plan malo aparece **solo
en la composición**, cuando el planificador re-planea el árbol completo
inlineado. Por eso la vista "se veía bien" y el cron se moría: **hay que medir la
composición, no la pieza.**

## 5. El arreglo: una palabra

```diff
-        ), pred AS (
+        ), pred AS MATERIALIZED (
```

Nada más. Cero líneas de lógica, cero columnas, cero semántica. Un CTE
`MATERIALIZED` devuelve exactamente las mismas filas, solo que calculadas una vez.

### Lo que NO hice, y por qué

- **No lo moví a una vista materializada aparte.** Eso acoplaría los picks a la
  frescura de *otro* refresco, y un pick calculado en silencio sobre predicciones
  viejas es peor que un cron lento.
- **No le puse filtro de fecha a `pred`**, aunque se podría (solo se usa vía
  `p.espn_event_id = u.espn_event_id`, así que restringirla a los eventos de
  `upcoming` daría el mismo resultado). Sería más rápido todavía, pero es un
  cambio con semántica que discutir, y este arreglo no lo necesitaba.

### Prueba de que no cambió nada

Huella sobre `(canonical_event_id, p_reto_home, p_reto_draw, p_reto_away,
model_status, mejor_pick, mejor_pick_prob, predicted_score)`:

```
ANTES    276 filas   md5 34ae61b715a0c91edc88d32c5d725928
DESPUES  276 filas   md5 34ae61b715a0c91edc88d32c5d725928
```

**Idénticas.**

### Antes y después, en el servidor real

```
v_reto13m_global_candidate_source_v2:
  ANTES    110-120s, fallando contra el techo de 120s
  DESPUES   47.8s,  42 candidatos
```

De 120s que fallaban a 48s. El techo vuelve a tener 2.5× de margen.

## 6. Por qué costó aplicarlo, y qué misterio resuelve

`CREATE OR REPLACE VIEW` expiró a los 60s. La causa, medida en `pg_stat_activity`:

```
refresh materialized view concurrently public.mv_reto_soccer_read_context_v1   81s activo
```

Tres crons refrescan vistas materializadas que **leen** `v_futpro_v2` — dos de
ellos **cada 5 minutos**, tardando decenas de segundos. Entre los tres casi nunca
hay un hueco, y cada uno sostiene un lock de lectura que bloquea el DDL.

**Esto explica el misterio de `absorber_agenda_espn`** de ISS289, donde tres
`CREATE OR REPLACE` expiraron sin causa conocida y lo declaré sin resolver. No
era la función: eran lectores largos de crons solapados.

La solución fue pausar los tres crons (510, 511, 515), aplicar, y **volverlos a
encender verificándolo en un statement aparte** — porque leer `cron.job` en el
mismo statement que el `alter_job` devuelve la instantánea previa y parece que
siguen apagados.

## 7. El detector que faltaba

`gate_cron_sano` ya avisaba *"3 de 3 últimas corridas fallaron"*: grita **después**
de la caída. Nadie miraba el **margen**. Un trabajo a 113s contra un techo de 120s
estaba a una variación del 6% de morir, y esa información existía desde horas
antes.

`public.gate_cron_al_borde_de_su_techo()` (**G50.12**) mide margen, no fallo: qué
fracción de su techo consume la corrida más lenta de 24 h. El techo efectivo lo
deriva del comando, así que **no se vuelve ciego si a un trabajo le suben el
techo** — exactamente el parche de la §2, que así no podía quedar invisible.

- ≥80% del techo → **FAIL**
- ≥60% → **INFO**

Primera corrida, y se pagó solo:

```
motor-cache-horizonte-largo        peor 240s de 120s (200.0%)  1/1 no ok  <- ya muerto
refresh-cobertura-soccer-20m       peor 120s de 120s (100.4%)
reto-prediction-ledger-capture-5m  peor 120s de 120s (100.1%)
futbol-jugadores-pedir             peor 108s de 120s ( 90.2%)
espejo-apifootball-live            peor 102s de 120s ( 84.8%)
reto-futpro-analysis-snapshot-v1   peor  99s de 120s ( 82.6%)
```

`espejo-apifootball-live` tarda hasta 102s y corre **cada 2 minutos**: ocupa un
worker el 85% del tiempo. Con `max_worker_processes=6` y 281 crons activos (114
sub-horarios), ahí está buena parte de las 11 corridas que se perdieron en 24 h
por `job startup timeout`.

## 8. Lo que queda abierto, declarado

- **48s siguen siendo mucho** para 42 filas. El siguiente punto caliente es el
  `Nested Loop` del 25.6%. No lo toqué: un arreglo por evidencia a la vez, y la
  evidencia del siguiente hay que capturarla de nuevo.
- **`motor-cache-horizonte-largo` sigue 100% muerto** (240s contra 120s, en
  `v_fu…`). Mismo patrón, otra vista. No arreglado hoy.
- **`refresh-cobertura-soccer-20m`** pega el techo en
  `fn_crossleague_features_canonical`.
- La **saturación de workers** (6 workers, 281 crons) es estructural. La respuesta
  correcta es bajar frecuencias o partir trabajo, y es una decisión de producto
  sobre frescura, no mía.
- `v2.diagnostico_plan` se queda con el plan de hoy, para el siguiente arreglo.

## Rollback

```sql
-- 1. volver pred a CTE inlineado (NO recomendado: reintroduce el fallo)
--    recuperar la definicion previa de public.v_futpro_v2 sin AS MATERIALIZED
-- 2. retirar el guardia y el capturador
drop function if exists public.gate_cron_al_borde_de_su_techo();
drop function if exists v2.capturar_plan(text,text);
drop table if exists v2.diagnostico_plan;
```

El parche de `statement_timeout` del job 515 **ya está retirado**: su comando
volvió a `refresh materialized view concurrently public.mv_reto13m_global_candidate_v2`.
Los crons 510, 511 y 515 quedaron **activos**, verificado.

No se borró un dato, no se tocó un modelo, no se movió un pick, no se encendió
dinero.
