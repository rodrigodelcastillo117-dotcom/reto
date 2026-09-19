# ISS258 / ISS259 — O/U fuera del API publica, y el linaje del prior por fin visible

Proyecto Lovable: **«Remix of Reto 13M»** `d243f279-2db6-4f18-a269-029cf284267f`
Supabase: **`wpiztubmmmzclhlprgpd`**
Fecha: **2026-09-19**

> **Todas las cifras de este documento llevan hora.** La tabla de puertas es VIVA:
> cambia sola cuando se califican partidos. Una cifra sin hora es una cifra que ya
> no se puede auditar.

---

## 0. CORRECCION DE ALGO QUE YA HABIA ESCRITO

En `docs/ISS257_veredicto_lo_gana_quien_publica.md` publique esta tabla:

| deporte | mercado | modelo | n | upper95 | puerta |
|---|---|---|---|---|---|
| soccer | 1X2 | crossleague_v1 (prior) | 198 | −0.0084 | ~~**PASA**~~ |
| soccer | 1X2 | soccer_canonical_v2 | 66 | +0.0194 | NO PASA |

**Medido de nuevo a las 19:15:46 UTC del mismo dia, ya no es cierto:**

| mercado | modelo | n | brier | lower95 | upper95 | puerta |
|---|---|---|---|---|---|---|
| 1X2 | crossleague_v1 | **209** | 0.6281 | −0.0773 | **+0.0001** | **NO PASA (cruza cero)** |
| 1X2 | soccer_canonical_v2 | **77** | 0.6408 | −0.0905 | **+0.0387** | NO PASA (cruza cero) |
| BTTS | crossleague_v1 | 209 | 0.4986 | −0.0189 | +0.0161 | NO PASA |
| BTTS | soccer_canonical_v2 | 77 | 0.4787 | −0.0492 | +0.0066 | NO PASA |

Dos correcciones, las dos en mi contra:

1. **El prior ya NO pasa la puerta.** Con 11 partidos mas (198 -> 209) su intervalo
   cruzo el cero por un pelo: +0.0001. **Hoy no hay NINGUN modelo de futbol que
   pase la puerta de dinero, ni el que publica ni el prior.**
2. **Dije que soccer_canonical_v2 era "mejor que el prior". Con mas datos, ya no.**
   Escribi que su diff (−0.0497) le ganaba al del prior (−0.0481). A las 19:15 el
   que publica va en −0.0259 y el prior en −0.0386: **ahora el prior es el mejor de
   los dos**, y el que publica EMPEORO al crecer su muestra (Brier 0.6169 -> 0.6408
   al pasar de 66 a 77 partidos). No lo maquillo: el modelo no mejoro, se le noto
   mas.

Esto no cambia el arreglo de ISS257 — lo refuerza. Si el veredicto se siguiera
heredando del prior, la insignia verde "Validado" habria sobrevivido hasta hoy por
inercia y habria caido por casualidad, no por regla.

---

## 1. ISS258 — Over/Under retirado tambien del API publica

### El rastreo

Busque TODA columna de over/under legible por `anon` o `authenticated`. Salieron
113 columnas en 40 objetos. Separadas por lo que de verdad son:

- **Prediccion de RETO** (probabilidad de un total) -> se retira.
- **Contexto factual** (momios y linea de la casa, frecuencias historicas) -> se
  conserva: son hechos, no pronosticos nuestros.

Surtido real de PREDICCION de O/U de futbol servida hoy (18:5x UTC):

| vista | filas | p_over | p_under |
|---|---|---|---|
| `v_futpro_publication_v3` | 97 | **94** | **94** |
| `v_futpro_v2` | 147 | **94** | **94** |
| `v_prediccion_reto_futbol` | 58 | 0 | 0 |
| `v_prediccion_reto_canonico` | 58 | 0 | 0 |
| `v_analisis_partido` | 963 | 0 | 0 |

`v_futpro_publication_v3` lee `FROM v_futpro_v2` y pasa las columnas tal cual, y
`v_futpro_v2` tiene **un solo dependiente**: v3. Por eso se arreglo en v2 y bajo a
las dos de un golpe.

### Eran TRES fugas, no una

Un barrido por nombre de columna solo habria encontrado la primera:

1. **columnas** `p_over` / `p_under`
2. **`mejor_pick`**: su argmax incluia las tuplas `('Más de X goles', p_over)` y
   `('Menos de X goles', p_under)`. Por eso `mejor_pick` nombraba un mercado
   **retirado** en 49 de 97 filas.
3. **el jsonb `markets`**: llevaba `over_current`, `under_current`, `over25`,
   `under25`, `over35`, `under35`, `over45`, `under45` escondidos dentro del blob.

### Antes / despues, medido

