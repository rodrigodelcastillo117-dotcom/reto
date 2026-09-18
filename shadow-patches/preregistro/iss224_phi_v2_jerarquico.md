# ISS224 — PREREGISTRO: `league_strength_hierarchical_v2`

Estimador jerárquico de fuerza de liga con partial pooling.
Challenger en shadow. NO toca el sello de `crossleague_v1_1`.

**Escrito y comiteado ANTES de ajustar o medir nada.** Todo lo que sigue —
splits, hiperparámetros, criterios — queda fijado aquí. Si después algo no se
cumple, se reporta como FALLO, no se reinterpreta.

Fecha de preregistro: 2026-09-18.
Motivo: `PHI_NOT_SERVABLE` es hoy la causa única y dominante de pérdida de
cobertura en fútbol (67–77%). Medido en ISS222: 0 de 39 ligas pendientes
alcanzan el mínimo de 20 puentes directos; promedio 2.4. El backlog drena bien;
el cuello es la muestra, no el cron.

---

## 0. DIAGNÓSTICO PREVIO — por qué v1 se queda corto

`v2.fn_fit_phi_extension` ajusta **un escalar phi por liga, de forma
independiente**, y exige que **la liga rival YA tenga phi servible**
(`join v2.crossleague_league_strength s ... and s.servable`).

Eso son dos limitaciones distintas, y las dos son estructurales:

1. **Anclaje codicioso.** Una liga sólo puede estimarse contra las 23 ya
   instaladas. Sus puentes contra otras ligas no instaladas se descartan por
   completo, aunque existan y sean informativos.
2. **Umbral por liga aislada.** Cada liga necesita ≥20 puentes *ella sola*
   contra ese conjunto reducido.

No se propone bajar el umbral. Se propone **cambiar el estimador**: estimar
todas las ligas a la vez, en un solo sistema, donde un puente entre dos ligas
débilmente ancladas sigue aportando información a las dos.

---

## 1. DATASET EXACTO

### 1.1 Corrección de identidad que hay que hacer primero

`v2.soccer_coverage_job.domestic_league_id` es la **división actual** de cada
equipo (ISS146/ISS147: "la división actual manda"), un único valor por equipo.
No existe hoy una tabla de división punto-en-el-tiempo.

Consecuencia medida al construir el grafo de puentes con ese mapa:

| clasificación | partidos |
|---|---|
| aparentes "cross-league" | 1,981 |
| **artefacto de ascenso/descenso** (partido jugado DENTRO de una liga de una sola división) | **1,378 (70%)** |
| amistosos de club | 22 |
| **puente real de partido** | **581** |

Los 1,378 son partidos como `soccer/eng.4` entre dos equipos de League Two,
marcados como "cross-league" sólo porque uno de ellos ascendió después y su
mapa apunta a `eng.3`. **Un partido jugado en una competición de una sola
división no puede ser un puente entre ligas, por definición.**

Tratarlos como puentes habría inflado la muestra 3.4× con ruido puro. Se
excluyen. Se reaprovechan por otra vía (§1.3).

### 1.2 Membresía punto-en-el-tiempo — derivada, no inventada

La competición de cada partido determina la división de ambos equipos ese día:
si el partido se jugó en `soccer/ita.2`, los dos equipos estaban en la Serie B
esa fecha. De ahí se deriva, sin ninguna fuente externa:

| | |
|---|---|
| filas (equipo, división, temporada) | 1,855 |
| equipos | 564 |
| divisiones | 25 |
| (equipo, temporada) ambiguas | 1 |
| **equipos que cambiaron de división** | **94** |

Regla de desambiguación, fijada aquí: para la única (equipo, temporada)
ambigua gana la división con más partidos; si empata, la de menor `tier`.

### 1.3 Las dos familias de evidencia

- **Puente A — de partido.** Dos equipos de ligas distintas *en esa fecha* se
  enfrentan: copas continentales y copas domésticas entre divisiones.
  **581 partidos, 113 pares de ligas, 49 ligas.**
- **Puente B — de movimiento de equipo.** El mismo equipo juega en la división
  X una temporada y en la Y la siguiente. **94 equipos.** Es el único canal
  denso que conecta segunda división con primera dentro de un país.

v1 usa **sólo A**, y sólo contra rivales ya instalados.

### 1.4 Filtros de inclusión (fijados)

