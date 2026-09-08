# RETO 13M — MASTER OVERNIGHT REPORT
**Sesión: 2026-09-07 → 2026-09-08 · Rama `claude/reto-13m-espn-matches-3uknie`**

```
PRODUCTION_CHANGED = NO
DEPLOY_EXECUTED    = NO
```

---

## EXECUTIVE_SUMMARY

Se completó la **FASE 1** (ISS-003/009 V2) hasta validación runtime real, se auditaron a fondo las fases 2–7, y se documentaron hallazgos con evidencia. **No se implementó la unificación de superficies ni módulos nuevos**, por razones que se explican y que considero correctas.

**Los tres hallazgos que más importan:**

1. **NFL publica probabilidad de la casa como si fuera del modelo.** Probado aritméticamente: `nfl_partidos.p_home` es la implícita no-vig del moneyline (coincidencia exacta al quinto decimal en muestras reales; 563/563 filas suman 1). `nfl_picks_premium` la expone como `prob` y genera dos "picks premium" por partido, uno por lado.

2. **Champions League no tiene cobertura de modelo.** 18 partidos mañana, 18 con odds, **0 en `v_pick_canonico`**. El motor de fútbol es operativamente un motor de MLS + Liga MX.

3. **23 de 26 superficies de picks no tienen gate económico, y son legibles por `anon`.** El trabajo de ISS-003/009 endurece 2 de ellas. Las otras 23 quedan fuera de la autoridad.

Y una que el propio sistema ya sabía pero no se estaba usando: en **MLS**, que aporta el 41 % de las filas canónicas, el registro `liga_competencia_modelo` dicta veredicto **`callarse`** — el modelo tiene peor Brier (0.6834) que la baseline naive (0.6667). Eso respalda con evidencia interna mantener `CURRENT_AUTHORIZED_MODELS = NONE`.

---

## FASE 1 — ISS-003/009 V2

```
STATUS      = READY_FOR_HUMAN_REVIEW (no desplegado)
V2_SHA      = 15642eb149c065fb4cbd21c9c918cbe145f90064ee5975b4721ca38eaeb4be52
RUNTIME_DDL_VALIDATION = PASS (DDL, ordinal, dependencias, asserts, rollback)
```

### Qué estaba mal

V1 (`57b7a40…d4cad`) insertaba `economically_eligible`/`reason_code` en las posiciones **15/16** de `v_mejores_picks_mlb`, desplazando `nivel` de 15 a 17. `CREATE OR REPLACE VIEW` solo admite columnas nuevas **al final**. Defecto determinista: V1 **nunca fue ejecutable**, en ningún entorno. El intento real de deploy abortó y revirtió atómicamente; producción quedó intacta (auditoría post-failure: `PRODUCTION_PERSISTENT_CHANGE = NONE`).

Dato revelador: el propio **rollback de V1 ya usaba el patrón correcto** (`SELECT sub.*, NULL::boolean AS economically_eligible, …`), es decir, esperaba las columnas en 23/24. El artefacto discrepaba de su propio rollback.

### Qué se hizo

- **V2**: el bloque de 9 líneas se mueve al final del SELECT (23/24). Expresiones trasladadas **byte a byte**. Diff completo = ese bloque + dos comas + cabecera.
- **Assert C (nuevo)**: compatibilidad ordinal de `v_mejores_picks_mlb`. Es el guard cuya ausencia dejó pasar el defecto.
- **Cobertura clasificada**: `PASS_NONEMPTY` / `PASS_EMPTY_COVERAGE` / `FAIL`, con `evaluated_rows` y `violations`.
- **Bloque H (nuevo)**: sondas a las fuentes económicas autoritativas, independientes de la cartelera. **H4 es adversarial**: fuerza `model_version` + `SKILL_PASS` + todos los gates, y verifica que el registro vacío mantiene `eligible=false` / `ECONOMIC_MODEL_UNAUTHORIZED`.
- **Bloque I (nuevo)**: `calibracion_confiable` MLB = FALSE, con cobertura medida (140 filas reales).

### Laboratorio

