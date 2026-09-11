# El % del modelo llega a la TARJETA (iss056) — aplicado a producción

Aplicado en `wpiztubmmmzclhlprgpd` el 2026-09-11, bajo la autorización explícita del owner
("aplica a prod todo"). Todo **aditivo**: ninguna columna existente cambió de nombre, tipo ni
posición, y ningún objeto previo perdió nada.

## Por qué la tarjeta decía que no había porcentaje propio

`iss054` dejó el modelo en `v2.nfl_decision_snapshot` y lo expuso en `public.nfl_dossier`. Pero
el dossier sólo se pide al hacer clic en "VER ANÁLISIS". **La lista de tarjetas lee
`public.nfl_tablero`**, y esa vista únicamente tenía `prob_local` / `prob_visitante`, que son el
implícito sin comisión de la casa.

O sea: el modelo ya existía y estaba bien; lo que faltaba era que llegara a la vista que la
pantalla realmente consulta. Era una brecha de **integración**, no de datos.

## La trampa que casi tiraba toda la pantalla de NFL

`public.nfl_tablero` tiene `security_invoker=on`. Si la hubiera hecho leer `v2` directamente,
`anon` habría necesitado `USAGE` en el esquema `v2` y `SELECT` en la tabla de snapshots — y sin
eso **la vista completa falla**, no sólo las columnas nuevas: se habría caído la pantalla entera.

Por eso el puente `public.nfl_reto_modelo` va **sin** `security_invoker`: corre con los
privilegios de su dueño, así que `anon` sólo necesita `SELECT` sobre el puente y `v2` se queda
cerrado. Verificado con `set local role anon` → 31 filas visibles.

## Lo que NO se hizo

`prob_local` / `prob_visitante` **siguen siendo mercado**, con ese nombre. El modelo llega en
columnas nuevas y `prob_fuente` dice cuál trae la fila (`MODELO_RETO` / `MERCADO_NO_VIG`).
Pisar `prob_local` con P_RETO habría hecho imposible distinguirlos después — es justo lo que el
contrato prohíbe.

## Objetos

| Objeto | Tipo | Qué hace |
|---|---|---|
| `v2.fn_fmt_spread(numeric)` | función nueva | formato de spread con signo: `-3.5`, `+7`, `PK` |
| `public.nfl_reto_modelo` | vista nueva | puente sobre v2, último snapshot por evento |
| `public.nfl_tablero` | vista **modificada** | +21 columnas al final (25 → 46) |
| `public.nfl_semana_actual` | vista nueva | la semana NFL vigente, 1 fila |
| `public.nfl_tablero_semana` | vista nueva | la semana vigente completa, finalizados incluidos |
| `public.nfl_lock_semana` | vista nueva | LOCK informativo, `ranking = 1` es el LOCK |

## Dos bugs míos, corregidos antes de dar esto por bueno

1. **El snapshot guarda porcentaje (65.2), no fracción.** Mi primera versión multiplicaba por 100
   otra vez y la tarjeta mostraba **6520%**. Lo detecté comparando contra los valores crudos.
2. **`to_char(3.0,'FM9990.9')` devuelve `"3."`, sin signo.** El spread salía
   `"Detroit Lions 3."` en lugar de `"+3"`. De ahí `v2.fn_fmt_spread`.

Y un tercero en la vista de semana: el primer intento unía por `(semana, temporada)` contra
`nfl_tablero`, pero ahí `temporada` es el **tipo** (`'regular'`), no el año. La semana 1 existe
en 2025 **y** en 2026 → devolvía 32 filas en lugar de 16. El filtro va por `espn_event_id`.

## Medido después de aplicar

| Qué | Valor |
|---|---|
| Columnas de `nfl_tablero` | 25 → 46, **0 perdidas** (verificado columna por columna) |
| Partidos de la semana vigente | 16 (semana 1, 2026) |
| Con número propio | **15 de 16** |
| Suma `p_reto_local + p_reto_visitante` | 100.0 en todas |
| Push en línea entera (`DET -7`) | 4.9 % |
| Push en línea media (`LAR -3.5`) | 0.0 % |
| Visible para `anon` | sí, verificado con `set local role anon` |
| LOCK semana 1 | Jacksonville 78.4 % (mercado 79.1 %, coinciden) |

