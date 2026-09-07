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

---

# CORRECCIONES POST-REVISIÓN (2026-09-07) — supersede lo anterior donde aplique

`PREDEPLOY_ISS003_009_GATE = PENDING` (reabierto por el auditor). Se cierran 2 puntos y se amplía el mapa de consumidores.

## MLB_CONFIABLE_SEMANTICS = **EDGE_RELIABILITY**
Probado en `predecir_mlb` (verbatim): `'confiable', brecha <= BRECHA_ALERTA`, con `brecha = |prob_modelo − prob_mercado|` (`brecha_pp`). El aviso al superar el umbral lo dice literal: *"El modelo y el mercado no se parecen: X puntos… NO es una oportunidad, es una señal de que al modelo le falta información. No apostar la línea de ganador."*
→ `v_picks_mlb_modelo.confiable` es **fiabilidad del edge (divergencia modelo-vs-mercado)**, **NO** confianza de calibración. (Además existe `predecir_mlb.calibrado = v_en_rango` = "la prob cae en el tramo medido" — es data-readiness, tampoco "calibración confiable"; y aun en rango el skill MLB es negativo, #191.)

## RETRACTACIÓN (ISS-003a)
Mi primera propuesta mapeaba `mm.confiable → calibracion_confiable`. **Incorrecto**: sería renombrar EDGE_RELIABILITY como CALIBRATION_CONFIDENCE para pasar un gate — justo el patrón que originó estos bugs. Corrección:
- **`calibracion_confiable` MLB = FALSE (fail-closed)** — MLB no tiene fuente real de confianza de calibración y su skill es negativo. (Shadow Parte 1: `true AS bool` → `false`, ya corregido en el .sql.)
- **`modelo_confiable`/`edge_confiable` = `mm.confiable`** se conserva donde ya se usa como edge (`v_mejores_picks_mlb`, `predecir_mlb`/`PronosticoMlbModelo`). NO se pierde la señal; NO va a `calibracion_confiable`. (Si se quiere exponer en `v_pick_canonico`, sería columna nueva additiva — opcional, no forzada.)

## RECHAZO ACEPTADO — skill NO va al registry
Se retira la Parte 3 (skill_final dentro de `economic_model_authority`). `ECONOMIC_MODEL_AUTHORIZED` ("permiso administrativo para mover dinero") ≠ `MODEL_SKILL` ("capacidad predictiva demostrada"). Quedan como gates **independientes**. MLB sigue bloqueado por **dos razones separadas**: `MODEL_SKILL=INSUFFICIENT` **y** `ECONOMIC_MODEL_AUTHORIZED=FALSE`. La fuente autoritativa de skill es un asunto aparte (hoy: MLB=INSUFFICIENT por #191; el gate falla fail-closed cuando el ctx no trae `SKILL_PASS`). No se fusiona con el registry.

## CONSUMER_MAP — ampliado con auditoría frontend (verdicts por superficie)
| Superficie | Fuente | Presenta MLB como | Gate | Veredicto ISS-009 |
|---|---|---|---|---|
| `/mlb` `MejoresPicksMlb.tsx` | `v_mejores_picks_mlb` (nivel) | VALOR/EV, framing "no es quién gana" | nivel de la vista | **INFORMATIONAL** pero `nivel` fuerte/ojo = lenguaje de recomendación → shadow lo degrada a 'informativo' |
| `/mlb` `PronosticoMlbModelo.tsx` | RPC `predecir_mlb` | texto "✅ QUÉ HARÍA: <team> ML" | `edge.confiable`/aviso (propio) | recomendación textual, sin dinero/botón; gateado por edge — aceptable como análisis, pero relabelar |
| **Dossier `AnalisisCompletoModal`** | RPC **`analisis_completo`** | **"🎯 PICK SUGERIDO POR EL MOTOR UNIFICADO"** | **ninguno económico** | **GAP**: Athletics ML **+23.5% EV** mostrado como PICK SUGERIDO aunque su `zona.peor_que_volado=true`. Además dispara para CUALQUIER deporte con `mercados` no-vacío (residuo general bajo NONE). |
| `/reto-13m` `Reto13M.tsx` | RPC `reto_picks_hoy` | `ApostarButton` + Monto | `puede_apostar` (backend) | SAFE hoy: MLB `monto=0`/`puede_apostar=false` (verificado). Depende de `bloqueado_por='sin_modelo'`. |
| `/hoy` `DestacadoCard` | RPC `destacados_del_dia` | "Agregar a canasta" | `estable` (backend) | SAFE hoy: **0 MLB** en destacados. Camino existe. |
| `PicksSeguroValorCards`/`AnalysisTab` | edge fn `obtener-picks-seguro-valor` | ApostarButton + BET/ÉLITE | edge fn `ok` | Huérfano (no ruteado). Riesgo latente si se monta. |
| `v_favorito_mlb`, `v_radar_mlb`, `MLBDeepStatsSection` | motor_cache/badrino | chip favorito / stats | n/a | INFORMATIONAL OK |

**Conclusión frontend:** la página `/mlb` dedicada es informativa (sin botón de apuesta). Los gaps ISS-009 reales están en RPCs backend: **`analisis_completo` (dossier "PICK SUGERIDO")** es el principal, no gateado por elegibilidad económica; `reto_picks_hoy`/`destacados_del_dia` ya están gateados (MLB $0/ausente hoy). El frontend renderiza lo que devuelven esos RPCs → **el gate debe ir en el backend**.

## SQL_DIFF (corregido/ampliado — shadow, NO aplicado)
1. **v_pick_canonico**: `true AS bool` → `false` (calibracion_confiable MLB fail-closed). ✅ corregido.
2. **v_mejores_picks_mlb**: `COALESCE(j.confiable, true)` → `COALESCE(j.confiable, false)` (aquí `confiable`=edge, uso semánticamente correcto, NULL=FAIL); + `economically_eligible`/`reason_code`; + `nivel`→'informativo' cuando no elegible.
3. **`analisis_completo` (NUEVO, requiere scoping)**: el resumen `1_el_resumen.mercados` debe marcar por-mercado `economically_eligible` y el banner sólo decir "PICK SUGERIDO" cuando sea elegible; si no → "ANÁLISIS — NO APUESTA AUTORIZADA". Afecta a todos los deportes (bajo NONE, todos informativos), no sólo MLB. Es función grande (~21KB) → **pendiente de scoping antes de proponer diff byte-exacto**.
4. Skill al registry: **RETIRADO**.

## FRONTEND_DIFF
- `MejoresPicksMlb.tsx`: mostrar rótulo inequívoco **"ANÁLISIS MLB — NO APUESTA AUTORIZADA"**, mostrar `economically_eligible=false`/`reason_code`, y no usar 'fuerte'/'ojo' como recomendación (consumir `nivel='informativo'` de la vista parcheada).
- `AnalisisCompletoModal.tsx` (`BannerPickCanonico`): no pintar "🎯 PICK SUGERIDO" para mercados con `economically_eligible=false`; mostrar el banner informativo + razón. (Depende del fix backend #3.)
- `PronosticoMlbModelo.tsx`: mantener como análisis; asegurar que "QUÉ HARÍA: … ML" no lea como apuesta autorizada (añadir "análisis, no apuesta autorizada").
- `Reto13M.tsx`/`Hoy.tsx`: ya gateados por backend; sin cambio salvo mantener `bloqueado_por='sin_modelo'` visible para MLB.
- No introducir lenguaje económico (PICK/FUERTE/OJO/ELITE/APOSTAR/% banca) en ninguna superficie MLB mientras `MODEL_SKILL != PASS`.

## ATHLETICS_BEFORE_AFTER (corregido)
```
BEFORE (hoy)
  modelo_confiable (edge)  = FALSE
  calibracion_confiable    = TRUE     (hardcode)               ❌
  P_RAW=45.9  P_DECISION=46.5  EV_DECISION=+25.07 (sin tocar)
  dossier                  = "🎯 PICK SUGERIDO" ML Athletics +23.5% (peor_que_volado=true) ❌
  es_pick=false  stake=$0

AFTER_EXPECTED
  modelo_confiable (edge)  = FALSE     (conservado como edge_confiable)
  calibracion_confiable    = FALSE     (fail-closed; NO = mm.confiable)
  MODEL_SKILL              = INSUFFICIENT
  economic_authorized      = FALSE
  economically_eligible    = FALSE
  reason_code              = MODEL_VERSION_PROVENANCE_MISSING (y SKILL/UNAUTHORIZED con version+registro)
  dossier                  = "ANÁLISIS — NO APUESTA AUTORIZADA" (no PICK SUGERIDO)
  stake_final              = $0
```
P/EV intactos; el bloqueo viene de gobernanza/evidencia, no de tocar probabilidades.

## ESTADO
```
ROOT_CAUSE_ISS003 = CONFIRMED
ROOT_CAUSE_ISS009 = CONFIRMED
MLB_MONEY_GATE    = SAFE
MLB_CONFIABLE_SEMANTICS = EDGE_RELIABILITY
FRONTEND_DIFF     = ENTREGADO (arriba)
PENDIENTE para PASS: scoping/diff byte-exacto de analisis_completo (dossier "PICK SUGERIDO")
PREDEPLOY_ISS003_009_GATE = PENDING
```
NO DEPLOY.

---

# ISS-009B — analisis_completo (dossier "PICK SUGERIDO") — scoped

## ISS009B_CONSUMER_TRACE
```
RPC analisis_completo(p_event)
  └─ arma `jmkt`  (SELECT jsonb_agg(jsonb_build_object('mercado',c.mercado,'pick',c.pick_nombre,
        'momio_justo',...,'momio_casa',coalesce(vv.m,c.momio_mercado),'casa',...,'ev_pct',<raw>,
        'como_se_calculo',c.razon) ORDER BY c.probabilidad_pct DESC) INTO jmkt
        FROM v_pick_canonico c  LEFT JOIN LATERAL (odds_espn vivo) vv)   ← provenance = v_pick_canonico
  └─ '1_el_resumen' := coalesce(s1,'{}') || jsonb_build_object('mercados', jmkt)
→ payload.1_el_resumen.mercados
→ AnalisisCompletoModal.SeccionResumen → BannerPickCanonico(mercados)
→ condición del banner: `mercados.length > 0` → "🎯 PICK SUGERIDO POR EL MOTOR UNIFICADO"
                        (si vacío → "SIN RECOMENDACIÓN DE DINERO")
```
Campos de identidad/provenance en jmkt: `pick` (c.pick_nombre), `mercado` (c.mercado), `casa`/`momio_casa` (odds_espn vivo o c.momio_mercado), `probabilidad_pct`, `ev_pct` (raw), `como_se_calculo` (c.razon). **Fuente = `v_pick_canonico c`, unida por `espn_event_id`+`pick` — trae `c.es_pick` (gate canónico). Provenance SUFICIENTE; no se inventan joins.**

## EXACT_ROOT_CAUSE
`mercados.length > 0` significa **"hay información de mercado"**, no **"hay apuesta recomendada"**. `jmkt` incluye TODOS los mercados de `v_pick_canonico` para el evento sin propagar `c.es_pick`, y el frontend enciende el banner de recomendación con la mera existencia de filas. El gate económico canónico (es_pick) está a un `c.` de distancia pero se descarta.

## MINIMAL_BACKEND_DIFF (shadow, Parte 4 del .sql)
Insert en el fragmento `jmkt` (anchor único `'como_se_calculo', c.razon`, verificado ×1; `c.es_pick` hoy 0 usos):
```
+ 'economically_eligible', c.es_pick, 'stake_final', 0,
```
Reusa el gate canónico (c.es_pick de v_pick_canonico). No recomputa P/EV, no inventa joins, no reescribe la función. `reason_code` (opcional, no-duplicante): exponer `reason_code` desde v_pick_canonico (misma llamada a economic_eligibility_v1 que ya calcula es_pick) y añadir `'reason_code', c.reason_code`.

## MINIMAL_FRONTEND_DIFF
`AnalisisCompletoModal` / `BannerPickCanonico`: la condición pasa de `mercados.length > 0` a
`mercados.some(m => m.economically_eligible === true)`. Mercados con `economically_eligible=false`
se renderizan bajo **"ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"** (prob, EV, matchup visibles;
sin "PICK SUGERIDO", sin stake). La gobernanza NO se recomputa en el frontend: sólo lee el flag server-side.

## ATHLETICS_BEFORE_AFTER (dossier)
```
BEFORE:  banner = "🎯 PICK SUGERIDO POR EL MOTOR UNIFICADO"
         incluye ML Athletics  ev_pct=+23.5  momio 2.69 (DraftKings)  (zona.peor_que_volado=true)
AFTER :  jmkt: cada mercado con economically_eligible=false, stake_final=0
         banner = "ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"
         EV/prob/matchup siguen visibles; ML Athletics NO como PICK SUGERIDO
         (P/EV intactos; bloqueo por gobernanza)
```

## CROSS_SPORT_TEST_MATRIX (read-only, hoy, NONE)
| caso | evidencia | resultado esperado tras fix |
|---|---|---|
| soccer no autorizado + EV+ | v_pick_canonico soccer: 69 filas, es_pick=0 | informativo (0 PICK SUGERIDO) |
| MLB skill insuf + EV+ | v_pick_canonico MLB: 44 filas, es_pick=0 | informativo |
| unknown model_version + EV+ | economic_eligibility_v1 → UNAUTHORIZED/MISSING | informativo |
| eligible=false + mercados>0 | Athletics dossier 4 mercados, es_pick=0 | NO PICK SUGERIDO |
| eligible=true (fixture controlado) | **fuera de producción** (rollback lab): autorizar versión + skill PASS → es_pick=true | permite wording de recomendación |
Global hoy: `PICK_SUGERIDO_COUNT = 0`, `ECONOMIC_RECOMMENDATION_LABELS = 0` en TODOS los deportes.

## ESTADO FINAL
```
ISS003_SEMANTICS               = PASS   (EDGE_RELIABILITY; calibracion_confiable=FALSE fail-closed; edge_confiable=mm.confiable)
ISS009A_MLB_GOVERNANCE         = PASS   (dinero MLB $0; v_mejores_picks_mlb gateado + COALESCE(...,false))
ISS009B_GLOBAL_PRESENTATION_GATE = PASS (dossier: economically_eligible=c.es_pick; banner gateado; 0 PICK SUGERIDO bajo NONE, todos los deportes)
PREDEPLOY_ISS003_009_GATE      = PASS
CURRENT_AUTHORIZED_MODELS = NONE · MLB economic_authorized = FALSE · MLB stake = $0
```
Invariante global cableado (server-side): `ECONOMICALLY_ELIGIBLE=false → jamás PICK SUGERIDO/APOSTAR/ELITE/FUERTE/% BANCA/stake`, independiente del deporte. **NO DEPLOY.** Producción sólo lectura; el fixture eligible=true se prueba en lab aislado con rollback.
