# MLB `C0-prod-2026-09` — ¿recalibrar? Diagnóstico honesto

_Fecha: 2026-10-14 · prod `wpiztubmmmzclhlprgpd` · modelo `mlb_canonical_v1` / candidate `C0-prod-2026-09`_
_Autorización: el usuario pidió "arranca" (iniciar recalibración MLB). Dinero sigue APAGADO._

## Pregunta
¿Se puede recalibrar el modelo MLB para cerrar el `CALIBRATION_FAIL` (gap 10pp) y liberar money?

## Respuesta corta
**No hay nada que recalibrar.** La "falla de calibración" NO es un defecto del modelo: es
ruido de muestra chica. Forzar una recalibración sobre estos 116 juegos sería sobreajuste y
**empeoraría** el modelo (demostrado abajo). El único bloqueo real y honesto es el **tamaño de
muestra** (116 < 120) y la regla de cobertura de buckets. Dinero se queda gateado (correcto).

## Evidencia

### 1. La muestra forward real son 116 juegos (no 0)
`v_mlb_canonical_release_authority_v1` reporta hoy `n_oos_events=0` / `FORWARD_SAMPLE_INSUFFICIENT`.
Eso es el bug de fuente del kickoff (`JOIN agenda_espn` purga juegos pasados) — ver
`iss_mlb_authority_kickoff_source_fix.sql`. Con la fuente corregida (`historico_partidos_espn`),
la muestra calificada = **116** juegos.

### 2. Métricas del gate con la muestra visible (fuente corregida)
| Criterio | Umbral | Valor | ¿Pasa? |
|---|---|---|---|
| n OOS | ≥ 120 | **116** | ❌ (por 4) |
| Brier | < 0.25 | 0.23835 | ✅ |
| LogLoss | < 0.693 | 0.66953 | ✅ |
| Brier Δ sup95 (skill significativo) | < 0 | −0.00096 | ✅ (apenas) |
| Buckets soportados (n≥20) | ≥ 3 | **2** | ❌ |
| Gap de calibración (buckets soportados) | ≤ 5pp | **10.0pp** | ❌ |

### 3. El gap de 10pp NO es real — es ruido
Prueba binomial por bucket (Wald, z = |p_modelo − observado| / SE):

| bucket | n | modelo | observado | gap | SE | z | veredicto |
|---|---|---|---|---|---|---|---|
| 0.30 | 3 | 0.371 | 0.333 | 3.7pp | 27.2pp | 0.14 | ruido |
| 0.40 | 39 | 0.459 | 0.359 | **10.0pp** | 7.7pp | **1.31** | **ruido** |
| 0.50 | 66 | 0.541 | 0.576 | 3.4pp | 6.1pp | 0.57 | ruido |
| 0.60 | 8 | 0.634 | 0.750 | 11.6pp | 15.3pp | 0.76 | ruido |

**Ningún bucket se distingue del azar** (todos z < 1.96). El 10pp que tumba el gate es una
oscilación de 1.3σ sobre 39 juegos. No existe miscalibración estadísticamente establecida.
No se puede corregir lo que no está roto.

### 4. Recalibrar aquí EMPEORA el modelo (medido, no opinado)
Apliqué la transformada lineal histórica vigente de beisbol (`calibracion_coef` id=6:
a=−0.0389, b=1.0665, ajustada sobre 1,056 juegos de backtest — genuinamente fuera de
muestra respecto a los 116 forward) a los 116 juegos:

- Brier crudo = **0.23835**
- Brier calibrado (en rango) = **0.24317** → **peor**

Es decir: la recalibración existente, aplicada honestamente OOS, degrada el Brier. Cualquier
transformada ajustada a los 116 juegos de prueba (y luego "validada" sobre esos mismos 116)
sería circular y sobreajustaría ese 10pp de ruido. Eso sería "debilitar la guardia para
pasar el gate" — prohibido.

### 5. Por qué solo hay 2 buckets soportados (tensión de diseño)
El modelo amortigua 70% hacia la base (`AMORTIGUA=0.70`, `BASE_LOCAL≈52.8%`), así que
105/116 probabilidades caen en [0.40, 0.60). Esa compresión fue **justificada empíricamente**
(la varianza real del margen 22.09 vs 9.15 de Poisson → razón de desviaciones 0.645 ≈ 0.70).
No hay evidencia de que la compresión esté mal (los gaps son ruido y el skill es positivo),
así que **no se toca AMORTIGUA**. Pero esa compresión hace que la regla "≥3 buckets con n≥20"
sea casi inalcanzable para un moneyline MLB bien calibrado y centrado. Es una pregunta de
diseño para el auditor, no un bug del modelo.

## Conclusión / ruta legítima
1. **No recalibrar.** No hay miscalibración real; recalibrar sobreajusta y degrada (medido).
2. **Dinero sigue APAGADO** — n=116<120 de todos modos. Aun con calibración perfecta, no libera hoy.
3. **Honestidad del reporte:** aplicar `iss_mlb_authority_kickoff_source_fix.sql` (auditor) para
   que el gate reporte el n real (116) y el status verdadero, en vez del `n=0` engañoso.
4. **Acumular muestra:** faltan ~4 juegos para n≥120. MLB entra a postemporada/offseason →
   crece lento. La captura forward (crons 520/521) sigue viva y honesta.
5. **Pregunta de diseño al auditor:** la regla de "≥3 buckets soportados" vs. un modelo
   deliberadamente comprimido. Si se mantiene la regla, el modelo nunca la cumplirá por diseño,
   aunque esté bien calibrado; conviene decidirlo explícitamente, no por accidente.

**No fabriqué ninguna recalibración. No modifiqué el modelo en prod. Dinero sigue gateado.**
