# ISS283 — ESPN dejó de aceptar rangos de fecha, y se llevó MLB y soccer por delante

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-29**

El dueño preguntó: *"¿por qué no salen partidos de MLB de hoy?"*

---

## La respuesta: no era MLB, era toda la ingesta de agenda

Medido contra el servidor real, el mismo día:

```
dates=20260929-20261007 (9 días)  ->  400 {"code":400,"message":"Failed to get events endpoint."}
dates=20260929-20261001 (3 días)  ->  400     <- el rango falla, no el tamaño
dates=20260929           (1 día)  ->  200, 4 partidos
sin parámetro dates               ->  200, 4 partidos
```

**ESPN rechaza cualquier rango de fechas en `/scoreboard`.** Y falla para todas
las ligas: NFL con el mismo rango también devuelve 400. Se comprobó pidiéndolo.

### Por qué solo se notó en MLB

NFL tiene un sembrador propio, `sembrar_agenda_nfl()` (cron 365), que no pasa
por `pedir_agenda_espn`. Por eso conservó sus 224 partidos mientras el resto se
quedaba sin agenda.

MLB y soccer no tenían red. Y `absorber_agenda_espn` borra lo que pasa de 6
horas, así que **se vaciaron solas**, sin que nada gritara.

### Por qué fue silencioso

`net.http_get` devuelve un id de petición **al instante**; el estado HTTP llega
después. El cron reportaba `succeeded` seis veces al día mientras las 44
respuestas eran 400. `absorber_agenda_espn` sí contaba las respuestas OK y las
devolvía en su jsonb… que **nadie leía**.

Octava aparición de la misma enfermedad en este sistema.

## El arreglo

Mínimo: una petición por día en vez de una por rango, conservando el mismo
horizonte (`p_dias`) para no encoger el producto en silencio.

```sql
cross join generate_series(0, greatest(p_dias, 0)) as d(i)
...
|| '/scoreboard?limit=400&dates=' || to_char(current_date + d.i, 'YYYYMMDD')
```

44 endpoints × 9 días = **396 peticiones por corrida**, cada 4 horas.
Medido: **385 en 200, 0 errores, 11 aún en vuelo.** Sin límite de tasa.

## Antes y después, en el servidor

| | antes | después |
|---|---|---|
| `agenda_espn` · baseball | **0** | **25** (24 futuros) |
| `agenda_espn` · soccer | 2 (1 liga) | **42** (4 ligas) |
| `agenda_espn` · football | 224 | 224 |
| `v_mlb_publication_v1` | **0** | **10, las 10 READY** |
| `v_reto13m_global_candidate_v2` | **0** | **8** |
| `v_reto13m_daily_best_by_sport_v1` | **0 — la app en blanco** | **1 pick** |

El pick que volvió: **Gana New York Yankees** vs Boston (playoffs), P_RETO 58.2%,
`mlb_one_brain_v2`.

De los 8 candidatos, el piso editorial de 58% descarta 7. **No es un fallo**: es
el gate haciendo su trabajo. Se comprobó uno por uno.

## Lo que NO era un fallo, y conviene tenerlo claro

Cuando la app no mostraba nada, la causa inmediata **no era el bug**: la vista
fuente exige `kickoff < now() + 48 horas`, y el 29 de septiembre el primer
partido de NFL era el 2 de octubre (a 3 días) y el de Liga MX el 29 de octubre.
Sin MLB, no había nada dentro de la ventana. La ventana de 48 h es deliberada y
no se tocó.

## Que no vuelva a pasar en silencio

- **`public.agenda_ingesta_log`**: cada corrida del absorber deja respuestas OK,
  con error, en vuelo, y partidos escritos.
- **G50.7**: FAIL si la última corrida no tiene ninguna respuesta OK, si las
  fallidas superan a las buenas, o si no hay rastro en 9 horas.

Hoy: `PASS — 385 ok, 0 con error, 11 aún en vuelo, 81 partidos escritos`.

## Un error mío dentro del arreglo

La primera versión del registro contaba como "mal" toda respuesta con
`status_code <> 200`, y pg_net deja la fila con `status_code` NULL mientras la
petición sigue en vuelo. Absorbí a los 45 segundos de soltar 396 peticiones y me
reportó **"321 ok, 75 mal"**. Volviendo a medir a los ~2 minutos: **385 en 200 y
11 sin respuesta todavía. Cero errores reales.**

Una petición pendiente no es una petición fallida. Corregido: se cuentan aparte,
y el borrado de `_carga_agenda` ahora solo retira lo que ya tiene respuesta, para
no perder una petición en vuelo.

En producción los crons van separados 6 minutos (299 a los :15, 300 a los :21),
así que ahí nunca se dio el problema. No se tocó esa separación.

## Límites de lo comprobado

- No sé **cuándo** dejó ESPN de aceptar rangos. La agenda solo guarda futuro, así
  que no hay rastro histórico. Lo que sí sé es que el 20 de septiembre había
  agenda de MLB y soccer, y el 29 no.
- Los 10 partidos de MLB entraron como READY, pero **la calidad de esas
  probabilidades en playoffs no está validada aparte**: `mlb_one_brain_v2` se
  midió sobre temporada regular.
- No toqué `sembrar_agenda_nfl`, la ventana de 48 h, ni ningún piso editorial.

## Rollback

```sql
-- volver al rango (que hoy devuelve 400):
--   sustituir el cross join generate_series por el rango original en pedir_agenda_espn
drop function if exists public.gate_agenda_ingesta();
drop table if exists public.agenda_ingesta_log;
```

No borra datos ni toca modelos, gates de dinero ni picks.
