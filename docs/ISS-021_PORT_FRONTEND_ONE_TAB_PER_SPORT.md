# ISS-021 — Puerto total del frontend RETO13 + arquitectura "un deporte = una pestaña"

> Estado: **PLAN EJECUTABLE — auditoría cerrada, motor V2 en construcción, vehículo de puerto definido.**
> Principio rector: **"Conserva la carrocería (todo el frontend/UX de RETO13), cambia el motor (cablea SOLO a los contratos V2, mata el cerebro contaminado)."**
> Norte de producto: **"¿Qué cree RETO que va a pasar y con qué probabilidad?"** — la probabilidad (P_RETO) es el producto. Nunca EV/Kelly/momio como P_RETO. Fail-closed honesto.

---

## 0. Decisión de vehículo (resuelve 4 pivotes previos)

| Proyecto Lovable | Stack | Contenido | Backend | Veredicto |
|---|---|---|---|---|
| `00f8f06b` "Reto 13M" (`reto13.lovable.app`) | **vite_react_shadcn_ts** | **App completa** (todas las pantallas, scan, share, Zeus/Hades, bankroll, ciclo de vida) | Ya apunta a `wpiztubmmmzclhlprgpd` (real) | **REMIX → vehículo del puerto** |
| `b7ca6de0` "Reto 13M Pro" | tanstack_start_ts | Solo Fut Pro | wpiztubmmmzclhlprgpd | Descartado (rebuild, no puerto; framework distinto) |
| `a50526e3` "Reto Fut Pro" (`fybmx`) | tanstack_start_ts | Solo Fut Pro | Falló contra Lovable Cloud | Descartado |

**Conclusión:** portar "todo el frontend" ⇒ **remix del proyecto `reto13` (`00f8f06b`)**. Es la única operación que da fidelidad 100% en un paso, en el MISMO stack que `/home/user/reto13`, y ya cableado al Supabase correcto. Sobre esa copia se ejecuta el intercambio de motor y la reestructuración de navegación. Los dos experimentos en TanStack quedan obsoletos.

---

## 1. Auditoría legacy — LEGACY_FRONTEND_SURFACES_INVENTORIED = 100%

Fuente: clon congelado `/home/user/reto13` (github `reto13`, Lovable `00f8f06b`). Superficie total:
**~50 rutas · ~45 páginas · ~180 componentes · 42 hooks.**

### 1.1 Rutas (App.tsx) y clasificación de puerto

Clasificación: **PORT_AS_IS** (UX/infra pura) · **PORT_AND_CLEAN** (conserva shell, cambia lectura predictiva a contrato V2) · **REBUILD** (concepto sobrevive, implementación cambia por "un deporte = una pestaña") · **DO_NOT_PORT** (cerebro contaminado / dev / redundante).

