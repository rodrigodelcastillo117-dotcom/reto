# ISS-022 — Migración cero-contaminación (P0) + marcador desde una sola distribución (P0)

> Rige por encima de ISS-021. Principio: **"Quiero la experiencia vieja; NO quiero el cerebro viejo."**
> El remix `reto13` es **CUARENTENA / DONANTE**, no "la app limpia" por tener id nuevo.
> PORTAR: UI + UX + workflows + ciclo de vida + comportamiento por estado.
> BLOQUEAR: toda fuente de datos predictiva y toda lógica de decisión predictiva legacy.

---

## P0-A — Regla de migración cero-contaminación

### Procedimiento por componente (NO copiar directorio y limpiar después)
Para cada componente migrado: (1) identificar presentación/UI; (2) identificar workflow/estado; (3) identificar dependencias de backend; (4) identificar dependencias PREDICTIVAS; (5) portar UI/workflow; (6) reemplazar dependencias predictivas por contratos V2; (7) recién entonces marcar limpio.
El remix, antes de ser "la app": desconectar/bloquear todos los adaptadores predictivos legacy → fail-closed → reemplazar uno por uno por V2 → correr las compuertas.

### Denylist predictiva — descubierta transitivamente en el donante `reto13`
(no exhaustiva; el gate la vuelve a descubrir en cada build)

**Vistas/RPC predictivas legacy (conteo de referencias en donante):**
`v_pick_canonico` (14) · `predecir_mlb` (10) · `analizar-partido` (10, como autoridad) · `analisis_completo` (8) · `v_prediccion_reto_futbol` (6) · `v_picks_futbol_*` (6) · `v_radar_mlb` (5) · `v_motor_valor_proximos` (5) · `v_poisson_*` (3) · `v_mejores_picks_mlb` (3) · `evaluar_parlay` (2) · `v_super_pick` (1) · `v_picks_mlb_modelo` (1) · `v_analisis_fut_completo` (1) · `calcular_1x2_futbol`.

**Cerebro cliente (módulos JS a NO portar como autoridad):**
`utils/coreModel.ts` · `utils/safetyEngine.ts` · `utils/adaptiveEngine.ts` · `utils/marketUpgrader.ts` · `lib/soccerCanonical.ts` · `lib/oraculoCanonico.ts` · `lib/eligibilityGate.ts` · `lib/oraculoPresentation.ts` · `lib/sports-adapter.ts` · `hooks/useMatrizReto.ts` · `hooks/use-mlb-prediccion.ts` · `hooks/useAutoGrader.ts` · `utils/metaBuilders.ts`.

**Saturación cliente (medida):** `ev_` ×245 · `kelly` ×160 · `Kelly` ×48 · `lambda` ×134 (cálculo de P en el navegador). Todo esto es cerebro, no carrocería.

**Archivos con lectura predictiva directa (ledger de migración):**
`components/MotorValueSection` · `SharePostal` · `fut/MatchCard` · `fut/PicksFutbolLimpio` · `mlb/MejoresPicksMlb` · `mlb/PronosticoMlbModelo` · `partido/AnalisisCompletoModal` · `reto/MejorPickHoy` · `reto/OraculoRecomendados` · `reto/PickDelDiaCard` · `reto/PicksProbabilidadFavoritos` · `shared/LiveWarRoom` · `pages/Fut` · `pages/MLB`.
Para cada uno: portar el modal/acordeones/estilos/tablas/logos; **arrancar** la conexión a la vista/RPC legacy; **reconectar** al contrato V2 (dossier limpio).

### Allowlist V2 (únicas fuentes predictivas)
`v_futpro_v2` · `v_analisis_v2` · `v_mlb_v2` · `v_nfl_v2` · `v_canonical_event/prediction/analysis` · `v2.team_logo` · `v2.competition_catalog` · `v2.soccer_prediction_snapshot`.
Todo lo mostrado como P_RETO / marcador predicho / 1X2 / BTTS / totales / selección recomendada / conclusiones de análisis DEBE trazar a un contrato V2. Sin fallback legacy. Si V2 no tiene respuesta → **fail-closed** (no disponible).

### Compuertas (CI sobre el frontend NUEVO) — `docs/frontend_v2/contamination-gate.mjs`
`LEGACY_PREDICTIVE_IMPORTS=0` · `LEGACY_PREDICTIVE_RPC_CALLS=0` · `LEGACY_PREDICTIVE_VIEW_READS=0` · `CLIENT_SIDE_P_CALCULATORS=0` · `EV_DRIVEN_PRIMARY_SELECTIONS=0` · `MARKET_AS_P_RETO_PATHS=0` · `LEGACY_SCORE_FALLBACK_PATHS=0` · `P_RETO_WITHOUT_V2_PROVENANCE=0` · `UNKNOWN_PREDICTIVE_DEPENDENCIES=0`.
Un componente no se considera migrado hasta que su grafo de dependencia predictiva pasa estas compuertas. El script corre `node docs/frontend_v2/contamination-gate.mjs ./src` en el repo del frontend nuevo (se copia ahí).

