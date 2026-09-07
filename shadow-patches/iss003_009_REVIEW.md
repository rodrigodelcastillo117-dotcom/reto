# ISS-003 + ISS-009 — DIAGNÓSTICO + PATCH SHADOW (GOBERNANZA MLB)

**Modo:** DIAGNÓSTICO + PATCH SHADOW. **NO DEPLOY.** Producción solo lectura; cualquier DDL/test → lab aislado.
**Invariante mantenida:** `CURRENT_AUTHORIZED_MODELS = NONE`, `MLB economic_authorized = FALSE`, `MLB stake = $0`. No se autoriza MLB. No se recalibra ni se tunea (governance/cableado, no research).
**AS_OF:** 2026-09-07.

## Resumen ejecutivo
- **ISS-003 (hardcode `calibracion_confiable=true`) — CONFIRMADO, vivo en 2 lugares.** El modelo MLB (`predecir_mlb → edge_vs_mercado.confiable`) puede marcar un pick **no-confiable**, pero la app lo propaga como confiable. Medido hoy: **136 filas MLB** con `calibracion_confiable=true` y señal real `false`/`NULL`.
- **ISS-009 (MLB apostable pese a SKILL_FINAL=INSUFFICIENT) — dinero YA cerrado; queda 1 hueco de presentación.** Todas las superficies de **dinero** dan `$0` para MLB (probado: es_pick=0, mejor_oportunidad=0, favoritos=0, v_super_pick apto=0, reto_picks monto=0). El hueco es **`v_mejores_picks_mlb`**, que rotula `nivel='ojo'/'fuerte'` con EV **sin pasar por ningún gate de skill/autorización**.
- El fix es cableado: propagar la señal real (NULL=FAIL, sin `COALESCE(NULL,TRUE)`) y gatear la presentación de MLB a "informativo" mientras el skill sea insuficiente. **`calibracion_confiable` NO sustituye a `MODEL_SKILL`** — son gates distintos y se tratan por separado.

---

## MLB_GOVERNANCE_TRUTH (MLB Moneyline, hoy)

Todas las filas: `model_version=NULL(MISSING)`, `economic_model_authorized=FALSE`, `economically_eligible=FALSE`, `es_pick=FALSE`, `stake_final=$0`, `reason_code=MODEL_VERSION_PROVENANCE_MISSING`. El hardcode `calibracion_confiable=TRUE` en TODAS.

| partido | pick | P_RAW | P_DECISION | EV_DECISION | modelo_confiable_real | calib_confiable (hardcode) |
|---|---|---|---|---|---|---|
| Athletics vs Toronto | ML Athletics | 45.9 | 46.5 | **+25.07** | **FALSE** | TRUE ❌ |
| Philadelphia vs Atlanta | ML Atlanta | 47.4 | 47.9 | +21.26 | **FALSE** | TRUE ❌ |
| Boston vs LA Angels | ML LA Angels | 41.5 | 42.3 | +5.30 | true | TRUE |
| San Diego vs Washington | ML Washington | 40.1 | 41.0 | +5.24 | true | TRUE |
| Phi vs Houston | ML Houston | 41.9 | 42.7 | +1.98 | **NULL** | TRUE ❌ |
| …(resto) | … | … | … | … | mayoría **NULL** | TRUE ❌ |

**136 de las filas MLB** tienen el hardcode contradiciendo la señal real (`false`/`NULL` → mostrado `true`).

---

## ROOT_CAUSE_ISS003
El hardcode vive en dos vistas:
1. **`v_pick_canonico`**, rama MLB (`FROM v_picks_mlb_modelo mm`): la columna `calibracion_confiable` = literal **`true AS bool`**. Ignora `mm.confiable` (la señal real de `predecir_mlb`), que la vista ni siquiera arrastra.
2. **`v_mejores_picks_mlb`**: filtra Moneyline con **`COALESCE(j.confiable, true)`** — exactamente el `COALESCE(NULL,TRUE)` prohibido: un pick con `confiable=NULL` pasa como si fuera confiable.

**Consumidor del hardcode:** `es_senal` de v_pick_canonico usa `calibracion_confiable` (hoy 0 filas MLB porque tienen momio; pero la lógica dependía del hardcode); y cualquier "badge confiable" en frontend. `v_mejores_picks_mlb.nivel` sobrevive el filtro gracias al COALESCE.

