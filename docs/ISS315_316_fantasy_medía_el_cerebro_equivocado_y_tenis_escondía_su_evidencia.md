# ISS315-316 — Fantasy medía el cerebro equivocado, y Tenis escondía su propia evidencia

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-10-17**

El dueño pidió *"el mejor sistema… mejor info, mejor decisión de quién start y
por qué"* y *"revisa marcadores en tennis y ajusta qué pasó"*. Lo que apareció
en los dos casos es el mismo patrón: **el sistema ya tenía la evidencia medida
y no se la enseñaba a nadie.**

---

## 1. ISS315 — El historial de Fantasy era el de un cerebro que no decide

`v2.capture_fantasy_recommendation_v3` llevaba el modelo escrito a fuego:

```sql
declare ... v_model text := 'fantasy-b1-rq80-2026.09.1';
```

Producción sirve **`fantasy-b2-rival-2026.09.2`**. Es decir: cada recomendación
que se registraba para construir el historial se pedía a **B1**, no al cerebro
que de verdad decide lo que el usuario ve. Contra la regla explícita de un solo
cerebro por deporte.

Ahora el modelo sale de `v2.fantasy_model_config_v2` —la **misma** fuente que
usa el optimizador— y si no hay ninguno autorizado la captura falla cerrada en
vez de inventar una versión.

### El calificador existía, funcionaba, y nadie lo había programado

```
v2.grade_fantasy_recommendations_v3   escribe el registro -> NINGUN cron lo llama
v2.run_fantasy_learning_cycle_v1      cron cada 6h, 28/28 OK -> NO toca el registro
                                                              NO toca la calibracion
```

Por eso el historial murió en la semana 3: alguien lo corrió tres veces a mano
en septiembre y nunca más.

Y hay una conexión con ISS312 que vale la pena dejar escrita. El calificador
filtra así:

```sql
where ... and jsonb_array_length(s.changes) > 0
```

**Solo califica recomendaciones que propusieron un cambio.** Con el defecto de
ISS312 —un titular lesionado era inamovible— `cambios` salía casi siempre
vacío. Así que el defecto del optimizador no solo costaba ~25 puntos por
semana: **mataba de hambre al ciclo de aprendizaje.** Sin cambios no hay nada
que calificar, sin calificación no hay historial, y sin historial nadie puede
saber si el sistema sirve. Arreglar ISS312 era requisito para que esto pudiera
existir.

### El registro guardado estaba rancio

Al correr el calificador autorizado, la semana 3 pasó de `0.00` a **−3.60**: se
había calificado el 23 de septiembre, antes de que existieran los resultados, y
nadie volvió a correrlo.

### Lo que el historial dice de verdad

```
sem 2   Sutton por Egbuka   previsto +1.4   real  5.50 - 10.30 = -4.80   PERDIO
sem 3   Sutton por Egbuka   previsto +0.6   real  7.60 - 11.20 = -3.60   PERDIO
                                                  -----------------------
                            2 cambios calificados, 0 ganados, 2 perdidos, -8.40
```

Dos cambios, los dos perdidos, y los dos eran **la misma recomendación** que el
modelo repitió. Con n=2 no se concluye que el sistema sea malo: es **ausencia
de evidencia**, no evidencia en contra. Pero desde luego no respalda el
`confianza 95` que la tarjeta imprimía.

### Dos crones nuevos, y una guarda temporal que se niega a mentir

```
fantasy-capturar-recomendacion-semanal  [9 16 * * *]   jobid 579
fantasy-calificar-recomendaciones       [11 14 * * *]  jobid 580
```

La captura es **idempotente por semana** (si ya existe una foto de esa semana
para ese modelo, no crea otra), así que un fallo de un día no cuesta la semana
entera de historial.

Y lleva un corte temporal explícito:

```
v2.capturar_recomendaciones_de_la_semana()
  -> {"ok": true, "week": 6, "capturadas": 0, "reason": "SEMANA_YA_ARRANCO"}
```

**Se niega a capturar porque la semana 6 ya empezó.** Registrar una
recomendación después del primer saque no es una predicción. Las semanas 4 a 6
**no se pueden rellenar** sin fuga temporal, y la función se niega sola en vez
de fabricar un historial bonito. El primer registro honesto será el de la
semana 7.

### `confianza` no era confianza

```sql
'confianza', least(100, 35 + least(60, a.n_history*3))
```

Eso es **el número de juegos jugados convertido en porcentaje**. Kyren Williams
salía con "95" por tener 22 juegos, dijera lo que dijera la exactitud real del
modelo sobre él. Se conserva la clave porque el frontend la lee, y se añade al
lado lo que significa de verdad.

### La calibración medida llevaba un mes huérfana

`v2.fantasy_residual_calibration_v2` existe desde septiembre y **ningún
constructor la consume**:

