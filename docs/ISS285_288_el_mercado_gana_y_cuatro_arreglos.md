# ISS285-288 — El mercado le gana a fútbol, y cuatro arreglos

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-30**

El dueño pidió arreglar lo necesario y dejar la mejor app posible con los datos
que hay. Lo primero que había que hacer era la prueba dura, porque de ella
dependía si valía la pena tocar el producto.

---

## 1. La decisión: NO se baja el piso editorial

Ayer medí que fútbol le gana a la tasa base y sugerí un piso relativo. **Hoy lo
probé contra el precio de cierre y la idea queda rechazada.**

| referencia | n | Brier RETO | Brier referencia | delta | upper95 | veredicto |
|---|---|---|---|---|---|---|
| tasa base real (45.0/24.8/30.2) | 351 | 0.60439 | 0.64474 | **−0.04035** | **−0.01892** | le gana |
| **precio de cierre sin vig** | 343 | 0.60338 | **0.58671** | **+0.01666** | +0.03828 | **pierde** |

Y por versión de modelo, **el mercado gana en las cuatro, sin excepción**:

| modelo | n | Brier | delta vs mercado |
|---|---|---|---|
| `soccer_canonical_v2` | 165 | 0.62870 | +0.01241 |
| `crossleague_v1` | 138 | 0.62141 | +0.01780 |
| `dc-2026.09.1` | 42 | 0.46873 | +0.02825 |
| `crossleague_v1_1` | 6 | 0.49392 | +0.02438 |

**Trampa que este corte desarma:** `dc-2026.09.1` tiene un Brier de 0.469, muy
por debajo del resto, y parece el mejor modelo. No lo es: el mercado en esos
mismos partidos da **0.440**. Eran partidos fáciles. Contra el precio es la
**peor** de las cuatro. Por eso la referencia tiene que ser el mercado y no el
valor absoluto.

**Consecuencia:** publicar más picks de fútbol sería publicar picks que el precio
ya valora mejor. El piso de 58% se queda. La decisión la toma la evidencia.

*El precio de mercado se usa aquí SOLO como vara de validación. Nunca para
elegir un pick ni para sustituir P_RETO.*

## 2. El error que casi reporto como victoria

La primera corrida me dio **Brier del mercado = 0.99159** y el veredicto
"RETO LE GANA AL MERCADO" por 0.39. Un volado uniforme de tres da 0.667: que la
línea de cierre puntúe peor que el azar es imposible en un mercado real.

**Era mi error.** `momios_cierre_espn.p_home` está en **fracción (0-1)** y la
volví a dividir entre 100, convirtiendo 0.45 en 0.0045.

Lo cacé porque el número era absurdo, **no porque el sistema me avisara**. Eso se
arregla abajo.

### Auditoría de la misma trampa en código vivo

Busqué toda función o vista que mezcle `momios_cierre_espn` con una conversión de
100. Hay una: **`v2.refresh_mlb_market_reference`**. La revisé línea por línea:
hace `s.p_home/100 = o.p1` (snapshot en porcentaje) y usa `m.p_home` tal cual
(mercado en fracción). **Está correcta.** La cifra de MLB contra DraftKings de
ISS270 se sostiene.

## 3. Cuatro arreglos

### ISS285 — Fantasy llevaba 4 corridas fallando

```
ERROR: record "p" is not assigned yet
```

En `build_fantasy_projection_snapshot_v2` solo la rama `else` asignaba el record
`p`. Las otras cuatro (`IDENTITY_BLOCKED`, `NO_SCHEDULE`, `UNAVAILABLE_OUT`,
`UNSUPPORTED_POSITION`) lo dejaban sin asignar, y el INSERT lo referencia dentro
de un `CASE`. PL/pgSQL necesita la estructura del record para **planear** la
sentencia; no le basta con que la rama no se tome.

**Un solo jugador bloqueado no perdía su fila: tumbaba la corrida entera.**

