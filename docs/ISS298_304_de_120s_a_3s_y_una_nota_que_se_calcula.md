# ISS298-304 — De 120s a 3s, y una nota que la base calcula sola

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-15**

El dueño pidió *"llévala a 95 de calificación"*. Lo primero que hice fue medir qué
había aguantado solo dos días, y lo segundo fue convertir el "95" en algo que la
base calcula, porque **un número sin rúbrica es una opinión, y la mía no debería
ser la que cuenta.**

---

## 1. Qué aguantó solo

| cron | corridas 48h | resultado |
|---|---|---|
| `motor-cache-horizonte-largo` | 2 | **2 OK**, 52s. Arreglado y sostenido |
| `reto-global-candidate-snapshot-v1` | 191 | 178 OK / 13 mal — **las 13 son las viejas del día 13** |

**Cero fallas en 24 horas.** Pero el tiempo no era plano:

```
Oct 14 10:00  47s      Oct 14 19:00  85s  <- pico
Oct 14 13:00  57s      Oct 15 02:00  66s
Oct 14 16:00  75s      Oct 15 09:00  59s
```

Pico de 85-89s contra un techo de 120s = **74%**. Eso no es seguro: en un día con
más partidos cruza. Faltaba el punto caliente que no había tocado.

## 2. El punto caliente, por tercera vez el mismo patrón

Capturé el plan real otra vez (el cliente MCP muere a los 60s, así que fuera de
banda). El escaneo de fútbol que costaba 256,117 ms en ISS293 ahora cuesta
**116 ms**. El nuevo dominante:

```
Nested Loop   propio 60,910 ms   97.2%   loops=39   98 filas
  Join Filter: (v_1.canonical_event_id = v.canonical_event_id)
  -> Hash Join      401 ms,  39 filas              (externo)
  -> Nested Loop  1,575 ms x 39 loops = 61,425 ms  (interno, RE-EJECUTADO)
```

De dónde sale el auto-join:

```sql
FROM v_futpro_publication_v3 s
LEFT JOIN v_soccer_publication_form_guard_v2 fg
       ON fg.espn_event_id = s.canonical_event_id
WHERE ... AND COALESCE(fg.exclude_from_top, false) = false
```

…y `v_soccer_publication_form_guard_v2` **lee `v_futpro_publication_v3`**. Así que
entra dos veces: como `s` y dentro de `fg`. El planificador inlinea el form guard
y lo recalcula por cada fila externa.

Y el form guard es caro porque llama **dos veces por fila** a
`v2.fn_soccer_publication_form_context_v1` (HOME y AWAY).
**Medido: el form guard solo = 98 filas en 1,738 ms. Por 39 loops = ~61 s.**
Cuadra con el plan al milisegundo.

Lo que descarté antes de tocar nada: que alguna función estuviera marcada
`VOLATILE` (eso obliga a re-ejecutarla por fila). **Las doce `v2.fn_soccer_*` son
`STABLE`.** No era eso.

### El arreglo

Un CTE `MATERIALIZED` que calcula el form guard **una** vez. De todo lo que
produce esa vista, aquí solo se consume `exclude_from_top`, así que el CTE trae
dos columnas.

### La prueba

La vista depende de `now()` y de una ventana de 48h, así que tomé la huella **dos
veces seguidas antes** de tocar nada, para descartar deriva natural:

```
ANTES  1a vez:  35 filas  md5 7c9a12171e7f9cd4d52e77832f1e9649   59,121 ms
ANTES  2a vez:  35 filas  md5 7c9a12171e7f9cd4d52e77832f1e9649   <- identicas
DESPUES:        35 filas  md5 7c9a12171e7f9cd4d52e77832f1e9649    8,748 ms
```

Y en producción, el cron:

```
10:02   succeeded  72s   <- antes
10:17   succeeded   3s   <- despues
```

**De 120s fallando a 3 segundos.** 2.5% de su techo. El recorrido completo de los
tres arreglos: 120s (fallando) → 48s → **3s**.

## 3. La cobertura de fútbol: 588 llamadas donde bastan 374

`refresh-cobertura-soccer-20m`: promedio **89s de un techo de 120s**, cada 20
minutos. `v2.fn_refresh_crossleague_coverage_jobs` arma dos filas por partido
(local y visitante) de los próximos 21 días y por cada fila llama a
`v2.fn_crossleague_features_canonical`. Pero el resultado depende **solo del
equipo**, y el paso final agrupa por equipo de todos modos.

```
294 partidos -> 588 llamadas  |  374 equipos distintos -> 374 necesarias  |  1.57x de mas
```

**Lo que NO toqué:** `fn_crossleague_features_canonical`. Es la que alimenta al
cerebro en producción y trae documentado un fallo sutil de selección de liga
(Coventry City entraba con 31 partidos del Championship y datos de mayo).
Abaratarla sería tocar el modelo. Se abarató **a quien la llama**, que es
planeación de cobertura.

### El detalle que casi se me va

