# Calibración V4 — sobre la historia completa

Fecha: 2026-09-11 · Rama: `claude/eager-noether-s7p33g`
Ejecutables: `iss088` (backfill) → `iss089` (recálculo) → `iss090` (herramientas) → `iss091` (decisión)

**SIN EV. SIN KELLY. SIN "EDGE CONTRA EL MERCADO" PARA DECIDIR.** Nada de lo que
sigue leyó una casa de apuestas. La lambda sale de carreras/puntos anotados y
recibidos; la dispersión, de residuos propios.

---

## 1. Lo que estaba roto y ya no

### El agujero de datos (el grande)
MLB 2025 tenía **119 juegos regulares de ~2,430**. 2024 tenía **1,796**. Todos
los números de V1, V2 y V3 se calcularon sobre esa historia mutilada.

Escribimos nuestro propio backfill (`iss088`): `fetch → validar → staging →
diff contra DB → upsert idempotente por espn_event_id → replay`. Conflictos a
tabla de auditoría, nunca se pisa en silencio.

| temporada | antes | después | real |
|---|---|---|---|
| 2023 | 2,511 | **2,431** | 2,430 |
| 2024 | 1,796 | **2,426** | 2,430 |
| 2025 | 119 → 308 | **2,429** | 2,430 |
| 2026 | 2,044 | **2,187** | en curso, al 10-sep |

Los 3 días sin juegos de cada temporada son el Juego de Estrellas.
**0 duplicados. 0 conflictos. Segunda corrida inserta 0 filas** (idempotente).

Partidos con lambda utilizable: **5,266 → 8,657**.

### El bug de las ventanas
`iss087` declaraba `MLB 24 meses / 30 días` vs `NFL 36 meses / 120 días` en un
CTE `par`… y los marcos `RANGE` estaban **hardcodeados a 36 months / 120 days
para ambos**. MLB corrió con memoria de equipo de 36 meses sin que nadie lo
supiera. Un marco `RANGE` no se puede parametrizar en SQL, así que `iss089`
calcula la lambda en **dos ramas separadas**, una por deporte. Y la ventana
usada queda **escrita en cada fila** (`vent_equipo`, `vent_liga`), para que la
invariante 8 pueda verificarla en vez de creerle al comentario.

### Linaje por feature
`feature_cutoff = partido − 1 día` era una promesa. Ahora cada feature reporta
su as-of real: `asof_home`, `asof_away`, `asof_league`, `asof_dispersion`, y
`data_asof_real = greatest(los cuatro)`.
**0 violaciones. Margen mínimo medido: 1.000 día.**

---

## 2. MLB Over/Under — la conclusión SE INVIRTIÓ

V3 dijo «identity, Platt no significativo». Eso salía de 5,266 partidos.
Con la historia completa:

### Folds internos (aquí se eligió el método)

| fold | entrena | evalúa | identity | platt | isotónica |
|---|---|---|---|---|---|
| 1 | <2024 (1,645 p) | 2024 (2,371 p) | 0.246631 | **0.241134** | 0.241460 |
| 2 | <2025 (4,016 p) | 2025 (2,356 p) | 0.242237 | **0.238906** | 0.239263 |

Bootstrap por partido (cluster = partido):
- fold 1 · platt IC95 **[0.004248, 0.006718]** significativo, 100% a favor
- fold 2 · platt IC95 **[0.001098, 0.005939]** significativo, 99.9% a favor

**Platt gana a identidad 2/2 y a la isotónica 2/2.**
La isotónica se probó como exigió el dueño y **perdió donde se la midió**. No se
adopta: 2 parámetros le ganan a ~20 bloques.

### Holdout limpio 2026 — medido UNA vez, método ya fijado

2,075 partidos · 15,870 eventos · 730 pushes

| | RAW | CAL (platt) |
|---|---|---|
| Brier | 0.239267 | **0.237714** |
| ECE | 0.041366 | **0.018106** |
| LogLoss | 0.671449 | 0.668163 |

Bootstrap: media 0.001745 · **IC95 [−0.000608, 0.004084] → CRUZA CERO** · 93% a favor.

