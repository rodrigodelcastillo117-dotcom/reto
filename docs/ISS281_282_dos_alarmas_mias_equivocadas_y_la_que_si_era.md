# ISS281/282 — Dos alarmas mías equivocadas, y la que sí era

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-21**

El dueño pidió mejorar los picks. Empecé midiendo y **di dos alarmas falsas**
antes de encontrar lo real. Las dejo escritas porque el error de método importa
más que el hallazgo.

---

## Error 1: medí la calibración del modelo que NO publica

Reporté que NFL tenía la calibración rota, con una brecha de **24.21 pp**, y
construí toda una máquina para acotarla. El número es correcto, pero es de
`nfl_elo_v1_k20_h25`: **un modelo de laboratorio que no publica ni un pick.**

El que sirve los picks de NFL es `nfl_hybrid_ml_v1`, y su evidencia sellada dice:

```
rama temprana (Elo prior, k=40 hfa=40 carry=0.60):
   2024: 4.42 pp | 2025: 6.54 pp | 2026 sem1: 5.42 pp
rama madura (nfl_form_ml_v1, n=123):
   brecha maxima 4.79 pp, acierto 69.92%
```

**Todas por debajo del listón de 7.5.** No había incendio.

La causa: `v2.team_elo_selected_model` tiene una fila `football/NFL` y la tomé
como "el modelo de NFL" sin comprobar qué produce las probabilidades publicadas.
Es la sustitución silenciosa de identidad que tengo explícitamente prohibida,
cometida sobre modelos en vez de sobre equipos.

## Error 2: dije que NBA no tenía tubería de producto

Escribí que NBA —el único modelo calibrado— no tenía "puente" ninguno. **Falso.**
Existe completo y lleva tiempo ahí:

| pieza | estado |
|---|---|
| `v_team_sports_publication_v1` | existe, sirve basketball/hockey |
| `mv_team_sports_recommendation_gate_v1` | existe, exige P_RETO >= 65% y corte pre-saque |
| entrada a `v_reto13m_global_top_v2` | existe, rama `sport='basketball'` |
| `live_n`, `live_calibration_gap_pp`, `live_accuracy_pct` | **ya expuestos** |

**Primer partido de NBA: 2026-10-03.** No hay que construir el puente; hay que
verificar que aguanta cuando lleguen los partidos.

Busqué tablas con nombre `nba%` y no encontré ninguna, y concluí que no había
nada. La tubería es genérica (`team_sports`), no por deporte. Buscar por nombre
no es medir.

### De paso, dos exclusiones que sí funcionan

- **WNBA**: 14 partidos próximos, brecha en vivo de **70.42 pp** sobre 8 partidos.
- **NHL**: 51 partidos próximos, modelo en `OOS_FAIL`.

Ninguno llega a picks: `v_reto13m_global_candidate_v2` devuelve **0 filas** para
ambos. Medido, no supuesto.

---

## Lo que SÍ era real

```
v_team_sports_publication_v1 (NBA, NHL, WNBA):
   live_n, live_calibration_gap_pp, live_accuracy_pct    <- SI

v_nfl_publication_v1:
   ninguna de las tres                                    <- NO
```

**NFL es el único deporte que sirve picks y el único sin calibración en vivo.**
Y la vista filtra `kickoff > now()`: por construcción tira el pasado, así que no
puede mirarse a sí misma.

Su evidencia estaba **sellada el 2026-09-15** y nunca recalculada, con las
semanas 1 a 3 ya jugadas. Séptima aparición de la misma enfermedad: la
maquinaria existe, la cosecha no.

### Lo que dice la temporada en curso

`public.v_nfl_live_calibration_v1` (ISS282), calculado desde
`v2.nfl_decision_snapshot` exigiendo `decision_time < kickoff`:

