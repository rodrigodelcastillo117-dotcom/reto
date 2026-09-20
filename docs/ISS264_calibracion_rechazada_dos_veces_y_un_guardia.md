# ISS264 — Calibracion probada dos veces y rechazada, y un guardia para que no vuelva a pasar en silencio

Supabase: `wpiztubmmmzclhlprgpd` · Fecha: **2026-09-20**

## 1. Segundo intento de calibrar NFL: Platt scaling

El primer intento (ISS262) fue compresion de un parametro y lo rechazo su propia
ventana de ajuste. Eso no agotaba el asunto: faltaba el estandar de la industria,
**Platt scaling**, con dos parametros (pendiente e intercepto en espacio logit),
que SI puede corregir un sesgo sistematico que la compresion simple no toca.

Misma disciplina: ajuste en los 424 partidos viejos, validacion en los 92 que el
calibrador nunca ve. Rejilla pendiente ∈ [0.6, 1.3], intercepto ∈ [−0.2, 0.2].

| pendiente | intercepto | Brier ajuste (424) | Brier validacion (92) |
|---|---|---|---|
| **1.10** | **0.00** | **0.22497** ← mejor | 0.26130 |
| 1.00 (sin calibrar) | 0.00 | 0.22500 | **0.25831** |
| 0.90 | 0.00 | 0.22535 | 0.25553 |

**RECHAZADO.** El mejor ajuste gana **0.00003** de Brier — tres cienmilesimas,
indistinguible de cero — y **empeora** la validacion (0.26130 contra 0.25831).

Y el resultado es revelador en si mismo: la pendiente optima es **1.10**, o sea
*mas* confianza, no menos; y el intercepto optimo es **0**. **No hay sesgo
sistematico que corregir.** Coincide con lo ya medido: el sesgo por tramo cambia
de signo entre periodos, y ningun mapa suave arregla ruido.

**Dos familias de calibrador probadas. Las dos rechazadas por su propia prueba.**
No se registra `calibration_version` para NFL.

## 2. El arreglo que de verdad hacia falta: un guardia

NFL no estuvo roto por falta de modelo ni de datos. Estuvo roto **porque nadie
miraba**. La cadena se rompio en tres puntos distintos y **ninguno lanza un
error**: los tres devuelven cero en silencio.

`public.gate_cerebro_sin_cosechar()` mide esos tres puntos:

| gate | que detecta |
|---|---|
| **G50.1** | deportes con candidatos del laboratorio y SIN modelo promovido (el laboratorio produce y nadie cosecha) |
| **G50.2** | modelo promovido que NO genera ni una prediccion pese a tener partidos por delante |
| **G50.3** | deporte declarado del producto sin ningun cerebro con evidencia medida |

Los tres habrian cazado a NFL. Hoy los tres dan **PASS**.

### Probado que DETECTA, no solo que aprueba

Un guardia que solo aprueba con el paciente sano no sirve. Se recreo la averia
real de NFL dentro de una transaccion y se deshizo:

```
delete from v2.team_elo_learning_snapshot where model_version='nfl_elo_v1_k20_h25';
-> G50.2  FAIL  1
   "Modelos promovidos que NO capturan futuros pese a tener partidos por
    delante: nfl_elo_v1_k20_h25 (NFL, 76 partidos). Revisar la lista de ligas
    de v2.capture_team_elo_future() y que league_name case con live_scores.liga."
rollback;  -- los 76 snapshots siguen intactos, verificado
```

El guardia no solo falla: **nombra el modelo, la liga, cuantos partidos se estan
perdiendo y donde mirar.**

### Lo que este guardia NO hace

No enciende nada, no publica, no autoriza dinero, no promueve modelos. Solo mide
y grita. `revoke all ... from public, anon, authenticated`.

## Rollback

```sql
drop function if exists public.gate_cerebro_sin_cosechar();
```
