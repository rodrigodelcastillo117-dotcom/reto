# ISS295-297 — Una tarjeta viva que elegía por precio, y una regresión mía

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-13**

El dueño preguntó *"puedes lograrlo?"*. Esto es lo que sí me tocaba: los FAIL
que son ingeniería. Salieron tres cosas, y la tercera es la que importa.

---

## ISS295 — Primero, una regresión que yo introduje hoy

En ISS293 puse `pred AS MATERIALIZED` para matar un Nested Loop que re-ejecutaba
una subconsulta 4,557 veces. Funcionó: 120s fallando → 48s.

**Pero una barrera de materialización también impide que un filtro de afuera baje
al CTE.** Y hay un camino que filtra por un solo evento:

```sql
-- public.motor_del_partido(text,integer), linea 8
select * from public.v_futpro_publication_v3 where canonical_event_id = p_event limit 1
```

Lo llama `refrescar_motor_cache(240, 20)`: 20 eventos × 3 ventanas = **60 veces**.

Medido, y es mi regresión:

```
DISTINCT ON completo    923 filas   279 ms   <- lo que paga cada llamada ahora
DISTINCT ON un evento     1 fila      5 ms   <- lo que pagaba antes
```

~17 segundos extra repartidos en las 60 llamadas. **No rompí ese cron** —
`motor-cache-horizonte-largo` fallaba desde el 15 de septiembre — pero lo
encarecí, y eso se arregla, no se deja.

### El arreglo gana en los dos caminos

`pred` solo se usa vía `LEFT JOIN pred p ON p.espn_event_id = u.espn_event_id`,
donde `u` es `upcoming`. Restringirla a esos eventos es **exactamente idéntico**:

- el `DISTINCT ON` es **por evento**, así que quitar eventos no puede cambiar cuál
  fila gana dentro de un evento que se conserva;
- un evento fuera de `upcoming` nunca empareja nada en el `LEFT JOIN`.

En ISS293 escribí que esto era *"un cambio con semántica que discutir"*. Lo revisé
y **no lo es.** Lo corrijo.

```
DISTINCT ON restringido a upcoming   276 filas   25 ms   <- 11x mas barato
```

| medida | antes de ISS293 | ISS293 | ISS295 |
|---|---|---|---|
| Huella de `v_futpro_v2` | 276 / `34ae61b7…5928` | **idéntica** | **idéntica** |
| Búsqueda por un evento | ~5 ms de pushdown | 1,076 ms | **248 ms** |
| `v_reto13m_global_candidate_source_v2` | 110-120s **fallando** | 47.8s | 52.3s |

Honestidad sobre esa última fila: **el camino de candidatos no mejoró** con
ISS295, y 52.3 vs 47.8 está dentro del ruido de los crons concurrentes. Lo que
mejoró 4.3× es el camino por evento.

### Y eso revivió el otro cron muerto

`motor-cache-horizonte-largo` llevaba 1/1 corridas fallidas, 240s contra un techo
de 120s. Corrí **su comando exacto**:

```
refrescar_motor_cache(240, 20)  ->  {"filas": 60, "partidos": 106}   36,446 ms
```

**36.4 segundos**, el 30% de su techo. De paso llenó caché que estaba vacío: el
motor_cache pasó a cubrir 106 partidos.

*(Límite: su corrida programada es mañana 9:25. Probé el comando, no la corrida.)*

## ISS296 — Un guardia que medía un partido imposible de medir

```
G28.3_autoridad_no_quemada         FAIL  'contrato n_oos= status= | tabla n_oos=0 ...'
G28.5_brain_authority_no_confunde  FAIL  'Debe existir brain_in_use ...'
```

La selección del evento era *el próximo partido de MLB por fecha*. Hoy ese es
`401908024`: un placeholder de playoffs **"TBD @ TBD"**. Sin equipos no hay
predicción, el contrato devuelve nulos —correctamente— y el guardia leía esos
nulos como si el contrato estuviera mintiendo.