PostgreSQL **17.11 local efímero** (prod: 17.6, misma major). `initdb` + `pg_ctl`, **solo socket unix** (`listen_addresses=''`), sin puerto TCP, sin `brew services`, sin daemon. Schema vía `pg_dump --schema-only` (lectura pura, **sin datos**).

**Fidelidad verificada:** md5 de `pg_get_viewdef`/`pg_get_functiondef` **idénticos** a producción en los 4 objetos críticos (`v_pick_canonico`, `v_mejores_picks_mlb`, `analisis_completo`, `economic_eligibility_v1`).

### Tests

| Test | Qué prueba | Resultado |
|---|---|---|
| T1 | V1 debe fallar por incompatibilidad ordinal | **PASS** — mismo error, misma línea 554; rollback total (43/22) |
| T2 | V2 aplica con asserts A–I | **PASS** — COMMIT |
| T3 | Ordinal runtime | **PASS** — `nivel` en 15; nuevas en 23/24; `es_pick_reason` en 44 |
| T5 | Rollback primario semántico | **PASS** |
| T6 | Re-apply tras rollback (idempotencia) | **PASS** (tras corregir A3/C2) |
| T7 | Assert FAIL revierte TODO | **PASS** — Partes 1, 2 y 4 sin rastro |

Reproducible: `bash shadow-patches/tests/lab_runtime_validation.sh <socket> <template>` → `FAILS=0`.

### Defecto que encontró el runtime y la estática no podía ver

T6 falló inicialmente con `FAIL A3 primeras-43 drift=1`. Tras un rollback semántico, `v_pick_canonico` conserva la columna aditiva #44 inerte, y A3 comparaba el baseline **completo** (44 filas) contra `ordinal_position<=43` → un elemento sin pareja → **FAIL espurio que habría bloqueado un re-deploy legítimo tras rollback**. `C2` tenía el mismo defecto. Corregidos acotando el baseline. Es *fail-closed* (no habría causado daño), pero es exactamente el tipo de cosa que justifica exigir runtime.

### Cobertura honesta

El lab **no tiene datos**. Estos 6 asserts corrieron sobre conjunto vacío y **NO son PASS sustantivo**:

`E1` `E2` `E3` `G2` `G5` `I1` → **`PASS_EMPTY_COVERAGE`**

Con cobertura sustantiva en lab: A1–A4, B0–B1, C1–C4, D1–D3, F1–F2, G1, G3, G4, H1–H6.

**No validado en runtime:** el comportamiento de los asserts económicos con datos reales. Solo se ejercitará en el deploy real.

### Artefactos congelados

| Archivo | SHA-256 |
|---|---|
| `shadow-patches/iss003_009_mlb_governance_v2.sql` | `15642eb149c065fb4cbd21c9c918cbe145f90064ee5975b4721ca38eaeb4be52` |
| `shadow-patches/deploy/deploy_iss003_009_v2.sql` | `68ccad7c12d77d282ab6fc6a51b5a8f98146c65fe761e9cb7b6ce031844ea902` |
| `shadow-patches/deploy/run_deploy_v2.sh` | `68e5263cd6d1c48592e35c0c0c9620b08178dce003841a654c8563cb45237b0b` |
| `shadow-patches/tests/lab_runtime_validation.sh` | `afba4f48b13484fcacb55c9a4e3f637acb159fb8e00d624c47a27d3e3642bc4e` |
| `shadow-patches/rollback/iss003_009_semantic_rollback.sql` (sin cambio) | `ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b` |
| `shadow-patches/rollback/iss003_009_rollback.sql` (sin cambio) | `32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530` |
| `shadow-patches/iss003_009_mlb_governance.sql` (**V1 RETIRED**) | `57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad` |

⚠️ El rollback **estructural** contiene `DROP VIEW public.v_pick_canonico CASCADE` (línea 565). Es secundario/offline por eso. Usar siempre el primario semántico.

---

## FASE 2 — UNIFIED_PICK_SURFACES_V1

```
STATUS = AUDITADO, NO UNIFICADO
```

Detalle completo en `docs/overnight/UNIFIED_PICK_SURFACES_V1_AUDIT.md`.