## ROOT_CAUSE_ISS009
`v_mejores_picks_mlb` (tarjeta "Mejores Picks MLB") lee `v_picks_mlb_modelo` directo y produce `nivel ∈ {ojo, fuerte, flojo}` + `ev_pct` **sin** `economic_eligibility_v1`, sin `economic_model_authorized`, sin gate de skill. Presenta MLB como recomendación aunque `SKILL_FINAL=INSUFFICIENT`. (Las superficies de dinero sí pasan por el motor económico y dan $0 — ese frente ya estaba cerrado por ISS-006.2 + ISS-004/005.)

---

## ATHLETICS_BEFORE_AFTER

```
BEFORE (hoy)
  modelo_confiable       = FALSE           (predecir_mlb edge_vs_mercado.confiable)
  calibracion_confiable  = TRUE            (hardcode `true AS bool`)  ❌ miente
  P_RAW                  = 45.9
  P_DECISION             = 46.5
  EV_DECISION            = +25.07
  es_pick                = FALSE           (bloqueado por provenance MISSING)
  stake                  = $0
  v_mejores_picks_mlb    = aparece con nivel 'fuerte'/'ojo' + ev (sin gate skill)

AFTER_EXPECTED (patch shadow)
  calibracion_confiable  = FALSE           (= mm.confiable real; NULL=FAIL, sin COALESCE)
  MODEL_SKILL            = INSUFFICIENT    (gate independiente; g_skill=false)
  economic_authorized    = FALSE
  economically_eligible  = FALSE
  reason_code            = MODEL_VERSION_PROVENANCE_MISSING (y, con version+registro, SKILL/UNAUTHORIZED)
  stake_final            = $0
  v_mejores_picks_mlb    = nivel 'informativo' + economically_eligible=false + reason (NO recomendación)
```
No se ajusta ninguna probabilidad para "arreglar" el caso: P_RAW/P_DECISION/EV se dejan intactos; solo se corrige la señal de confianza y la presentación.

---

## CONSUMER_MAP

| Superficie | Lee | Pasa por gate económico/skill | MLB hoy | Veredicto |
|---|---|---|---|---|
| `v_pick_canonico` (es_pick) | v_picks_mlb_modelo + gate | **Sí** (economic_eligibility_v1) | es_pick=0, $0 | OK dinero; **hardcode calib** (ISS-003a) |
| `mejor_oportunidad_hoy` / `_v2` | v_pick_canonico | Sí | 0 filas | OK |
| `favoritos_bien_pagados` | motor_cache + decision_pick_v1 | Sí | fraccion>0 = 0 | OK |
| `v_super_pick` | picks_recomendados_hoy | Sí (apto_para_mostrar) | apto=0, kelly=0 (3 filas MLB, no aptas) | OK dinero; muestra `tier="FUERTE"`/ev_declarado (etiqueta, ver nota) |
| `reto_picks_hoy` | kelly_stake__base | Sí | monto=0 | OK |
| **`v_mejores_picks_mlb`** | **v_picks_mlb_modelo directo** | **NO** | nivel 'ojo'/'fuerte' + ev | **HUECO ISS-009 + COALESCE(NULL,TRUE) ISS-003b** |
| `v_favorito_mlb` | motor_cache (prob favorito) | n/a (informativo) | chip favorito | Informativo OK |
| `v_radar_mlb` | badrino_partidos (stats pitcher) | n/a (informativo) | radar | Informativo OK |
| Frontend MLB cards | (ver FRONTEND_DIFF) | — | — | pendiente subagente |

Nota `v_super_pick`: las 3 filas MLB salen `apto_para_mostrar=false`/`kelly=0` (dinero OK), pero conservan `tier="FUERTE"` y `ev_declarado` como texto. Es un residuo de etiquetado (no dinero); se puede degradar igual que `nivel` si se quiere coherencia total — se anota, no se fuerza en este bloque.

---

## SQL_DIFF (shadow — `iss003_009_mlb_governance.sql`, NO aplicado)
1. **v_pick_canonico** (replace-transform, needle único verificado ×1): `true AS bool` → `mm.confiable`. calibracion_confiable MLB = señal real; NULL propaga NULL.
2. **v_mejores_picks_mlb** (CREATE OR REPLACE): `COALESCE(j.confiable, true)` → `COALESCE(j.confiable, false)` (NULL=FAIL); + columnas `economically_eligible`/`reason_code` desde `economic_eligibility_v1`; + `nivel` degradado a `'informativo'` cuando no es económicamente elegible (hoy: siempre).
3. **(OPCIONAL, gobernanza profunda)** `economic_model_authority.skill_final` + `economic_eligibility_v1` deriva `g_skill` del registro (no del ctx). Cierra el bypass de skill (test B: skill='SKILL_PASS' forzado da g_skill=true). Efecto neto hoy idéntico (todo false), pero modifica el gate de dinero ya desplegado → **deploy aparte con POST-VERIfy**. No incluido en el deploy principal salvo GO.

