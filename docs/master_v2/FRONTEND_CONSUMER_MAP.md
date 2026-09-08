# CONSUMER MAP — RETO 13M (frontend + edge + cron)

> **Actualización 2026-09-08 (PRIORITY 1):** la limitación de la Parte B ("el frontend
> no está en el repo") queda **resuelta**: el frontend SÍ fue localizado — es un proyecto
> **Lovable** (`reto13`), fuera de git. Ver **Parte A**. La Parte B (mapa edge/cron/DB por
> `pg_stat_statements`) se conserva íntegra como evidencia corroborante del backend.

---

# PARTE A — FRONTEND REAL (React) · localizado

## A.0 Repos / apps

| App | Dónde | Stack | Rol | Editable desde aquí |
|---|---|---|---|---|
| **`reto`** | GitHub `…/reto` (esta sesión) | SQL + edge (Deno) | Backend: vistas, RPC, shadow-patches, seguridad | ✅ commit/push |
| **`reto13`** | **Lovable** `00f8f06b-3762-44a6-a397-e41dd7d9b7c5` · https://reto13.lovable.app · screenshot **`ba828acc`** | vite+react+shadcn+**TS** | **Frontend de análisis** (MLB/NFL/fut dossier, Mejores Picks, analisis_completo, ISS-009B) → Supabase | ⚠️ solo vía agente Lovable = **deploy a prod** (§A.4) |
| **`reto-13m`** | GitHub `…/reto-13m` (local `/home/user/reto-13m`) | vite+react+**base44** (JS) | Tracker separado (Pick/Parlay/PIT). Push abr-2026 | ✅ clon local; repo distinto |

**Confirmado:** el frontend con los bugs de MLB/NFL/"Mejores Picks" es **`reto13` (Lovable)**. `reto-13m` (base44) NO contiene el copy problemático ni referencias a `v_pick_canonico`/`v_mejores_picks_mlb`/`analisis_completo`. El screenshot `ba828acc` de reto13 = el deploy citado en ISS-009B.
`FRONTEND_REPO_FOUND = YES`

## A.1 Consumer map — surfaces money/pick (deep-read con código)

### NFL — `src/components/nfl/NflPremiumPicks.tsx` ⚠️ NF-01 CRÍTICO
QUERY `supabase.from('nfl_picks_premium').limit(60)` · P=`probabilidad` (MARKET_NO_VIG; sin modelo NFL) · EV=`momio_justo/americano` · ELIG=`nivel` (señal/mercado) · STAKE=—  · COPY **"⭐ PICKS PREMIUM"**, chip **"SEÑAL"**/MERCADO. BUG: dato de mercado como premium/señal; aviso "prob. de la casa (sin modelo)" solo si NO es señal; sin gate económico.

### MLB modelo — `src/components/mlb/PronosticoMlbModelo.tsx` ⚠️ VISUAL FAIL
QUERY RPC `predecir_mlb` (`useMlbPrediccion`) · P=`gana_local/visita_pct` (MODELO) · EV=`edge_vs_mercado` · ELIG=`edge.confiable`/`aviso_modelo` (per-partido, **no** autoridad económica) · COPY "Favorito del modelo", **"✅ QUÉ HARÍA: X ML pagando Z o más"**, "a tu favor", **"señal hacia OVER/UNDER (+d)"**. BUGS: (1) CTA económica sin gate `economically_eligible`; (2) señal de total = `total_esperado − lineaTotal` (prohibido).

### MLB mejores picks — `src/components/mlb/MejoresPicksMlb.tsx` ⚠️ PRODUCT_SEMANTIC_BUG
QUERY `v_mejores_picks_mlb` + `v_favorito_mlb`, **ORDER BY EV DESC** · P=`prob_calibrada` · EV=`ev_pct` · ELIG=`nivel` (fuerte/ojo/flojo) · COPY **"⭐ MEJORES PICKS MLB DE HOY"** (subtítulo honesto "no es quién gana — es dónde la casa paga de más"). BUG: ranking EV rotulado "MEJORES PICKS"; no consume `economically_eligible`.

### Value fut/global — `src/components/MotorValueSection.tsx` ✅ naming correcto
QUERY `v_motor_valor_proximos`, EV DESC · COPY **"🎯 Motor · Value EV+"**. Referencia de taxonomía correcta.

## A.2 Inventariados (sin deep-read; método: `mcp__Lovable__read_file`)
ISS-009B: `partido/AnalisisCompletoModal.tsx`. Picks/valor: `AnalizarPartido/PicksSeguroValorCards.tsx`, `fut/PremiumPicksSection.tsx`, `fut/PicksFutbolLimpio.tsx`, `reto/MejorPickHoy.tsx`, `reto/PickDelDiaCard.tsx`, `reto/OraculoRecomendados.tsx`, `reto/AccionDelDia.tsx`, `reto/PicksProbabilidadFavoritos.tsx`. Dinero: `ApostarButton`, `StakeButton`, `reto/CalculadoraMonto`, `reto/StakeGateModal`, `reto/EVBadge`. MLB extra: `AnalizarPartido/MLBDeepStatsSection.tsx` (posible "bien calibrado"/"aguanta"/"Ventaja del modelo" — no hallado en los 4 deep-read). App ≈ 200+ archivos.
`FRONTEND_CONSUMER_MAP = PARTIAL/PASS`

## A.3 Copy del smoke humano
"9.06 vs 8.5 · sin señal (+0.56)" → `PronosticoMlbModelo.tsx` (señal total = esperado−línea) ✅. "Ventaja del modelo"/"aguanta"/"bien calibrado" → no en los 4 deep-read; probable `MLBDeepStatsSection.tsx`/`AnalisisCompletoModal.tsx` ⏳.

## A.4 Restricción de entrega
`reto13` es Lovable: sin repo git local; editar = **agente Lovable** (gasta credits + **publica a prod** reto13.lovable.app). Bajo **NO production deploy**, las correcciones P2/P3/P4 se entregan como PREPARE_FOR_DEPLOY (ver APP_MASTER_HANDOFF.md). Decisión del usuario: (a) autorizar agente Lovable (=deploy) o (b) conectar reto13 a GitHub.

---

# PARTE B — MAPA EDGE / CRON / DB (pg_stat_statements, read-only)

```
UNIFIED_PICK_CONSUMER_MAP = PARCIAL (ya no BLOCKED)
METODO                    = pg_stat_statements + cron.job, read-only
```

## B.1 Evidencia sin acceso a frontend
PostgREST deja el CTE `pgrst_source`; el rol distingue capa: `authenticated`/`anon`=frontend, `service_role`=edge/backend, `postgres`/`supabase_*`=cron/plataforma. Los cron jobs revelan edge functions vía `net.http_post` a `/functions/v1/<nombre>`. Sonda: `shadow-patches/observabilidad/consumer_map_probe.sql`.

## B.2 Limitación honesta
`pg_stat_statements` reseteado 2026-09-08 13:44Z; ventana medida = 7 min. `NO_OBSERVADO_EN_VENTANA` no prueba ausencia de consumo. `max=5000`, 164 registradas, `dealloc=0` ⇒ la sonda acumula sola; correrla en días da el mapa real.

## B.3 Observado (ventana 7 min)
Frontend (`authenticated`): `live_scores`(17), `score_notifications`(4), `alertas_sistema`(1). Ninguna superficie de picks (ver B.2). Edge (`service_role`): `mlb_stats_cache`(10), `picks`(9), `parlays`(4), `ligas_master`(3), `ligamx_partidos`(2), `odds_espn`(2), `alineaciones_espn`(2), `live_scores`(2), `sharp_money_alerts`, `push_subscriptions`, `cola_analisis`, `oraculo_picks_tracking`.

## B.4 Edge functions — 51 fns, 70 cron jobs (de 229 jobs)
Picks: `pick-del-dia`, `extraer-picks-de-analisis`, `oraculo-cron/-diario/-premium`, `grade-oraculo-picks`, `autopsiar-picks-finalizados`, `expirar-picks`, `reconectar-picks-huerfanos`, `validar-coherencia-pick`, `notificar-pick-del-dia`. MLB: `mlb-stats-enrich`, `mlb-player-stats-enrich`, `mlb-splits-enrich`. NFL: `nfl-datos-sync`, `nfl-def-k-sync`, `nfl-fpi-sync`, `nfl-lesiones-sync`, `nfl-momios-sync`, `nfl-player-stats-enrich`. Soccer: `pre-analizar-fut-diario`, `sync-ligamx`, `espn-standings-sync`, `badrino-sync/-backfill`, `rongol-momios`. Tennis: `tennis-oddsapi-scores`. Análisis: `pre-generar-analisis-diario`(x3), `procesar-cola-analisis`, `calc-advanced-stats`, `recalibrate-model-weights`, `detect-user-patterns`, `extraer-lecciones-de-autopsias`. Plataforma: `health-check-monitor`, `resumen-diario`, `cierre-semanal/-temporada`, `guardar-snapshot-semanal`. `fantasy-start-sit` existe (PAUSED_BY_USER, solo documentado).

## B.5 TENNIS — corrección
Tenis SÍ tiene ingesta viva y activa: `tenis_linescore`(2 978), `tenis_ls_carga`(421), `live_scores` tenis(613), `_carga_tenis`(47), `stake_tennis_torneos`(4); 5 crons activos (`tenis-espn-pedir`, `tenis-espn-absorber`, `tenis-linescore`, `tennis-oddsapi-scores-backup`, `revisar-tenis-atascado`). Falta: presencia en `agenda_espn` (cableado calendario→cadena de predicción). No hay que construir, hay que conectar.

## B.6 Estado por superficie
`picks` (edge 70) CANONICAL_INPUT no tocar · `oraculo_picks_tracking` (edge 4) LEGACY no tocar · `live_scores` (frontend 17) USER_FACING fuera de alcance · `nfl_picks_premium` DANGEROUS → migrar a `nfl_game_card_v1` · resto UNKNOWN (ventana corta).

## B.7 Próximo paso
Dejar acumular `pg_stat_statements` varios días con tráfico real y re-correr la sonda. Hasta entonces ninguna superficie user-facing se retira por ausencia en 7 min.