Medido sobre un evento que **sí** se puede medir (`401908035`, Brewers vs Dodgers):

```
brain_in_use                                   = mlb_one_brain_v2
official_prediction.release_authority.n_oos    = 0
official_prediction.release_authority.status   = FORWARD_SAMPLE_INSUFFICIENT
v_mlb_canonical_release_authority_v1           = 0 / FORWARD_SAMPLE_INSUFFICIENT
```

Coinciden exactamente. **El contrato no tiene ningún hueco.**

### Un error mío dentro de la medición

Primero consulté `mlb_terminal_v2(ev)->'release_authority'`, salió nulo, y estuve
a punto de declarar un hueco real en el contrato. El campo vive en
`->'official_prediction'->'release_authority'`. **Era mi ruta, no el contrato.**

### La línea que no se cruza

Cambié la selección al próximo evento **cuyo contrato produce una predicción**, y
si no hay ninguno reporta INFO diciendo cuántos se saltó y por qué.

El filtro es por **medibilidad**, NO por "que pase el guardia". Si el contrato
publica una predicción con números de autoridad que no cuadran con la tabla,
**G28.3 sigue dando FAIL**. Lo único que deja de hacer es gritar por un partido
entre equipos que todavía no existen. G28.1 a G28.7 quedan idénticos: solo cambia
de qué evento hablan.

Resultado: **seis PASS y un INFO**, midiendo `401908035` con `p_reto=51.3`
etiquetado "Predicción no validada" y `product_release_authorized=false`.

## ISS297 — Lo importante: una tarjeta viva que elegía por precio

`gate_un_solo_cerebro / G45.4` daba **FAIL con 41**. El detalle decía que las
escrituras post-barrera eran 0 y que los 29 intentos quedaron bloqueados y
auditados — o sea **no había fuga nueva**. El 41 era otra cosa: *"analisis_partidos
ACTIVOS que difieren de P_RETO canónico"*.

Desglosé las 55 filas READY activas por cada una de las siete condiciones:

```
c2 probabilidades fuera de 0.05 del P_RETO    39
c6 prob del pick fuera de 0.05                40
c3 numero de picks != 1                       25
c5 pick != canonico                           25
c1 model_version distinto                      2
c7 CLAVES DE PRECIO en el pick                 1   <- categoria aparte
```

**La mayoría es desfase, no un cerebro pirata.** `analisis_partidos` guarda una
foto y `v_futpro_publication_v3` es vivo, así que la tarjeta se queda atrás. Le
pega al usuario igual —dos números distintos para el mismo partido— pero no es
una violación de gobierno.

### La excepción sí lo era

Fila `69df2883…`, evento `761773` = **FC Cincinnati vs D.C. United, MLS, saque el
21 de octubre** (activo, faltaban 8 días). Escrita por `motor_picks` el 4 de
septiembre:

```json
"pick":  "[💰 PICK DE VALOR] FC Cincinnati ML",
"prob":  68.4,
"razon": "El pick aprobado por el sistema es FC Cincinnati ML y el precio de
          mercado citado (1.526) queda por encima del momio justo (1.46),
          generando un edge real positivo. ... el soporte principal viene de la
          valoración de PRECIO y localía.",
"ev_estimado": "+4.4%",  "momio_justo": 1.46,  "edge_calculado": 4.3,
"odds_source": "libro:DraftKings",  "ev_con_precio_real": 4.4
```

El cerebro autorizado dice **"Gana FC Cincinnati" al 61.4%**.

El lado coincide, pero la probabilidad difiere **7 puntos** y la justificación
escrita es el precio. **El precio eligió el pick y lo dice con todas sus letras**,
en una tarjeta viva, con la marca "PICK DE VALOR". Es exactamente la prohibición
del dueño: *"SIN EV. SIN KELLY. SIN EDGE CONTRA EL MERCADO PARA DECIDIR."*

### Cómo se arregló, sin destruir nada

