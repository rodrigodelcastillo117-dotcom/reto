# ISS290/291 — Por qué mi DELETE borraba cero, y seis semanas de historia que nadie cargaba

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-13**

---

## 1. El DELETE no fallaba. Borraba cero, en silencio

Intenté cuatro veces borrar 107 filas de `agenda_espn` y la consulta expiraba.
La causa no era el tiempo:

```
agenda_espn:  RLS ACTIVA
              una sola politica -> agenda_lectura, comando 'r' (SELECT), USING(true)
              NO HAY POLITICA DE DELETE
```

Con RLS encendida y sin política de borrado, **un DELETE desde un rol que no es
dueño afecta cero filas sin lanzar error**. Es el mismo patrón que yo mismo
documenté en ISS269: *RLS lanza 42501 en INSERT, pero en UPDATE/DELETE
simplemente no toca nada.* **Aunque no hubiera expirado, habría borrado cero.**

`absorber_agenda_espn()` sí borra porque el cron la corre como `postgres`, dueño
de la tabla, con `relforcerowsecurity = false`.

### El arreglo no fue un borrado a mano

`public.limpiar_agenda_fuera_de_alcance()` — SECURITY DEFINER, mismo patrón que
`sincronizar_estado_agenda`, revocada a `anon`/`authenticated`/`public`. Aplica
una **regla**, no un borrado puntual:

> La agenda solo guarda deportes declarados en `v2.deporte_del_producto`.

Cron **556** cada 4 horas. Si mañana vuelve a entrar algo fuera de alcance —por
un cambio mío o de quien sea— se retira solo en la siguiente vuelta.

```
limpiar_agenda_fuera_de_alcance() -> 107 retiradas
agenda_espn: soccer 281 | football 193 | baseball 11   (y nada mas)
```

## 2. G50.2 juzgaba modelos que el producto no vende

No es que quisiera ablandar un guardia. Es que **`G50.1`, su hermano en la misma
función, ya filtra por `v2.deporte_del_producto`. `G50.2` no lo hacía.** Dos
fuentes de verdad para la misma pregunta, dentro del mismo archivo.

Que un modelo RETIRADO no capture futuros no es un fallo: es lo que debe pasar.

Se partió en dos, sin silenciar nada:

| | |
|---|---|
| **G50.2** FAIL | modelo **vigente y dentro del alcance** que no captura futuros |
| **G50.2b** INFO | retirado o fuera de alcance, con partidos por delante y sin capturar |

### Y corregí mi propio texto

La primera versión de G50.2b decía *"con partidos por delante y SIN capturar"* y
listaba `nfl_elo_v1_k20_h25`, que **sí estaba capturando** (14 snapshots futuros).
Le faltaba la condición que su hermano sí tiene. Un guardia que describe mal lo
que ve es peor que no tenerlo: entrena a ignorarlo. Corregido: de 4 pasó a 3, y
los 3 son correctos.

## 3. Lo grande: seis semanas sin historia de NFL, un mes sin MLB

`G50.5b` llevaba creciendo **2 → 14 → 30 → 54**. Era el síntoma. La causa:

```
historico_partidos_espn (la tabla de historia DURADERA):
  soccer        34,545 filas   ultimo 2026-10-13   AL DIA
  football/nfl   1,986 filas   ultimo 2026-08-29   6 SEMANAS PARADA
  baseball/mlb  11,444 filas   ultimo 2026-09-11   1 MES PARADA
```

De **79 partidos de NFL jugados esta temporada: 0 en el histórico**, y solo 15 en
`live_scores`, que es efímero y se purga.

**La última línea de `pedir_historico_meses`:**

```sql
where (l.activa or l.historico_activo)
  and l.espn_endpoint like 'soccer/%'      -- <- solo futbol
```

La ingesta de historia duradera era **solo de fútbol**, aunque
`v2.deporte_del_producto` declara los tres. Esta vez **sí contradice el
gobierno** — a diferencia de `pedir_agenda_espn`, donde la lista coincidía y me
equivoqué al llamarla candado (ISS289).

### Comprobado antes de cambiar

```
football/nfl  dates=202610 -> 200, 60 eventos
baseball/mlb  dates=202610 -> 200, 38 eventos
```

El formato por mes funciona para los tres. El alcance ahora lo decide
`v2.deporte_del_producto`, igual que ya hace G50.1.

### Resultado

```
300 peticiones, 300 ok, 0 fallidas, 336 partidos nuevos

                antes            despues
baseball        0 en 30 dias     216 en 30 dias, ultimo 2026-10-13
football        0 en 30 dias      69 en 30 dias, ultimo 2026-10-13

G50.5b          INFO (54)        PASS (0)
```

## 4. Panel completo

```
G50.1  candidatos sin promover          PASS
G50.2  modelo vigente sin predicciones  PASS
G50.2b retirado sin capturar            INFO (3)  <- correcto y visible
G50.3  deporte declarado sin cerebro    PASS
G50.4  dinero sin aprobacion            PASS
G50.5  partido terminado sin resultado  PASS
G50.5b resultado sin corroborar         PASS      <- era INFO(54)
G50.6  NFL cumple en vivo               PASS      n=62, brier 0.22387, brecha 6.34pp
G50.7  ingesta de agenda                PASS      423 ok, 0 con error
G50.8  MLB fase sin evidencia           PASS
G50.9  escalas de probabilidad          PASS      10 columnas
```

Un solo INFO, y es el estado correcto hecho visible a propósito.

## 5. Límites

- **`absorber_agenda_espn` no se modificó.** Tres intentos de `CREATE OR REPLACE`
  expiraron a los 60 s en este entorno, verificado cada vez que no quedaron
  aplicados. No hizo falta: el alcance lo impone `pedir_agenda_espn` al pedir y
  `limpiar_agenda_fuera_de_alcance` al limpiar. **No sé por qué esa función
  concreta no se deja reemplazar**; queda declarado.
- `pedir_historico_faltantes` (relleno inicial) sigue usando un **rango de
  fechas**, que ESPN rechaza con 400 desde ISS283, y sigue siendo solo de fútbol.
  Está dormida (solo actúa en ligas sin ninguna historia). **Declarada, no
  arreglada.**
- MLB en postemporada sigue en **n=8**, muy por debajo de los 150 de la política.

## Rollback

```sql
select cron.unschedule('limpiar-agenda-fuera-de-alcance');
drop function if exists public.limpiar_agenda_fuera_de_alcance();
-- G50.2 y pedir_historico_meses: reponer la version anterior desde git
```

Ningún cambio tocó modelos, el gate de dinero ni un pick. Las 107 filas retiradas
eran partidos futuros de deportes fuera de alcance que yo mismo había insertado.
