# Fantasy NFL: datos frescos (depth charts) + señal de decisión (sorpresas vs ADP)

Fecha: 2026-10-20. Continuación del diagnóstico: como el MODELO ya está validado y
las mejoras de la matemática fueron probadas y rechazadas, las palancas reales son
datos frescos y mejores decisiones. El usuario pidió ambas. Nada de dinero (OFF).

## #1 Depth charts frescos (antes: 1 carga del 31-ago, 7 semanas viejos)
- Edge function `sync-nfl-depth-chart`: por cada uno de los 32 equipos baja el depth
  chart de la **core API de ESPN** (`.../seasons/2026/teams/{id}/depthcharts`) +
  el roster (para nombres id→nombre), parsea QB/RB/WR/TE (grupo ofensivo) y K
  (special teams), con orden denso por posición (cap QB2/RB3/WR4/TE2/K1), y hace
  reemplazo atómico por equipo en `public.nfl_depth_chart` (fuente `espn_core_<fecha>`,
  `verificado=false` — honesto: es automático, no verificado a mano).
- Primera corrida: 32 equipos, 383 filas, 0 errores, 0 nombres sin resolver.
  **15 equipos tenían un titular (#1) distinto** a la preseason (p.ej. KC con Kenneth
  Walker III RB1; DET sin Pacheco). Respaldo de la data previa en
  `public._bk_nfl_depth_chart_20261020`.
- Crons: `nfl-depth-chart-jue` (jue 13:11 UTC) y `nfl-depth-chart-sab` (sáb 16:11 UTC).
- Nota: el depth chart NO alimenta el número de proyección (eso usa historial); mejora
  roles/waivers/"titular vs suplente". Los lectores no filtran `verificado`, así que
  la data fresca se usa de inmediato. `fantasy_limitaciones` ahora reporta la fecha
  fresca automáticamente (lee `max(cargado_at)`).

## #2 Señal de decisión: "Sorpresas de la temporada vs ADP"
- `public.v_reto_fantasy_sorpresas_v1`: por jugador con ≥3 juegos calificados de 2026,
  compara su rendimiento real (ppg con reglas de la liga, de `v_lab_ff_official_snapshot`)
  contra su draft de consenso (`nfl_adp.adp`). `salto` = rk_adp − rk_perf (positivo =
  rinde mejor que su draft). Etiquetas JOYA/Sube/DECEPCION/Baja/En línea. Equipo tomado
  del catálogo (`nfl_jugadores`) para no mostrar equipos raros; null si no hay.
- 192 jugadores, 73 sorpresas fuertes. Ejemplos reales: JOYAS Keon Coleman (10.9 ppg,
  ADP 172), Matthew Golden (16.5, ADP 101), Tre Tucker (13.1, ADP 132); DECEPCIONES
  Saquon Barkley (4.7 ppg, ADP 16), Marvin Harrison Jr., Ladd McConkey.
- Frontend: sección "Sorpresas de la temporada" (Joyas = waiver/start; Decepciones =
  reconsiderar), debajo de "¿Qué tan preciso es el modelo?". Framing honesto: es
  rendimiento de temporada, no predicción de la semana.

## Por qué NO el "decisiones personales" todavía
El reporte personal (start/sit) ya trae todo (cambios, razones de matchup, byes,
`ganancia_si_cambias`, `consejo_fiable`). Pero su valor fiable depende de que la
captura del usuario traiga los números del sitio; hoy el único roster marca
`consejo_fiable=false` honestamente. La palanca ahí es de producto (capturar el roster
con proyecciones), no de modelo. Las sorpresas vs ADP sirven a TODOS desde ya.
