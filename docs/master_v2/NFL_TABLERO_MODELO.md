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
