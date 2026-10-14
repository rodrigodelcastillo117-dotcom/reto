# RETO 13M — HANDOFF PARA REVISIÓN INDEPENDIENTE
Sesión autónoma 2026-09-07 → 2026-09-08 · Rama `claude/reto-13m-espn-matches-3uknie`

===== MORNING SPORTS READINESS =====

CHAMPIONS_READY = 🔴 NO como análisis de modelo · 🟡 SÍ como información de mercado etiquetada
CHAMPIONS_BLOCKERS = 18 partidos UCL con odds pero 0 cobertura de modelo (0 filas en v_pick_canonico, 0 en v_picks_futbol_calibrado). UCL no registrada en liga_competencia_modelo. El motor de fútbol cubre MLS + Liga MX.

MLB_READY = 🟡 SÍ como motor de análisis, fail-closed económicamente
MLB_BLOCKERS = (1) calibracion_confiable=TRUE en 140/140 filas MLB hoy mientras MODEL_SKILL=INSUFFICIENT: la app afirma "bien calibrado" sin respaldo, y solo lo corrige el deploy de ISS-003/009 V2. (2) 21 de 35 partidos sin odds. (3) Riesgos temporales (latest-snapshot leakage, timestamp de pitcher) NO verificados.

TENNIS_READY = 🔴 NO
TENNIS_BLOCKERS = agenda_espn no contiene ni un solo evento de tenis, ni histórico. Solo existe scaffolding de linescore en vivo. Sin calendario no hay cadena.

FANTASY_DRAFT_READY = 🔴 NO
FANTASY_DRAFT_BLOCKERS = las 11 tablas lab_ff_* están vacías (0 jugadores, 0 ADP). lab_ff_sync_contract vacía: no consta scoring, roster slots, nº equipos, tipo de draft, posición de pick ni keepers. Requiere decisión humana.

NFL_WEDNESDAY_READY = 🔴 NO como picks · 🟡 SÍ como mercado etiquetado
NFL_BLOCKERS = p_home es probabilidad no-vig de la casa publicada como `prob` en nfl_picks_premium; cada partido genera dos "picks premium" (uno por lado). No existe modelo NFL propio.

CLOUD_AUTONOMY = SÍ — 247 cron jobs en pg_cron (229 activos) dentro de Supabase
LAPTOP_DEPENDENCY = NINGUNA detectada. El lab local es efímero y se apaga al terminar.

WHAT_CAN_BE_USED_TOMORROW =
  · MLB como motor de análisis informativo (con la salvedad del "bien calibrado" falso hasta desplegar V2)
  · MLS y Liga MX como análisis (con la salvedad de que MLS tiene veredicto propio `callarse`)
  · Champions, MLB y NFL como información de mercado SI y SOLO SI cada porcentaje va etiquetado como probabilidad de la casa

WHAT_MUST_NOT_BE_USED =
  · Cualquier % de Champions presentado como predicción del modelo (no existe)
  · Cualquier % de NFL presentado como predicción del modelo (es la casa)
  · nfl_picks_premium como superficie de "picks premium"
  · Tennis (sin pipeline)
  · Fantasy Draft War Room (sin datos ni config)
  · TOP PICK (sin evidencia forward: las tablas de captura están a 0)

HIGHEST_PRIORITY_MORNING_ACTION =
  Desplegar ISS-003/009 V2 (validado en lab, T1–T7 PASS, GO humano pendiente).
  Es lo único que elimina el "bien calibrado" falso sobre 140 filas MLB y degrada
  las filas ojo/fuerte a informativo. Inmediatamente después: verificar en la UI
  que ningún % de Champions o NFL se presente como predicción propia.

===== END MORNING SPORTS READINESS =====

---

## 1. QUÉ ENCONTRASTE

**Punto de partida.** Un intento previo de desplegar ISS-003/009 abortó en producción. Se verificó read-only que no dejó cambios persistentes.

**Causa raíz del fallo.** V1 insertaba dos columnas nuevas en medio del SELECT de `v_mejores_picks_mlb`, desplazando `nivel` de la posición 15 a la 17. PostgreSQL solo admite columnas nuevas al final en `CREATE OR REPLACE VIEW`. Defecto determinista: V1 nunca fue ejecutable. Detalle revelador: el rollback de V1 ya usaba el patrón correcto (columnas al final), es decir, **el artefacto discrepaba de su propio rollback**.

**Hallazgos nuevos de la auditoría:**

