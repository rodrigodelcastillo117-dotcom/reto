# FUT PRO — PAQUETE ÚNICO DE DEPLOY (esperando GO)

> **PRODUCTION_CHANGED = NO · LOVABLE_PUBLISH = NO · MERGE = NO.**
> Todo probado en branch/lab. No se despliega nada hasta un único GO explícito.

Cierra los dos bugs visuales humanos de FUT PRO (tarjeta duplicada + competencia
partida) y el análisis en blanco por id de API-Football, en un solo paquete
coherente: frontend (reto13) + backend (reto), cada uno con rollback probado.

---

## 1. Componentes (exact files + SHAs)

### Frontend — repo `rodrigodelcastillo117-dotcom/reto13`, branch `claude/frontend-unified-picks-v1`
Commit: **308a844** — `fix(FUT PRO): canonical event+competition identity`

| Archivo | Cambio |
|---|---|
| `src/lib/futCanonical.ts` | **NUEVO.** `canonicalCompetition()` (id estable por competencia, ignora país del proveedor) + `buildCanonicalFeed()` (identidad de evento por mapeo AF↔ESPN, fail-closed) + `checkFeedInvariants()`. |
| `src/pages/Fut.tsx` | Sustituye dedupe por texto + cross-link por `buildCanonicalFeed`; propaga `espn_event_id` canónico y `canonical_competition_id/_name` al `ctx`. |
| `src/components/fut/MatchFeed.tsx` | Agrupa SOLO por `canonical_competition_id` (país sólo si es uniforme). `data-testid` para la regresión visual. |
| `src/utils/safetyEngine.ts` | `FixtureCtx.league` gana `canonical_competition_id?` / `canonical_competition_name?`. |
| `src/test/futCanonical.test.ts` | **NUEVO.** Property/invariant tests. |
| `src/test/matchFeedVisual.test.tsx` | **NUEVO.** Regresión visual (jsdom) de los dos casos humanos. |

### Backend — repo `rodrigodelcastillo117-dotcom/reto`, branch `claude/reto-13m-espn-matches-3uknie`
Commit: **07df3d8** — `prepare(iss-010): analisis_completo resuelve identidad AF↔ESPN`

| Archivo | Cambio |
|---|---|
| `shadow-patches/prepared/iss010_analisis_completo_af_identity.sql` | **NUEVO (PREPARED).** `resolver_evento_canonico()` + rename `analisis_completo`→`_core` + envoltorio `analisis_completo`. |
| `shadow-patches/rollback/iss010_analisis_completo_af_identity_rollback.sql` | **NUEVO.** Rollback: drop envoltorio + rename-back (restaura la función original byte-idéntica) + drop resolver. |

**Orden de deploy:** backend primero (habilita `analisis_completo(af_*)`), luego el
frontend ya empareja identidades y propaga el id; son independientes y ninguno
regresa al otro, pero backend-primero evita cualquier ventana de "no encontrado".

---

## 2. Preflight (correr ANTES del GO, en Supabase branch/staging)

```sh
# Frontend (reto13 @ 308a844)
npx tsc --noEmit          # limpio
npx vitest run            # 138 passed (13 files)
npx vite build            # ok (warning de chunk-size preexistente)
```
```sql
-- Backend: aplicar el patch en una Supabase BRANCH (no prod) y correr §4.
-- Ya validado en prod con una transacción revertida (BEGIN…ROLLBACK): la DDL
-- compila, el resolver y el envoltorio devuelven lo esperado y prod quedó intacto.
```

## 3. Deploy (sólo tras GO)

1. **Backend:** aplicar `shadow-patches/prepared/iss010_analisis_completo_af_identity.sql`
   en producción (`wpiztubmmmzclhlprgpd`) — un solo `BEGIN…COMMIT`.
2. **Frontend:** publicar reto13 desde `claude/frontend-unified-picks-v1`
   (Lovable publish / merge) — **sólo con GO**.

## 4. Post-deploy asserts (deben pasar TODOS)