| modelo | n | Brier | acierto | dice | brecha | veredicto |
|---|---|---|---|---|---|---|
| **`nfl_hybrid_ml_v1`** (publica) | **15** | 0.24779 | 60.0% | 62.8% | **2.85 pp** | **MUESTRA INSUFICIENTE** |
| `nfl-2026.09.2` (predecesor) | 30 | 0.25648 | 53.3% | 61.8% | 8.49 pp | FUERA DEL LISTÓN / NO LE GANA A ADIVINAR |

El modelo que publica va bien en lo que lleva, y le gana al predecesor en las
tres métricas. **Con 15 partidos la vista se niega a dar veredicto**, que es lo
honesto: `MUESTRA INSUFICIENTE` no es aprobado.

El predecesor sí tiene muestra y sí reprueba. Ya no publica.

### Un error propio dentro de la medición

La primera consulta usó `distinct on (espn_event_id)` sin separar por modelo. Las
tres versiones cubren **los mismos 47 eventos**, así que se colapsaron en una y
me salió `nfl_hybrid_ml_v1` con n=1 y un Brier de 3785. Corregido con
`distinct on (model_version, espn_event_id)`.

## G50.6 — el detector con consumidor

La lección de ISS279 es que un detector sin consumidor no sirve. `G50.6` juzga
**solo al modelo que realmente publica**, no a los predecesores del historial:

- brecha fuera del listón, o Brier peor que adivinar, con n>=30 → **FAIL**
- n<30 → **INFO** (muestra insuficiente no es aprobado, ni es fallo del modelo)

Hoy: `INFO — nfl_hybrid_ml_v1: n=15, brier=0.24779, brecha=2.85pp`.

## Lo que construí y NO cambia ningún pick, dicho claro

`v2.fn_rango_calibracion_publicable` + `v2.rango_calibracion_publicable`: derivan
del holdout hasta qué probabilidad está demostrado que cada modelo no miente.

| modelo | techo | n dentro | brecha dentro | corta porque |
|---|---|---|---|---|
| NBA | 100% | 1352 | 4.90 | todos los tramos califican |
| NFL (lab) | 80% | 492 | 3.53 | tramo 4: solo 24 partidos |
| NHL | 70% | 801 | 4.74 | tramo 3: brecha 15.29 pp |
| WNBA | 90% | 339 | 5.35 | tramo 5: solo 4 partidos |

La máquina es correcta y el criterio se deriva de la evidencia, no se escribe a
mano. **Pero hoy no afecta a ningún pick**, porque está indexada por los modelos
de `team_elo_selected_model` y el que publica NFL no es uno de ellos. Lo dejo
declarado así en vez de presentarlo como una mejora que no es.

Donde sí aplica limpio es en NBA, cuyo modelo publicador **sí** es
`nba_elo_v1_k24_h50`. Queda listo para el 3 de octubre.

## Verificación

```
G50.6 calibracion NFL en vivo     INFO (n=15, muestra insuficiente)
G50.5 partido sin resultado       PASS (0)
G50.5b resultado sin corroborar   INFO (14)
G50.4 dinero sin aprobacion       PASS (0)
```

## Límites

- `v_nfl_live_calibration_v1` solo ve desde el **2026-09-11**, que es cuando
  arranca `nfl_decision_snapshot`. No hay temporadas anteriores por ahí.
- No toqué `v_nfl_recommendation_gate_v1`. El piso editorial de 58% sigue igual
  y **no puse ningún techo**, porque el techo que calculé es de otro modelo.
- El rango publicable **no está cableado a ninguna vista de producto.** A
  propósito.

## Rollback

```sql
drop function if exists public.gate_nfl_calibracion_en_vivo();
drop view if exists public.v_nfl_live_calibration_v1;
drop function if exists v2.refresh_rango_calibracion_publicable(integer,numeric);
drop table if exists v2.rango_calibracion_publicable;
drop function if exists v2.fn_rango_calibracion_publicable(text,integer,numeric);
```

Nada de esto toca datos, modelos, el gate de dinero ni un solo pick.
