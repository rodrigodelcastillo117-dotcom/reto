# ISS262 — NFL tenia cinco temporadas de datos y ningun modelo

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

---

## El hallazgo

NFL medía 25.0% de acierto en Spread y 31.3% en Total. La lectura facil es "el
modelo es malo". La medicion dice otra cosa:

| deporte | modelo | observaciones | desde |
|---|---|---|---|
| NBA | nba_elo_v1_k24_h50 | 1,352 | 2025-04-05 |
| NHL | nhl_elo_v1_k12_h25 | 863 | 2025-02-09 |
| WNBA | wnba_elo_v1_k32_h25 | 351 | 2025-09-07 |
| **NFL** | nfl-2026.09.2 | **48** | **2026-09-11** |

**No era un modelo malo. Era la ausencia de un modelo.** NFL corria con 48
observaciones de una semana, mientras NBA, NHL y WNBA tenian modelos Elo
entrenados con cientos o miles.

## Y los datos estaban ahi desde el principio

`v2.team_history_event` contiene **1,738 eventos de NFL (1,725 decisivos) desde
2021-08-06** — cinco temporadas. Nunca se uso.

## Por que nunca se construyo: el hueco

La cadena existe completa y funciona:

1. `v2.refresh_team_elo_labs()` — **cron 471, diario 08:35** — genera candidatos.
   Ya habia corrido: 30 combinaciones de NFL con fecha 2026-09-19 08:35.
2. `v2.refresh_selected_team_elo_models()` — promueve el mejor candidato.
   **NO TIENE CRON. Nadie lo ejecuta nunca.**

El laboratorio genera candidatos todos los dias y la promocion no corre. Ademas
`football/nfl` YA estaba declarado en `v2.deporte_del_producto`, asi que la
barrera ISS210 nunca fue el problema.

## Que hice

Ejecutar la promocion que ya existia. Nada inventado, nada de umbrales.

**Prerregistro antes de mirar resultados:** rejilla k ∈ {12,16,20,24,32} × hfa ∈
{25,40,50,65}, min_prior=5.

**Correccion a mi propio prerregistro:** yo escribi "elegir por menor
`brier_holdout`". Eso habria contaminado el holdout al seleccionar sobre el. La
maquinaria existente elige por `brier_train` y **valida** en holdout, que es la
disciplina correcta. Me equivoque y segui la suya. Su eleccion (k=20, hfa=25)
dio en holdout exactamente lo que mi rejilla independiente habia medido para esa
combinacion (0.23094 / 64.15%): validacion cruzada limpia.

## Resultado — antes y despues

| | antes (`nfl-2026.09.2`) | despues (`football/nfl_elo_v1_k20_h25`) |
|---|---|---|
| partidos evaluados | **16** | **516** |
| acierto | 56.3% | **64.2%** |
| Brier holdout | — | 0.23094 |
| **upper95** | **+0.10948** | **−0.01225** |
| veredicto de habilidad | no se sabe | **LE GANA A ADIVINAR** |
| gap de calibracion | 35.5 pp | 24.2 pp |
| `prediction_authorized` | false | **false** (falla calibracion) |
| `money_authorized` | false | **false** |

**El dinero sigue apagado.** La promocion da autoridad de prediccion, no de
dinero; el dinero exige evidencia adicional contra mercado. Y `prediction_authorized`
sigue en false porque la calibracion falla el umbral de 7.5 pp.

## Donde falla exactamente la calibracion

| tramo | partidos | dice | ocurre | sesgo | soporte (n>=20) |
|---|---|---|---|---|---|
| 6 | 216 | 54.8% | 58.3% | +3.5 | si |
| 7 | 174 | 64.7% | 67.8% | +3.1 | si |
| 8 | 102 | 73.9% | 71.6% | −2.4 | si |
| **9** | **24** | **82.5%** | **58.3%** | **−24.2** | si (al filo) |