### El partido que NO tiene número propio: New England @ Seattle

No es un bug: **es el contrato funcionando.** Ese partido ya arrancó (jueves 00:20 UTC), y
`v2.nfl_decision_snapshot` tiene `CHECK (decision_time < kickoff)`. Un snapshot posterior al
saque inicial es **físicamente imposible de guardar**, justo para que nunca podamos decidir con
información que no teníamos. Ese partido se queda con el % del mercado, etiquetado como mercado.
No hay forma de "arreglarlo" sin romper lo único que hace creíbles los números de los otros 15.

## El LOCK y por qué NO entra a RETO 13M como MLB y futbol

El owner pidió que el LOCK pasara a la pestaña RETO 13M "como es con MLB y FUTBOL". Se hizo —
pero **fuera de la lectura económica**, y la razón no es mía:

`public.reto_picks_hoy` filtra por `public.sin_modelo_independiente(deporte, mercado)`, y para
NFL esa función devuelve un bloqueo con su **criterio de reingreso escrito**:

> AUC fuera de muestra >= 0.55 con n >= 250 sobre 2 temporadas, **Y** ganarle en LogLoss a la
> línea sin vig.

Contra lo medido en `NFL_BACKTEST_2025_EVIDENCIA.md`:

| Condición | Exigido | Medido | ¿Cumple? |
|---|---|---|---|
| Muestra | n >= 250, 2 temporadas | n = 208, 1 temporada | **NO** |
| Ganarle a la línea sin vig | sí | Brier 0.22702 vs mercado 0.21822 | **NO** |

**Dos de dos fallan.** Meter NFL al repartidor de Kelly sería dimensionar dinero real sobre una
ventaja que la medición dice que no existe. No se toca ese gate.

Lo que sí se entrega: `public.nfl_lock_semana`, informativo, sin monto y sin EV, con
`nota_honesta` impresa en la propia fila. "El más seguro" se define como el **menor** entre
nuestro % y el del mercado, y sólo entre partidos donde **ambos van por el mismo lado** — tomar
el mayor sería quedarse siempre con el número más optimista.

## Rollback

```sql
drop view if exists public.nfl_lock_semana;
drop view if exists public.nfl_tablero_semana;
drop view if exists public.nfl_semana_actual;
-- nfl_tablero: volver a la definición de 25 columnas (en el historial de este archivo)
drop view if exists public.nfl_reto_modelo;
drop function if exists v2.fn_fmt_spread(numeric);
```

---

# Dos bugs de ingesta encontrados al revisar NE @ SEA (11-sep-2026)

El owner señaló que NE @ SEA ya se jugó. Tenía razón, y al verificarlo salieron dos problemas
que **no son del modelo** sino de la ingesta de resultados.

## 1. `nfl_partidos.estado` nunca se pone en `final` para 2026

Medido: **0 de 273** partidos de la temporada 2026 tienen `estado = 'final'`, incluido uno cuyo
`live_scores.status` ya dice `final`. El cierre de partidos no está escribiendo esa columna.

Consecuencia: un partido de ayer seguía apareciendo como "programado".

**Mitigado** (no arreglado en el origen): `public.nfl_tablero_semana` deriva `terminado` de
`nfl_partidos.estado = 'final'` **O** `live_scores.status = 'final'`. La pantalla ya lo muestra
como terminado. El arreglo de fondo es que vuelva a correr el cierre (`cerrar-partidos-espn` /
`nfl-datos-sync`), y eso **no se puede hacer desde esta sesión**: el proxy de salida bloquea
tanto `site.api.espn.com` como `*.supabase.co/functions/v1`, así que no hay forma de invocar la
edge function ni de ir por el dato a ESPN.

## 2. `live_scores` marca `final` con el marcador en NULL, y un 0-0 fabricado

| Partido | `status` | marcador | `status_detail` |
|---|---|---|---|
| NE @ SEA (10-sep) | `final` | **NULL / NULL** | `Final` |
| CHI @ TEN (29-ago, pretemporada) | `final` | **0 / 0** | `FT (recuperado del historico ESPN)` |