1. **NFL publica probabilidad de la casa como `prob`.** Probado aritméticamente (ver §14).
2. **Champions sin cobertura de modelo.** 18/18 con odds, 0/18 con modelo.
3. **MLS: el modelo es peor que la baseline naive** y el propio sistema lo sabe (veredicto `callarse`), pero aporta 112 de 275 filas canónicas.
4. **23 de 26 superficies de picks sin gate económico**, todas legibles por `anon`.
5. **8 funciones SECURITY DEFINER sin search_path fijado.**
6. **Forward capture con 0 capturas** — no existe evidencia forward.
7. **Tennis sin pipeline de calendario.** **Fantasy con 11 tablas vacías.**
8. **Defecto en los propios asserts** (A3/C2), encontrado solo gracias a la ejecución runtime.

## 2. QUÉ CAMBIASTE

Solo archivos nuevos. **Cero archivos existentes modificados. Cero cambios en producción.**

- `shadow-patches/iss003_009_mlb_governance_v2.sql` — artefacto corregido
- `shadow-patches/deploy/deploy_iss003_009_v2.sql` — wrapper con asserts A–I endurecidos
- `shadow-patches/deploy/run_deploy_v2.sh` — runner con SHA guard + guard read-only explícito
- `shadow-patches/iss003_009_DEPLOY_RUNBOOK_V2.md` — runbook V2
- `shadow-patches/V1_RETIRED.md` — marca de retiro (sin tocar V1, para preservar su SHA)
- `shadow-patches/tests/lab_runtime_validation.sh` — suite reproducible
- `docs/overnight/` — 7 documentos de auditoría

## 3. QUÉ NO CAMBIASTE

- Producción: ni DDL, ni DML, ni un byte.
- V1 y sus archivos (para que su SHA siga verificable como referencia histórica).
- Los rollbacks: ya eran ordinal-correctos y V2-compatibles.
- P, EV, Kelly, thresholds, modelos, autoridad económica: intactos.
- Las 23 superficies sin gate: auditadas, no tocadas (ver §4).
- El Champion de fútbol: `team_strength=ON`, `venue_split/xG/H2H=OFF`. Sin activar nada.

## 4. POR QUÉ

**Por qué V2 mueve las columnas al final:** es la única forma de satisfacer la restricción de PostgreSQL sin `DROP`. Las expresiones se trasladan byte a byte: no cambia matemática alguna.

**Por qué no unifiqué las 23 superficies:** acabamos de comprobar, con un fallo real, que cambiar el contrato de **una** vista sin verificación ordinal rompe el deploy. Hacer 23 de noche, sin poder ver qué pantalla consume cada una (frontend fuera del repo) y con el deploy prohibido, habría sido temerario. La instrucción además ordena: primero autoridad segura, después consumidores.

**Por qué no construí el Fantasy War Room:** sin jugadores ni config de liga habría tenido que inventar ADP, proyecciones y pesos. Un War Room sobre datos inventados da confianza falsa en una decisión irreversible.

**Por qué no construí un modelo NFL:** hacerlo bien exige features + integridad temporal + holdout intacto. Hacerlo mal es peor que no hacerlo.

## 5. ARCHIVOS MODIFICADOS

```
A  shadow-patches/V1_RETIRED.md
A  shadow-patches/deploy/deploy_iss003_009_v2.sql
A  shadow-patches/deploy/run_deploy_v2.sh
A  shadow-patches/iss003_009_DEPLOY_RUNBOOK_V2.md
A  shadow-patches/iss003_009_mlb_governance_v2.sql
A  shadow-patches/tests/lab_runtime_validation.sh
A  docs/overnight/CHAMPIONS_MATCHDAY_READINESS.md
A  docs/overnight/MLB_MATCHDAY_READINESS.md
A  docs/overnight/TENNIS_MATCHDAY_READINESS.md
A  docs/overnight/FANTASY_DRAFT_READINESS.md
A  docs/overnight/NFL_WEDNESDAY_READINESS.md
A  docs/overnight/UNIFIED_PICK_SURFACES_V1_AUDIT.md
A  docs/overnight/RETO13M_MASTER_OVERNIGHT_REPORT.md
A  docs/overnight/CHATGPT_HANDOFF.md
M  (ninguno)
```

## 6. COMMITS

```
e436db5dd4a4410e0e3d46eeb61f785f027305ea
  ISS003_009_V2: corrige defecto ordinal de V1 + validación runtime en lab efímero

e2ee86006244a5e103312349fb1f1752d44bf63f
  OVERNIGHT_AUDIT: readiness por deporte + auditoría de superficies de picks
```
(+ un tercer commit con este handoff)