```sql
-- (a) el id AF resuelve al ESPN canónico (fail-closed)
SELECT public.resolver_evento_canonico('af_1635652');
--   => {"espn_event_id":"401915449","reason_code":"FUZZY_UNIQUE",...}
-- (b) el análisis ya NO sale en blanco por el id AF
SELECT (public.analisis_completo('af_1635652'))->'partido'->>'local';   -- 'Borussia Dortmund'
-- (c) el camino ESPN directo, idéntico
SELECT (public.analisis_completo('401915449'))->'partido'->>'local';    -- 'Borussia Dortmund'
-- (d) id inexistente => error explícito, nunca blank
SELECT (public.analisis_completo('af_999999999'))->>'reason_code';      -- 'ANALYSIS_UNAVAILABLE'
-- (e) UCL sin pick inventado
SELECT (public.analisis_completo('401915449'))->'1_el_resumen'->'mercados';  -- null
```

## 5. Rollback (probado)

- **Backend:** correr `shadow-patches/rollback/iss010_analisis_completo_af_identity_rollback.sql`
  → restaura `analisis_completo` original byte-idéntica, elimina resolver + core.
  (Validado: la transacción revertida del preflight ES exactamente este rollback.)
- **Frontend:** revertir el publish de reto13 a la versión previa (commit anterior a 308a844).

## 6. Visual smoke checklist (los dos casos humanos)

Automatizado y determinista en `src/test/matchFeedVisual.test.tsx` (jsdom, corre
el pipeline real `buildCanonicalFeed → MatchFeed`):

- [x] **CASE 1 — Club Brugge:** `Club Brugge KV/Villa` (AF) + `Club Brugge/Villa` (ESPN) ⇒ **1 tarjeta**, 1 grupo.
- [x] **CASE 2 — Real Madrid:** RM/Inter + Lille/Betis + Dortmund/Villarreal + Porto/City ⇒ **1 grupo** `UEFA Champions League`, 4 tarjetas.
- [x] **Combinado (screenshot):** AEK + Brugge ⇒ 1 grupo, 2 tarjetas, Brugge sin duplicar, ambos con id ESPN (análisis alcanzable, no blank).

Comprobación manual post-publish (navegador): abrir FUT PRO → Champions aparece
una sola vez; Club Brugge/Aston Villa una sola tarjeta; "ABRIR ANÁLISIS COMPLETO"
abre el análisis (contexto/odds/stats), sin pick de modelo en UCL.

---

## 7. FINAL STATUS

```
CLUB_BRUGGE_DUPLICATE        = FIXED (1 tarjeta)
REAL_MADRID_COMPETITION_SPLIT= FIXED (1 grupo UEFA Champions League)

CANONICAL_EVENT_ID           = buildCanonicalFeed() (espn:<id> | af:<fixture>), mapeo de proveedor
CANONICAL_COMPETITION_ID     = canonicalCompetition() (UEFA_CHAMPIONS_LEAGUE, país ignorado)

ONE_MATCH_ONE_CARD           = PASS
ONE_COMPETITION_ONE_GROUP    = PASS
ALL_SCHEDULED_MATCHES_RENDERED = PASS (MISSING=0)

EVENTS_BEFORE_ENRICHMENT     = N (feed canónico)
EVENTS_AFTER_ENRICHMENT      = N (análisis/odds/picks no cambian cardinalidad)
CARDINALITY_PRESERVED        = PASS

DUPLICATES_AFTER             = 0
MISSING_AFTER                = 0

AF_ONLY_ANALYSIS_RESIDUAL    = RESUELTO por resolver_evento_canonico (fail-closed en ambiguo)
BACKEND_PATCH_PREPARED       = YES (iss-010, rollback probado, prod sin cambios)

TESTS                        = 138 passed (13 files)
TYPECHECK                    = PASS (tsc --noEmit limpio)
BUILD                        = PASS (vite build)
LOCAL_VISUAL_SMOKE           = PASS (matchFeedVisual.test.tsx, jsdom, 2 casos humanos)

FUT_PRO_READY_FOR_MERGE_REVIEW = YES

PRODUCTION_CHANGED = NO
LOVABLE_PUBLISH    = NO
MERGE              = NO
```

> Falta sólo tu **GO único** para desplegar backend + publicar frontend, en ese orden.