Se incluye un partido como puente A si:
- tiene marcador final (`home_score`/`away_score` no nulos);
- los dos equipos tienen división asignada y **distinta** en esa fecha;
- la competición **no** es de una sola división (`espn_endpoint !~ '^soccer/[a-z]+\.[0-9]+$'`);
- no es amistoso (`<> 'soccer/club.friendly'`);
- no es femenil (`!~ '\.w\.'`) ni juvenil (`!~ '(youth|u1[789]|u2[01])'`);
- **no es CONMEBOL Sudamericana** (§1.5);
- ambos equipos tienen ≥15 partidos domésticos previos en ventana de 540 días
  (`sample_floor_domestic`, el mismo piso de v1 — no se relaja).

### 1.5 Sudamericana — supuesto declarado

El dueño escribió "Sudamericana continúa excluida". Esa línea aparece en el
bloque de cobertura y producto; la lista de fuentes permitidas dice
"competiciones continentales". Hay tensión real entre las dos lecturas.

**Decisión conservadora: se excluye también del entrenamiento.**
Es la lectura que no puede violar una instrucción explícita, y es reversible.

Costo medido de esa exclusión, reportado para que el dueño pueda revertirla:
**133 de 581 puentes (23%)**, concentrados en ligas sudamericanas, sobre 28
pares. Si el dueño autoriza su uso como evidencia de entrenamiento (sin
producir picks), se reejecuta con el mismo preregistro y se reporta aparte.

### 1.6 Tamaños finales

| conjunto | puentes A |
|---|---|
| desarrollo (≤ 2026-01-31) | **316** |
| holdout sellado (> 2026-01-31) | **114** |
| total | **430** |

Distribución de puentes por liga en desarrollo (51 ligas con ≥1):

| puentes directos | ligas |
|---|---|
| ≥20 | **9** |
| 5–19 | **30** |
| 1–4 | 12 |

Promedio 12.4, máximo 53.

**Esas 30 ligas del tramo 5–19 son la población objetivo.** Hoy son
`PHI_NOT_SERVABLE` con certeza aritmética bajo v1. El techo teórico de v2 es
51 ligas contra las **23** instaladas hoy por `crossleague_v1_1`.

---

## 2. CORTE TEMPORAL

- Ventana de datos: 2023-07-12 … 2026-09-18.
- **Desarrollo:** fecha ≤ **2026-01-31** (n=316).
- **Holdout sellado:** fecha > **2026-01-31** (n=114).

Holdout **nuevo**, no reutiliza ninguno anterior. Se abre **una sola vez**, al
final, con el modelo ya elegido. Si se abre, se acabó: cualquier ajuste
posterior obliga a un preregistro nuevo y a un holdout nuevo.

Rasgos de cada partido calculados **as-of la fecha del partido**, ventana de
540 días hacia atrás, vía `v2.fn_crossleague_features_training_asof`. Ningún
insumo posterior al partido.

---

## 3. FEATURES

Forma funcional **idéntica a v1**, deliberadamente, para que v2 sea un módulo
sustituible y la comparación sea peral con peral. Lo que cambia es la
**estimación**, no la forma:

```
log λ_local    = a0 + batt·ln(gf_local)  + bdef·ln(ga_visita) + home_adv + (θ_Llocal − θ_Lvisita)
log λ_visitante= a0 + batt·ln(gf_visita) + bdef·ln(ga_local)             + (θ_Lvisita − θ_Llocal)
```

`a0, batt, bdef, home_adv, rho` se **congelan** en los valores sellados de
`crossleague_model_registry` (a0=-0.2214, batt=0.6057, bdef=0.3896,
home_adv=0.3568, rho=0.0705). No se reajustan. El único parámetro libre es θ.

Insumos por equipo (todos pre-partido): promedio de goles a favor y en contra
en su división, ventana 540 días, piso 15 partidos.
Insumos por liga: país e `tier`, derivados del `espn_endpoint` (`soccer/ita.2`
→ país `ita`, tier 2). Sin fuente externa.

**Prohibido y no usado:** cuotas en ninguna forma; cualquier dato posterior al
partido; xG (no hay fuente point-in-time confiable auditada — se declara
UNAVAILABLE, no se sustituye).

---

## 4. ASCENSOS Y DESCENSOS

- La división de un equipo es la observada **en la fecha del partido** (§1.2),
  no la actual.