## 7. PUSH

Ver bloque final. Rama de feature; **sin merge, sin force push**.

## 8–9. TESTS Y RESULTADOS EXACTOS

**Runtime en lab efímero** (PostgreSQL 17.11 local, socket unix, sin TCP, schema de prod sin datos; fidelidad md5 idéntica a producción en los 4 objetos críticos):

| Test | Resultado | Evidencia |
|---|---|---|
| T1 V1 debe fallar | **PASS** | `cannot change name of view column "nivel" to "economically_eligible"`, línea 554; estado 43/22 tras rollback |
| T2 V2 aplica | **PASS** | COMMIT; asserts A–I |
| T3 ordinal runtime | **PASS** | 15:nivel · 22:pick_es_favorito · 23:economically_eligible · 24:reason_code · vpc44:es_pick_reason |
| T5 rollback primario | **PASS** | COMMIT; `ac_key=0` |
| T6 re-apply (idempotencia) | **PASS** | tras corregir A3/C2 |
| T7 assert FAIL revierte todo | **PASS** | vpc 43→43, defs vmm y analisis_completo idénticas |
| **Suite completa** | **FAILS=0** | `lab_runtime_validation.sh` |

**Estática:** `bash -n` PASS · SHA guard coherente · paréntesis y dollar-quotes balanceados · 0 DML · 0 DROP CASCADE en V2 · 17/17 dependencias existen en prod · diff V1↔V2 acotado al bloque movido.

**Asserts con cobertura vacía — NO son PASS sustantivo:**
```
PASS_EMPTY_COVERAGE: E1, E2, E3, G2, G5, I1
```
Con cobertura sustantiva en lab: A1–A4, B0–B1, C1–C4, D1–D3, F1–F2, G1, G3, G4, H1–H6.

## 10. QUÉ FALLÓ DURANTE EL PROCESO

1. **Ruta de socket unix > 103 bytes** → el lab no arrancaba. Corregido moviendo el socket a ruta corta (datos siguen en scratchpad).
2. **`pg_dump` fija `search_path=''`** → columnas generadas que llaman `unaccent` sin cualificar fallaban en cascada (433 errores). Corregido adaptando el search_path **del lab** (no del artefacto) + stubs de roles/schemas/extensiones. Bajó a 3–5 errores irrelevantes.
3. **T6 falló: `FAIL A3 primeras-43 drift=1`.** Defecto real en el assert (ver §11).
4. **Un `DO` block mío mal escrito** (FOREACH sobre variable no declarada) falló sin efecto; los roles se crearon en el bucle siguiente.
5. **Consulta de conteos con timeout** sobre vistas pesadas; se movió a background y se sustituyó por consultas acotadas con `statement_timeout`.
6. **Pooler devolvió `EAUTHQUERY … timed out`** de forma intermitente. Ocurre antes de abrir transacción; se añadieron reintentos.

## 11. CÓMO LO CORREGISTE — el defecto de los asserts

Tras un rollback semántico, `v_pick_canonico` conserva la columna aditiva #44 inerte. A3 comparaba el baseline **completo** (44 filas) contra `ordinal_position<=43` del estado actual → un elemento sin pareja → **FAIL espurio que habría bloqueado un re-deploy legítimo tras rollback**. C2 tenía el mismo defecto para 23/24.

Corregido acotando ambos baselines (`WHERE ordinal_position<=43` / `<=22`). Es *fail-closed* (no habría causado daño), pero **solo aparece en ejecución**: es exactamente lo que la validación estática no podía ver, y justifica haber insistido en el runtime.

## 12. BLOQUEADO

| Blocker | Requiere |
|---|---|
| Pipeline de calendario de tenis | Ingeniería de datos + fuente externa |
| Config de liga Fantasy | **Decisión humana** |
| Universo de jugadores Fantasy | Fuente externa |
| Cobertura de modelo UCL | Datos históricos + validación OOS |
| Auditoría de UI/UX/copy | Acceso al repo del frontend (Lovable) |
| Forward capture operativo | Deploy del productor (prohibido esta noche) |
| Deploy ISS-003/009 V2 | **GO humano** |

## 13. PENDIENTE

Unificación U0–U3 · modelo NFL en shadow · tests temporales MLB con histórico · métricas del detector de incoherencia NFL · `REVOKE` de `anon` sobre backup/debug · fijar `search_path` en las 8 SECURITY DEFINER.

## 14. EVIDENCIA DE CADA PASS