**NO PASA la barra.** Sin adornos: en el holdout limpio, de una sola temporada,
la mejora de Brier no es distinguible de cero.

### El dato que no hay que esconder ni sobrevender

Walk-forward agrupado 2024+2025+2026, cada ventana calibrada sólo con lo
anterior, **6,802 partidos**: Brier 0.241258 → 0.237640, media 0.003639,
**IC95 [0.002536, 0.004759]**, 100% a favor, **significativo**.
Y la pendiente de Platt es <1 en todos los ajustes: **b = 0.857, 0.814, 0.792**.
La sobreconfianza del modelo es real, estable y siempre en la misma dirección;
las 3 temporadas fuera de muestra mejoran con Platt y el ECE baja en todas.

**Pero ese agrupado NO es un holdout limpio**: 2 de sus 3 temporadas eligieron
el método. No promueve nada. Sirve para una sola cosa: decir que el IC que cruza
cero en 2026 huele a falta de potencia (2,075 partidos) y no a ausencia de
efecto. No es prueba. Es una sospecha bien medida.

### Decisión
`elegido = true` · `apto_para_lock = false`

Son dos cosas distintas y ahora son dos columnas distintas. Platt es el mejor
calibrador que tenemos medido; el holdout limpio no alcanzó para promover.

**MLB Over/Under: ANÁLISIS EXPERIMENTAL y nada más.
SIN LOCK. SIN "Lo Mejor". SIN Parlay. SIN Reto13M.**

---

## 3. NFL Over/Under — sin cambio de conclusión

| fold | evalúa | identity | platt |
|---|---|---|---|
| 1 | temp. 2023 (239 p) | 0.238266 (ECE 0.104550) | **0.227650** (ECE 0.021416) |
| 2 | temp. 2024 (239 p) | **0.232611** (ECE 0.072559) | 0.257187 (ECE 0.171028) |

1-1, **y la derrota es mayor que la victoria**. Los parámetros de Platt casi no
cambian entre folds (a −0.498/−0.455, b 0.874/0.869): lo que cambia es la
temporada. Un calibrador que ayuda un año y hace daño el siguiente no se adopta.

**NFL se queda en identidad.** Holdout temporada 2025: 238 partidos,
Brier 0.226115, ECE 0.045459. 238 partidos sirven para auditar, no para promover.
`apto_para_lock = false`.

---

## 4. Invariantes

Las 12 reglas de `verificar_invariantes.sql` **pasan**. Las 6 nuevas:

7. Linaje: 0 filas con un feature a la fecha del partido o posterior.
8. Ventanas: 0 filas usando una ventana que no es la de su deporte.
9. Push: 0 eventos en línea `.5` con push (el bug que infló V1).
10. Pretemporada: 0 filas de Spring Training en los backtests.
11. `apto_para_lock` no se regala sin mejora OOS.
12. Un solo calibrador elegido por (deporte, mercado) entre los vigentes.

V1, V2, V2-simulación y V3 quedan `invalidado = true` con motivo escrito.
Calibradores vigentes: 4 filas, 2 elegidos, **0 aptos para LOCK**.

---

## 5. Lo que sigue pendiente

1. **Líneas reales**: marcar lo viejo `HISTORICAL_REAL_LINE_UNAVAILABLE` y
   congelar proveedor + timestamp + fuente en cada predicción nueva.
2. **Soccer 1X2 multiclase** (el esquema ya soporta `p_raw_multi` / `clase_real`).
3. **NFL dedicado `nfl-2026.09.2`** — auditar y calibrar el cerebro bueno, que
   NO es `nfl_ml_poisson_v1` (ese está MODEL_REJECTED).
4. **Fantasy** con MAE/RMSE/bias/coverage.
5. **MLB por mercado**: Moneyline / Totales / Run line por separado.
6. Migrar los 8 llamadores de `zona_realidad/2` a la versión de 3 argumentos.
7. Sólo al final: conectar `P_CAL` a lo que se muestra.

Nada de esto está conectado a la ruta de decisión. `v_reto13m_mejores` sigue con
`es_lock = false` y `validado_fuera_de_muestra = false`.