- Un equipo que cambia de división **no arrastra** su θ: θ es de la liga, no
  del equipo. Sus rasgos de forma sí se leen de la división donde jugó.
- Los 1,378 partidos intra-división quedan **fuera** de los puentes A.
- Se usan como puente B sólo en la variante v2b (§7).

## 5. CLUBES NUEVOS

Un equipo sin ≥15 partidos domésticos previos en 540 días **no entra** a
ningún puente. No se le imputa forma. Fail-closed, igual que v1.

## 6. DECAIMIENTO TEMPORAL

Peso de cada puente: `w = exp(−ln2 · edad_días / H)`, con vida media `H`
elegida en validación dentro de `{365, 540, 730}`.

---

## 7. ESTRUCTURA JERÁRQUICA

```
θ_L = μ_país(L) + δ_tier(L) + u_L
```

- `δ_tier` : efecto de nivel de división (tier 1..4). Sin forma monótona impuesta.
- `μ_país` : efecto de país, con `μ_c ~ N(0, τ_c²)`.
- `u_L`    : residual de liga, con `u_L ~ N(0, τ²)`.
- Identificabilidad: `θ` de la liga de referencia (`league_id=39`, Premier
  League) se fija en 0, igual que v1.

**Ligas con pocos puentes:** el término de encogimiento domina, θ_L se acerca
al prior de país/tier y **el intervalo se ensancha**. Nunca se presenta como
certeza.
**Ligas con datos suficientes:** la verosimilitud domina al prior.

### Variantes preregistradas

- **v2a (PRIMARIA)** — jerarquía sobre puentes A.
- **v2b (SECUNDARIA)** — v2a más el canal de puentes B: un equipo observado en
  las divisiones X e Y en temporadas consecutivas aporta una pseudo-observación
  del salto `θ_X − θ_Y`, con su propia varianza y un factor de encogimiento
  `κ` por cambio genuino del equipo.

La elección entre v2a y v2b se hace **sólo con validación walk-forward sobre
desarrollo**, nunca con el holdout. Regla: gana v2b únicamente si baja el log
loss de validación en ≥0.005; si no, gana v2a por parsimonia.

---

## 8. PRIORS

- `u_L ~ N(0, τ²)`, `τ ∈ {0.10, 0.20, 0.35}`
- `μ_c ~ N(0, τ_c²)`, `τ_c ∈ {0.15, 0.30}`
- `δ_tier`: sin encogimiento (4 niveles, muestra suficiente).
- `κ` (sólo v2b): `{0.50, 0.75}`.

Escala: θ es aditivo sobre log-goles. τ=0.20 significa que el 95% de las ligas
de un mismo país y nivel caen dentro de ±0.39 en log-goles, ≈ ±48% en λ.

## 9. HIPERPARÁMETROS

Rejilla determinista: `τ × τ_c × H` = 3×2×3 = **18** combinaciones (v2a).
v2b añade `κ`: 36. Sin búsqueda aleatoria. Sin semilla.

**El holdout NO se usa para elegir hiperparámetros.** Punto.

## 10. TRAINING

MAP por **descenso coordinado** sobre θ: para cada liga, en orden ascendente de
`league_id`, se minimiza su NLL penalizada condicional sobre la rejilla
`θ ∈ [−1.500, +0.500]` paso `0.002` (la misma de v1), manteniendo las demás
fijas; se itera hasta que `max|Δθ| < 0.001` o 50 pasadas.

Orden determinista, sin aleatoriedad, sin semilla → reproducible bit a bit.
Verosimilitud Dixon-Coles con el mismo `tau` de corrección de marcadores bajos
que v1.

## 11. VALIDACIÓN

**Walk-forward expansivo** dentro de desarrollo, folds trimestrales:
se ajusta con todo lo anterior al fold, se predice el fold, se avanza.
En cada predicción: sólo partidos anteriores; ningún resultado futuro; ningún
snapshot posterior; estado del modelo reconstruido hasta ese instante;
predicción guardada antes de incorporar el resultado.

Se eligen `τ, τ_c, H` (y `κ`) por **log loss agregado de validación**.

## 12. HOLDOUT TEMPORAL SELLADO

fecha > 2026-01-31, n=114. Se sella su hash antes de cualquier ajuste.
Una sola apertura, al final, con el modelo ya congelado.

## 13. BASELINES

