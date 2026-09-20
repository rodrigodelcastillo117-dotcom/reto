# ISS271 — La validación cruzada anidada se probó y se RECHAZÓ (y dejó el mejor diagnóstico de la sesión)

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

---

## Qué intentaba resolver

En NFL había un desacuerdo sistemático: **k más alto salía PEOR en train y MEJOR
en holdout**, con y sin margen de victoria. La maquinaria de producción elige por
`brier_train`. Si el train no representa el presente, elegir ahí elige mal.

La hipótesis: con una **validación cruzada anidada** —partir el train en dos y
elegir dentro de él, sin tocar el holdout— se elegiría mejor.

## Método

Función de laboratorio aparte, `v2.fn_team_elo_backtest_nested`. **No toqué**
`v2.fn_team_elo_backtest`, que usan NBA, NHL y WNBA; moverla movería modelos
vivos. Mismo criterio que ISS265.

```
[0, 0.49)      entrenamiento interno   760 partidos
[0.49, 0.70)   VALIDACION INTERNA      361 partidos   <- aqui se elige
[0.70, 1]      HOLDOUT                 516 partidos   <- no se toca para elegir
```

El holdout de 516 es **exactamente** el de producción, así que los Brier son
comparables uno a uno.

**Preregistro, escrito antes de ver un solo número:** rejilla k ∈ {12,16,20,24,32}
× hfa ∈ {25,40,50,65}, `min_prior=5`. Selección por **menor `brier_inner_val`**.
Regla de decisión: adoptar la elección anidada **solo si** su `brier_holdout`
mejora al del modelo vivo (k=20, hfa=25). Si no, se queda el vivo.

## Resultado: RECHAZADO

| | k / hfa | Brier holdout |
|---|---|---|
| **Elección de la validación anidada** | **16 / 40** | **0.23291** |
| Modelo vivo en producción | 20 / 25 | **0.23094** |

**La elección anidada es PEOR que la que ya está viva.** Por mi propia regla
preregistrada: se rechaza. Producción no se toca.

El mejor en holdout de toda la rejilla es k=32 / hfa=25 con **0.22887**. **No lo
tomo.** Elegirlo sería seleccionar sobre el conjunto de validación — exactamente
el error que ya me corregí una vez en ISS262. Que el holdout me diga cuál habría
sido el mejor no me autoriza a usarlo para elegir.

## Lo que sí produjo: el desacuerdo, cuantificado

Esto es más valioso que un k nuevo.

| medición | valor | qué significa |
|---|---|---|
| **Spearman(orden en validación interna, orden en holdout)** | **−0.3263** | **NEGATIVO.** Elegir por la ventana interna no es solo inútil: está ligeramente **al revés** de lo que funciona después. |
| corr(k, Brier holdout) | **−0.7867** | k más alto → **mejor** en el periodo reciente |
| corr(k, Brier validación interna) | **+0.7170** | k más alto → **peor** en el periodo viejo |

Las dos correlaciones son fuertes (|ρ| ≈ 0.72–0.79) y de **signo opuesto**. No es
ruido: es la misma variable empujando en direcciones contrarias según la época.

## El diagnóstico

`k` es la velocidad de olvido del Elo: k alto olvida rápido el pasado y sigue la
forma reciente. Que k alto sea mejor en el periodo reciente y peor en el viejo
significa una sola cosa:

> **La fuerza de los equipos de NFL cambia más rápido de lo que sugieren los datos
> de 2021–2024.**

Eso explica de un solo golpe tres cosas que estaban sueltas:

1. Por qué elegir en train falla (el train pide memoria larga; el presente pide corta).
2. Por qué el Brier de los 92 partidos más recientes es **0.25831**, peor que adivinar.
3. Por qué falla la calibración en el tramo de máxima confianza: un modelo con
   memoria demasiado larga queda **sobreconfiado** cuando el equipo ya cambió.

Ningún procedimiento de selección arregla esto, porque el problema no es **cómo**
se elige sino **sobre qué datos**. Cambiar de selección simple a anidada fue
cambiar una ventana vieja por otra ventana vieja.

## Lo que NO hice, a propósito

- **No adopté k=32** aunque gane en holdout. Contaminación.
- **No registré ninguna calibración.** `prediction_authorized` sigue en false,
  el dinero apagado.
- **No toqué la función compartida** de backtest.

## Lo que sigue, y por qué no lo hice a medias

El remedio que el diagnóstico señala no es otro método de selección: es un modelo
con **memoria corta explícita** — decaimiento temporal o ventana móvil, con el
peso de la recencia como parámetro preregistrado. Y su validación no puede ser
una sola partición: tiene que ser **walk-forward con varios pliegues**, porque
con una sola ventana ya demostré que la conclusión depende de cuál elijas.

Eso es un experimento entero, y hacerlo mal produciría justo el tipo de número
bonito que esta sesión ha estado rechazando. Queda escrito, no improvisado.

## Recuento de experimentos de la sesión

| # | experimento | veredicto |
|---|---|---|
| 1 | Calibrador por compresión (NFL) | RECHAZADO |
| 2 | Calibrador Platt (NFL) | RECHAZADO |
| 3 | Elo con margen de victoria | RECHAZADO |
| 4 | Promoción del Elo de NFL | **ACEPTADO** |
| 5 | **Validación cruzada anidada** | **RECHAZADO** |

**Cuatro de cinco rechazados.** En los cuatro existía una configuración que le
ganaba al modelo vivo en el holdout. No se tomó ninguna.

## Rollback

```sql
drop function if exists v2.fn_team_elo_backtest_nested(text,text,numeric,numeric,integer,numeric,numeric);
```

No toca datos, ni modelos, ni el gate. Es solo un laboratorio.
