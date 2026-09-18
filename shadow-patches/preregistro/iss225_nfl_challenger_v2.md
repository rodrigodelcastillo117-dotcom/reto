# ISS225 — PREREGISTRO: `nfl_elo_challenger_v2`

Challenger NFL en shadow. Sustituye el intento fallido `nfl_hybrid_ml_v1`
**sin modificarlo retroactivamente**. NFL productivo sigue apagado y
fail-closed hasta que este challenger pase su propio criterio.

**Escrito y comiteado ANTES de entrenar o medir.**

Fecha de preregistro: 2026-09-18.

---

## 0. ESTADO DEL MODELO ANTERIOR — lo que sí y lo que no quedó probado

De ISS223, ya medido y comiteado:

- La reproducción del Elo sellado **converge dentro de tolerancia numérica**,
  no bit a bit. Delta máximo **0.055713 → 0.000127**, 9 de 10 eventos por
  debajo de 0.0001. Se reporta como
  **`REPRODUCIBLE_DENTRO_DE_TOLERANCIA_NUMERICA`**, no como "exacto".
- Causa de las 10/42 diferencias: **el tratamiento de los empates**. Mi
  reimplementación daba 0 a los dos lados, así que los marcadores no sumaban 1
  y cada empate fugaba un punto entero de masa, que se propagaba a todo rival
  posterior. Hay 13 empates, 11 en agosto. New England, que empató el
  2026-08-13, salía 3 de 3 divergente.
- **Residuo de 0.000127 pendiente de investigar** (§18). No se toca el modelo
  viejo para investigarlo.
- Reproducible **no** es válido: el IC95 de `nfl_hybrid_ml_v1`
  `[-0.03873, +0.00088]` **sigue cruzando cero**. El veredicto no cambia.

Las cuatro correcciones que ISS223 identificó entran **aquí**, como diseño
nuevo, y **ninguna** se aplica retroactivamente al modelo sellado.

---

## 1. LOS CUATRO DEFECTOS CORREGIDOS

| # | defecto medido en el modelo viejo | corrección en v2 |
|---|---|---|
| 1 | empate puntuado `sh_home=0, sh_away=1` — un empate cuenta como derrota del local | **empate = 0.5 / 0.5** |
| 2 | los 11 empates de agosto y toda la pretemporada alimentan la fuerza de temporada regular, sin justificación medida | **pretemporada excluida** de las actualizaciones (§4) |
| 3 | `"Washington"` (20 partidos) y `"Washington Commanders"` (87) son dos identidades distintas en la tabla de ratings | **unificadas** (§3) |
| 4 | `"AFC"` y `"NFC"` entran como equipos, 5 partidos cada uno: es el Pro Bowl | **excluidos** (§3) |

Ninguna de las cuatro fue elegida mirando el holdout. 1 y 2 salen de la
matriz 2×2 de ISS223 sobre diferencias de *reproducción*, no de acierto.
3 y 4 son defectos de identidad, verificables sin ningún resultado.

---

## 2. DATASET

Fuente: `public.historico_partidos_espn` restringido a NFL, partidos con
marcador final. Base declarada en ISS223: **1,738 partidos, 0 duplicados**.

Temporada NFL = **agosto → julio**: `temporada = (mes >= 8) ? año : año-1`.
Este es el bug que hundió mi primer intento en ISS217 (`extract(year) > v_anio`
dispara en enero, así que el arrastre de agosto nunca se aplicaba; el delta
bajó de 0.068 a 0.0018 al corregirlo). Queda fijado aquí explícitamente.

### 2.1 Exclusiones
- `"AFC"` y `"NFC"` (Pro Bowl): fuera, como equipos y como partidos.
- Partidos sin marcador: fuera.
- Pretemporada: **no se excluye del dataset**, se excluye de las
  actualizaciones de fuerza (§4). Se conserva para diagnóstico.

### 2.2 Unificación de identidad
Mapa explícito, cerrado, versionado en `v2.nfl2_alias`:
`"Washington"` → `"Washington Commanders"`.
Cualquier otro alias que aparezca se **declara y detiene la corrida**
(fail-closed): no se resuelve con similitud difusa. Prohibido el fuzzy match
silencioso.

---

## 3. CORTE TEMPORAL Y HOLDOUT

- **Desarrollo:** temporadas 2020 … 2024 (inclusive).
- **Holdout sellado NUEVO:** temporada **2025** completa.
- La temporada 2026 en curso **no entra a nada**: días incompletos no se
  evalúan.

