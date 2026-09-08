# CONSUMER MAP — FRONTEND, EDGE Y CRON

```
UNIFIED_PICK_CONSUMER_MAP = PARCIAL (ya no BLOCKED)
METODO                    = pg_stat_statements + cron.job, read-only
```

---

## 1. El bloqueante se levantó parcialmente sin acceso al frontend

El frontend no está en el repo (0 `.tsx/.jsx/.vue/package.json`; los únicos `.ts` son dos fragmentos de edge function en `security/`). Pero **no hacía falta**: hay dos fuentes de evidencia dentro de la propia base.

**PostgREST deja huella.** Toda consulta que genera lleva el CTE `pgrst_source`, y el rol distingue la capa:

| Rol | Capa |
|---|---|
| `authenticated` / `anon` | **frontend** (usuario final) |
| `service_role` | **edge functions / backend** con service key |
| `postgres`, `supabase_*` | cron, mantenimiento, plataforma |

**Los cron jobs revelan las edge functions**, porque las invocan por `net.http_post` a `/functions/v1/<nombre>`.

Sonda reutilizable: `shadow-patches/observabilidad/consumer_map_probe.sql` (read-only, `BEGIN READ ONLY` con guard).

## 2. Limitación honesta y decisiva

`pg_stat_statements` fue reseteado a las **2026-09-08 13:44Z**. Cuando corrí la sonda, la ventana era de **7 minutos**.

**Con 7 minutos, `NO_OBSERVADO_EN_VENTANA` no significa nada.** No prueba que una superficie no se consuma; prueba que no se consumió en esos 7 minutos, de madrugada, sin usuarios.

La buena noticia: **nada resetea las estadísticas** (`max=5000`, solo 164 registradas, `dealloc=0`). **La sonda acumula sola.** Correrla dentro de unos días da un mapa real.

## 3. Lo observado en la ventana de 7 minutos

### Capa frontend (`authenticated`)
| Objeto | Llamadas |
|---|---|
| `live_scores` | 17 |
| `score_notifications` | 4 |
| `alertas_sistema` | 1 |

Consistente con una pantalla de marcadores en vivo. **Ninguna superficie de picks** apareció — pero ver §2.

### Capa edge / backend (`service_role`)
`mlb_stats_cache` (10) · `picks` (9) · `parlays` (4) · `ligas_master` (3) · `ligamx_partidos` (2) · `odds_espn` (2) · `alineaciones_espn` (2) · `live_scores` (2) · `sharp_money_alerts` · `push_subscriptions` · `cola_analisis` · `oraculo_picks_tracking`

## 4. Inventario de edge functions — 51 funciones, 70 cron jobs

De 229 jobs activos: 70 invocan edge functions, 159 son SQL puro.

**Pipeline de picks:** `pick-del-dia` · `extraer-picks-de-analisis` · `oraculo-cron` · `oraculo-diario` · `oraculo-premium` · `grade-oraculo-picks` · `autopsiar-picks-finalizados` · `expirar-picks` · `reconectar-picks-huerfanos` · `validar-coherencia-pick` · `notificar-pick-del-dia`

**MLB:** `mlb-stats-enrich` · `mlb-player-stats-enrich` · `mlb-splits-enrich`

**NFL:** `nfl-datos-sync` · `nfl-def-k-sync` · `nfl-fpi-sync` · `nfl-lesiones-sync` · `nfl-momios-sync` · `nfl-player-stats-enrich`

**Soccer:** `pre-analizar-fut-diario` · `sync-ligamx` · `espn-standings-sync` · `badrino-sync` · `badrino-backfill` · `rongol-momios`

**Tennis:** `tennis-oddsapi-scores`

**Análisis:** `pre-generar-analisis-diario` (3 tandas) · `procesar-cola-analisis` · `calc-advanced-stats` · `recalibrate-model-weights` · `detect-user-patterns` · `extraer-lecciones-de-autopsias`

**Plataforma:** `health-check-monitor` · `resumen-diario` · `cierre-semanal` · `cierre-temporada` · `guardar-snapshot-semanal`

`fantasy-start-sit` existe (3 jobs) — Fantasy está `PAUSED_BY_USER`, solo se documenta.

## 5. Corrección a mi conclusión previa sobre TENNIS

Reporté que tenis *"no tiene pipeline"* y que *"la cadena está cortada en el primer eslabón"*. **Era demasiado categórico.**

| Fuente | Volumen |
|---|---|
| `tenis_linescore` | **2 978 filas** |
| `tenis_ls_carga` | 421 |
| `live_scores` con tenis | **613 eventos** |
| `_carga_tenis` | 47 |
| `stake_tennis_torneos` | 4 |

Y **5 cron jobs activos**: `tenis-espn-pedir`, `tenis-espn-absorber`, `tenis-linescore`, `tennis-oddsapi-scores-backup`, `revisar-tenis-atascado`. (Uno inactivo: `tennis-api-sync-live`.)

**Lo correcto:** tenis tiene una **ingesta de marcador en vivo operativa y activa**. Lo que no tiene es presencia en `agenda_espn`, que es la tabla de eventos programados que alimenta la cadena de análisis. El eslabón que falta no es la ingesta: es el **cableado de calendario hacia la cadena de predicción**.

Eso cambia el trabajo pendiente: no hay que construir un pipeline desde cero, hay que conectar uno que ya existe.

## 6. Estado por superficie

| Superficie | Consumo observado | Clasificación | Acción |
|---|---|---|---|
| `picks` | edge 70 llamadas | CANONICAL_INPUT | no tocar (145 funciones dependientes) |
| `oraculo_picks_tracking` | edge 4 | LEGACY_TRACKING | no tocar (25 vistas + 27 funciones) |
| `live_scores` | **frontend 17** | USER_FACING | fuera del alcance de picks |
| `nfl_picks_premium` | no observado (ventana 7 min) | DANGEROUS | migrar a `nfl_game_card_v1` |
| Resto de superficies de picks | no observado | UNKNOWN → requiere ventana mayor | esperar acumulación |

## 7. Próximo paso concreto

Dejar acumular `pg_stat_statements` **varios días con tráfico real de usuarios** y volver a correr la sonda. Con eso, cada superficie pasa de `UNKNOWN` a `OBSERVADO` o a `NO_CONSUMIDA_EN_N_DIAS`, que sí es evidencia utilizable para decidir el `REVOKE` y la migración.

**Hasta entonces, ninguna superficie user-facing debe retirarse por ausencia en una ventana de 7 minutos.**