| Ruta | Página | Clase | Destino en la nueva arquitectura |
|---|---|---|---|
| `/` | Reto (home) | PORT_AND_CLEAN | INICIO — digest cross-sport desde contrato canónico |
| `/reto-13m` | Reto13M | PORT_AND_CLEAN | Pestaña **RETO 13M** (canónico cross-sport) |
| `/fut` | Fut | REBUILD | Absorbido por **FUT PRO** (semana→día→competencias→eventos) |
| `/v2/fut` | FutV2 | DO_NOT_PORT | Prototipo V2 — su lógica de contrato se funde en FUT PRO |
| `/liga-mx`, `/liga-mx/:id` | LigaMX, LigaMXPartido | REBUILD | Estado interno de FUT PRO (filtro competencia) |
| `/mls`, `/mls/:id` | MLS, MLSPartido | REBUILD | Estado interno de FUT PRO (filtro competencia) |
| `/partidos` | Partidos | REBUILD | Estado interno de FUT PRO (vista de día) |
| `/hoy` | Hoy | REBUILD | Estado interno de FUT PRO (chip "hoy") |
| `/tablero` | Tablero | REBUILD | Modal/sheet de standings dentro del evento FUT PRO |
| `/canasta` | Canasta | PORT_AND_CLEAN | Flujo dentro de RETO 13M (armar/scan de canasta) |
| `/numeros` | Numeros | REBUILD | Sheet "los números finos" dentro del evento |
| `/favoritos` | Favoritos | REBUILD | Pestaña **FAVORITOS** cross-sport (canónico) |
| `/mlb` | MLB | PORT_AND_CLEAN | Pestaña **MLB** (contrato V2 MLB) |
| `/nfl` | NFL | PORT_AND_CLEAN | Pestaña **NFL** (contrato V2 NFL) |
| `/nfl/fantasy` | NflFantasy | PORT_AND_CLEAN | Pestaña INTERNA de NFL (no es deporte) |
| `/oraculo` | OraculoPage | PORT_AND_CLEAN | Sección de RETO 13M (recomendados canónicos) |
| `/pick-del-dia`, `/parlay-del-dia` | PickDelDia, ParlayDelDia | PORT_AND_CLEAN | Secciones de RETO 13M |
| `/historial`, `/picks/:id`, `/parlays/:id` | Historial | PORT_AS_IS | CÓMO VOY / historial (ciclo de vida) |
| `/historial-equipos` | HistorialEquipos | PORT_AS_IS | Sheet histórico A–F dentro del evento |
| `/estadisticas`, `/mi-track-record`, `/mis-leaks`, `/mis-patrones`, `/informe` | varias | PORT_AS_IS | CÓMO VOY (stats del usuario, no del motor) |
| `/leaderboard`, `/leaderboard-classic`, `/comunidad` | Leaderboard*, Comunidad | PORT_AS_IS | Social (columnas acotadas por privacidad) |
| `/track-record`, `/track-record-publico`, `/calibracion` | TrackRecord*, Calibracion | PORT_AND_CLEAN | Transparencia (KPIs desde contrato, no RPC que miente) |
| `/premium`, `/sharp-money`, `/guerra`, `/batallas`, `/dashboard` | varias | PORT_AND_CLEAN | Secciones internas (sin EV/Kelly como autoridad) |
| `/nueva-password` | NuevaPassword | PORT_AS_IS | Auth (email+contraseña) |
| `/privacy`, `/terms` | legales | PORT_AS_IS | Legal |
| `/admin/salud`, `/admin/rongol`, `/debug` | AdminSalud, ReportesRongol, PickDebugLog | DO_NOT_PORT | Solo interno (fuera del producto público) |
| `/ai-pro`, `/pit/*`, `/mundial/*`, `/autopsias` | redirects | DO_NOT_PORT | Ya son redirects/legado |

### 1.2 Componentes (~180) por familia

