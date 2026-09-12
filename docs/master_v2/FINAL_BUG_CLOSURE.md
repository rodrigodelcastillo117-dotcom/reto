# FINAL BUG CLOSURE — FUT PRO / frontend (RETO 13M)

Fecha: 2026-09-08. Sin false PASS: lo cerrado está probado; lo no verificado
exhaustivamente se marca como tal.

Repos: `reto13` (frontend, branch `claude/frontend-unified-picks-v1` → merged a `main`),
`reto` (backend shadow-patches, branch `claude/reto-13m-espn-matches-3uknie`).

Estado de despliegue frontend: `main` @ `dbb59a9` publicado en Lovable (reto13.lovable.app).
Backend prod: ISS-010 (resolver AF↔ESPN) desplegado y verificado.

---

## CERRADOS (probados + desplegados)

| ID | sev | superficie | causa raíz | fix | test | deploy |
|---|---|---|---|---|---|---|
| FUT-DUP | alto | FUT PRO feed | dedup por igualdad exacta de slug; "Club Brugge KV"≠"Club Brugge" | `buildCanonicalFeed`: identidad de evento por mapeo de proveedor (contención), 1 partido=1 tarjeta | futCanonical.test + matchFeedVisual | ✅ dbb59a9 |
| FUT-COMP | alto | FUT PRO grupos | agrupaba por país (inconsistente entre proveedores) | agrupa SOLO por `canonical_competition_id`; UCL = 1 grupo | futCanonical.test | ✅ |
| FUT-BLANK | alto | análisis FUT PRO | tarjeta abría con id AF; `analisis_completo` sólo entendía ESPN → "no encontrado" | ISS-010 resolver AF→ESPN fail-closed (rename+wrap); front cross-linkea espn_event_id | txn lab + prod post-verify | ✅ backend prod |
| FUT-LIVE-ESPN | crítico | FUT PRO en vivo | estado en vivo salía de API-Football (feed congelado ~23min) | autoridad de vivo = ESPN siempre; `liveRaw`/`liveSource`; poll 30s ESPN por espn_event_id | futCanonical.test (+3), real replay | ✅ dbb59a9 · **NEEDS_LIVE_CONFIRMATION** (usuario) |
| GOV-FAILCLOSED | crítico | 9 superficies de pick | "falta elegibilidad ≠ permiso" | `eligibilityGate` (isActionable) en Premium, PickDelDia, ParlayDelDia, Dashboard, Oraculo(Banner/Radar/Accion), MatchCard, AiProSection, PicksFutbolLimpio | eligibilityGate.test, failClosedReactivation.test | ✅ (sesión previa) |

Invariantes FUT PRO reconfirmados (141/141 tests, tsc limpio, build ok):
ONE_MATCH_ONE_CARD, ONE_COMPETITION_ONE_GROUP, MISSING=0, DUPLICATES=0,
CARDINALITY_PRESERVED, CLUB_BRUGGE, REAL_MADRID, AEK_LASK, DORTMUND, ambigüedad fail-closed.

---

## ROOT-CAUSED — resolución = ESPN (no se re-habilita AF por decisión de producto)

| ID | sev | superficie | causa raíz | resolución |
|---|---|---|---|---|
| AF-INGEST-FREEZE | alto | `live_scores` (tracker de parlays / RETO 13M live) | Ingesta EN VIVO de API-Football throttled/apagada para conservar cuota (`sync-live-5min` jobid 205 INACTIVA; `espejo-apifootball-live` corre pero no avanza las filas `af_`). Medido: filas AF age ~1401s vs ESPN 22s | FUT PRO ya NO depende de AF en vivo (usa ESPN). Follow-up: que los consumidores de `live_scores` (ParlayCard/tracker) prefieran la fila ESPN. **PREPARED_FOLLOWUP** (no desplegado) |

---

## ABIERTOS (confirmados, honestos — NO false PASS)

| ID | sev | superficie | hallazgo | acción propuesta | estado |
|---|---|---|---|---|---|
| ACT-ANALYSISTAB | **alto** | `components/reto/AnalysisTab.tsx:799` "PICKS INDIVIDUALES DEL DÍA" | `StakeButton` (Apostar en Stake) sobre picks con Conf/Momio/EV **sin** `eligibilityGate` → superficie actionable sin autoridad de modelo | gatear con `isActionable`/eligibilidad o degradar a informativo | **USER_FACING_HIGH_OPEN** — requiere verificar la fuente de `individualPicks` antes de gatear (no gatear a ciegas) |
| ACT-PARLAYCARD | medio | `components/reto/ParlayCard.tsx:998` | `StakeButton` por pata sobre el ticket **propio del usuario** (no recomendación del modelo) | decisión de producto: es la apuesta que el usuario ya eligió | **NEEDS_PRODUCT_DECISION** |

`ACTIONABLE_WITH_AUTHORITY_NONE = ≥1` (ACT-ANALYSISTAB). **No es 0.** No se declara cerrado.

---

## NO RE-AUDITADO EXHAUSTIVAMENTE EN ESTE PASE (declarado, no falseado)

- NFL / MLB / Champions semántica user-facing: cubiertos por el sweep fail-closed
  previo (gate en superficies de pick) y por E (UCL MODEL_STATUS=NOT_VALIDATED,
  mercados=null verificado en prod). No se re-recorrió cada string en esta pasada.
- Código legacy no renderizado (p.ej. `/ai-pro`→redirect a `/fut`): identificado
  parcialmente; no se removieron imports/rutas en este pase.
- Indicador de frescura "actualización retrasada": NO implementado (sería feature;
  FUT PRO ya usa ESPN fresco, no lo requiere).

---

## PENDIENTES DE CONFIRMACIÓN EN VIVO

- FUT-LIVE-ESPN: requiere que un partido AF/UCL en vivo muestre ≥2 actualizaciones
  (54'→58' o HT→2H o 1-0→1-1) a través de provider→DOM en producción, con el
  usuario autenticado. Hasta entonces: **NEEDS_LIVE_CONFIRMATION**, no PASS.