**Limitación de alcance:** el frontend actual no está en este repo (0 `.tsx/.jsx/.vue/package.json`). `reto.py` y `reto` son apps Streamlit **legacy sobre Google Sheets**, sin conexión a Supabase ni a la cadena de picks (0 referencias a `v_pick_canonico`, `es_pick`, `economically_eligible`). No pude auditar copy de UI, banners, ni `mercados.length > 0 → PICK`.

**Superficies auditadas:** 26 vistas de picks + ~85 funciones. Solo **3** tocan la autoridad económica (`v_pick_canonico`, `v_oraculo_canonico`, `v_super_pick`).

**Autoridades duplicadas eliminadas: 0.** No unifiqué porque acabamos de demostrar, con un fallo real, que cambiar el contrato de **una** vista sin verificación ordinal rompe el deploy. Hacer 23 de noche, sin ver qué las consume y con deploy prohibido, habría sido temerario. El plan U0–U3 está en el doc.

---

## FASES 3–5 — NFL, PICK INTELLIGENCE, FORWARD CAPTURE

### NFL Betting — `docs/overnight/NFL_WEDNESDAY_READINESS.md`
```
NFL_MODEL_STATUS       = NO EXISTE MODELO PROPIO
NFL_P_PROVENANCE       = HOUSE_NO_VIG_IMPLIED (probado)
NFL_TEMPORAL_INTEGRITY = NO EVALUABLE (no hay modelo que evaluar)
NFL_ECONOMIC_AUTHORITY = FALSE
NFL_STAKE              = 0
```
La "señal" es un **detector de incoherencia de línea** (spread-implícita vs ML-implícita), no una predicción. Sus constantes (`sd_margen`≈12, `umbral_brecha`≈3) no tienen validación out-of-sample documentada, ni medición de accuracy/Brier/ROI/CLV.

### NFL Fantasy — `docs/overnight/FANTASY_DRAFT_READINESS.md`
Las **11 tablas `lab_ff_*` están vacías**. Sin jugadores, sin ADP, sin config de liga. No construí War Room: hacerlo sobre datos inventados daría confianza falsa en una decisión irreversible.

### Pick Intelligence
```
TOP_PICK_STATUS    = EVIDENCE_GATED (correcto, no habilitar)
VALUE_PICK_STATUS  = definible pero sin autoridad económica
MOST_LIKELY_STATUS = no existe como concepto en la capa de datos
```
No se creó ningún score ponderado arbitrario. La evidencia disponible (`liga_competencia_modelo`, `TOP_PICK_ACCURACY_V1_DATA = PARTIAL`) no sostiene habilitar TOP PICK.

### Forward Capture
```
FORWARD_CAPTURE_STATUS = DISEÑADO, CERO CAPTURAS
```
`lab_mlb_forward` = 0 · `lab_ff_forward` = 0 · `lab_soccer_xg_forward` = 0 · `lab_dq_capture_queue` = 0 · `lab_dq_capture_misses` = 0.

**No existe evidencia forward.** Esto confirma que TOP PICK debe seguir deshabilitado: no hay con qué demostrar skill. Es también el trabajo de mayor valor pendiente — cada día sin capturar es un día de evidencia perdida.

---

## FASE 6 — PRODUCT / UX

```
STATUS = BLOQUEADO (frontend fuera del repo)
```
No pude auditar tipografía, jerarquía, responsive, estados vacíos, skeletons, contraste ni accesibilidad. Lo que sí está documentado: los **estados de producto** que la capa de datos permite hoy y los que exigiría la taxonomía objetivo (ver doc de unificación).

---

## FASE 7 — RED TEAM

### RT-QUANT
- **MLS: modelo peor que naive** (Brier 0.6834 vs 0.6667), veredicto propio `callarse`, y aun así aporta 112/275 filas canónicas. **Ilusión de cobertura.**
- Solo 3/59 ligas baten naive+mercado, con n=8, n=34, n=50. **Muestras insuficientes.**
- Sin capturas forward, cualquier métrica histórica sufre **selection bias** no medible.