| posición | cobertura de la banda | sesgo | MAE | n |
|---|---|---|---|---|
| QB | 82.5% | −0.08 | 6.46 | 338 |
| RB | 81.6% | +0.43 | 4.63 | 716 |
| TE | 82.1% | +0.14 | 2.91 | 820 |
| WR | 79.4% | −0.24 | 4.26 | 1287 |

Una banda q10–q90 debería atrapar el 80% de los resultados: atrapa entre 79.4%
y 82.5%. **Está muy bien calibrada, y no se le enseñaba a nadie.**

**Honestidad sobre a qué modelo pertenece:** está medida sobre **B1**. B2
construye su banda así:

```sql
floor_points_B2   = floor_points_B1   * (nueva_media / projected_mean_B1)
ceiling_points_B2 = ceiling_points_B1 * (nueva_media / projected_mean_B1)
```

La hereda escalándola por el cambio de media, conservando la anchura relativa.
Es una suposición razonable, **no una medición sobre B2**, y el contrato lo
dice con esas palabras en `nota_calibracion`.

### Y el backtest sellado que nadie veía

El propio `fantasy_model_config_v2` guarda la evidencia de B2, incluido este
párrafo escrito por quien lo validó:

> *"La ganancia es pequeña: +0.057 puntos por decisión sobre un promedio de
> 4.34. Es real y pasó la barra preregistrada, pero nadie gana una liga con
> esto. Su valor está en los casos donde cambia la decisión."*

Más la escalera completa: L0 4.3408 → L1 4.3733 (PASA) → L2 4.3982 (PASA) →
L3 4.3996 (**FALLA, la escalera se para aquí**), sobre 113,604 decisiones
walk-forward, con `market_used: false`.

**Ese párrafo es exactamente el "por qué" que el dueño pedía, y llevaba un mes
enterrado en una columna JSON.** Ahora viaja en cada respuesta bajo
`evidencia`, junto al historial en vivo y a esta advertencia automática cuando
la muestra es corta:

```
"advertencia_muestra": "Muestra insuficiente para afirmar que estas
 recomendaciones funcionan: 2 cambios calificados. No es evidencia en contra;
 es ausencia de evidencia."
```

Y cada tarjeta de jugador añade su línea medida:

> *"Qué tan fino es este número, medido: en RB el modelo se equivoca 4.63 puntos
> en promedio, y la banda piso-techo atrapó el resultado real el 81.6% de las
> veces sobre 716 juegos de prueba."*

Verificado: `G43.1 / G43.2 / G43.3` **PASS**, `resumen 61.67 = suma de titulares
61.67`.

## 2. ISS316 — Tenis: 4% de cobertura y una evaluación escondida

### Qué pasó con los marcadores

```
partidos en el historial   45,382   (desde 2021-09-25)
con marcador derivado       1,833   = 4.04%
eventos con linescore crudo 2,373
   de esos, casan con un partido  1,837
   HUERFANOS sin partido            536
```

Dos cosas distintas: **el 96% del historial no tiene marcador** porque nunca se
capturó su linescore, y **536 eventos tienen marcador capturado y no existen en
la tabla de resultados**. Ninguna de las dos se arregla inventando un marcador.
Quedan declaradas y medidas.

De lo que sí hay: 1,820 `COMPLETO` + 13 `INCOMPLETO_PROBABLE_RETIRO`, y la
vista la lee el cliente.

### La evaluación existía y la pestaña no la mostraba

`v_reto_tenis_predicciones_v1` enseñaba `pick_ganador` y `pick_prob_pct` **sin
una sola medición de si acierta**. Mientras tanto:

```
ATP   n=8,148   acierto 62.58%   Brier 0.2231   (OOS, corte 2025-07-01, secuencial)
WTA   n=5,620   acierto 60.30%   Brier 0.2323
```

Secuencial en el tiempo: el rating que predice cada partido se construyó solo
con partidos anteriores. **Sin fuga hacia adelante.**

### El Elo por superficie ya se probó, y pierde

| variante | acierto | Brier |
|---|---|---|
| atp_pool | 62.58% | **0.2231** |
| atp_surf | 62.68% | 0.2232 |
| wta_pool | 60.34% | **0.2323** |
| wta_surf | 60.48% | 0.2330 |

+0.10 pp sobre 8,148 partidos son **8 partidos**: ruido. Y el Brier empeora en
las dos. **El Elo por superficie no le gana al conjunto.** No hay que
construirlo, y queda escrito para que nadie lo vuelva a proponer sin datos
nuevos.

### Lo que se añadió, sin tocar la decisión

La vista conserva sus 12 columnas con el mismo nombre, orden y tipo —lo que el
frontend ya lee no se mueve— y añade al final: `acierto_oos_pct`, `muestra_oos`,
`brier_oos`, `evaluacion_nota`, `dif_rating`, `forma_p1`, `forma_p2`, `h2h` y
`lectura`.

**El pick no cambia: lo sigue decidiendo el rating Elo y solo el rating.** La
forma y el H2H son información para el usuario, no entradas de la decisión. Un
cerebro.

