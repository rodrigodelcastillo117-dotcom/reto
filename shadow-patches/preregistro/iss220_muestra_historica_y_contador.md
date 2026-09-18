# ISS220 — ¿Se puede construir una muestra histórica válida? Y el contador diario

Los umbrales preregistrados en ISS215 **no se tocan**: fútbol 450, MLB 300.

## 1. La pregunta: correr los cerebros autorizados sobre snapshots point-in-time

Condiciones que exigiste, y qué encontré para cada una.

### Fútbol — `soccer_canonical_v2`: **POSIBLE, con una limitación que declaro**

- **Existe una función as-of real**: `v2.fn_crossleague_features_training_asof(team, event_time, window)`
  construye los rasgos filtrando `fecha < p_event_time`. No es una reconstrucción
  inventada: es la misma función que el cerebro usa en producción.
- **Cada input existe antes del evento**: sí, por construcción del filtro.
- **No usa tablas actuales como sustituto del pasado**: aquí está la limitación.
  Medido sobre `public.historico_partidos_espn` (rama soccer, 33,639 filas):
  **32,571 se cargaron más de 7 días DESPUÉS de la fecha del partido**, y
  `cargado_at` sólo va de 2026-08-30 a 2026-09-18. O sea la tabla es un
  **backfill**, no un libro de altas.
  Consecuencia exacta: puedo probar que cada insumo se refiere a un partido
  **ocurrido antes** del corte (point-in-time por tiempo de EVENTO), pero **no**
  que ese dato estuviera **en la base** en ese momento (point-in-time por tiempo
  de INGESTA). Para marcadores finales esa diferencia es casi inocua — un 2-1 de
  2025 sigue siendo 2-1 — pero no es lo mismo y no lo voy a presentar como si lo
  fuera.
- **Código congelado antes de generar la muestra**: pendiente. Exige sellar el
  hash de `fn_crossleague_features_training_asof` y del constructor ANTES de
  correr, y volver a verificarlo después.
- **Train y holdout temporalmente separados, holdout intocado**: factible, con
  corte por fecha.
- **Lineage reproducible**: factible; sería una tabla fila por fila como
  `v2.iss211_nfl_reproduccion`.

**Veredicto fútbol: se puede intentar, y es la única vía para no esperar a 2027.
No lo corro en este turno porque exige congelar el código primero y
preregistrarlo aparte. Queda como el siguiente trabajo, no como algo hecho.**

### MLB — `mlb_one_brain_v2`: **NO ES POSIBLE**

`mlb_one_brain_v2(espn_event_id)` lee `public.mlb_stats_cache`, que es un
**caché por evento que se sobrescribe**. No hay ninguna función as-of para los
rasgos de MLB (las que existen son `fn_nfl_dk_line_asof`, `fn_soccer_tiros_asof`,
`fn_soccer_venue5_asof_v1`, `forma_espn_asof`, `fut_metricas_equipo_asof` —
ninguna de béisbol). Reconstruir el pasado exigiría un caché histórico que no
existe.

**Veredicto MLB: sólo acumulación prospectiva.**

## 2. Lo que NO se mezcla, pase lo que pase

`crossleague_v1`, `crossleague_v1_1`, `predecir_mlb` (el `mlb_runtime_*`), el
Poisson de `construir_dossier_partido`, `dc-2026.09.1`, `ou_sot_v1`,
`ou_gfga_v1` y cualquier otro retador. Nada de eso entra a la muestra de un
cerebro autorizado.

## 3. Contador diario

`v2.calibrador_contador`, poblado por `v2.medir_calibrador_contador()`, cron
`calibrador-contador-diario` (jobid 546, 06:35 UTC). El ritmo semanal se mide
sobre los últimos 14 días de captura real.

Primera medición, 2026-09-18:

| deporte | muestra requerida | muestra válida | faltante | ritmo semanal | fecha estimada |
|---|---|---|---|---|---|
| soccer | 450 | 30 | 420 | 15.0 | **2027-04-02** |
| baseball | 300 | 9 | 291 | 4.5 | **2027-12-15** |

Eso es lo que cuesta esperar sólo a la acumulación prospectiva, y es la razón
por la que la reconstrucción histórica de fútbol vale el trabajo.