### Se CONSERVA (carrocería — es workflow, no autoridad predictiva)
HOME · bottom nav (overlays, safe-area iPhone, ocultar con teclado, menú, fixes Safari/iOS) · `GlobalFAB` (+: Escanear / Manual / Calificar / refrescar picks-parlays-bankroll) · scan · picks/parlays manuales · Calificar · ciclo próximos/vivo/final/calificado · bankroll + gráfica · stats · Cómo Voy · favoritos · share · push · historial · reto · avisos de riesgo/exposición · menús/sheets/dialogs · responsive/móvil/iOS · todo UX legítimo dependiente de estado.

---

## P0-B — El marcador debe ser predicción real de la MISMA distribución

### Hallazgo (causa raíz, verificado en `wpiztubmmmzclhlprgpd`)
- `v2.soccer_prediction_snapshot.modal_score` = `analisis_json->>'score_probable'`: **un string suelto**, no derivado de ninguna distribución al construir el snapshot.
- `analisis_json.probabilidades` contiene SOLO `home_win, draw, away_win` (marginales 1X2) + flags. **NO existe λ, NI matriz P(i,j), NI distribución conjunta** en ningún lado.
- `score_probable` = **"1-1" en los 3 análisis más recientes** → patrón artificial de 1-1 confirmado (`DEFAULT_SCORE_1_1_PATHS > 0`).

Conclusión: P0-B es un cambio de **MOTOR (cerebro)**, no de vista. Hay que producir y persistir una distribución conjunta de goles y derivar TODO de ella.

### Diseño objetivo (generador único)
1. En el generador de análisis de fútbol (trigger Dixon-Coles, ver ISS-195/196): calcular y **persistir** `lambda_home`, `lambda_away` y `tau` (corrección DC de marcadores bajos), solo cuando haya datos válidos y temporalmente seguros (fuerza of/def, rival, liga, localía, GF/GC, xG/xGA, tiros, forma, H2H con valor, alineaciones/lesiones, descanso/viaje, venue, clima, referee, ratings, calibración validada). "Usar todo" = solo variables validadas out-of-sample alteran la distribución.
2. Construir `P(i,j)` (i,j = 0..N goles) desde λ + τ. De la MISMA matriz:
   - `P_HOME=Σ_{i>j}`, `P_DRAW=Σ_{i=j}`, `P_AWAY=Σ_{i<j}`
   - `P_BTTS_YES=Σ_{i>0,j>0}`
   - `P_OVER(line)=Σ_{i+j>line}` para la línea REAL disponible
   - `PREDICTED_SCORE = argmax P(i,j)` + `PREDICTED_SCORE_PROB`
3. Persistir por partido para auditoría: `lambda_home, lambda_away, tau, top10 scorelines + prob, predicted_score, predicted_score_prob, 1X2, BTTS, O/U, P_RETO, model_version, data_asof, sample/reliability, provenance`.
4. Reemplazar `modal_score` (string) por `predicted_score` + `predicted_score_prob` en `soccer_prediction_snapshot` y `v_futpro_v2`/`v_analisis_v2`. Si no hay λ confiable → `predicted_score = NULL` y UI muestra **"MARCADOR NO DISPONIBLE"** (nunca fabricar 1-1).

### Coherencia (no forzar, no templates)
El 64% de victoria se reparte entre 1-0,2-0,2-1,3-1,… así que `P(2-1)` puede ser ~12% y ser el argmax: es correcto y NO debe igualar al 64%. Prohibido `favorito+BTTS+Over⇒2-1`. 1-1 es válido solo si `P(1-1) > P(otros)` desde la matriz real.

### Compuertas P0-B
`DEFAULT_SCORE_1_1_PATHS=0` · `HARDCODED_SCORE_PATHS=0` · `SCORE_DISTRIBUTION_MISMATCHES=0` · `SCORE_VS_1X2_MISMATCHES=0` · `SCORE_VS_BTTS_MISMATCHES=0` · `SCORE_VS_TOTAL_MISMATCHES=0`.

### UX objetivo (tarjeta / análisis)
```
RETO PREDICE
  América gana — 64%
Marcador más probable
  América 2–1 Tigres      (prob. exacta del marcador: 11.8%)
BTTS Sí 60%   ·   Over 2.5 58%
```
Sin "un escenario compatible". Si no hay modelo confiable: "MARCADOR NO DISPONIBLE".

---

## Orden de ejecución (revisado bajo P0)
1. **[hecho]** Denylist grounded + gate CI (`contamination-gate.mjs`) + este ISS.
2. **Motor P0-B:** persistir λ_home/λ_away/τ en el generador DC; construir P(i,j); derivar 1X2/BTTS/O-U/predicted_score de ella; exponer en snapshot + `v_futpro_v2`; fail-closed. Auditar y eliminar el 1-1 por defecto.
3. **Motor deportes:** `v_mlb_v2`, `v_nfl_v2`, canónicos cross-sport (molde fail-closed).
4. **Carrocería (cuarentena→limpio):** en el remix, neutralizar adaptadores predictivos (fail-closed), luego migrar componente por componente a V2, corriendo el gate hasta 0.
5. **Navegación** un-deporte-una-pestaña (ISS-021 §2) una vez las superficies leen V2.
