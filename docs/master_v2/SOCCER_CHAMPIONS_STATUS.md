# SOCCER / CHAMPIONS — ESTADO Y GATE DE EVIDENCIA

---

## 1. El hallazgo que ordena todo lo demás

`public.liga_competencia_modelo` ya compara, liga por liga, el Brier del modelo contra el del mercado y contra la baseline naive, y emite un veredicto. **Ese veredicto no lo consume nadie.**

Aplicando su propia lógica como gate (medido read-only contra producción):

| `n` mínimo exigido | Ligas que pasan | Partidos cubiertos |
|---|---|---|
| 0 | 5 | 189 |
| 30 | 5 | 189 |
| 50 | **1** | 50 |
| **100** | **0** | **0** |
| 200 | 0 | 0 |

Las cinco ligas con veredicto `usar_modelo`:

| Liga | n | Brier modelo | Brier mercado | Naive |
|---|---|---|---|---|
| Leagues Cup | 50 | 0.5812 | 0.5867 | 0.6667 |
| EFL League Two | 38 | 0.6501 | **—** | 0.6667 |
| Eredivisie | 34 | 0.6458 | 0.6733 | 0.6667 |
| LaLiga2 | 34 | 0.6488 | **—** | 0.6667 |
| Serie B Brasil | 33 | 0.6615 | **—** | 0.6667 |

Tres de las cinco **no tienen Brier de mercado**: baten a la baseline naive, pero nadie ha comprobado si baten al mercado, que es el benchmark que importa para apostar.

**A cualquier tamaño muestral defendible, el modelo de fútbol no tiene ni una liga con skill demostrado.**

Y mientras tanto: **MLS, con veredicto `callarse`** (Brier modelo 0.6834 > naive 0.6667), **aporta 112 de las 275 filas de `v_pick_canonico`**.

## 2. Por qué una superficie puede mostrar modelo con veredicto `callarse`

Porque no existe ningún consumidor del veredicto. `v_pick_canonico` se construye desde `motor_futbol_calibrado` sin consultar `liga_competencia_modelo` en ningún punto. El registro es un informe que nadie lee.

## 3. Gate implementado — `liga_evidencia_gate_v1`

`shadow-patches/soccer/liga_evidencia_gate_v1.sql` (SHADOW, no desplegado). Traduce el registro en un gate consumible, con la misma forma que `economic_eligibility_v1`.

Decisiones de diseño:

- **Fail-closed por defecto.** Liga ausente del registro → `LEAGUE_NOT_REGISTERED` → no se presenta modelo. **Champions cae aquí, y debe caer aquí.**
- **`callarse` nunca se sobreescribe**, aunque los números "casi" salgan.
- **`n` mínimo es parámetro obligatorio, sin default.** Deliberado: si alguien fija 30 para que pasen cinco ligas, tiene que escribirlo y firmarlo, no esconderlo como constante mágica. Pasar `NULL` devuelve `N_MINIMO_NOT_SPECIFIED` y no habilita nada.

`reason_code` ∈ `LEAGUE_NOT_REGISTERED` · `LEAGUE_VERDICT_SILENCE` · `LEAGUE_INSUFFICIENT_DATA` · `MARKET_BEATS_MODEL` · `SAMPLE_TOO_SMALL` · `MODEL_NOT_BETTER_THAN_NAIVE` · `MODEL_BEATS_NAIVE_ONLY` · `MODEL_BEATS_NAIVE_AND_MARKET`.

## 4. Champions League

| Check | Resultado |
|---|---|
| Eventos 72 h | 18 |
| Con odds | 18 |
| En `v_pick_canonico` | **0** |
| En `v_picks_futbol_calibrado` | **0** |
| Registrada en `liga_competencia_modelo` | **NO** |
| Bajo `liga_evidencia_gate_v1` | `LEAGUE_NOT_REGISTERED` → modelo **no permitido** |

El hueco de Champions **no se rellena**. Presentar la implícita del mercado como si fuera predicción propia sería reproducir exactamente el defecto NF-01 de NFL en otro deporte.

**Champion cuantitativo sin tocar:** `team_strength=ON`, `venue_split=OFF`, `xG=OFF`, `H2H=OFF`. No activé nada para "cubrir" Champions.

## 5. Qué haría falta de verdad para UCL

En orden, y ninguno es improvisable:

1. Registrar la competición en el mapping de ligas y en `liga_competencia_modelo`.
2. Histórico suficiente de UCL con identidad de equipo resuelta (los equipos ya existen por sus ligas domésticas; el problema es el cruce entre ligas).
3. Un `team_strength` comparable **entre ligas distintas** — el problema difícil: la fuerza relativa de un equipo neerlandés frente a uno español no sale de sus respectivas ligas domésticas sin un puente.
4. Fronteras train/dev/test y un holdout final intacto.
5. Evaluación contra mercado no-vig, no solo contra naive.

Punto 3 es el bloqueante real. Es investigación cuantitativa, no configuración.

## 6. Estado

```
SOCCER_MODEL_COVERAGE      = MLS + Liga MX (operativamente)
SOCCER_LEAGUES_WITH_SKILL  = 0 a n>=100 · 1 a n>=50 · 5 a n>=30 (3 sin baseline de mercado)
MLS_VERDICT                = callarse (modelo peor que naive) — y es el 41% de las filas canónicas
CHAMPIONS_MODEL_COVERAGE   = 0 · LEAGUE_NOT_REGISTERED
CHAMPIONS_ECONOMIC_AUTHORITY = FALSE
GATE_IMPLEMENTED           = SI (shadow, testeado en lab)
GATE_DEPLOYED              = NO
```

## 7. Recomendación

El gate no debe desplegarse a ciegas: **apagaría la presentación de modelo en casi todo el fútbol**, incluido MLS, que es la mayor parte de la superficie actual. Esa es una decisión de producto, no técnica.

Lo que sí es defendible sin discusión: **UCL no debe mostrar probabilidad de modelo mañana**, porque literalmente no existe. Y MLS no debería presentarse como predicción del modelo mientras su propio registro diga `callarse`.