Holdout **nuevo**. No reutiliza el de `nfl_hybrid_ml_v1`. Se sella su hash
antes de ajustar. **Una sola apertura**, al final, con el modelo congelado.
Si se abre, cualquier ajuste posterior exige preregistro y holdout nuevos.

---

## 4. PRETEMPORADA — decisión explícita

El modelo viejo la usaba **sin justificación medida**. Aquí se decide:

**La pretemporada NO actualiza la fuerza.** Razón declarada de antemano: los
equipos rotan titulares por diseño, así que el resultado no informa sobre la
fuerza del equipo que jugará la temporada regular. 11 de los 13 empates del
dataset son de agosto, lo que es consistente con partidos donde ganar no es
el objetivo.

Esto se registra como **decisión de diseño, no como hiperparámetro ajustable**.
Se reporta además una **ablación** (pretemporada dentro / fuera) medida
**sólo en validación walk-forward**, nunca en el holdout, como diagnóstico.

## 5. CLASIFICACIÓN DE PARTIDO

Se deriva de la fecha y del campo de tipo de ESPN cuando existe. Si para un
partido no se puede determinar si es pretemporada, regular o postemporada,
**el partido se excluye y se cuenta como `TIPO_INDETERMINADO`**. No se
adivina por la fecha sola.

---

## 6. MODELO

Elo con arrastre entre temporadas y ventaja de local:

```
E_local = 1 / (1 + 10^(-(R_local + HFA - R_visita)/400))
s_local = 1.0 gana | 0.5 empate | 0.0 pierde        <-- corrección #1
R_local  <- R_local  + K*(s_local - E_local)
R_visita <- R_visita + K*((1-s_local) - (1-E_local))
```

Los dos marcadores **suman 1 por construcción**. Esto se verifica como
aserción dura en cada actualización: si `s_local + s_visita <> 1`, la corrida
aborta. Es exactamente la fuga que causó las 10 diferencias de ISS223.

### 6.1 Prior de temporada anterior y regresión a la media
Al empezar la temporada `t`:
```
R_t0 = 1500 + LAMBDA * (R_fin(t-1) - 1500)
```
`LAMBDA` ∈ {0.50, 0.60, 0.75} elegido en validación. Equipo sin temporada
anterior en el dataset: `R_t0 = 1500`, y se marca `COLD_START_SIN_PRIOR`.

### 6.2 Cold start semanas 1–4
El problema real: en las semanas 1–4 el Elo de la temporada en curso casi no
tiene información nueva, y es la razón por la que NFL tendría 0 P_RETO hasta
~semana 5. Solución preregistrada, **no una excepción improvisada**:

`R_efectivo = R_t0` durante las semanas 1–4, con la **incertidumbre
explícita** derivada del prior (§10), y servibilidad decidida por esa
incertidumbre, no por el número de semana. Si el prior es informativo
(equipo con temporada anterior completa), puede ser servible en semana 1.
Si no lo es, no lo es ni en semana 6.

Esto separa **validación histórica** de **disponibilidad operativa**: son dos
preguntas distintas y el reporte las responde por separado.

### 6.3 Hiperparámetros
- `K` ∈ {20, 24, 32, 40}
- `HFA` ∈ {25, 40, 55}
- `LAMBDA` ∈ {0.50, 0.60, 0.75}
- pretemporada: fija en FUERA (§4); la ablación se reporta aparte.

36 combinaciones, rejilla determinista, sin búsqueda aleatoria, sin semilla.
**Elegidas sólo con validación walk-forward sobre desarrollo.**

## 7. QB Y ROSTER

Se incorporan **sólo si** existe información prepartido verificable en la base,
con `feature_asof` anterior al kickoff y proveniencia auditable.

Hasta que eso se verifique, **no entran**. No se imputa titularidad de QB. No
se infiere una baja por ausencia de dato. Si la fuente no existe se declara
**UNAVAILABLE**, no se sustituye. Es una variante (v2b) que sólo se mide si la
fuente pasa la auditoría de temporalidad; si no pasa, se reporta como
BLOQUEADA POR FUENTE y v2a es el único candidato.

## 8. ORDEN DETERMINISTA Y REDONDEO

- Partidos procesados en orden `(fecha asc, espn_event_id asc)`. Empates de
  fecha resueltos por `espn_event_id`, que es único.
- Aritmética en `double precision`, paralelismo apagado
  (`max_parallel_workers_per_gather = 0`) para que el orden de sumatoria esté
  fijado.
- Ratings almacenados con **6 decimales**; probabilidades con **6 decimales**.
  El redondeo se aplica **sólo al almacenar**, nunca dentro del bucle de
  actualización.