**NFL p_home = probabilidad de la casa** (el hallazgo más importante):
```
Minnesota Vikings vs Chicago Bears
  ml_home = -122  → implícita = 122/222 = 0.549550
  ml_away = +102  → implícita = 100/202 = 0.495050
  suma = 1.044600 ;  vig registrado = 0.0446        ← coincide
  no-vig p_home = 0.549550/1.0446 = 0.526095
  p_home almacenado = 0.52609                       ← coincide
Agregado: 563/563 filas cumplen p_home+p_away=1 (±0.001)
corr(p_home, -spread) = 0.9900 sobre n=562
```

**Cierre económico (H4, adversarial):** con `model_version='v99.9'` **y** `model_skill='SKILL_PASS'` y todos los gates forzados en verde → `eligible=false`, `ECONOMIC_MODEL_UNAUTHORIZED`. El cierre no depende de lo que declare la superficie, sino del registro vacío.

**Skill de fútbol:** 59 ligas / 1679 partidos. Solo 3 baten naive+mercado: Eredivisie (n=34), Leagues Cup (n=50), Saudi (n=8). MLS: Brier modelo 0.6834 vs mercado 0.6791 vs naive 0.6667 → veredicto `callarse`.

**Champions:** 18 eventos · 18 con odds · 0 en `v_pick_canonico` · 0 en `v_picks_futbol_calibrado`.

**Forward capture:** `lab_mlb_forward`=0, `lab_ff_forward`=0, `lab_soccer_xg_forward`=0, `lab_dq_capture_queue`=0, `lab_dq_capture_misses`=0.

## 15. NO VALIDADO

`NOT_RUNTIME_VALIDATED`: comportamiento de los asserts económicos con datos reales · integridad temporal MLB (leakage, timestamp de pitcher) · integridad temporal de fútbol · cualquier afirmación sobre UI/UX/copy del frontend actual · si `v_super_pick` aplica el gate correctamente (referencia `economic_eligibility_v1` y `decision_pick_v1`, pero no se auditó su lógica interna).

## 16. RIESGOS ABIERTOS

1. **NFL mostrando probabilidad de casa como propia** — el mayor riesgo de engaño al usuario.
2. **MLB "bien calibrado" falso** en 140/140 filas hasta desplegar V2.
3. **Champions con odds y sin modelo** — riesgo de que la UI rellene el hueco con el mercado sin etiquetarlo.
4. **23 superficies sin gate legibles por anon.**
5. **Superficie de bypass `g_skill`** (hoy inofensiva; peligrosa si el registro se puebla).
6. **Sin evidencia forward**, cualquier métrica histórica sufre selection bias no medible.

## 17–26. ESTADOS

```
17 ISS-003/009 V2      READY_FOR_HUMAN_REVIEW · runtime PASS · NO desplegado · NO CLOSED
18 Unificación picks   AUDITADO, NO UNIFICADO · 3/26 superficies con gate
19 NFL Betting         SIN MODELO · p = casa · NO AUTORIZADO · stake 0
20 NFL Fantasy         SCHEMA_ONLY · 11 tablas vacías · sin config de liga
21 Most Likely / Value / Top Pick   No existen como conceptos en datos · TOP PICK evidence-gated (correcto)
22 Forward Capture     DISEÑADO · 0 capturas · sin evidencia forward
23 UX / diseño         NO AUDITABLE (frontend fuera del repo)
24 Seguridad           SEC-01 anon+OWNER sobre 44 objetos (ALTA) · SEC-02 8 SECDEF sin search_path (MEDIA) · 0 secretos en repo
25 Integridad temporal NO EVALUADA para MLB/fútbol · NFL no aplica (sin modelo)
26 P / EV / staking    P y EV intactos (asserts F1/F2 = 0) · stake 0 · autoridad NONE
```

## 27. NUEVOS HALLAZGOS

| ID | Hallazgo | Prioridad | Evidencia requerida | Siguiente paso |
|---|---|---|---|---|
| NF-01 | NFL publica prob. de casa como `prob` | **CRÍTICA** | Ya probada | Etiquetar `MARKET_INFORMATION_ONLY`; una card por partido |
| NF-02 | Champions sin cobertura de modelo | **ALTA** | Ya probada | Decidir producto; no rellenar con mercado sin etiqueta |
| NF-03 | MLS peor que naive y aun así 41% de filas canónicas | **ALTA** | Ya probada (registro propio) | Revisar si MLS debe presentarse como análisis de modelo |
| NF-04 | 23 superficies sin gate, legibles por anon | **ALTA** | Ya probada | Plan U0–U3; REVOKE inmediato en backup/debug |
| NF-05 | 8 SECURITY DEFINER sin search_path | MEDIA | Ya probada | `ALTER FUNCTION … SET search_path = public` |
| NF-06 | Defecto A3/C2 en asserts | MEDIA | Ya corregida | — (corregido y testeado) |
| NF-07 | Forward capture con 0 capturas | **ALTA** | — | Priorizar el productor: cada día sin capturar es evidencia perdida |
| NF-08 | 21/35 partidos MLB sin odds | MEDIA | Investigar fuente | Revisar antes del primer horario |