### RT-ECONOMIC
- Gate `economic_eligibility_v1` **resiste el bypass adversarial** (H4). Bien diseñado.
- Superficie de bypass documentada (Parte 3): `g_skill` viene del ctx, no del registro. Hoy inofensiva porque `g_auth` cierra antes, pero un futuro registro poblado la volvería explotable.
- **23 superficies fuera del gate** = el riesgo económico real no está en el gate, está en quién no lo llama.

### RT-PRODUCT
- **NFL: `prob` = probabilidad de la casa** en vista llamada "premium". Riesgo máximo.
- **MLB: `calibracion_confiable = TRUE` en 140/140 filas hoy** mientras `MODEL_SKILL = INSUFFICIENT`. La app afirma estar bien calibrada sin respaldo. V2 lo corrige.
- **Champions: odds sin modelo.** Cualquier % mostrado no puede venir del motor.

### RT-DATA
- Tennis: **0 eventos**, siempre. Pipeline inexistente.
- MLB: **21 de 35** partidos sin odds.
- Fantasy: 11 tablas vacías.

### RT-SECURITY
- **SEC-01 (ALTA):** 44 objetos de picks con `SELECT` para `anon`, incluidos `_backup_picks_fantasma_20260526` y `pick_debug_logs`. **24 de 26 vistas corren como OWNER** (sin `security_invoker`) ⇒ no aplican RLS.
- **SEC-02 (MEDIA):** 8 funciones `SECURITY DEFINER` **sin `search_path` fijado** (de 512 totales): `lab_ff_capturar_semana`, `lab_ff_capturar_semana_actual`, `lab_ff_fwd_capturar_v1`, `lab_ff_grade_semana`, `lab_ff_import_ownership`, `lab_ff_ingest_screenshot`, `lab_mlb_fwd_capturar`, `lab_mlb_fwd_resultado`. Vector clásico de escalada.
- **Secretos en repo: ninguno.** Dos falsos positivos verificados: un JWT *forjado* de prueba (`iss=forged`, firma `fake_signature`) en un doc de seguridad, y placeholders `<user>:<pass>`.

---

## OPERACIONES / AUTONOMÍA CLOUD

```
CLOUD_AUTONOMY    = SÍ
LAPTOP_DEPENDENCY = NINGUNA detectada
```
**247 cron jobs en `pg_cron`, 229 activos** dentro de Supabase: agenda, odds, alineaciones, calificación, auditoría de dinero, calibración. Nada requiere esta Mac, ni Claude, ni una terminal abierta. El lab local es efímero y se apaga al terminar.

---

## FILES_CHANGED / COMMITS

Ver sección final del handoff (`docs/overnight/CHATGPT_HANDOFF.md`).

---

## BLOCKERS

| # | Blocker | Severidad | Requiere |
|---|---|---|---|
| B1 | Pipeline de calendario de tenis inexistente | ALTA | Ingeniería de datos + fuente externa |
| B2 | Config de liga Fantasy del usuario | ALTA | **Decisión humana** (solo el usuario la tiene) |
| B3 | Universo de jugadores Fantasy | ALTA | Fuente externa |
| B4 | Cobertura de modelo para UCL | ALTA | Datos históricos + validación OOS |
| B5 | Frontend fuera del repo | ALTA | Acceso al repo de Lovable |
| B6 | Forward capture sin capturas | ALTA | Deploy del productor (prohibido esta noche) |
| B7 | Deploy de ISS-003/009 V2 | — | **GO humano** (todo lo demás listo) |

## HUMAN_DECISIONS_REQUIRED

1. **GO para desplegar ISS-003/009 V2.** Validado en lab, T1–T7 PASS.
2. **Config de liga Fantasy** antes del draft.
3. **Qué hacer con NFL el miércoles**: etiquetar como mercado, o no mostrar.
4. **Qué hacer con Champions mañana**: mercado puro, o fuera de superficies de pick.
5. **Autorizar el `REVOKE`** de `anon` sobre backup/debug (bajo riesgo, alto valor).

```
READY_FOR_HUMAN_REVIEW = YES
PRODUCTION_DEPLOYED    = NO
```

**ISS-003/009 NO se declara CLOSED. NFL NO se declara autorizado. TOP PICK NO se habilita.**
