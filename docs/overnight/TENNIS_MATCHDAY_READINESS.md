# TENNIS — READINESS

**Semáforo: 🔴 RED — no debe utilizarse. No hay pipeline de calendario.**

---

## 1. Hallazgo determinante

`agenda_espn` **no contiene ni un solo evento de tenis**, ni para mañana ni históricamente.

```
Deportes en agenda_espn (histórico completo):
  football  272 eventos  (último 2027-01-10)
  soccer    260 eventos  (último 2026-11-14)
  baseball  123 eventos  (último 2026-09-17)
  tennis      0 eventos
```

Sin calendario no hay eventos, sin eventos no hay odds asociadas, ni modelo, ni análisis, ni dossier. **La cadena está cortada en el primer eslabón.**

## 2. Lo que sí existe

Hay scaffolding de tenis, orientado a **marcador en vivo**, no a predicción:

- Tablas: `_carga_tenis`, `stake_tennis_torneos`, `tenis_linescore`, `tenis_ls_carga`
- Funciones: `absorber_tenis_espn`, `pedir_tenis_espn`, `tenis_ls_pedir`, `tenis_ls_recoger`, `evaluar_juegos_tenis_v1`, `sets_coherentes_tenis`, `tenis_juegos_totales`, `guardar_tenis_coherente`, `preserve_tennis_score_details`, `revisar_tenis_atascado`, `vigilar_refresco_tenis`, `vigilar_sets_tenis`

Es un subsistema de ingesta y coherencia de linescore (sets/juegos), útil para seguir un partido en curso y para calificar apuestas ya emitidas. **No es un motor de predicción.**

## 3. Auditoría de features — no aplicable todavía

La auditoría solicitada (surface, ranking, serve/return stats, hold %, break %, H2H, fatiga, viajes…) **no puede ejecutarse**: sin tabla de partidos programados ni de jugadores no hay sobre qué evaluar `AVAILABLE / TEMPORALLY_SAFE / COVERAGE / HISTORICAL_EVIDENCE`. Marcar cualquiera de esas casillas sería inventar.

## 4. Estado declarado

```
TENNIS_MODEL_SKILL       = INSUFFICIENT (no existe modelo)
TENNIS_ECONOMIC_AUTHORITY= FALSE
TENNIS_STAKE             = 0
TENNIS_SCHEDULE_PIPELINE = MISSING  ← blocker raíz
```

## 5. Acción recomendada

**BLOCKER:** construir el pipeline de calendario de tenis (ingesta de torneos/cuadros/partidos programados a `agenda_espn` o equivalente). Es trabajo de ingeniería de datos con fuente externa, no ejecutable de forma segura esta noche ni improvisable.

Hasta entonces: **no mostrar tenis como superficie de análisis o pick.** Si la UI hoy muestra algo de tenis, procede de otra fuente y debe auditarse antes de mañana.