| | antes | despues |
|---|---|---|
| `v3.p_over` / `p_under` no nulos | **94** / 94 | **0** / 0 |
| `v2.p_over` / `p_under` no nulos | **94** / 94 | **0** / 0 |
| `markets` con llaves O/U | **94** | **0** |
| `mejor_pick` nombrando un total | **49** | **0** |
| **`over_line` (factual, se conserva)** | **94** | **94** |
| **`odds_over` (factual, se conserva)** | **94** | **94** |
| **`btts_yes` (NO retirado, se conserva)** | **97** | **97** |
| filas servidas | 97 | **97** |

**Cobertura intacta: 97 filas antes y 97 despues.** No se retiro un partido, se
retiro una afirmacion.

### Lo que NO se toco, y por que

- **BTTS / GG: intacto.** No esta retirado; esta **SIN VEREDICTO** por muestra
  insuficiente, que es otra cosa. Confundirlos seria justo el error que me pediste
  no cometer.
- **MLB y NFL:** su O/U tiene evidencia propia y se mide aparte. No se retira
  futbol y de paso otros deportes.
- **`v2.soccer_prediction_v2` y las tablas de backtest:** ahi viven los numeros que
  DEMOSTRARON que habia que retirar el mercado. Borrarlos seria destruir la
  evidencia del propio retiro.
- **`bt_fut_pred`** (21,252 filas con `p_over25`, legible por anon): es tabla de
  backtest, no superficie de producto. No la toco. Que anon pueda leer tablas de
  laboratorio es una exposicion **preexistente y distinta**, y queda anotada como
  pendiente, no colada dentro de este arreglo.

### Metodo y rollback

Parche **exactamente-una-vez** sobre `pg_get_viewdef`: si un ancla no aparece
exactamente 1 vez, el `DO` entero aborta y no se aplica nada. Mas una asercion
final de que no quedan rutas vivas de `p_over`.

El rollback es **por posicion, no por replace plano**, y aqui esta el motivo: el
parche convirtio SIETE condiciones distintas en el mismo texto
`WHEN false THEN p.p_over`, perdiendo el `2.5` / `3.5` / `4.5`. Un `replace()`
inverso no puede distinguirlas. Por eso `rollback_ou_api_publica.sql` parte la
cadena por el ancla y rearma cada original en su sitio.

**El rollback esta PROBADO, no solo escrito:** se ejecuto dentro de
`BEGIN … ROLLBACK` y devolvio p_over/p_under a 94, `markets` con O/U a 94 y
`mejor_pick` nombrando un total a 49 — exactamente el estado previo — y despues se
deshizo. El arreglo siguio en pie (verificado: 0 / 0 / 0).

---

## 2. ISS259 — El linaje del prior, visible y separado del veredicto

Pediste conservar la evidencia del modelo anterior como **linaje**, claramente
separada del veredicto del que publica. Al ir a verificarlo encontre que **no se
veia en ninguna parte**.

El frontend YA tiene el componente correcto (`LinajeEvidenciaVista`) y su lector
`adaptarLinaje` busca la llave `evidencia_por_mercado.<mercado>.**linaje**` con
campos `version_anterior`, `veredicto_de_la_anterior` y `advertencia` (esta ultima
obligatoria de mostrar, nunca en tooltip). **La vista nunca emitia esa llave**, asi
que el bloque jamas se pintaba: la evidencia del prior existia en
`evidencia_prior`, pero invisible.

Ahora se emite. Medido tras refrescar la cache:

| | valor |
|---|---|
| filas | 96 |
| `ganador` con `linaje` | **96** |
| linaje nombra al prior (`crossleague_v1`) | **96** |
| linaje trae la advertencia "no se hereda" | **96** |
| `btts` con linaje | 96 |
| `total` con linaje (valor JSON `null`) | 96 claves, **valor null** -> no se pinta |
| `ganador` con veredicto **validado** | **0** |
| prediccion visible (`ganador_pick`) | **96** |
| `over_pct` | **0** |

**Es condicional a proposito:** el linaje solo se emite mientras el que publica
*no* tenga veredicto propio. El dia que soccer_canonical_v2 gane el suyo, el linaje
desaparece solo, sin tocar codigo. Esa es la regla que el propio frontend declara.

**Una asercion mia salio mal y la data estaba bien:** conte `total` con
`evidencia_por_mercado->'total' ? 'linaje'` y me dio 96, no 0. El operador `?`
comprueba que la LLAVE exista; el valor es JSON `null`, y `adaptarLinaje` devuelve
null ante eso, asi que la pantalla no pinta nada. El error era mi prueba, no la
vista.

---

## 2bis. ISS260 — `v_picks_futbol_calc`, y una correccion a mi propio hallazgo

Siguiendo el rastro de `cuarentenaMercados.ts` llegue a otro contrato de picks de
futbol: `v_picks_futbol_calc`. Medido: **63 filas = 40 Over/Under (prob media
59.9%, ejemplo "Over 2.5") + 19 BTTS + 4 Moneyline**, con `apostable` en false en
las 63.

La vista YA traia `NOT pick_en_cuarentena('soccer','Over/Under',pick)`, pero esa
cuarentena solo tapa **Under 3.5** (ver `esUnder35` en el frontend). Por eso
"Over 2.5" pasaba entero. El mercado esta retirado completo, no una linea.

