# CHAMPIONS / SOCCER — MATCHDAY READINESS

**Semáforo: 🔴 RED para presentar UCL como análisis del modelo · 🟡 YELLOW como información de mercado**

Evidencia recogida read-only contra producción (`BEGIN READ ONLY` con `transaction_read_only=on` verificado en cada consulta). No se ejecutó DDL/DML.

---

## 1. Hallazgo principal

Los 18 partidos de UEFA Champions League de las próximas 72 h **tienen odds pero ninguno llega a la vista canónica de picks**.

| Métrica | Valor |
|---|---|
| Eventos UCL en `agenda_espn` (72 h) | **18** |
| De ellos con odds en `odds_espn` | **18** (100 %) |
| De ellos presentes en `v_pick_canonico` | **0** |
| De ellos cubiertos por `v_picks_futbol_calibrado` | **0** |
| Filas UCL en `v_pick_canonico` | **0** |

Es decir: **hay precio pero no hay probabilidad de modelo**. Cualquier porcentaje que la UI muestre mañana para un partido de Champions **no puede provenir del motor canónico**, porque el motor no produce ninguna fila para esos eventos.

## 2. Qué cubre realmente el motor de fútbol

`v_pick_canonico` tiene 275 filas totales (todos eventos futuros, ventana 2026-09-08 → 2026-09-12):

| Deporte | Liga | Filas |
|---|---|---|
| baseball | MLB | 140 |
| soccer | MLS | 112 |
| soccer | Liga MX | 10 |
| soccer | CONMEBOL Libertadores | 8 |
| soccer | La Liga | 2 |
| soccer | Danish Superliga / Jupiler / Ligue 1 | 1 c/u |

Cobertura del motor sobre la agenda de 72 h, por liga:

| Liga | En agenda | En motor |
|---|---|---|
| **UEFA Champions League** | **18** | **0** |
| MLS | 14 | 14 |
| Saudi Pro League | 7 | 0 |
| EFL Cup | 6 | 0 |
| Copa Libertadores | 4 | 1 |
| Copa Sudamericana | 4 | 0 |
| Eredivisie | 3 | 0 |
| Liga Portugal | 2 | 0 |
| Scottish Premiership | 2 | 0 |
| Liga MX | 1 | 1 |
| Super League Greece | 1 | 0 |

El motor de fútbol es, operativamente, **un motor de MLS + Liga MX**.

## 3. Evidencia de skill — `liga_competencia_modelo`

Registro autoritativo de comparación por liga (Brier; menor es mejor; naive 3-vías = 0.6667):

| Veredicto | Ligas | Partidos |
|---|---|---|
| `sin_datos` | 45 | 704 |
| `callarse` | 6 | 637 |
| `usar_modelo` | 5 | 189 |
| `usar_mercado` | 3 | 149 |
| **Total** | **59** | **1679** |

Ligas donde el modelo bate **a naive y a mercado** simultáneamente — las únicas tres:

| Liga | n | Brier modelo | Brier mercado | Brier naive |
|---|---|---|---|---|
| Eredivisie | 34 | 0.6458 | 0.6733 | 0.6667 |
| Leagues Cup | 50 | 0.5812 | 0.5867 | 0.6667 |
| Saudi Pro League | 8 | 0.4882 | 0.4992 | 0.6667 |

**MLS —el 41 % de las filas canónicas— tiene veredicto `callarse`:** Brier modelo 0.6834 vs mercado 0.6791 vs naive 0.6667. El modelo es **peor que no saber nada** en la liga que más presenta.

**UEFA Champions League no está registrada en absoluto** (las coincidencias por nombre son "Trophee des Champions" n=1 y "EFL Championship", competiciones distintas).

Con n=8, n=34 y n=50, ninguna de las tres ligas "ganadoras" alcanza tamaño muestral para autorización económica. **Esto respalda mantener `CURRENT_AUTHORIZED_MODELS = NONE`** — no es una postura conservadora arbitraria, es lo que dice la evidencia del propio sistema.

## 4. Matriz por partido — UCL 72 h

Aplica idéntica a los 18 eventos (no hay variación entre ellos):

| Check | Resultado |
|---|---|
| `EVENT_FOUND` | ✅ 18/18 |
| `EVENT_TIME_VALID` | ✅ (ventana 2026-09-08 12:00Z → 2026-09-11 03:00Z) |
| `ODDS_AVAILABLE` | ✅ 18/18 |
| `ODDS_FRESH` | ✅ snapshot más reciente 2026-09-08 04:21Z |
| `MODEL_AVAILABLE` | ❌ **0/18** |
| `DATA_READY` | ❌ sin fila de modelo |
| `P_PROVENANCE` | ❌ **no existe P de modelo para UCL** |
| `EV_AVAILABLE` | ❌ (requiere P de modelo) |
| `ECONOMIC_ELIGIBILITY` | ❌ FALSE (fail-closed correcto) |
| `ANALYSIS_AVAILABLE` | ⚠️ solo mercado |
| `DOSSIER_AVAILABLE` | ⚠️ sin sección de modelo |

## 5. Champion cuantitativo

Se respeta el congelado: `team_strength = ON`, `venue_split = OFF`, `xG = OFF`, `H2H = OFF`. **No se activó ninguna feature.** No existe evidencia nueva independiente y fuera de muestra que lo justifique; activar xG/venue/H2H para "cubrir" Champions sería exactamente el patrón prohibido.

## 6. Qué se puede y qué no se puede usar mañana

**Se puede:** mostrar los 18 partidos de UCL como **información de mercado** — odds, probabilidad implícita **etiquetada como de la casa**, hora, equipos.

**No se puede:** presentar ningún porcentaje de UCL como predicción del modelo, ni como MOST_LIKELY, VALUE PICK o TOP PICK. No hay P de modelo que lo respalde.

## 7. Acción recomendada

1. **Verificar en la UI** (fuera de este repo) que ningún partido de Champions muestre un porcentaje sin etiqueta `MARKET_INFORMATION_ONLY`. Es el riesgo #1 de mañana.
2. Decidir producto: mostrar UCL como mercado puro, o no mostrar UCL en superficies de pick.
3. A medio plazo: la cobertura del motor (MLS + Liga MX) es la limitación estructural real. Ampliarla exige datos y validación fuera de muestra, no un cambio de gate.

**BLOCKER:** ampliar cobertura de modelo a UCL requiere datos históricos + validación; no es ejecutable esta noche y no debe improvisarse.