`api_team_id` sale de `max(m.api_sports_id)` uniendo por `lower(espn_name) =
lower(team_name)`, y en la versión original hay varias filas por equipo que
pueden traer **grafías distintas** del nombre (`home_nombre` vs `away_nombre`).
Colapsar el nombre antes de ese join perdería un match que solo existe con la
otra grafía — **sustitución silenciosa de identidad en su versión por omisión.**
Así que se separaron las dos cosas: la función cara se llama una vez por equipo,
pero el mapa de nombres sigue viendo **todas** las grafías.

```
10:00   succeeded  98s   <- antes
10:20   succeeded  65s   <- despues
Trabajos de cobertura: 556 / 55 pendientes / 508 con api_id   ANTES Y DESPUES
```

## 4. La saturación de workers no era carga: era alineación

`CRON_SATURACION_DE_WORKERS` había subido de 11 a **17** corridas perdidas. Pero
al mirarlo de verdad:

**Las 17 fueron en una sola hora, las 07:00.** No es una fuga constante.

Y la utilización real de los 6 workers por los seis trabajos más pesados es
**1,493 segundos-worker por hora de 21,600 disponibles = 6.9%.**

Lo que pasaba a las 07:00:01, con un segundo de diferencia entre ellos:

```
refresh-cobertura-soccer-20m        94s
futbol-jugadores-pedir              47s
reto-futpro-analysis-snapshot-v1    44s
reto-prediction-ledger-capture-5m   29s
= 185 segundos-worker arrancando EN EL MISMO INSTANTE, 4 de 6 workers
```

y los 17 trabajos que venían detrás perdieron su turno.

**No es un problema de frecuencia: es que decenas de crons `*/N` disparan todos
en el minuto 0.** La respuesta correcta no es bajar frecuencias (eso cuesta
frescura) sino **desfasar los minutos, que no cuesta nada.** El sistema ya usaba
esa convención (`1-59/5`, `2-59/15`, `4-59/15`).

```
ANTES                         DESPUES
minuto 0: cobertura   96s     minuto 0: ledger      19s
          jugadores   43s     minuto 1: read-ctx    11s
          analisis    27s     minuto 2: candidatos   3s
          ledger      19s     minuto 3: analisis    27s
minuto 1: read-ctx    11s     minuto 4: motor-cache 24s
minuto 2: candidatos  67s     minuto 5: jugadores   43s
minuto 4: motor-cache 24s     minuto 7: cobertura   65s
```

Una escalera en vez de un pico. Misma cadencia, mismo trabajo, cero pérdida de
frescura.

## 5. Un guardia que le exigía a una foto que viera el futuro

`G44.2` daba FAIL: *"Kyren Williams: declara 21 juegos y debería declarar 22"*.

El guardia hacía `select distinct ... n_history` sobre
`v2.fantasy_projection_snapshot_v2` **sin elegir una foto**. La semana 6 tiene 840
filas = ~60 construcciones × 14 jugadores, así que el DISTINCT se quedaba con
todos los valores históricos:

```
Courtland Sutton  n_history=21  en 26 fotos (Oct 6 -> Oct 12, asof Oct 5)
                  n_history=22  en 30 fotos (Oct 12 -> Oct 15, asof Oct 12)  <- vigente
Kyren Williams    n_history=21  en 32 fotos (asof Oct 5)
                  n_history=22  en 24 fotos (asof Oct 13)                    <- vigente
```

**Las fotos vigentes ya declaran 22 y están correctas.** Las viejas declaraban 21
porque cuando se construyeron la semana 5 **no estaba calificada todavía**:

```
Courtland Sutton semana 5 calificada 2026-10-12 06:37   (foto: asof 2026-10-05)
Kyren Williams   semana 5 calificada 2026-10-13 06:37
```

Declarar 21 era lo **correcto**: incluir la semana 5 habría sido ver el futuro.
El guardia le exigía a una foto de hace nueve días que supiera algo que se
calificó después. **Tercera vez el mismo error de método** (ISS279: medir un
indicador indirecto; ISS296: medir un evento imposible de medir).

Arreglo: evaluar la foto **vigente** de cada jugador, con
`distinct on (espn_player_id) order by built_at desc`, y decir en el detalle
**sobre qué foto** habla.

Lo que sigue protegido, que es el motivo por el que el guardia existe (ISS193: el
modelo no veía los 23 toques y 3 TD de Montgomery en la semana 1): si alguien
vuelve a cortar la fuente a solo 2025, la foto vigente declararía 17 contra 21
esperados y **G44.2 falla igual**. El detector no se debilita.

```
G44.2  FAIL -> PASS  '12 jugadores, todos con historial = 2025 mas las semanas
                      calificadas de 2026. Foto vigente del 2026-10-15 10:01'
```

## 6. Dos correcciones a lo que yo mismo dije hace dos días

- Dije que `espejo-apifootball-live` *"ocupa un worker el 85% del tiempo"*. **Me
  basé en su máximo.** Su promedio es **2 segundos**: se protege con advisory
  locks y sale temprano si no hay partido en vivo. Ocupa ~1.7%.
- Dije que la saturación de workers era *"estructural"*. Es **una ráfaga por
  alineación de minutos**, y se arregla sin tocar frecuencias (§4).