1. **θ=0 para todas** — sin corrección de liga. Baseline principal.
2. **phi v1** — en el subconjunto donde v1 es servible.
3. **Fail-closed** — no predice; se compara en cobertura, no en Brier.
4. **Cerebro canónico actual** sobre los partidos hoy servibles.

## 14. MÉTRICAS

Brier 1X2 (suma sobre los tres resultados); log loss; calibración (fiabilidad
por deciles + ECE); cobertura (ligas servibles); error por liga; error por
tramo de puentes (≥20 / 5–19 / 1–4); IC95 por bootstrap pareado sobre partidos
(10,000 réplicas, semilla fija 224); estabilidad temporal por trimestre;
incertidumbre de θ por liga.

Accuracy sólo como secundaria, informativa.

**Incertidumbre de θ:** intervalo de perfil de verosimilitud al 95% — el rango
de θ donde la NLL penalizada sube 1.92 sobre su mínimo. Determinista, sobre la
misma rejilla ya evaluada.

## 15. TRATAMIENTO DE INCERTIDUMBRE Y REGLA DE SERVIBILIDAD

Una liga es **servible** en v2 sólo si cumple **las dos**:
- semiancho del intervalo de perfil 95% ≤ **0.25** en log-goles (≈ ±28% en λ); y
- **≥1 puente directo** en desarrollo.

La segunda es innegociable: una liga estimada *puramente* por el prior sería
"asumir que dos ligas tienen la misma fuerza", que está prohibido. Cero puentes
⇒ **no servible**, motivo `PHI_NO_BRIDGE`.

Una liga con incertidumbre excesiva:
- puede seguir sin pick monetizable;
- registra el motivo exacto (`PHI_UNCERTAIN`, con el semiancho medido);
- **no se excluye silenciosamente** del producto;
- la tarjeta puede explicar que todavía falta evidencia.

## 16. COMPETENCIAS EVALUADAS

Reporte desglosado obligatorio, aunque el n sea chico, y diciendo el n:
EFL Cup (Carabao) · Coppa Italia · AFC Champions · Libertadores ·
cruces primera vs segunda división · ligas con n directo <20 ·
ligas con n directo ≥20 · UEFA (Champions/Europa/Conference).

## 17. CRITERIO DE PROMOCIÓN

Sobre el holdout sellado, restringido a partidos donde **ambas** ligas tienen
estimación v2. Deben cumplirse **todos**:

- **PC1** Brier(v2) < Brier(θ=0), con IC95 del bootstrap pareado de la
  diferencia **estrictamente por debajo de 0**.
- **PC2** log loss(v2) < log loss(θ=0).
- **PC3** En el subconjunto donde v1 es servible: Brier(v2) ≤ Brier(v1) + 0.005.
  *v2 no puede degradar donde v1 ya funciona.*
- **PC4** ECE(v2) ≤ 0.05.
- **PC5** ligas servibles(v2) > **23** (las instaladas hoy por `crossleague_v1_1`).

PC5 sin PC1–PC4 **no promueve**. No se elige por cobertura.

## 18. CRITERIO DE ABORTO

Aborta —y se reporta como FALLO, sin reinterpretar— si:
- falla cualquiera de PC1–PC4; o
- el conjunto servible incluye una liga con cero puentes directos; o
- el holdout evaluable queda por debajo de **n=100**; o
- el descenso coordinado no converge en 50 pasadas; o
- la reejecución desde git no reproduce θ dentro de 1e-6.

## 19. RUTA DE PROMOCIÓN

`shadow → backtest → prospectivo → canary informativo → autorización del dueño
→ integración al cerebro único`.

- Sigue existiendo **un solo cerebro** `soccer_canonical_v2`.
- phi_v2 es un **módulo interno** suyo.
- **No** crea un segundo publicador.
- **No** crea otra P_RETO.
- **No** escribe en superficies productivas.
- Almacenamiento shadow aislado, sin acceso `anon` ni `authenticated`.
- Etiquetado `RETADOR_DECLARADO` en `v2.cerebro_autorizado`.
- Fecha de evaluación y criterio de retiro registrados.
- Se conserva `feature_asof`, linaje y versión de código.

## 20. HIPÓTESIS PRIMARIA, UNA SOLA

> El partial pooling jerárquico produce estimaciones de fuerza de liga
> servibles para ligas con menos de 20 puentes directos, **sin degradar** la
> calidad probabilística donde v1 ya es servible.

Una corrida. Un holdout. Un veredicto.