**492 de 516 partidos estan calibrados dentro de ±3.5 pp.** Los 24.2 pp vienen de
un unico tramo: el de maxima confianza. Es la sobreconfianza clasica del Elo en
NFL — la varianza de un solo partido es enorme.

Contraste importante con MLB: alli los 21 pp salian de un tramo de **7** partidos
sin soporte, y eran ruido. Aqui el tramo tiene 24 partidos y **si** tiene soporte,
aunque este justo en el minimo. Este defecto es real.

## El calibrador: PROBADO Y RECHAZADO (2026-09-20)

> **CORRECCION A ESTE MISMO DOCUMENTO.** Arriba escribi: *"Aqui hay un sesgo
> medido, localizado y con soporte. Es justo el caso donde calibrar es legitimo."*
> **Estaba equivocado, y la prueba lo demuestra.** Lo dejo escrito en vez de
> borrarlo.

### Metodo

Solo estan guardadas las 516 predicciones de holdout, no las 1,121 de
entrenamiento. Para no reimplementar el Elo, se partio el holdout en el tiempo:

- **ajuste**: 424 partidos, 2024-11-17 a 2025-12-30
- **validacion**: 92 partidos, 2026-01-03 a 2026-09-15 (el calibrador nunca los ve)

Calibrador probado: compresion monotona de un parametro
`p' = 0.5 + lambda*(p - 0.5)`, lambda ∈ [0.50, 1.00].
**Regla prerregistrada: lambda se elige en la ventana de AJUSTE.**

### Resultado

| lambda | Brier ajuste (424) | Brier validacion (92) |
|---|---|---|
| **1.00 (sin calibrar)** | **0.22500** ← mejor | 0.25831 |
| 0.75 | 0.22658 | 0.25111 |
| 0.50 | 0.23128 | 0.24732 |

**La ventana de ajuste elige lambda = 1.00: no calibrar.** Toda compresion
empeora el Brier ahi.

En validacion la compresion si mejora — pero **eso no es calibracion, es tapar**:
en esa ventana el modelo va peor que adivinar (0.25831 > 0.25), y encoger hacia
0.5 mejora mecanicamente cuando el modelo es malo. Elegir lambda por la ventana
de validacion seria seleccionar sobre el conjunto de validacion, el mismo error
que ya me corregi al elegir k.

### Por que el gap de 24.2 pp tampoco es un sesgo real

El sesgo por tramo **cambia de signo entre periodos**:

| tramo | sesgo en ajuste | sesgo en validacion |
|---|---|---|
| 5 | **−11.2 pp** | **+9.9 pp** |
| 7 | **+8.1 pp** | **−12.9 pp** |
| 8 | +3.4 pp | **−17.9 pp** |

Un defecto de calibracion real tiene direccion **estable**. Este se invierte en
el mismo tramo de un periodo a otro. Es ruido de tramos delgados.

**Mismo veredicto que en MLB, por un camino distinto:** el numero grande de
"mala calibracion" no sobrevive a que lo partas en dos.

### Accion correcta

**Ninguna.** No se registra `calibration_version`. `prediction_authorized` se
queda en false, el dinero apagado, y el modelo acumula partidos. El gate esta
haciendo exactamente lo que debe.

## Aviso que hay que vigilar

En los 92 partidos mas recientes (2026) el Brier es **0.25831, peor que 0.25 de
adivinar**. El 0.23094 global lo carga el periodo viejo. Con 92 partidos puede
ser ruido, pero es justo el numero que hay que mirar la semana que viene: si la
ventana reciente sigue por encima de 0.25, la habilidad demostrada sobre 516 deja
de ser la historia completa.

## Pendiente de gobierno

`v2.refresh_selected_team_elo_models()` sigue **sin cron**. El laboratorio
(cron 471) seguira generando candidatos y nadie los promovera. Eso es una
decision de producto — promover automaticamente es encender cosas solo — asi que
lo dejo anotado y no lo programo por mi cuenta.

## Rollback

