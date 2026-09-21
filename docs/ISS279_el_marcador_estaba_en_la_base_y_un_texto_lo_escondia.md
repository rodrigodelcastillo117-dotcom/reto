# ISS279 — El marcador estaba en la base, correcto, y un campo de texto lo escondía

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## Cómo apareció

El dueño mandó capturas de los marcadores de la jornada y escribió:
*"Y CREO QUE TIENES INFO INCORRECTA / REVISA LOS MARCADORES VS LO QUE TU DIJISTE"*.

Fui a revisar mis seis resultados ATS contra sus capturas. **Los seis estaban
bien.** Pero al verificar encontré algo que él no había señalado y que era peor:

> **Colts @ Chiefs terminó 33-30 en tiempo extra hace seis horas, y la base decía
> `scheduled`, sin marcador.**

## La cadena completa, medida

```
live_scores (401872945):
  home_team = Kansas City Chiefs   home_score = 33
  away_team = Indianapolis Colts   away_score = 30
  status = 'live'        status_detail = 'SIN SEÑAL'
```

**El marcador correcto SÍ estaba en la base.** Lo que fallaba:

1. La CDN de ESPN dejó de devolver el evento antes de la transición a
   `STATUS_FINAL`. `sync_nfl_cdn_tick` nunca vio el cambio de estado.
2. `marcar_partidos_congelados()` **detectó el atoro correctamente** y escribió
   `status_detail = 'SIN SEÑAL'`. **Solo eso.** Nunca toca `status`.
3. `v_nfl_resultado_autoritativo` juzga por `status`:
   ```sql
   WHEN l_status = 'final' AND ... THEN 'FINAL'
   WHEN l_status IN ('live','in')  THEN 'EN_VIVO'   -- cae aqui
   ```
   Y en esa rama pone `pts_home_aut = NULL`. **Tira un marcador que tiene
   enfrente**, porque un campo de texto dice `live`.
4. `desalineado = false`, porque solo marca desalineado cuando el autoritativo
   ES final. **Ningún guardia lo veía.**

Es la **séptima vez** en este sistema que aparece la misma enfermedad: maquinaria
completa cuyo último paso no dispara. Aquí con un agravante — el detector existe,
grita correctamente, y **nadie escucha su grito**.

### Corrección a mi primer diagnóstico

Dije "atorado para siempre". **Estaba equivocado.** `evitar_live_fantasma()` pone
`status='final'` cuando `game_date < now() - 8 horas`. El sistema se cura solo a
las 8 horas. Es una **ventana ciega de 8 horas**, no un bloqueo permanente. Y esa
cura es una suposición por reloj, no una consulta a la fuente.

## El arreglo: preguntarle a ESPN, no suponer

`public.nfl_rescatar_congelados()`, cron 550 cada 5 minutos. Dos fases, como
`sync_nfl_cdn_tick`, porque `net.http_get` es asíncrono. **Solo promueve si la
fuente dice `STATUS_FINAL`.** Si el feed no lo dice, no hace nada.

### Tres correcciones a mi propio código, todas medidas

| intento | qué falló | cómo se vio |
|---|---|---|
| 1 | `site.api.espn.com` | **403 de Akamai** (de ESPN, no del proxy). El único host que responde es `cdn.espn.com`, el que ya usaba la función viva. Cambia también la forma del JSON: `content->'content'->'sbData'->'events'`. |
| 2 | pedía la fecha en **UTC** | Un partido de domingo por la noche en EE.UU. cae al día siguiente UTC. Pedía `20260921` cuando el calendario correcto era `20260920`. ESPN indexa por fecha local de EE.UU. |
| 3 | no escribía `period` | `live_scores` tiene **doce triggers**. `validate_live_score_final` llama a `is_truly_final()`, que para NFL exige `period >= 4`. Con `period` vacío devolvía false y el trigger **regresaba la fila a `live`**. Por eso `status_detail` sí se guardaba y `status` no: el trigger solo revierte `status`. |

La tercera es la interesante. El arreglo no fue inventar un `'FT'` mágico: fue
**traer el periodo que el feed ya publica**. Volvió `period = '5'` — tiempo
extra — que coincide con el "Final/OT" de la captura del dueño.

## Antes y después, en el servidor real

```
ANTES   nfl_partidos: estado='scheduled', pts_home=null, pts_away=null
        autoritativo: EN_VIVO, pts_aut = null, desalineado=false

RESCATE promovidos:1 congelados:0
        live_scores: status='final' detail='FINAL' minute='FT' period='5' 33-30
        autoritativo: FINAL, pts_aut 33-30, fuente='live_scores', desalineado=true

DESPUES nfl_reconciliar_resultado(false):
        {"antes":"scheduled null-null", "despues":"final 33-30",
         "fuente":"live_scores", "filas_actualizadas":1}
```

## El guardia, y el falso positivo que yo mismo produje

El defecto era invisible porque `desalineado=false`. Añadí **G50.5**, que mira el
reloj en vez del estado: un partido no puede llevar más de 6 horas terminado sin
resultado. (El partido de NFL más largo de la historia duró poco más de 4.)

**Su primer disparo dio FAIL con dos partidos de la semana 1 de 2026** —
Patriots @ Seahawks y 49ers @ Rams, de hace 10 y 11 días.

Los miré antes de reportarlos. **No estaban rotos:** `estado='final'`, marcadores
10-13 y 27-7. El resultado está. Lo que falta es la fila de corroboración en
`live_scores`, que nunca se creó, así que el autoritativo cae a `n_logs>0` y
devuelve `JUGADO_SIN_MARCADOR`.

**Mi guardia medía la corroboración y la reportaba como si fuera el dato.** Es el
mismo error de método que ya produjo cuatro falsos positivos en esta sesión:
leer un indicador indirecto en vez de medir la cosa. Lo corregí en el acto:

| guardia | qué mide | hoy |
|---|---|---|
| **G50.5** | terminó hace horas y **el producto no tiene el resultado** | **PASS (0)** |
| **G50.5b** | el resultado está pero **ninguna fuente lo corrobora** | **INFO (2)** |

FAIL queda para la mentira al usuario. La falta de corroboración es deuda de
observabilidad y se reporta como tal, no se esconde ni se infla.

## Límites de lo comprobado

- Probado sobre **un** partido congelado real. La ruta de varios congelados en
  fechas distintas pide una fecha por tick: correcta pero **NO PROBADA** con más
  de uno a la vez.
- No toqué `marcar_partidos_congelados`, `evitar_live_fantasma`,
  `is_truly_final` ni ninguno de los doce triggers. Todos siguen igual.
- Las 2 filas ausentes de `live_scores` de la semana 1 quedan **declaradas, no
  arregladas**: el resultado ya está en producción y rellenarlas hacia atrás no
  cambia nada que el usuario vea.

## Rollback

```sql
select cron.unschedule('nfl-rescatar-congelados');
drop function if exists public.nfl_rescatar_congelados();
drop function if exists public.gate_partido_terminado_sin_promover();
drop table if exists public.nfl_rescate_estado;
```

No borra datos ni toca los triggers. El marcador 33-30 ya promovido se queda,
porque es el resultado real y vino de la fuente.