## 28. RECOMENDACIÓN EXACTA DEL SIGUIENTE PASO

**Desplegar ISS-003/009 V2**, en este orden:

```bash
export DATABASE_URL='…'                          # no pegar en chat
bash shadow-patches/deploy/run_deploy_v2.sh      # SHA guard → guard read-only → deploy atómico
# OK    → psql "$DATABASE_URL" -f shadow-patches/deploy/smoke_post_commit.sql
# FALLO → ya revirtió solo
```

Exit codes: `0` APPLIED · `2` SHA_DRIFT · `3` assert FAIL (revertido) · `4` guard read-only no verificable.

Al terminar, revisar cuáles asserts quedaron `PASS_EMPTY_COVERAGE`: en producción `I1` debería dar `PASS_NONEMPTY` con ~140 filas. **Si I1 sale vacío en producción, algo va mal** — es la señal de verificación más útil del deploy.

Inmediatamente después, y antes de que el usuario mire la app: **verificar que ningún porcentaje de Champions o NFL se presente como predicción propia.**

---

===== HANDOFF TO CHATGPT =====

PRODUCTION_CHANGED = NO
DEPLOY_EXECUTED = NO

ISS003_009_READY_FOR_REVIEW = YES (runtime validado, GO humano pendiente)
UNIFICATION_READY_FOR_REVIEW = YES como auditoría; NO como implementación
NFL_BETTING_READY_FOR_REVIEW = YES como auditoría; NO como producto
NFL_FANTASY_READY_FOR_REVIEW = NO (sin datos ni config)
PICK_SYSTEM_READY_FOR_REVIEW = PARCIAL (autoridad sí; taxonomía no existe)
FORWARD_CAPTURE_READY_FOR_REVIEW = NO (0 capturas)
UX_READY_FOR_REVIEW = NO (frontend fuera del repo)

P_INVARIANCE = PASS (F1 = 0 en runtime)
EV_INVARIANCE = PASS (F2 = 0 en runtime)
MONEY_SAFETY = PASS con matiz — E1/E2/E3/G5 fueron PASS_EMPTY_COVERAGE en lab; H1–H6 con cobertura sustantiva
ECONOMIC_AUTHORITY_STATUS = NONE (economic_model_authority con 0 filas; bypass adversarial cerrado)
TEMPORAL_INTEGRITY_STATUS = NO EVALUADA (MLB y fútbol pendientes; NFL no aplica)
SECURITY_STATUS = 2 hallazgos abiertos (SEC-01 ALTA, SEC-02 MEDIA); 0 secretos en repo

CRITICAL_OPEN = 1 (NF-01 NFL prob. de casa presentada como propia)
HIGH_OPEN = 5 (NF-02, NF-03, NF-04, NF-07, SEC-01)
MEDIUM_OPEN = 3 (NF-05, NF-08, SEC-02)
FALSE_PASS_RISKS_OPEN = 6 asserts PASS_EMPTY_COVERAGE (E1 E2 E3 G2 G5 I1), etiquetados como tales y nunca contados como PASS sustantivo

COMMITS_CREATED = e436db5dd4a4410e0e3d46eeb61f785f027305ea · e2ee86006244a5e103312349fb1f1752d44bf63f · (+1 con este handoff)
PUSH_STATUS = ver bloque final de la respuesta

BLOCKERS = tenis sin pipeline · config de liga Fantasy (humano) · universo de jugadores · cobertura UCL · frontend fuera del repo · forward capture requiere deploy · GO humano para V2

RECOMMENDED_NEXT_ACTION = Desplegar ISS-003/009 V2 con run_deploy_v2.sh y verificar que I1 dé PASS_NONEMPTY (~140 filas). Después, auditar en la UI que ningún % de Champions o NFL se presente como predicción propia.

MASTER_READY_FOR_HUMAN_REVIEW = YES
===== END HANDOFF =====

**No se declara ISS-003/009 CLOSED. No se declara NFL económicamente autorizado. No se habilita TOP PICK. No se desplegó producción.**