El vínculo tour → evaluación se **declara** en `v2.tenis_evaluacion_vigente` en
vez de adivinarse leyendo la nota de texto de la tabla de evaluaciones.

Dos ejemplos reales de por qué sirve:

```
Starodubtseva - Zakharova   dif_rating 11   pick 51.6%   h2h 0-1
  -> un volado, y ahora se ve. Antes decia "pick: Zakharova" con la misma
     autoridad visual que un 71%.

Maya Joint - Kyoka Okamura  pick Joint 62.2%
  forma: Joint 5-5   Okamura 8-2
  -> el pick no cambia, pero ya no te oculta que la forma reciente va al reves.
```

**El corte temporal de la forma y del H2H es la fecha del propio partido, no
`now()`:** la forma no puede incluir el resultado de lo que se está prediciendo
ni nada posterior.

### Casi rompo la pestaña, y lo agarré probando como el cliente

Primera versión: la vista llamaba a dos funciones nuevas. Probado **como
`anon`**, que es la llave que viaja en el bundle:

```
ERROR: 42501: permission denied for function tenis_forma_reciente
```

No habría mostrado columnas vacías: **la consulta entera falla y la pestaña de
Tenis queda en error.** Los privilegios sobre tablas dentro de una vista se
evalúan con el dueño de la vista; el `EXECUTE` de una función y la RLS de
dentro de ella se evalúan contra **quien llama**.

Medido antes de decidir cómo arreglarlo:

```
tenis_partidos_v1    RLS activo, CERO politicas  -> anon lee 0 filas directo
v_tenis_marcador_v1  (vista del dueno)           -> anon lee 1,833 filas
```

Ese es el patrón deliberado de esta base: **tabla base cerrada por RLS,
producto expuesto por vistas del dueño.** La salida fácil era marcar las
funciones `security definer`; eso es entregarle al cliente un lector
parametrizado de una tabla base, moralmente lo mismo que concederle SELECT, que
está prohibido. **Se hizo lo conservador:** el cálculo vive dentro de la vista,
y los `EXECUTE` que había concedido se retiraron.

Las funciones quedan como ayudantes de servidor, con un comentario que advierte
que la vista repite su lógica en línea a propósito y que si se cambia una hay
que cambiar la otra.

Verificado **como `anon`** después:

```
35 filas | 35 con forma | 9 con h2h | 35 con evaluacion | sin error
54 ms
G50.13 PASS · VISTA_DE_CLIENTE_SALTA_RLS_DE_TABLA_DE_USUARIO PASS
SECURITY_DEFINER_SIN_SEARCH_PATH PASS · PRIVILEGIO_POR_DEFECTO PASS
```

Nueve de 35 con H2H es correcto: la mayoría de esas parejas nunca se han
enfrentado.

## 3. Lo que NO está arreglado, declarado

- **El 96% del historial de tenis sigue sin marcador** y **536 linescores
  siguen huérfanos** de su partido. Medido, no arreglado: rellenarlo exige
  capturar linescores históricos, no derivar nada.
- **B2 no tiene calibración propia medida.** Hereda la de B1 escalada. Se dice
  en el contrato; no se re-mide aquí porque hace falta temporada calificada.
- **K/DST siguen sin modelo**: 2 de 15 slots del roster sin número.
- **Las semanas 4-6 de Fantasy no tendrán historial nunca**, y está bien: no se
  puede capturar hacia atrás sin fuga. El primero honesto será el de la semana 7.
- **El historial en vivo es n=2.** Cualquier afirmación sobre si el recomendador
  funciona es prematura, y el contrato lo dice solo.
- El frontend sigue **NO PROBADO** contra la app real (red bloqueada por
  política de la organización). Lo que sí se probó es la ruta de datos como
  `anon`.

## Rollback

```sql
-- ISS316
drop view if exists public.v_reto_tenis_predicciones_v1;  -- y recrear la version
                                                          -- de 12 columnas
drop index if exists public.idx_tenis_partidos_winner_fecha;
drop index if exists public.idx_tenis_partidos_loser_fecha;
drop table if exists v2.tenis_evaluacion_vigente;
drop function if exists public.tenis_forma_reciente(text, timestamptz, integer);
drop function if exists public.tenis_h2h(text, text, timestamptz);

-- ISS315
select cron.unschedule('fantasy-capturar-recomendacion-semanal');
select cron.unschedule('fantasy-calificar-recomendaciones');
drop function if exists v2.capturar_recomendaciones_de_la_semana();
--   y reponer el v_model escrito a fuego en capture_fantasy_recommendation_v3.
--   NO se recomienda: vuelve a registrar el historial del cerebro que no decide.
--   El bloque 'evidencia' y la clave 'calibracion' se quitan de
--   v2.fantasy_start_sit_auto_v2 borrando sus CTEs; nada mas depende de ellos.
```

No se borró un dato, no se borró un objeto, no se tocó un modelo, no se movió un
pick, no se encendió dinero. El único registro que cambió lo reescribió el
calificador autorizado al correr sobre resultados que ya existían.