No hubo que inventar un mecanismo: ya existe
`analisis_partidos.zzz_enforce_active_soccer_1x2` (el escritor que declaré en
ISS294), que en cada escritura fuerza el 1X2 desde P_RETO y **borra** las claves
de precio. Estas 41 filas son **anteriores al trigger**, por eso nunca pasaron
por él. Un `UPDATE` que toque una columna de su lista `OF` lo dispara.

**Pero sobrescribir destruye, y la regla es que todo retiro sea reversible.** Así
que primero se guardó la imagen previa COMPLETA de cada fila en
`v2.analisis_preimagen_iss297` — **41 filas, 41 imágenes**. Esa tabla *es* el
rollback.

Después se disparó el mecanismo. La fila del "PICK DE VALOR" quedó así:

```json
{ "pick": "Gana FC Cincinnati",
  "prob": 61.4,
  "label": "Prediccion del modelo; no recomendacion de apuesta",
  "razon": "Selector 1X2 canónico: argmax único de P_RETO; momios/EV/Kelly no participan.",
  "mercado": "Moneyline",
  "money_authorized": false }
probabilidades: 61.4 / 19.5 / 19.1
```

Ni una clave de precio, ni la marca "PICK DE VALOR", la probabilidad es la
canónica, y queda etiquetado como predicción y no como recomendación.
**Ningún número se inventó: todos salen del cerebro autorizado.**

### Verificación

```
v2.gate_active_soccer_analysis_1x2()                 FAIL(41) -> PASS(0)
gate_un_solo_cerebro / G45.4                         FAIL(41) -> PASS(0)
gate_el_precio_no_elige_el_pick                      PASS x3  (sin cambios)
gate_tarjeta_no_se_contradice                        PASS x3 + INFO
gate_tarjetas_soccer                                 PASS x9 + INFO(242)
gate_tarjeta_universal                               PASS x4 + INFO
```

Sin daño colateral en ninguna superficie de tarjetas.

## Lo que queda abierto

- **BTTS de fútbol con n=313 sin superar la tasa base.** Decisión del dueño, no
  mía.
- `gate_precio_no_decide / P0_SIN_CLASIFICAR (5)`: las leí y ninguna lee un
  precio, pero la firma es humana (ISS294).
- Saturación de workers: 6 workers para 281 crons, 114 sub-horarios.
  `espejo-apifootball-live` tarda 102s y corre cada 2 minutos. Bajar frecuencias
  es una decisión sobre frescura.
- `refresh-cobertura-soccer-20m` pega el techo en
  `fn_crossleague_features_canonical`.
- `captura_prospectiva B`, `fantasy_ve_la_temporada_en_curso`, G50.10 (`rongo`).
- **El frontend sigue NO PROBADO.** Red bloqueada por política de la organización.

## Rollback

```sql
-- ISS297: devolver las 41 tarjetas a su contenido anterior
update public.analisis_partidos a
   set analisis_json = pi.analisis_json_prev,
       model_version = pi.model_version_prev,
       motor         = pi.motor_prev
  from v2.analisis_preimagen_iss297 pi
 where pi.id = a.id;
-- OJO: el trigger zzz_enforce_active_soccer_1x2 volvera a realinearlas en la
-- siguiente escritura. Para revertir de verdad habria que retirar el trigger,
-- y eso reabre la fuga de precio.

-- ISS296
--   reponer la seleccion anterior (el proximo evento por fecha) en
--   public.gate_probabilidad_sin_autoridad. NO se recomienda: vuelve a medir
--   placeholders TBD.

-- ISS295
--   quitar el WHERE s.espn_event_id IN (SELECT ... FROM upcoming) de `pred` en
--   public.v_futpro_v2. NO se recomienda: reintroduce 279ms por busqueda.
```

No se borró un dato, no se tocó un modelo, no se encendió dinero. Las 41 tarjetas
cambiaron de contenido y su contenido anterior está guardado.