**ISS260** agrega `AND mercado <> 'Over/Under'` y deja BTTS (19) y Moneyline (4)
intactos.

### Correccion: dije que esto se veia en pantalla. NO se ve.

Escribi que esas 40 filas "se muestran en las superficies de descubrimiento".
**Lo infieri de un comentario del frontend, no de una medicion.** Cuando fui a
probarlo, la cadena entera resulto estar MUERTA:

| Comprobacion | Resultado |
|---|---|
| `SELECT` como `anon` | **denegado** (42501) |
| `SELECT` como `authenticated` | **denegado** (42501) |
| Grants de `anon`/`authenticated` sobre la vista | INSERT, UPDATE, DELETE, TRUNCATE… **pero NO SELECT** |
| Grants sobre `picks_futbol_cache` | **ninguno** para anon ni authenticated |
| Alguna funcion SECDEF que anon/auth pueda ejecutar y lea la cache | **ninguna** |
| Ultimo refresco exitoso de la cache | **2026-09-11 15:38:48 UTC** (8 dias 5 h) |
| Cron 314 `picks-futbol-cache` | **`active = false`** (apagado) |
| `refrescar_picks_futbol()` | **ROTA**: hace `insert … select *, now()`; la vista tiene 24 columnas (la 24 es `desacuerdo_vs_precio_pp`) y la cache tiene 24 pero la suya es `calculado_at`. 25 expresiones contra 24 destinos. |

**Que la rotura NO es mia:** mi cambio no agrego ni quito columnas (reproduje las
24 exactas), y el ultimo refresco exitoso es del **11 de septiembre**, 8 dias
antes de esta sesion.

Asi que ISS260 **no arreglo una fuga viva**: arreglo un contrato que, si alguien
revive esa superficie, ya no publicara un mercado retirado. Es correcto y barato,
pero no vale lo que yo dije que valia.

**Lo que NO hice, a proposito:** no arregle la funcion de refresco ni reencendi el
cron 314. Un cron apagado a mano es una decision de alguien, y esa superficie
ademas trae `ev`, `score_valor` y `nivel` — justo el vocabulario que el dueno
prohibio para decidir. Revivirla no me toca.

---

## 3. Prediccion visible vs pick monetizable

Medido 19:1x UTC:

| superficie | filas | prediccion visible | pick monetizable |
|---|---|---|---|
| `v_tarjeta_soccer_v1` | 96 | 96 (`ganador_pick`) | **0** |
| `v_futpro_publication_v3` | 97 | 97 (`canonical_pick`) | **0** (`top_only_authoritative` = literal false) |
| `v_pick_canonico` | 399 | 399 | **0** (`es_pick` false, `SIN_CALIBRATION_VERSION`) |

**Los conteos son distintos en las tres superficies y nunca se cruzan: lo visible
es analisis, lo monetizable es cero.** La separacion existe en los datos. Que las
ETIQUETAS de pantalla lo digan igual de claro en las tres es frontend, y esa parte
sigue **PENDIENTE de prueba visual** (ver limites).

---

## 4. Limites de lo comprobado — lo que NO puedo afirmar

| Prueba | Estado | Por que |
|---|---|---|
| `anon` dentro de la base (`SET ROLE anon`) | **PROBADO** | p_over 0, p_under 0, markets sin O/U, btts 97, over_line 94 |
| `anon` por HTTP real contra PostgREST | **NO EJECUTADA** | El proxy de salida deniega el CONNECT a `wpiztubmmmzclhlprgpd.supabase.co:443` (403, politica de la organizacion). Lo confirme en `__agentproxy/status`. No es un fallo del arreglo: es que desde este contenedor no hay salida. La capa no probada es PostgREST, que no puede inventar valores que la vista no devuelve. |
| FUT Pro / Favoritos / Scanner en el Remix real | **PENDIENTE** | El Remix esta detras de login. Ver §5. |
| Pruebas de `reto13` | **NO APLICA** | `reto13` NO es el Remix (le faltan `canonicalPick.ts` y `MatchSheetV2.tsx`). No voy a presentar sus pruebas como pruebas del Remix. |

---

## 5. Pendientes

| # | Pendiente | Estado |
|---|---|---|
| 1 | Prueba visual de FUT Pro / Favoritos / Scanner en movil y escritorio | **PENDIENTE** — bloqueada por login |
| 2 | Que las ETIQUETAS de pantalla separen "analisis" de "pick" tan claro como lo hacen los datos | PENDIENTE (frontend / Lovable) |
| 3 | `TresPorcentajesSoccer` en modo `compacto` no muestra "Son analisis, no una recomendacion de apuesta"; solo sale en el detalle | PENDIENTE (frontend / Lovable) |
| 4 | `bt_fut_pred` y otras tablas de backtest legibles por `anon` | PENDIENTE — exposicion preexistente, distinta de O/U |
| 5 | Evidencia prospectiva valida para desbloquear picks | PENDIENTE — **sin atajos**: no se registra exencion de calibracion por sesgo cero |
