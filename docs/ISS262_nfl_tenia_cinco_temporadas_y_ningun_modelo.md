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

## Siguiente paso concreto (NO hecho todavia)

Ajustar un mapa de calibracion monotono (isotonica o Platt) **solo sobre el
tramo de entrenamiento**, validarlo en el holdout de 516, y registrarlo como
`calibration_version` unicamente si baja el gap por debajo de 7.5 pp **sin**
empeorar el Brier. Si no lo logra, no se registra y se dice.

Esto NO es el caso de MLB/futbol, donde la calibracion se probo y se rechazo:
alli el modelo ya estaba insesgado o el calibrador empeoraba. Aqui hay un sesgo
medido, localizado y con soporte. Es justo el caso donde calibrar es legitimo.

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