- Criterio de reproducibilidad: dos corridas desde git deben coincidir en
  `|Δ| <= 1e-9` por rating. Si no coinciden, aborta.

## 9. VALIDACIÓN

**Walk-forward por temporada** dentro de desarrollo: se entrena con las
temporadas anteriores, se predice la siguiente, se avanza. En cada predicción:
sólo partidos anteriores; ningún resultado futuro; estado del modelo
reconstruido hasta ese instante; predicción guardada antes de incorporar el
resultado.

Prueba adversarial obligatoria de no lookahead: insertar un partido con fecha
posterior y comprobar que la predicción **no cambia**; rollback sin residuos.

## 10. INCERTIDUMBRE

Por partido: desviación del pronóstico derivada de (a) partidos acumulados de
cada equipo en la temporada en curso y (b) antigüedad del prior. Se publica
junto con la probabilidad. Un partido con incertidumbre por encima del umbral
**no es monetizable** y registra el motivo exacto; la tarjeta puede explicar
que falta evidencia. Nunca se presenta una estimación débil como certeza.

## 11. BASELINES

1. **0.25 por resultado** (Brier de referencia declarado por el dueño).
2. **Sólo ventaja de local**, sin fuerza de equipo.
3. **`nfl_hybrid_ml_v1`** sobre el mismo holdout, para comparar.
4. **Fail-closed** — no predice; se compara en cobertura.

## 12. MÉTRICAS

Brier (ganador), log loss, calibración por deciles + ECE, accuracy
(secundaria), IC95 por bootstrap pareado (10,000 réplicas, semilla fija 225),
estabilidad por temporada y por tramo de semana (1–4 / 5–9 / 10–18 /
postemporada), error por equipo.

## 13. CRITERIO DE PROMOCIÓN

Sobre el holdout sellado (temporada 2025), todos:

- **PC1** Brier(v2) < 0.25, con IC95 de la diferencia **estrictamente por
  debajo de 0**. *Este es el criterio que el modelo viejo no cumplió: su IC95
  cruzaba cero.*
- **PC2** log loss(v2) < log loss del baseline de sólo ventaja de local.
- **PC3** ECE(v2) <= 0.05.
- **PC4** la aserción `s_local + s_visita = 1` se cumple en el 100% de las
  actualizaciones.
- **PC5** reproducibilidad `|Δ| <= 1e-9` entre dos corridas desde git.
- **PC6** cero alias no declarados; cero `TIPO_INDETERMINADO` dentro del
  holdout.

## 14. CRITERIO DE ABORTO

- Falla cualquiera de PC1–PC6.
- Aparece un alias de equipo no declarado en `v2.nfl2_alias`.
- El holdout evaluable queda por debajo de n=200 partidos.
- Cualquier insumo con `feature_asof` posterior al kickoff.

## 15. NFL PRODUCTIVO

Sigue **apagado y fail-closed**. No se reactiva por este preregistro.
Se reactiva sólo tras: holdout pasado → prospectivo → canary informativo →
autorización explícita del dueño.

Un solo cerebro NFL. El challenger vive en almacenamiento shadow aislado, sin
acceso `anon` ni `authenticated`, sin consumidores productivos, etiquetado
`RETADOR_DECLARADO` en `v2.cerebro_autorizado`, con fecha de evaluación y
criterio de retiro registrados, y con `feature_asof`, linaje y versión de
código conservados.

## 16. VALIDACIÓN HISTÓRICA ≠ DISPONIBILIDAD OPERATIVA

Se reportan por separado, y no se confunden:
- **Histórica:** ¿le gana al baseline en el holdout 2025? La responde §13.
- **Operativa 2026:** ¿hay hoy suficiente información prepartido para servir
  una probabilidad? La responde §6.2 vía incertidumbre, partido por partido.

Un PASS histórico **no** enciende NFL en 2026 por sí solo.

## 17. HIPÓTESIS PRIMARIA, UNA SOLA

> Con los empates puntuados 0.5/0.5, la pretemporada fuera de las
> actualizaciones y la identidad de equipos corregida, el Elo NFL supera el
> baseline de 0.25 con IC95 que no cruza cero en un holdout temporal nuevo.

Una corrida. Un holdout. Un veredicto. Sin reinterpretar después de medir.

## 18. PENDIENTE DECLARADO

Investigar el residuo de **0.000127** de ISS223 (orden de sumatoria en float,
o el redondeo de los ratings almacenados). Se investiga **sobre el
reimplementado**, no modificando el modelo sellado. No bloquea este
challenger: es una pregunta sobre la reproducción del viejo, no sobre la
validez del nuevo.
