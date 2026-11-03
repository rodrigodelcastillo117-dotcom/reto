# Auditoría 360 de honestidad: hallazgos + fixes

Fecha: 2026-11-03. Barrido (solo lectura) de todas las vistas/RPC con grant SELECT a
anon/authenticated (lo que la app puede leer), buscando los 7 "pecados" de honestidad.
Confirmó limpias las correcciones previas (totales informativos, sin etiquetas
invertidas, fútbol fuente única v3, ledger limpio, sin EV/Kelly en tarjeta/editorial,
sin datos hardcodeados). Encontró 3 cosas; 2 arregladas aquí, 1 para decisión del dueño.

## ARREGLADO

### ALTA #1 — acierto histórico "prestado" entre deportes (ENGAÑOSO, arreglado)
`v_reto_mejores_picks_v1.acierto_historico_pct`: el CTE `tramo_hist` calculaba el acierto
por tramo de confianza pegando el MISMO número a todos los deportes. Como
`v_reto_pick_grade_v1` solo tiene calificados de soccer/tenis/NFL, los picks de **NBA (38)
y NHL (33)** mostraban "acierto histórico" (hasta 79.4%) **sin un solo partido de ese
deporte detrás** — el trío 59.6/.../79.4 idéntico en los 5 deportes.
Fix: `tramo_hist` ahora agrupa por (deporte, tramo). Cada deporte muestra SU propio
acierto por tramo; si no tiene historial calificado (NBA/NHL hoy) muestra NULL (honesto).
Verificado: NBA/NHL → NULL; Soccer ALTA 82.6% / CONFIABLE 61.7% / FAVORABLE 61.3%;
Tenis 80.0/54.8/49.0; NFL 66.7/33.3/63.6 (reales, por deporte).

### MEDIA #3 — mercado O/U retirado dentro del track record de fútbol (arreglado)
`v_reto_track_record_v1` agrupaba `evidencia_modelo_forward` por deporte mezclando el
mercado **Over/Under (retirado)**: soccer tenía 864 Moneyline + 15 O/U retirado.
Fix: `WHERE mercado <> 'Over/Under'`. Soccer ahora = 864 Moneyline puro (53.1%),
football 122 (60.7%). (Impacto numérico chico, pero un mercado retirado ya no contamina
una cifra mostrada.)

## PARA DECISIÓN DEL DUEÑO (NO tocado)

### ALTA #2 — récord legacy con DINERO y mercados retirados (`track_record_*`)
La familia `track_record_global` / `track_record_combinado_por_mercado` / `track_record_real`
(todas con grant anon, y listadas como superficie que lee el front en
`docs/BACKEND_SURFACE_USADA.md`) expone **dinero**: `track_record_global.ganancia_total =
+349,627.73`, win_rate 26% al lado; `track_record_combinado_por_mercado` muestra ganancia/
ROI por mercado e **incluye mercados retirados** (Fútbol/Totales O/U +2035.74, Baseball
O/U y ML); `track_record_real` expone apuesta/ganancia/ROI (dinero real de usuarios:
43 picks, 3 apodos, -4,552.61). Fuentes: tablas `picks`+`parlays` (última `created_at`
2026-09-19, obsoleta) y `oraculo_picks_tracking`.

Por qué NO lo toqué: contradice en apariencia "dinero OFF en todo", PERO podría ser una
función legítima de **bitácora personal de apuestas del usuario** (la app tiene bankroll,
parlays, stake, canasta). Distinguir "récord del motor" (debe ir sin dinero y sin mercados
retirados) de "mis apuestas personales" (dinero del usuario, legítimo) es decisión de
producto/dueño. Rehacer o revocar estas vistas podría romper una función real del front.
Recomendación: el dueño decide si (a) es bitácora personal → se deja, o (b) es récord del
motor → se limpia (quitar dinero/ROI y mercados retirados, o separarlo del récord honesto).

## OBSERVACIÓN (sin acción)
- BAJA #4: prob Elo de tenis corre ~5-8pp sobre el acierto realizado (n=98/134), pero
  dentro del IC95 y la vista ya declara OOS/Brier. En observación.
- BAJA #5: líneas/porcentajes informativos (MLB 8.5, over/under) bien etiquetados
  ("NO línea de casa", informativo, pick_prob_pct NULL). Aceptable.
