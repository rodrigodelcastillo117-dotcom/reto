# APP_MASTER_HANDOFF — RETO 13M (2026-09-08)

> **Alcance de este documento:** aporta la capa que faltaba — **descubrimiento y auditoría
> del frontend real** (PRIORITY 1). Para backend/SEC/unified/MLB-temporal, la fuente
> autoritativa es el trabajo overnight paralelo en este mismo `docs/master_v2/`:
> `OVERNIGHT_MASTER_HANDOFF.md`, `UNIFIED_CONSUMER_MAP.md`, `UNIFIED_PICK_CONTRACT_V1.md`,
> `MLB_VISUAL_PROBABILITY_AUDIT.md`, `NFL_BETTING_STATUS.md`, `SEC05_CLASSIFICATION.md`,
> `SECURITY_MATRIX_V1.md`, `SOCCER_CHAMPIONS_STATUS.md`, `EMPIRICAL_SUFFICIENCY_V1.md`,
> `MLB_TEMPORAL_AUDIT.md`. Las líneas de estado no-frontend de abajo se citan de ese estado
> heredado, no re-verificadas en esta ronda.

## REPORTE

```
PRODUCTION_CHANGED         = NO
DEPLOY_EXECUTED            = NO

FRONTEND_REPO_FOUND        = YES  (reto13 @ Lovable id 00f8f06b-3762-44a6-a397-e41dd7d9b7c5,
                                    https://reto13.lovable.app, screenshot ba828acc;
                                    + reto-13m @ GitHub, app base44 separada/legacy)
FRONTEND_CONSUMER_MAP      = PARTIAL/PASS  (surfaces money/pick P2-P4 deep-read con evidencia de
                                    código; resto inventariado — ver FRONTEND_CONSUMER_MAP.md)

UNIFIED_PICK_TOTAL         = 46
UNIFIED_PICK_MIGRATED      = 4/46  (sin cambio esta sesión; bloqueado hasta conocer consumidores reales — ahora conocidos los money/pick)
DANGEROUS_REMAINING        = NFL PICKS PREMIUM, MLB QUÉ-HARÍA, MEJORES PICKS MLB (3 surfaces con lenguaje de recomendación sin gate económico)

MLB_VISUAL_SEMANTICS       = FAIL  (PronosticoMlbModelo CTA "QUÉ HARÍA" sin gate económico; señal total = esperado−línea)
MEJORES_PICKS_SEMANTICS    = FAIL  (v_mejores_picks_mlb ordenado EV DESC, rotulado "MEJORES PICKS" = PRODUCT_SEMANTIC_BUG CONFIRMED)

NFL_NF01                   = CRITICAL_OPEN  (NflPremiumPicks: nfl_picks_premium presentado como "PICKS PREMIUM/SEÑAL"; sin gate MARKET_NO_VIG→informativo)
NFL_USER_VISIBLE_STATUS    = MARKET DATA MISLABELED AS PREMIUM PICKS
NFL_MODEL_STATUS           = NO MODEL (p = MARKET_NO_VIG; model probability = unavailable)

TENNIS_PIPELINE            = NOT_AUDITED_THIS_SESSION (ingesta existe per handoff previo; wiring pendiente)
TENNIS_AGENDA_WIRING       = PENDING

SEC03                      = PREPARED_FOR_DEPLOY, NOT DEPLOYED (sin cambio esta sesión)
SEC05                      = CRITICAL_OPEN — PATCH1 prepared (38 fns), 89 sin clasificar (sin cambio esta sesión)

SOCCER                     = evidence-gated (MotorValueSection = value framing correcto)
CHAMPIONS                  = fail-closed (sin cobertura de modelo validada)

TOP_PICK                   = EVIDENCE_GATED / DISABLED (sin cambio)
FORWARD_CAPTURE            = AUTHORIZED=FALSE hasta SEC-03 deploy (V4 FROZEN, sin cambio)

TESTS_PASS                 = n/a esta sesión (no se corrieron; frontend no editable localmente)
TESTS_FAIL                 = n/a
TESTS_BLOCKED              = frontend tests viven en reto13 (Lovable) — no ejecutables desde esta sesión

CRITICAL_OPEN              = NF-01 (NFL market→premium); MLB visual semantics; SEC-05
HIGH_OPEN                  = MEJORES PICKS naming; ISS-003/009 SQL sin desplegar (transport BLOCKED)
MEDIUM_OPEN                = Tennis wiring; Unified pick migration 4/46; copy "bien calibrado/aguanta" sin localizar

FILES_CHANGED              = 2  (docs/master_v2/FRONTEND_CONSUMER_MAP.md, docs/master_v2/APP_MASTER_HANDOFF.md)
COMMITS                    = 1 (esta ronda)
PUSH_STATUS               = pushed a claude/reto-13m-espn-matches-3uknie

WHAT_IS_FIXED             = nada en código (descubrimiento + auditoría + specs)
WHAT_IS_PREPARED          = consumer map + specs exactos de corrección P2/P3/P4 (abajo)
WHAT_IS_BLOCKED           = edición de frontend (Lovable = deploy a prod, prohibido); deploy SQL ISS-003/009 (transport BLOCKED); SEC deploys (prohibidos)
WHAT_MUST_NOT_BE_TRUSTED  = "PICKS PREMIUM"/"SEÑAL" de NFL (es MARKET_NO_VIG, no modelo); "✅ QUÉ HARÍA" de MLB (sin autoridad económica); "señal OVER/UNDER" de total MLB (esperado−línea); "MEJORES PICKS MLB" (es ranking EV, no "mejores")

NEXT_EXACT_ACTION         = Decidir mecanismo de edición de reto13 (agente Lovable = deploy prod, o conectar a GitHub). Con eso: aplicar FIX-NFL-01 (gate MARKET_NO_VIG→informativo en NflPremiumPicks.tsx) primero, luego FIX-MLB-QUEHARIA y FIX-MEJORES-PICKS-NAMING.
```