El primero: el escritor marcó el cierre pero no escribió los puntos. El segundo es peor —
**un 0-0 en NFL no existe en la práctica**, es un placeholder que el backfill del histórico
guardó como si fuera un resultado. Cualquier cosa que calcule aciertos sobre eso cuenta un
partido que nunca terminó 0-0.

**Mitigado:** `nfl_tablero_semana` expone `marcador_confiable`, que es `false` cuando el marcador
falta **o** cuando es exactamente 0-0. El frontend entonces escribe
*"terminado · ESPN todavía no mandó el marcador"* en lugar de pintar un resultado inventado.

**No inventé el marcador de NE @ SEA.** Cuando revisé, no estaba en ninguna tabla (lo busqué en
`historico_partidos_espn`, `marcadores_archivo`, `score_snapshots`, `live_scores` y
`resultados_historicos`; lo único que había era un 0-0 placeholder en `score_snapshots`), y no
tengo salida de red para consultarlo: el proxy bloquea ESPN y las edge functions.

**ACTUALIZACIÓN (misma sesión, ~1 hora después):** el marcador llegó solo a `live_scores` —
**NE 10 – 13 SEA**, ganó Seattle. Alguien corrió la sincronización, o corre periódicamente con
retraso. Dos cosas quedan en pie de todas formas:

- `nfl_partidos.estado` **sigue** en `'scheduled'` y `nfl_partidos.marcador` sigue en NULL para
  ese partido. Lo único que se llenó fue `live_scores`. O sea: el bug #1 es real y sigue abierto,
  y la derivación de `terminado` desde `live_scores` es justo lo que hace que la tarjeta muestre
  el resultado. Sin esa mitigación, ese partido seguiría saliendo como "programado" con el
  marcador escondido.
- El 0-0 fabricado de CHI @ TEN sigue ahí. Ese no se arregla solo.

## Qué falta para cerrarlo de verdad

1. Correr `nfl-datos-sync` / `cerrar-partidos-espn` desde un entorno con salida a ESPN.
2. Revisar por qué el escritor de `live_scores` pone `status='final'` sin los puntos — pinta a que
   escribe el estado y el marcador en pasos separados y el segundo falla en silencio.
3. Borrar o marcar el 0-0 de `CHI @ TEN` como inválido en lugar de dejarlo como resultado.


---

# Props de jugador: `public.nfl_props_jugador`

Una fila por **jugador × métrica**, resumiendo sus últimos 10 partidos: `n_ultimos10`,
`promedio`, `mediana`, `minimo`, `maximo`, `desviacion`, `n_ultimos5`, `promedio_ultimos5`,
`ultimo_partido`. Métricas: `pass_yards`, `pass_tds`, `interceptions`, `rush_yards`, `rush_tds`,
`rush_attempts`, `receptions`, `rec_yards`, `rec_tds`, `targets`, `tds_totales`.

**No trae probabilidad ni línea sugerida, a propósito.** No hay modelo de props validado; la
columna `naturaleza` dice `HISTORIAL_SIN_MODELO` para que ninguna pantalla lo presente como
pronóstico.

Dos decisiones que cambian los números y por eso quedan escritas:

- **NULL no es cero.** Un partido sin registro de esa métrica se excluye de la `n`. Promediarlo
  como 0 arrastra el promedio hacia abajo y miente sobre el jugador.
- **`tds_totales`**: si `rush_tds` y `rec_tds` son ambos NULL el partido no cuenta; si sólo uno
  es NULL, suma el otro.

Verificado contra jugadores reales: Mahomes 264.80 yardas de pase de promedio (mediana 268.5,
rango 160–352), Jacobs 57.00 yardas por tierra (mediana 64, rango 3–87).

## La advertencia de muestra, que importa más que la vista

Al 11-sep-2026 `nfl_player_game_logs` tiene 6,291 filas y 939 jugadores, **pero sólo 20 filas de
la temporada 2026** (el juego del jueves). Todo lo que una pantalla de props muestre hoy se
sostiene en el **historial 2025**. Es dato real y sirve, pero presentarlo como "forma actual"
sería falso: la temporada apenas arrancó.
