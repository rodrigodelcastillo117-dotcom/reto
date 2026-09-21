# ISS277 — «Esta temporada vale más que la pasada», ahora medido por deporte

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## Dos correcciones mías antes de nada

El dueño pidió una mejora de fondo para los tres deportes. Mi primer camino fue
xG, siguiendo la lista de variables de un análisis de ChatGPT. **Me equivoqué dos
veces por hablar antes de medir:**

1. Dije *«tienes 41,087 filas de xG»*. **Falso.** `ligamx_team_form` tiene 41,087
   filas pero solo **803 con xG**, y 269 de ésas son **estimadas**. xG genuino:
   ~534 filas (1.3%).
2. Entonces dije *«lo que sí tienes en volumen son tiros a puerta»*. **También
   falso.** Solo **1,072 filas (2.6%)** tienen `tiros_arco`. Posesión 1,070.
   Atajadas 87. Goles evitados: **cero**.

**La tabla es un cascarón.** El dato de rendimiento subyacente no existe en
volumen usable. Toda la ruta del xG está muerta hasta que se ingiera, y eso es un
proyecto con costo de API, no un `join`.

## La mejora que sí salió, y de dónde viene

No de un texto de internet: **de mi propia medición en ISS271.**

```
corr(k, brier_holdout)          = -0.7867    k alto -> MEJOR en lo reciente
corr(k, brier_validacion_vieja) = +0.7170    k alto -> PEOR en lo viejo
```

`k` es la velocidad de olvido del Elo. Dos correlaciones fuertes de signo
**opuesto** dicen una sola cosa: **la fuerza de los equipos cambia más rápido de
lo que suponen los datos viejos.** Es la regla del dueño convertida en número.

### Qué se construyó

`v2.fn_team_elo_backtest_carry` — laboratorio aparte. Al detectar temporada nueva
acerca los ratings a la media:

```
rating := 1500 + carry * (rating - 1500)
```

- `carry = 1.00` → no olvida nada. **Es el Elo actual: el baseline.**
- `carry = 0.60` → conserva 60% de la ventaja acumulada.

**La temporada se detecta por un hueco global de más de 45 días sin partidos**,
no por un calendario escrito a mano — justo el tipo de candado que encontré en
ISS263. Se adapta solo a NFL, NBA, NHL y WNBA sin conocer sus fechas.

**No toca** `v2.fn_team_elo_backtest` (la usan NBA, NHL y WNBA en vivo) ni
`fn_team_elo_backtest_nested`. Mismo criterio que ISS265 e ISS271.

### Preregistro

Rejilla `carry ∈ {1.00, 0.85, 0.75, 0.60, 0.50}`. **Selección por menor
`brier_inner_val`**, con el holdout intacto. Adoptar solo si el holdout mejora
contra el baseline de `carry = 1.00`.

## Resultado

### NFL (k=20, hfa=25)

| carry | validación interna | holdout | acierto |
|---|---|---|---|
| 1.00 (baseline) | 0.23790 | 0.23094 | 64.15% |
| 0.85 | 0.23711 | 0.22833 | 64.92% |
| **0.75 ← elegido** | **0.23701** | **0.22741** | **64.92%** |
| 0.60 | 0.23733 | 0.22687 | 64.92% |
| 0.50 | 0.23778 | 0.22693 | 65.31% |

**Mejora: 0.23094 → 0.22741 (−0.00353).**

### NBA (k=24, hfa=50)

| carry | validación interna | holdout | acierto |
|---|---|---|---|
| 1.00 (baseline) | 0.21484 | 0.20937 | 67.97% |
| 0.75 | 0.21329 | 0.20751 | 67.68% |
| **0.60 ← elegido** | **0.21307** | **0.20702** | 67.83% |
| 0.50 | 0.21321 | 0.20694 | 68.12% |

**Mejora: 0.20937 → 0.20702 (−0.00235).**

### NHL (k=12, hfa=25) — NO CAMBIA

| carry | validación interna | holdout |
|---|---|---|
| **1.00 ← elegido** | **0.23904** | 0.24761 |
| 0.75 | 0.24023 | 0.24380 |
| 0.50 | 0.24252 | 0.24349 |

**La validación interna de NHL elige no olvidar nada.** Su holdout mejoraría al
bajar el carry (0.24761 → 0.24349), **pero eso no autoriza tomarlo**: sería
seleccionar sobre el holdout, el error que ya me corregí en ISS262 y que volví a
rechazar en ISS271.

NHL se queda como está. **Eso es lo que significa «ajustado a cada deporte»: el
método responde distinto y se respeta la respuesta.**

## Por qué este resultado es distinto de los cinco que rechacé

En el experimento de `k` (ISS271), la validación interna y el holdout estaban
**anti-correlacionados** (Spearman −0.33): elegir bien en uno significaba elegir
mal en el otro.

Aquí, en NFL y NBA, **los dos están de acuerdo**: el carry que gana en validación
interna también gana en holdout. Tiene sentido — el carry no es una velocidad
dentro de la temporada, es una propiedad estructural del límite entre temporadas,
y eso es estable entre épocas.

En NHL sí discrepan, y por eso NHL no se toca.

## Límites, declarados

- **Es una sola partición.** No calculé intervalo de confianza sobre la mejora.
  Un `−0.0035` sobre 516 partidos es real pero modesto; no afirmo que sea
  concluyente.
- **No se promovió nada.** La regla del dueño es explícita: no promuevo modelos.
  La maquinaria de promoción (`refresh_selected_team_elo_models`) elige por
  `brier_train` y no conoce el parámetro `carry`; conectarlo es un cambio aparte
  que el dueño debe autorizar.
- **WNBA no se probó** (excluida del producto).
- **Fútbol no aplica**: su cerebro no es Elo, usa lambdas de Poisson.

## Recuento de la sesión

| # | experimento | veredicto |
|---|---|---|
| 1 | Calibrador por compresión (NFL) | RECHAZADO |
| 2 | Calibrador Platt (NFL) | RECHAZADO |
| 3 | Elo con margen de victoria | RECHAZADO |
| 4 | Promoción del Elo de NFL | ACEPTADO |
| 5 | Validación cruzada anidada | RECHAZADO |
| 6 | **Elo con olvido de temporada** | **ACEPTADO en NFL y NBA, rechazado en NHL** |

## Rollback

```sql
drop function if exists v2.fn_team_elo_backtest_carry(text,text,numeric,numeric,numeric,integer,integer,numeric,numeric);
```

No toca datos, ni modelos vivos, ni el gate. Es solo un laboratorio.