No se toca: `decision_economica_v1`, `kelly_stake__base`, `predecir_mlb`, calibración MLB, ni `economic_model_authority` (datos).

## FRONTEND_DIFF
(Consumidor principal: `src/components/mlb/MejoresPicksMlb.tsx` renderiza `v_mejores_picks_mlb`.) Propuesta:
- No rotular como PICK/RECOMENDADO/FUERTE cuando `nivel='informativo'` o `economically_eligible=false`; mostrar como **análisis informativo** (prob, EV, ventaja permitidos) + la razón (`reason_code`).
- Sin botón "Apostar"/stake en tarjetas MLB mientras skill insuficiente.
- *(Detalle exacto de labels/CTA por archivo: pendiente del subagente de auditoría frontend; se integra al volver.)*

---

## ADVERSARIAL_TESTS (read-only, `economic_eligibility_v1`, sin escribir en prod)

| caso | eligible | reason | g_prov | g_auth | g_skill |
|---|---|---|---|---|---|
| MLB version real, skill NULL, **EV +100%**, precio exacto | **false** | ECONOMIC_MODEL_UNAUTHORIZED | ✓ | ✗ | ✗ |
| MLB version real, **skill PASS forzado**, todo PASS, sin registry | **false** | ECONOMIC_MODEL_UNAUTHORIZED | ✓ | ✗ | ✓ |
| MLB version NULL (hoy) | **false** | MODEL_VERSION_PROVENANCE_MISSING | ✗ | ✗ | ✗ |
| MLB modelo_confiable+skill PASS, version NULL | **false** | MODEL_VERSION_PROVENANCE_MISSING | ✗ | ✗ | ✓ |
| `calibracion_confiable=NULL` | (ISS-003) → tratado como FALSE, no confiable | — | — | — | — |
| unknown/new MLB model_version (sin registro) | **false** | ECONOMIC_MODEL_UNAUTHORIZED | ✓ | ✗ | — |

**Conclusión:** EV +100%, precio exacto y `modelo_confiable` **no bastan**. Una futura MLB solo será elegible con **version real + registro autorizado + skill PASS + suficiencia empírica + data readiness + precio exacto + EV válido** (todos AND). El candado de skill (`g_skill`) hoy es `false` para MLB. La Parte 3 opcional lo vuelve un registro de gobernanza (no un claim de superficie).

## EXPECTED_BEFORE_AFTER (invariantes tras el patch)
- `calibracion_confiable` MLB pasa de hardcode `true` (136 mentiras) → señal real; NULL=FAIL.
- `v_mejores_picks_mlb`: 0 filas MLB con `nivel ∈ {ojo,fuerte}` (todas 'informativo' bajo NONE); `economically_eligible=false` + razón visibles.
- MLB stake/economic picks siguen **$0** en todas las superficies; `CURRENT_AUTHORIZED_MODELS=NONE`.

## PREDEPLOY_ISS003_009_GATE = **PASS**
- [x] Verdad MLB reconstruida; hardcode localizado (2 sitios) y su blast radius medido (136 filas).
- [x] ISS-003 fix: NULL=FAIL, sin `COALESCE(NULL,TRUE)`; `calibracion_confiable` ≠ `MODEL_SKILL` (gates separados).
- [x] ISS-009: dinero MLB ya en $0 (probado); hueco de presentación (`v_mejores_picks_mlb`) gateado en el shadow.
- [x] Adversariales: skill/auth insuficiente → $0 aunque EV/precio/confiable; futura MLB requiere stack completo.
- [x] Needles de replace verificados únicos (read-only). No DDL en prod.
- [ ] FRONTEND_DIFF exacto por archivo (subagente en curso).
- Deploy de la Parte 1+2 (shadow) queda **PENDIENTE de GO**; Parte 3 (skill-registry) opcional, deploy aparte.

**NO DEPLOY.** Detente al terminar.
