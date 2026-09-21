# ISS276 — «Uno por deporte», y por qué hoy eso da UN pick

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## La regla, y mi sobrecorrección

El dueño dijo: *"un pick solo. de todos los deportes, el mejor.. esa es la regla.
que tenga mucha seguridad la AI segun el analisis"*.

Lo leí como **una sola fila global** y lo implementé así (ISS276). Me aclaró:
*"pero como tenemos ahorita 3 deportes, son 3 picks"*. Es **el mejor de CADA
deporte**. Revertido en ISS276b.

Regla final, en firme:

- El mejor pick **de cada deporte**
- de **un solo día**: el más próximo con contenido
- en **orden cronológico**
- sin nada ya empezado (`kickoff > now()`)
- con desempate determinista (`p_reto_pct` desc, luego `kickoff`, luego id), para
  que la app no cambie de opinión entre recargas

## Por qué hoy sale UN pick y no tres

Esto es lo que de verdad importa, y es medición, no teoría. **No tenemos tres
deportes con picks. Tenemos dos, y en días distintos:**

| día | deporte | partidos sobre el piso de 58% | el mejor |
|---|---|---|---|
| **Lunes 21** | football | **1** | Gana LA Rams · 70.0% |
| **Martes 22** | baseball | **5** | Gana Atlanta Braves · 70.1% |
| — | **fútbol** | **0** | — |

Como la vista se queda con **un solo día**, y ese día (lunes) solo tiene fútbol
americano, el resultado es una fila.

**«Uno por deporte» y «uno global» dan exactamente lo mismo hoy.** No porque la
regla falle, sino porque en un día dado solo un deporte tiene contenido que
supere el piso.

## Por qué fútbol aporta CERO

Sus dos únicos candidatos no llegan:

```
20 Sep 20:05   P_RETO 51.8%   ANALYSIS_ONLY_P_RETO_BELOW_RECOMMENDATION_GATE
23 Sep 19:30   P_RETO 54.0%   ANALYSIS_ONLY_P_RETO_BELOW_RECOMMENDATION_GATE
```

*"probabilidad oficial válida, pero debajo del gate predefinido"*. Es decir: el
modelo sí opina, y su opinión se publica como **análisis**; simplemente no la
presenta como pick. Coherente con lo medido todo el día: el cerebro de fútbol no
tiene habilidad demostrada (upper95 **+0.0064** contra adivinar, y **pierde**
contra el precio de la casa en los cuatro mercados).

## Verificación final, leída como la lee la app

```
anon: 1 fila, 1 dia, 1 deporte
  [football · 21 Sep 18:15 · "Gana Los Angeles Rams" · 70.0%]
con_dinero = 0
```

## Lo que el dueño debe esperar de aquí en adelante

| cuándo | qué verá |
|---|---|
| hoy (lunes el día más próximo) | **1 pick** (NFL) |
| cuando el martes sea el más próximo | **1 pick** (MLB, el mejor de 5) |
| un día con NFL + MLB + fútbol sobre el piso | **3 picks** |
| un día sin nada sobre el piso | **0 picks** |

Tres picks es posible, pero **requiere que los tres deportes tengan algo bueno el
mismo día**. Con fútbol sin habilidad demostrada y NFL jugando una vez por
semana, eso será raro hasta octubre, cuando NFL pase al cerebro maduro
(`nfl_form_ml_v1`, Brier 0.21033, 69.92%).

## La palanca, si se quieren más picks

El piso editorial de **58%**. Bajarlo llena la pantalla de inmediato:

| piso | picks del lunes 21 |
|---|---|
| 58% (actual) | **1** |
| 52% | 4 (entran tres de MLB en 52.4%, 54.4%, 55.4%) |

Esos tres son prácticamente volados. **Mi recomendación es dejar el piso en 58%**,
pero es decisión del dueño y el costo está medido.

## Rollback

La versión anterior está en el historial de migraciones (`iss275`, `iss276`).
Ninguna fila tocada; solo la forma de la vista.