## 7. La nota, calculada

Antes no existía forma de ver el panel completo: correr los 63 `gate_*()` pasa
del `statement_timeout` de 120s. **Un panel que no se puede leer entero es un
panel que nadie lee entero.**

| objeto | qué hace |
|---|---|
| `v2.panel_guardias_snapshot` | fotos del panel, append-only, agrupadas por `corrida_id` |
| `v2.panel_guardias_detallado(p_como)` | reporta la **función** de origen, no solo el nombre del guardia |
| `v2.capturar_panel_completo()` | captura todo en una transacción, desde cron con techo propio |
| `v2.panel_fotos` | resumen por foto, con `completa` = cubre todas las funciones |
| `v2.calificacion_peso` | **los pesos, en una tabla que el dueño puede cambiar y auditar** |
| `v2.calificar_backend()` | un renglón por dimensión más el TOTAL |
| cron `panel-guardias-foto` | cada 6 horas |

### Cómo NO se deja inflar

1. **Solo califica una foto COMPLETA.** Una foto a medias sería una nota inflada
   por omisión.
2. **Tope duro de 70** si hay FAIL en un guardia crítico (dinero, precio,
   identidad, RLS, superficie cruda). Eso no son puntos de calidad: son
   violaciones.
3. **Tope de 92 si hay CUALQUIER FAIL.** Un sistema con un foco rojo conocido no
   es un 95. Para pasar de 92 los rojos tienen que ser **cero**.
4. Los seis `gate_*` que devuelven jsonb sin veredicto mecanizable **no cuentan
   como PASS**: cuentan como no medidos.

### Y lo que la nota NO dice

Lo lleva escrito la propia función:

> *ESTA NOTA NO DICE NADA SOBRE SI LA APP GANA DINERO: mide integridad del
> backend. El valor esperado es otro eje.*

Un backend de 100 puede perder plata. Fútbol **le gana a la tasa base y le pierde
al precio de cierre**, y eso no lo arregla ningún refactor.

## 8. Dónde quedó el panel

```
CRON_ACTIVO_FALLANDO_SIEMPRE         FAIL(1)  -> PASS(0)
CRON_CORRIDAS_QUE_PEGAN_EN_EL_TECHO  FAIL(16) -> FAIL(1)   (historial de cobertura)
G50.12 cron al borde                 FAIL(8)  -> FAIL(3)
G44.2 fantasy ve la temporada        FAIL     -> PASS
```

Sigue abierto, y **dos de ellos no son código**:

- **BTTS de fútbol con n=313 sin superar la tasa base.** Decisión del dueño.
- **`rongo` con `user_id = NULL`.** Necesita su correo, no mi corazonada.
- `captura_prospectiva B_COBERTURA_MODELO (4)`: motivos declarados
  (`SAMPLE_BELOW_MINIMUM`, `POLICY_NOT_APPROVED`, `PHI_NOT_SERVABLE`), con
  `A_CAPTURA_PREEVENTO = PASS(0)`: **no se perdió muestra**.
- Las cinco líneas P0 de precio sin clasificar: leídas, ninguna lee un precio,
  firma humana pendiente (ISS294).
- **El frontend sigue NO PROBADO.** Red bloqueada por política de la organización.

**Por eso no puedo entregar un 95 yo solo:** el tope de 92 exige cero rojos, y dos
de los rojos son decisiones tuyas. Eso es la rúbrica funcionando, no una excusa.

## Rollback

```sql
-- ISS301
--   quitar el CTE fg_una_vez de v_reto13m_global_candidate_source_v2 y volver al
--   LEFT JOIN directo. NO se recomienda: devuelve el cron a 72s.
-- ISS302
--   volver a llamar fn_crossleague_features_canonical por lado-partido.
--   NO se recomienda: devuelve el cron a 98s.
-- ISS303
--   quitar el distinct on (espn_player_id). NO se recomienda: vuelve a comparar
--   fotos de hace nueve dias contra el presente.
-- ISS304 (desfase de minutos, reversible al instante)
select cron.alter_job((select jobid from cron.job where jobname='refresh-cobertura-soccer-20m'),      schedule => '*/20 * * * *');
select cron.alter_job((select jobid from cron.job where jobname='futbol-jugadores-pedir'),            schedule => '*/10 * * * *');
select cron.alter_job((select jobid from cron.job where jobname='reto-futpro-analysis-snapshot-v1'),  schedule => '*/5 * * * *');
-- ISS299/300
drop function if exists v2.calificar_backend();
drop table if exists v2.calificacion_peso;
drop view if exists v2.panel_fotos;
drop function if exists v2.capturar_panel_completo();
drop function if exists v2.capturar_panel_tramo(text,uuid);
drop function if exists v2.panel_guardias_detallado(text);
drop table if exists v2.panel_guardias_snapshot;
select cron.unschedule('panel-guardias-foto');
```

No se borró un dato, no se tocó un modelo, no se movió un pick, no se encendió
dinero. Las tres huellas antes/después quedaron idénticas.