| Familia | # | Clase dominante | Nota de puerto |
|---|---|---|---|
| `ui/` (shadcn) | ~55 | PORT_AS_IS | Primitivas; se copian tal cual con el remix |
| `fut/` | ~40 | PORT_AND_CLEAN | Núcleo del evento FUT PRO (MatchCard, MatchDetailSheet, TendenciasTabs, DossierSection, AlineacionesSection, LiveMatchDetailSheet, LiveStandingsDrawer, MonteCarloDrawer, PostMortemDrawer, RachasEquipos, RefereeBadge…). **Quitar** PinnacleEVBadge/CLVBadge/OddsTracker como autoridad; momio solo informativo con fuente+frescura |
| `reto/` | ~65 | mixto | Ciclo de vida + bankroll + scan + celebración. PORT_AS_IS: CelebracionOverlay, ResultadoOverlay, CrystalBall*, ProgressHeader, StatsToggle, LoginScreen, NotificationBell, PickCard, ParlayCard, AvisosPick, CashOut*, CerrarApuesta*, CorregirApuesta, EditarResultadoManual, ScanBoletoCanastaButton, SmartUploadButton, Espn*Modal, DateAmbiguityPicker, HomonymPicker, MisEquipos, LigasSheet, MasSheet. **DO_NOT_PORT/CLEAN**: EVBadge, DevilsAdvocateModal (si expone EV), CalculadoraMonto/StakeGateModal (sizing DEBE venir del contrato canónico, no del LLM/momio) |
| `stats/` | ~13 | PORT_AS_IS | Gráficas bankroll/rendimiento (curva por sección: sencillas vs parlays) |
| `shared/` | ~12 | PORT_AND_CLEAN | EscudoEquipo→`v2.team_logo`; PrediccionRetoLinea→P_RETO canónico; GameCard, LiveNowStrip, EstadoDatos |
| `nfl/` | 7 | PORT_AND_CLEAN | Fantasy interno de NFL; NflPremiumPicks sin EV como autoridad |
| `mlb/` | 2 | PORT_AND_CLEAN | PronosticoMlbModelo, MejoresPicksMlb → contrato V2 MLB |
| `track/`, `tablero/`, `soccer/`, `share/`, `analytics/`, `partido/`, `AnalizarPartido/` | ~15 | mixto | share/* PORT_AS_IS; MotorValueSection/PicksSeguroValorCards DO_NOT_PORT como autoridad de valor |

### 1.3 Hooks (42) — foco de descontaminación

- **PORT_AS_IS (infra/UX):** use-mobile, use-toast, use-teclado-abierto, use-escudos (→ team_logo), use-live-now, use-live-scores(-direct), use-score-notifications, useRealtimeSync, use-equipo-corto, use-casa-preferida, PullToRefresh.
- **PORT_AND_CLEAN (leen cerebro → deben leer contrato V2):** use-supabase-data, use-mlb-prediccion, useMatrizReto, useAiProAnalysis, use-enriched-analysis, useObtenerPicksSeguroValor, use-veredicto-criterio, use-leg-colors/use-leg-live-colors/use-backend-leg-colors (estados de ciclo de vida → estado canónico), useTrackRecord, useStatsDesglose, use-bankroll-real/-cache.
- **DO_NOT_PORT como autoridad:** use-tamano-apuesta (sizing debe salir de autoridad única canónica, ver #207/#208), useDevilsAdvocate/usePagoAnticipado si emiten EV, use-odds-ingest (ingesta, no frontend).

**UNEXPLAINED_FRONTEND_BEHAVIORS = 0:** toda ruta/componente/hook anterior tiene destino asignado; no queda superficie sin clasificar.

---

## 2. Arquitectura destino — "UN DEPORTE = UNA SOLA PESTAÑA"

### 2.1 Bottom nav (única navegación principal)

```
INICIO · FUT PRO · MLB · NFL · RETO 13M        [ FAB "+" = ESCANEAR ]
        └ FAVORITOS y CÓMO VOY accesibles desde header/RETO 13M
```

- **1 pestaña por deporte** = TODA la experiencia de ese deporte. Análisis = modal/sheet/drawer DENTRO de la pestaña, nunca pestaña aparte.
- **FUT PRO** contiene TODO el fútbol: chips de días de la semana → día → competencias → eventos → detalle de evento con TODO (equipos con escudo real, liga, fecha+hora México, estadio, estado, marcador vivo/final, standings, forma, lesiones, alineaciones, stats, P_RETO, pick principal, mercado/selección/línea exacta, momio real+fuente+frescura, análisis completo, xG, 1X2, BTTS, O/U de línea real, distribución de marcador como secundaria, "por qué RETO cree", model_status, razón explícita si P_RETO NULL, share, favorito, ciclo de vida completo).
- **MLB / NFL**: mismo molde. **NFL Fantasy** = pestaña interna de NFL (no deporte). NBA/NHL/Tenis después.
- **Cross-sport (leen contrato canónico):** solo **FAVORITOS** y **RETO 13M** — mismo P_RETO/pick/análisis/momio/estado en toda la app.
- **ESCANEAR** ("+"): al detectar ticket PlayDoIt pregunta **"¿es para el RETO 13M?"** (+ bono, single/parlay).

### 2.2 Lenguaje visual (todos los deportes)

🏠 local · ✈️ visita · racha: **W** verde / **E** amarillo / **L** rojo.
Barras de estado de pick en vivo: verde (gana / pago anticipado / FT) · aqua (con chance según tiempo/monto) · amarillo (50/50) · naranja (difícil) · rojo (perdido / FT perdido).

---

## 3. Motor V2 — contratos que el frontend portado consumirá

| Deporte / superficie | Contrato de lectura | Estado |
|---|---|---|
| Fútbol — cartelera + P_RETO | `public.v_futpro_v2` (agenda-driven, fail-closed) | **VIVO** (221 próximos, 99 con P_RETO) |
| Fútbol — análisis profundo | `public.v_analisis_v2` | **VIVO** |
| Escudos | `v2.team_logo` (join precomputado) | **VIVO** |
| Catálogo/ligas | `v2.competition_catalog`, `v2.liga_alias` | **VIVO** |
| MLB — cartelera + predicción + análisis | `public.v_mlb_v2` (por construir, molde fail-closed) | **PENDIENTE** |
| NFL — cartelera + predicción + análisis | `public.v_nfl_v2` (por construir, molde fail-closed) | **PENDIENTE** |
| Cross-sport canónico | `public.v_canonical_event` + `v_canonical_prediction` + `v_canonical_analysis` (unen los 3 deportes) | **PENDIENTE** |

`model_status`: READY_UNVALIDATED · READY_NO_EDGE (publican P_RETO) · NO_MODEL · NO_SUPPORTED_LINE · DATA_INCOMPLETE · PENDING_ANALYSIS (fail-closed, sin número + razón).

---

## 4. Compuertas de aceptación (machine gates)

| Gate | Meta | Cómo se mide |
|---|---|---|
| SPORT_MAIN_SURFACES_PER_SPORT | 1 | # de pestañas principales por deporte en el bottom nav |
| DUPLICATE_SOCCER_MAIN_SURFACES | 0 | rutas de fútbol como superficie principal ≠ FUT PRO |
| CROSS_SCREEN_P_MISMATCHES | 0 | mismo evento, mismo P_RETO en toda pantalla (contrato único) |
| CROSS_SCREEN_ANALYSIS_MISMATCHES | 0 | mismo análisis en toda pantalla |
| CROSS_SCREEN_ODDS_MISMATCHES | 0 | mismo momio+fuente+frescura en toda pantalla |
| UNKNOWN_EVENT_STATUS_BEHAVIORS | 0 | todo estado de evento→pick→UI/CTA/bankroll/grading definido |
| WRONG_LOGOS | 0 | escudo correcto por equipo (team_logo + fallback monograma) |
| LEGACY_P_VISIBLE_AS_P_RETO | 0 | ningún EV/Kelly/momio mostrado como P_RETO |
| LEGACY_FRONTEND_SURFACES_INVENTORIED | 100% | §1 (cerrado) |
| UNEXPLAINED_FRONTEND_BEHAVIORS | 0 | §1 (cerrado) |

---

## 5. Orden de ejecución

1. **[hecho]** Auditoría legacy 100% + arquitectura destino + vehículo (este documento).
2. **Motor:** construir `v_mlb_v2`, `v_nfl_v2` (molde `v_futpro_v2`) y las vistas canónicas cross-sport; verificar fail-closed.
3. **Carrocería:** remix de `00f8f06b` → nuevo proyecto "RETO 13M V2".
4. **Cambio de motor:** reescribir el cableado predictivo a los contratos V2 (§3) — quitar toda lectura de `analisis_completo`/`v_pick_canonico`/coreModel/safetyEngine/EV-Kelly-momio como autoridad.
5. **Reestructura de navegación:** bottom nav §2.1; fundir superficies de fútbol en FUT PRO; Fantasy interno de NFL; FAVORITOS + RETO 13M canónicos.
6. **Verificación de compuertas** §4 y captura de pantalla por deporte.

Restricciones permanentes: un solo backend `wpiztubmmmzclhlprgpd`; solo llave publishable, nunca service-role; NO Lovable Cloud; NO desarrollar dentro del repo viejo `reto13`; ligas sudamericanas domésticas fuera por diseño.
