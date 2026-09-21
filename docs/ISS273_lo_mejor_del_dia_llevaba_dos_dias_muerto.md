# ISS273 — «Lo mejor del día» llevaba dos días muerto

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

---

## El hallazgo

El dueño pidió, textual: *"que la AI seleccione el mejor pick"* sobre el análisis
existente. Fui a ver si esa función existía. Existe **cuatro veces**, y las cuatro
estaban en **CERO filas**:

| superficie | filas |
|---|---|
| `v_reto13m_daily_best_by_sport_v1` | **0** |
| `v_reto13m_lo_mejor` | **0** |
| `v_reto13m_mejores` | **0** |
| `v_reto13m_daily` | **0** |

Mientras tanto `v_pick_canonico` servía **120 picks**. La app tenía picks y
ninguna selección del mejor — justo la función que se pedía.

## Causa raíz, eslabón por eslabón

Seguí la cadena hacia arriba hasta encontrar dónde moría:

| eslabón | filas |
|---|---|
| `mv_reto13m_global_candidate_v2` (**materializada**) | 53 |
| `v_reto13m_global_candidate_source_v2` (viva) | 20 |
| **`v_reto13m_global_candidate_v2`** | **0** ← muere aquí |
| `v_soccer_recommendation_gate_v2` | 2 |
| `v_mlb_recommendation_gate_v1` | 19 |
| **`v_nfl_recommendation_gate_v1`** | **32** |
| `mv_team_sports_recommendation_gate_v1` | 15 |
| `v_reto13m_global_top_v2` | 0 |

Las compuertas por deporte funcionaban bien. Lo que fallaba era el candidato
global, y la razón es de manual:

| | filas | kickoffs | futuros |
|---|---|---|---|
| materializada | 53 | **17 – 19 sep, todos pasados** | **0** |
| fuente viva | 20 | 21 – 23 sep | 20 |

**La vista materializada se congeló el 19 de septiembre.** Todo lo que colgaba de
ella filtraba por `kickoff > now()` y no encontraba nada.

Y el cron que la refresca **existía y estaba apagado**:

```
jobid 515   reto-global-candidate-snapshot-v1   [2-59/15 * * * *]   active = false
```

Es la **cuarta aparición del mismo patrón en esta sesión**: maquinaria completa
cuya última pieza no corre. ISS262 (promoción sin cron), ISS263 (candado escrito
a mano), ISS270 (gates sin cosecha) y ahora ésta.

## Probado antes de aplicar

En transacción revertida:

```
mv            53 filas / 0 futuros  ->  20 filas / 20 futuros   (refresco: 6.7 s)
candidate_v2   0 -> 20
global_top_v2  0 ->  6
LO MEJOR DEL DIA  0 -> 2
```

## Aplicado y verificado en vivo

```
cron_515_activo = true
mv = 20 filas, 20 futuros
lo_mejor_del_dia = 2 | top_global = 6 | con_dinero = 0
```

## La selección que ahora produce la app

Ordenada por `P_RETO`, sin cuota, sin EV, sin Kelly — la disciplina que ya estaba
definida:

| # | deporte | partido | pick | P_RETO | cerebro | evidencia |
|---|---|---|---|---|---|---|
| **1** | MLB | Atlanta Braves vs Cincinnati Reds | Gana Atlanta | **70.1%** | `mlb_one_brain_v2` | CANONICAL_ANALYSIS |
| 2 | **NFL** | LA Rams vs NY Giants | Gana Rams | **70.0%** | `nfl_hybrid_ml_v1` | **OOS_VALIDATED** |
| 3 | MLB | Colorado vs Arizona | Gana Arizona | 66.2% | `mlb_one_brain_v2` | CANONICAL_ANALYSIS |
| 4 | MLB | Philadelphia vs Milwaukee | Gana Milwaukee | 60.9% | `mlb_one_brain_v2` | CANONICAL_ANALYSIS |
| 5 | MLB | Chicago Cubs vs Miami | Gana Cubs | 60.9% | `mlb_one_brain_v2` | CANONICAL_ANALYSIS |
| 6 | MLB | Baltimore vs Toronto | Gana Baltimore | 59.2% | `mlb_one_brain_v2` | CANONICAL_ANALYSIS |

**Cero con dinero autorizado**, como debe ser.

Detalle que vale la pena notar: el pick de NFL (rank 2) es el único de la lista
con `validation_status = OOS_VALIDATED`. Los de MLB dicen `CANONICAL_ANALYSIS`,
que es un nivel de respaldo menor. El #1 y el #2 están separados por **una décima
de punto** — y el #2 tiene mejor evidencia que el #1.

## Límite declarado, y es importante

**NO SÉ POR QUÉ ALGUIEN APAGÓ EL CRON 515.** No hay nota, ni comentario, ni
registro. Lo reactivé porque:

1. El refresco funciona y tarda 6.7 s.
2. Es `CONCURRENTLY`, así que no bloquea lecturas.
3. Apagado dejaba muerta la función principal del producto.

Si se apagó por una razón que no veo, este cambio la revive y hay que revisarlo.
Lo dejo escrito para que se pueda cuestionar en vez de descubrirlo por sorpresa.

## Rollback

```sql
select cron.alter_job(job_id := 515, active := false);
```

La materializada se queda con lo último que tenga; no se pierde nada.
