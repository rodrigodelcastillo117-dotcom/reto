# FUT PRO — FINAL CLOSURE MASTER (RETO 13M)

Fecha: 2026-09-08. Sin false PASS. Lo cerrado está probado + desplegado; lo no
verificado exhaustivamente o pendiente de vivo se marca explícitamente.

Frontend prod: `reto13` main publicado en Lovable, commits en orden:
`4a10965` (identidad canónica) → `dbb59a9` (ESPN live authority) → `1993920`
(§17 gate + AnalysisTab). Backend prod: ISS-010 (resolver AF↔ESPN) desplegado.

Estados válidos: CLOSED · PREPARED_FOR_DEPLOY · DEPLOYED_PENDING_SMOKE ·
NEEDS_LIVE_CONFIRMATION · BLOCKED · NEEDS_PRODUCT_DECISION.

---

## Bugs

| ID | sev | causa raíz | fix | test | prod |
|---|---|---|---|---|---|
| FUT-DUP (Real Madrid, Club Brugge) | alto | dedup por igualdad exacta de slug | `buildCanonicalFeed` identidad por mapeo de proveedor (contención, fail-closed); 1 partido=1 tarjeta | futCanonical + matchFeedVisual + real-replay 8-sep (6 eventos) | **CLOSED** `4a10965` |
| FUT-COMP (UCL split) | alto | agrupaba por país inconsistente | agrupa SOLO por canonical_competition_id | futCanonical | **CLOSED** `4a10965` |
| FUT-BLANK (análisis no abre) | alto | tarjeta con id AF; RPC sólo ESPN | ISS-010 resolver AF→ESPN fail-closed; front cross-linkea espn_event_id | txn lab + prod post-verify (IDENTITY_AMBIGUOUS demostrado en vivo) | **CLOSED** backend prod |
| FUT-LIVE-FREEZE | crítico | ingesta EN VIVO de API-Football throttled/apagada (sync-live-5min INACTIVA; espejo corre pero no avanza). AF age ~1401s vs ESPN 22s | autoridad de vivo = ESPN siempre; `liveRaw`; poll 30s ESPN por espn_event_id | futCanonical (+3) + real replay (RM 0-0/9'→ESPN 2-0/32') | **DEPLOYED** `dbb59a9` · **NEEDS_LIVE_CONFIRMATION** |
| UCL-OVER25 (§17) | alto | header colapsado pintaba pick del motor cliente en VERDE sin gate de autoridad (UCL modelo NO validado) | gate `isActionable(safe)`; sin autoridad → `🔬 <escenario>` informativo (no verde) | 141 tests + revisión de código | **CLOSED** `1993920` |
| ACT-ANALYSISTAB | alto | "PICKS INDIVIDUALES DEL DÍA" con StakeButton sin autoridad | quitado el CTA; reetiquetado ANÁLISIS INFORMATIVO (dato conservado) | tsc + grep residual | **CLOSED** `1993920` |
| GOV-FAILCLOSED (9 superficies) | crítico | falta elegibilidad ≠ permiso | `eligibilityGate` en Premium/PickDelDia/ParlayDelDia/Dashboard/Oraculo/MatchCard/AiProSection/PicksFutbolLimpio | eligibilityGate + failClosedReactivation | **CLOSED** (sesión previa) |

---

## Invariantes (141/141 tests, tsc limpio, vite build ok, jsdom smoke)

ONE_MATCH_ONE_CARD ✅ · ONE_COMPETITION_ONE_GROUP ✅ · MISSING=0 ✅ · DUPLICATES=0 ✅ ·
CARDINALITY_PRESERVED ✅ · CLUB_BRUGGE ✅ · REAL_MADRID ✅ · AEK_LASK ✅ · DORTMUND ✅ ·
ambigüedad fail-closed ✅ · LIVE authority=ESPN ✅ (identidad AF, vivo ESPN).

Cardinalidad real 8-sep UCL: AF_INPUT=6, ESPN_INPUT=6, CANONICAL=6, DUPLICATES=0,
MISSING=0, UCL_GROUPS=1.

---

## ABIERTO / DECISIÓN / NO RE-AUDITADO (honesto)

| ID | estado | nota |
|---|---|---|
| FUT-LIVE-FREEZE confirmación | NEEDS_LIVE_CONFIRMATION | smoke autenticado del usuario: ≥2 observaciones (54'→58' / HT→2H / 1-0→1-1) |
| ANALYSIS_BADGE_TRUTHFUL (§7 estricto) | PARCIAL | la pista por defecto "análisis disponible" no verifica payload por evento; con ISS-010 el análisis es alcanzable para eventos cross-linkeados. Endurecer el badge a estado real (FULL/PARTIAL/UNAVAILABLE/AMBIGUOUS) queda como follow-up |
| ACT-PARLAYCARD | NEEDS_PRODUCT_DECISION | StakeButton por pata sobre el TICKET PROPIO del usuario (no recomendación del modelo) |
| AF-INGEST cron freeze | root-caused; resolución=ESPN | no se re-habilita AF (conservación de cuota). Follow-up: consumidores de `live_scores` (tracker parlay) prefieran fila ESPN |
| NFL / MLB / Champions sweep string-por-string | NO RE-AUDITADO este pase | cubierto por gate fail-closed previo + UCL mercados=null verificado en prod |
| Legacy no-render, telemetría, indicador "actualización retrasada" | NO EN ESTE PASE | serían features/refactor; FUT PRO ya usa ESPN fresco |

---

## Éxito

READY_FOR_FINAL_DEPLOY = DESPLEGADO (frontend `1993920` + backend ISS-010).
READY_TO_DECLARE_CLOSED = **NO todavía** — depende de:
  (1) confirmación en vivo de FUT-LIVE-FREEZE (smoke del usuario),
  (2) endurecer ANALYSIS_BADGE_TRUTHFUL (§7),
  (3) decisión de producto ACT-PARLAYCARD.
El resto (duplicados, grupos, análisis alcanzable, §17, actionable-sin-autoridad en
superficies de modelo) está CLOSED y en producción.
