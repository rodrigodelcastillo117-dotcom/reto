# Auditoría de calibración + recalibración de tenis ATP (validada OOS)

Fecha: 2026-11-08. Gatillo: "haz TODO bien" + "que la IA aprenda". Auditoría de honestidad de todo el motor.

## Auditoría de salud (solo lectura)
- **Crons:** ~230 activos; solo 2 fallan y son benignos (`panel-guardias-foto` = "server restarted" infra transitoria; `lab_ff_weekly_capture` = timeout de un lab de fantasy, periférico). El pipeline central (momios, lesiones, agendas, calificación) está sano y fresco.

## Auditoría de calibración (predicho vs. real, por deporte)
- ✅ **Soccer (P0): honesto.** 55%→56.8%, 63%→61.7% (muestras 700+). 
- ✅ **NHL: casi perfecto** (63%→63.4%).
- ✅ **NFL: bien** (54%→56.7%).
- ⚠️ **NBA: mixto** — tramo 60-69% sobreconfiado ~−9pp (pendiente, ver abajo).
- ❌ **Tenis ATP: sobreconfiado** (el bucket 80-100% de muestra completa ganaba ~56%).
- ⚠️ **Tenis WTA: leve sobreconfianza** en medio.

## Recalibración de tenis — hecha BIEN (validación OOS, no al vapor)
Se probó Platt scaling y shrinkage, **validando train/test 70/30 por fecha**:
- **Platt empeoró el Brier OOS** en ambos tours → descartado (el −29pp dramático era ruido de muestra chica, no sesgo estable).
- **Shrinkage hacia 50%:**
  - **ATP: k=0.70 MEJORA OOS** (Brier test 0.0587 → 0.0514; sesgo +4.5 → −0.9pp). ✅ Aplicado.
  - **WTA: NO mejora** (Brier 0.0215 → 0.0274) → **k=1.0, no se toca**. ✅
  - Combinado (todo tenis): no mejora → la ganancia es solo de ATP.
Lección clave: la validación OOS **evitó** aplicar una recalibración que sonaba bien pero sobreajustaba.

## Lo construido (el "cerebro que aprende, pero validado")
- **Tabla `reto_calibracion_deporte_v1`** (RLS on): registro de recalibraciones con sus métricas antes/después OOS y `validado` bool. Hoy: `tenis_atp` k=0.70 validado; `tenis_wta` k=1.0 no-aplicar. Regla de oro: **solo se aplica lo que pasa OOS.**
- **Vista `v_reto_tenis_tour_proximo_v1`**: partidos de tenis próximos con su tour (ATP/WTA) desde `tenis_agenda_v1`.
- **Email `mejores-picks-diario` v4**: recalibra en vivo las probs de tenis **ATP** (shrink con k guardado; WTA intacto), con fallback a prob cruda si falla, y nota honesta en el pie. Probado: send 200.

## Pendiente (siguiente iteración honesta)
- NBA tramo medio (60-69%) sobreconfiado: repetir el mismo proceso OOS cuando haya más muestra NBA.
- Generalizar esto a un job semanal que mida calibración por deporte y aplique SOLO los ajustes que pasen OOS (auto-aprendizaje con compuerta de integridad).
- Modelo de fútbol P0: bien calibrado pero no le gana al mercado — mayor espacio de mejora de edge.
