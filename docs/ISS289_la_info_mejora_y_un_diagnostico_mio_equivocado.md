# ISS289 — Sí, la info mejora. Y NBA no estaba bloqueada: está retirada a propósito

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-13**

---

## 1. La respuesta: sí mejora, y no solo en volumen

Trece días desde la última medición (30 sep → 13 oct):

| medida | 30 sep | 13 oct | |
|---|---|---|---|
| **NFL** n en vivo | 32 | **62** | +94% |
| NFL Brier | 0.22538 | **0.22387** | mejora |
| NFL brecha calibración | 6.38 pp | **6.34 pp** | PASS se sostiene |
| **Fútbol** `soccer_canonical_v2` n | 165 | **310** | +88% |
| Fútbol vs tasa base (upper95) | +0.01031 | **−0.01567** | **cambió de veredicto** |
| Fútbol vs mercado (delta) | +0.01241 | **+0.02188** | **peor** |
| **MLB** postemporada n | 0 | **8** | primera evidencia |
| Momios de cierre · fútbol | 686 | **859** (38 ligas) | |
| Momios · hockey / basket / NFL | 5 / 36 / 48 | **89 / 84 / 79** | |
| Agenda, partidos por corrida | 84 | **302** | |
| Ingesta de agenda | 396 ok / 0 err | **396 ok / 0 err** | aguanta sola |

**Lo importante no es que crezca: es que un veredicto cambió.** Con 310 partidos,
fútbol pasó de "no demostrado" a **le gana a la tasa base**. Y al mismo tiempo su
desventaja contra el mercado **se ensanchó** de +0.0124 a +0.0219.

Las dos conclusiones del 30 de septiembre se confirmaron con más datos, en
direcciones opuestas: **habilidad real, y aun así por debajo del precio.** La
decisión de no bajar el piso editorial queda más firme que antes.

## 2. Me equivoqué con NBA, dos veces

El 21 de septiembre y otra vez hoy dije que NBA era *"tu mejor modelo, bloqueado
por una lista escrita a mano"*. Vi esto en `pedir_agenda_espn`:

```sql
or espn_endpoint in ('baseball/mlb','football/nfl')
```

y lo llamé el candado de ISS262. **Estaba equivocado.** Esa lista más la rama de
soccer es **exactamente** `v2.deporte_del_producto` = soccer, baseball, football.
Coincidía con el gobierno; no lo contradecía.

Lo que no había leído, y que la base dice con todas sus letras:

```
v2.cerebro_autorizado -> basketball/nba_elo_v1_k24_h50 = RETIRADO
  "El producto no vende NBA. Su sello es OOS_SKILL_CALIBRATED con n_holdout=1352,
   brier 0.20937, upper95 -0.03103 y brecha 4.90pp -- o sea el modelo es bueno,
   pero es de un deporte que no se vende. Se retira POR ALCANCE, NO POR CALIDAD."
  retirement_enforced_at = 2026-09-21 17:39:35
```

`hockey/nhl_elo_v1_k12_h25` también RETIRADO, y además su sello es `OOS_FAIL`.

**NBA no publica porque el dueño decidió que no se vende, y lo dejó escrito.** No
es un defecto. Mi lectura del código fue superficial: encontré un `IN (...)` y lo
clasifiqué por su forma en vez de comprobar contra qué se comparaba.

### Lo que hice y revertí

Cambié la función para que mandara el catálogo (`ligas_master.activa`) en vez de
la lista. Resultado medido:

- agenda: basketball 0 → 43, hockey 0 → 64
- peticiones por corrida: 396 → 423
- **`G50.2` pasó de PASS a FAIL**: tres modelos retirados con partidos por delante
  que no capturan futuros

Y revertirlo **no pierde nada**: `v2.team_history_event` ya recolecta NBA (4,578
filas, 41 en las últimas dos semanas) y NHL (3,052, 89) por
`absorb_team_sports_history` (cron 470) — una ruta que nunca pasó por la agenda.

Mi cambio duplicaba recolección existente, sumaba peticiones para deportes fuera
de alcance y encendía un guardia. **Revertido.**

Se conserva de ISS283 lo que sí era defecto real: **una petición por día**, porque
ESPN responde 400 a cualquier rango de fechas.

## 3. Lo que NO quedó limpio — declarado, no escondido

Las 107 filas de basketball/hockey que yo metí en `agenda_espn` **siguen ahí**.
Intenté borrarlas cuatro veces y el `DELETE` expira a los 60 segundos, incluso
**para una sola fila**. Comprobado y descartado:

- sin candados sobre la tabla (`pg_locks` vacío)
- sin sesiones activas ni inactivas-en-transacción
- sin triggers propios
- sin llaves foráneas apuntando a ella
- `replica identity` = default, no FULL

Los `SELECT` sobre la misma tabla responden al instante. **No sé por qué el DELETE
se cuelga.** Lo declaro como no resuelto en vez de inventar una causa.

**Consecuencia, y es culpa mía:** `G50.2` se queda en FAIL hasta que esos partidos
se jueguen (el último es el 22 de octubre), porque `absorber_agenda_espn` borra lo
que pasa de 6 horas del saque. Se cura solo en ~9 días. Mientras tanto ese guardia
no sirve para detectar un fallo real.

## 4. Lo que el guardia destapó, y sí vale la pena

`G50.2` lee `v2.team_elo_selected_model` (la promoción del laboratorio) y llama
"promovido" a un modelo que `v2.cerebro_autorizado` tiene **RETIRADO**. Son dos
fuentes de verdad distintas para la misma pregunta.

Hoy no causa daño porque los retirados no tienen partidos. **No lo toco**: cambiar
un guardia para que un rojo se ponga verde es justo lo que no se hace, y el rojo
de ahora lo provoqué yo, no el sistema. Queda declarado para decidirlo en frío.

## 5. Estado de los guardias

```
G50.4 dinero sin aprobación         PASS
G50.6 NFL cumple en vivo            PASS   n=62, brier 0.22387, brecha 6.34pp
G50.7 ingesta de agenda             PASS   396 ok, 0 con error
G50.8 MLB fase sin evidencia        PASS   (MLB no publica ahora)
G50.9 escalas de probabilidad       PASS   10 columnas
G50.1 candidatos sin promover       PASS
G50.3 deporte declarado sin cerebro PASS
G50.2 promovido sin predicciones    FAIL   <- lo causé yo, se cura en ~9 días
```

## Rollback

La reversión ya está aplicada. Para volver a la versión de catálogo habría que
reponer el `ISS289` original, pero **no se recomienda**: contradice
`v2.deporte_del_producto`.