Arreglado con variables escalares. Y se cerró de paso una fuga que antes no
existía porque reventaba: sin reiniciarlas en cada vuelta, un jugador bloqueado
habría heredado la proyección del anterior.

```
Después: {"capturados":848,"errores":0,"graded_previous":19}
```

### ISS286 — `momios_cierre_espn.deporte` estaba NULL en todo menos NFL

333 filas recientes sin etiqueta, mientras `endpoint` y `liga` sí venían llenos.
No era pérdida de datos, pero cualquier consulta que filtrara por `deporte`
perdía lo reciente **en silencio** — yo mismo caí ayer.

Quien escribe es una edge function. En vez de redesplegar TypeScript, la etiqueta
se **deriva de `endpoint`** con un trigger, más relleno de lo ya guardado.

| antes | después |
|---|---|
| ⚽ 515 (al 24 sep) · ⚾ 240 (al 19 sep) · **333 sin etiqueta** | **⚽ 686 en 38 ligas** · ⚾ 366 · 🏈 48 · 🏀 36 · 🏒 5 · **0 sin etiqueta** |

La etiqueta escondía que fútbol cubre **38 ligas**, no un puñado.

### ISS287 — Registro de escalas, y G50.9

Dos convenciones conviven bajo el mismo nombre de columna, y **la escala no se
adivina mirando un valor**: 0.67 es válido en las dos.

| fracción 0-1 | porcentaje 0-100 |
|---|---|
| `momios_cierre_espn.p_*` | `soccer_prediction_v2.p_*` |
| `team_elo_holdout_prediction.p_home` | `mlb_learning_snapshot.p_home` |
| `lab_mlb_forward.p_raw_home` | `nfl_decision_snapshot.p_home_ml` |

`v2.escala_probabilidad` la declara y **G50.9** la verifica: una fracción nunca
pasa de 1; un porcentaje real siempre supera 1 en algún evento.

```
G50.9  PASS — 10 columnas verificadas, todas dentro de su escala
```

### ISS288 — La medición de fútbol, persistente

`public.v_soccer_live_validation_v1` mide contra **las dos** referencias, por
versión de modelo, y lleva escritas las escalas en el propio SQL para que el
error de arriba no pueda repetirse ahí.

## 4. Estado de los guardias

```
G50.4 dinero sin aprobación        PASS (0)
G50.5 partido terminado sin result PASS (0)
G50.5b resultado sin corroborar    INFO (30)  <- deuda declarada, creciendo
G50.6 NFL cumple en vivo           PASS  n=32, brier 0.22538, brecha 6.38pp
G50.7 ingesta de agenda            PASS  396 ok, 0 con error
G50.8 MLB fase sin evidencia       INFO  postemporada, n=2
G50.9 escalas de probabilidad      PASS (10 columnas)
```

## 5. Lo que queda declarado y NO arreglado

- **G50.5b va en 30 y subiendo** (era 2 el 21 de sep). Son partidos de NFL con
  resultado correcto en producción pero sin fila en `live_scores` que lo
  corrobore. No hay daño al usuario; sí se pierde la verificación cruzada.
  Arreglarlo es decidir cuánto retener `live_scores`, que es decisión de
  almacenamiento, no un defecto.
- **MLB en postemporada sigue con n=2.** G50.8 en INFO.
- La edge function `cierre-espn-sync` sigue sin mandar `deporte`. El trigger lo
  cubre, pero el origen no se corrigió.

## Rollback

```sql
drop view if exists public.v_soccer_live_validation_v1;
drop function if exists public.gate_escala_de_probabilidades();
drop table if exists v2.escala_probabilidad;
drop trigger if exists trg_momios_cierre_deporte on public.momios_cierre_espn;
drop function if exists public.tg_momios_cierre_deporte();
-- ISS285 se revierte restaurando la version anterior de
-- v2.build_fantasy_projection_snapshot_v2 (volveria a fallar).
```

El relleno de `deporte` se revierte poniendo NULL donde `endpoint not like 'football/%'`.
Ningún cambio borró datos, tocó modelos, el gate de dinero ni un pick.