---

## PREPARED FIXES (PREPARE_FOR_DEPLOY — no aplicados; frontend reto13 @ Lovable)

### FIX-NFL-01 — `src/components/nfl/NflPremiumPicks.tsx` (CRÍTICO)
- Renombrar sección: "⭐ PICKS PREMIUM" → **"📊 INFORMACIÓN DE MERCADO — NFL"**; subcopy "líneas reales de mercado (sin modelo propio)".
- Banner fijo: **"MODELO NFL TODAVÍA NO AUTORIZADO — probabilidades = mercado sin comisión (no-vig)"**.
- Eliminar chip "SEÑAL"; todos los rows son estado **"MERCADO"**. Nunca ámbar de recomendación.
- `probabilidad` siempre etiquetada "prob. de mercado (no-vig)"; nunca como model probability. Model probability = null/unavailable.
- Una tarjeta por juego (ML/Spread/Total dentro); no dos lados como picks independientes.
- Tests a añadir (en reto13): MARKET_NO_VIG nunca → "modelo"/"premium"/"señal"; ambos lados nunca en "best"; EV sin P de modelo válido nunca genera pick.

### FIX-MLB-QUEHARIA — `src/components/mlb/PronosticoMlbModelo.tsx` (CRÍTICO, dinero)
- Gate: mientras MLB `economically_eligible !== true` (autoridad económica = NONE), **nunca** renderizar el bloque "✅ QUÉ HARÍA: X ML". Sustituir por **"ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"** (mostrar prob del modelo y matchup permitido; sin CTA, sin "a tu favor", sin "pagando Z o más").
- Prohibir vocabulario `aguanta/apostar/recomendado/pick sugerido/fuerte/ojo` bajo no-elegible.
- Total: **eliminar** "señal hacia OVER/UNDER (+d)" derivado de `total_esperado - lineaTotal`. Reemplazar por P(Over)/P(Under) desde distribución (Neg. Binomial CDF) del backend; si no hay esa P, mostrar solo "carreras esperadas X" sin señal direccional.
- No afirmar "bien calibrado/confiable" salvo linkage de model-version probado (hoy `MODEL_VERSION_PROVENANCE_MISSING`).
- No cambiar P ni EV ni el modelo estadístico.

### FIX-MEJORES-PICKS-NAMING — `src/components/mlb/MejoresPicksMlb.tsx` (ALTO)
- Renombrar "⭐ MEJORES PICKS MLB DE HOY" → **"💰 VALOR MLB — dónde la casa paga de más"** (el subtítulo ya lo dice; el título debe coincidir).
- Taxonomía de producto (aplicar a toda la app): **🔥 MÁS PROBABLES** (probabilidad) · **💰 VALOR/VALUE** (EV) · **🏆 TOP PICKS** (evidencia; hoy DISABLED) · **🔬 ANÁLISIS** (informativo). Nunca "MEJORES/BEST/TOP" para un ranking EV.
- Consumir `economically_eligible` cuando ISS-009 despliegue; hasta entonces no rotular `fuerte`/verde como recomendación de apuesta.
- `MotorValueSection.tsx` ya usa el framing correcto ("Motor · Value EV+") — usar como referencia.

---

## CONTEXTO DE ESTADO (no re-auditar; heredado + revalidado)
- **ISS-003/009:** BACKEND_GATE=PASS, MONEY_SAFETY=PASS, VISUAL_SEMANTICS=FAIL, NOT_CLOSED. SQL congelado `57b7a40…cad`, SHA_DRIFT=NO, rollback primario semántico (no-cascade). Deploy bloqueado por `SAFE_SQL_TRANSPORT=BLOCKED` (sin DATABASE_URL). Ver `shadow-patches/iss003_009_REVALIDATION_2026-09-08.md`.
- **MLB:** economic authority=NONE, stake=0. Fuga viva pre-deploy: `v_mejores_picks_mlb` 3 filas `ojo/fuerte` (kelly=$0). Modelo pierde vs mercado. Presentación cross-model: Poisson score + Neg. Binomial totals.
- **TOP_PICK_FORWARD_CAPTURE_V1:** V4 FROZEN. No tocar.
- **Fantasy:** PAUSED_BY_USER. No trabajado.

## REGLAS DE ESTA ERA (Claude Code APP principal)
NO production deploy · NO production DDL/DML · NO merge · NO force push · SEC deploys solo PREPARED. Permitido: editar/refactor/test/build/lint/commit/push normal. Cualquier cosa que toque prod = PREPARE_FOR_DEPLOY.