```sql
delete from v2.team_elo_selected_model where model_version = 'football/nfl_elo_v1_k20_h25';
delete from v2.team_elo_holdout_prediction where model_version = 'football/nfl_elo_v1_k20_h25';
delete from v2.model_learning_observation where model_version = 'football/nfl_elo_v1_k20_h25';
select v2.refresh_model_learning_gates();
```

No borra datos historicos: `team_history_event` y `team_elo_backtest_result`
quedan intactos.

---

# ISS263 — El modelo existia y no podia producir ni una prediccion

Promover el modelo (ISS262) no bastaba. Habia **dos candados escritos a mano** en
la misma cadena, y los dos habia que abrirlos para que NFL llegara a la pantalla.

## Candado 1 — la liga estaba fuera de la captura

`v2.capture_team_elo_future()` filtraba:

```sql
and liga in ('NBA','WNBA','NHL')
```

**NFL no estaba.** Y el recuento hace la ironia evidente:

| liga | partidos proximos en `live_scores` |
|---|---|
| **NFL** | **255** |
| NBA | 1 |
| NHL | 0 |
| WNBA | 0 |

El deporte con mas futuro por delante era el unico excluido.

## Candado 2 — el nombre de la liga no casaba

`refresh_selected_team_elo_models()` mapea el nombre con un CASE que solo conocia
NBA/WNBA/NHL. NFL caia en el ELSE y se guardaba como `league_name='football/nfl'`.
La captura une por `league_name = r.liga`, donde `r.liga='NFL'`. Aunque NFL
hubiera pasado el filtro del candado 1, el join habria fallado igual.

Los dos arreglados en la raiz con parche exactamente-una-vez, y el modelo
re-promovido con el nombre correcto: `nfl_elo_v1_k20_h25`, `league_name='NFL'`,
34 equipos con rating.

## Trampa del contador (por la que casi lo doy por fallido)

`capture_team_elo_future()` devolvio `{"captured":0,"skipped_unmatched":0}`. Con
76 filas que si cumplian el filtro, eso no cuadraba. **El trabajo si se hizo:**
el contador va detras de un `if found` posterior a un upsert, y no cuenta cuando
el INSERT resuelve sin insertar. Si me hubiera creido el valor de retorno habria
reportado un fallo que no existia.

## Resultado, verificado como `anon`

```
v_reto_brain_prediction_timeline_v1  (legible por anon)
  sport=football  league=NFL  model_version=nfl_elo_v1_k20_h25
  76 partidos, del 2026-09-20 al 2026-10-20
```

Muestra de las predicciones, todas con `temporal_safe=true`, sumando 1.0000 y
cargando su propio status honesto (`OOS_SKILL_CALIBRATION_FAIL`) en el `meta`:

| partido | local | visita |
|---|---|---|
| Ravens vs Saints | 80.6% | 19.4% |
| Titans vs Eagles | 24.9% | **75.1%** |
| Jets vs Packers | 30.6% | **69.4%** |
| Bears vs Vikings | 50.4% | 49.6% |
| Buccaneers vs Browns | 64.2% | 35.8% |

## Aviso para quien lea esa vista

La misma vista sirve TRES versiones de modelo de NFL: `nfl_elo_v1_k20_h25` (76
filas), `nfl-2026.09.2` (27,945) y `nfl_hybrid_ml_v1` (1,248). Quien la consuma
**tiene que filtrar por `model_version`**, o mezclara cerebros. Es el mismo
riesgo que ya señale para MLB.

## Rollback

```sql
delete from v2.team_elo_learning_snapshot where model_version='nfl_elo_v1_k20_h25';
-- y revertir los dos parches quitando 'NFL' de capture_team_elo_future()
-- y la rama 'football/nfl' del CASE de refresh_selected_team_elo_models().
```

## Lo que sigue sin estar encendido

`prediction_authorized` = false y `money_authorized` = false. La calibracion no
se establecio (ver arriba: el calibrador se probo y se rechazo). NFL publica
**analisis**, no picks de dinero.
