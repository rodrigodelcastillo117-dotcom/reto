# SOCCER BRANCH EXECUTION — evidencia real en Supabase branch aislado

repo: `reto` · branch git: `claude/reto-13m-espn-matches-3uknie`
Supabase branch: `soccer-validation` (project_ref `gvegxeunobxfpqnvtgyd`, parent `wpiztubmmmzclhlprgpd`)
autorización: usuario autorizó SOLO el gasto del branch (~$0.01344/hr). PROD_FREEZE=ON · RELEASE_GATE=HOLD.
NO cutover · NO deploy · NO prod mutation.

## BLOCKER estructural descubierto (real, honesto)
El branch se creó `ACTIVE_HEALTHY` pero con estado **MIGRATIONS_FAILED** y **0 tablas**
(`with_data=false`). Es decir: el repo `supabase/migrations/` **NO reproduce el esquema de
producción** (prod fue construido en gran parte fuera de migraciones — additive/manual), y el
branch **no clona datos**. Consecuencia:
- No se puede validar el PIPELINE COMPLETO (builder sobre agenda real, BLOQUE 2b, invariantes
  sobre vectores reales, coverage, triggers de grading/bankroll) en el branch, porque faltan
  ~15 objetos de prod (fn_score_dist, historico, parlays, is_truly_final, catálogos…) y NO hay datos.
- **Esos gates permanecen READ_ONLY_VERIFIED contra PROD (datos reales)** — evidencia más fuerte
  que un branch vacío. Se documenta abajo.
- Lo que SÍ se validó en branch: artefactos con dependencias reconstruibles + datos sintéticos.

## Ejecutado en branch (evidencia medida)
### iss037 — φ versionado / replay (OPEN AUDIT 5607948324/5608359234) → **BRANCH_TESTED PASS**
- Aplicado: `v2.liga_fuerza`, `v2.liga_fuerza_version` (PK incl. cutoff), `fn_seal_liga_fuerza_snapshot`,
  `fn_crossleague_active_cutoff`, `fn_crossleague_phi_asof`. Sello real crossleague_v1@2026-09-08 (3 ligas).
- Test adversarial 2 cutoffs (synthetic): T1=2026-01-01 φ0.1000, T2=2026-06-01 φ0.2000.
  - replay entre T1,T2 → **φ(T1)=0.1000** ✓
  - replay post-T2 → **φ(T2)=0.2000** ✓
  - replay pre-T1 → **fail-close (0 filas)** ✓
  - reinsert φ0.9999 en T1 con DO NOTHING → **T1 sigue 0.1000 (append-only)** ✓
- Resuelve el AUDIT_NO_PASS de iss037: la historia φ es append-only y replay-safe.

### iss038 — parlay joint-prob fail-closed (§25) → **BRANCH_TESTED PASS**
- Aplicado `v2.v_parlay_canonical_contract` sobre `public.parlays` (mínima).
- Insertados 2 parlays (uno con `ai_prob_combinada=0.42`). Contrato: **2/2 filas
  `joint_probability IS NULL`**, `joint_reason='NO_VALIDATED_JOINT_MODEL'`,
  `ai_prob_combinada` sólo como `context_only` / `LLM_ORIGIN_NOT_AUTHORITY`.
- `invariant_all_null=true`. §25 satisfecho aun cuando el valor LLM existe.

### iss033 — núcleo temporal AS-OF (§5/§6/§7 F3/F5) → **BRANCH_TESTED PASS**
- Aplicado `v2.fn_soccer_features_asof` (versión endurecida: exclude_event_id + enforce_availability).
- Synthetic historico: H con P1/P2/P3 (pre-2026-05-01) + TARGET(2026-06-01) + FUT1/FUT2 goleadas post.
  - as-of(D=2026-05-01) home_gf = **2.0000**, n=3, max_source **2026-04-01**, temporal_safe=**true**.
  - exclude TARGET → idéntico 2.0000/n=3 (F3 funciona).
  - agregado móvil (sin filtro fecha) = **5.0000** (contaminado por goleadas post) → **moving_contaminated=true**.
  - Prueba de inmunidad temporal: las goleadas POST-decisión NO afectan la feature as-of.
- Tablas iss033 aplicadas limpias (F2 `soccer_prediction_v2_staged`, F1 `feature_snapshot`).
  Persistencia F1 probada: fila SNAPTEST con home_gf=2.0000 congelado + feature_snapshot_id.

## Gates: antes → después (branch)
| gate | antes | después |
|---|---|---|
| CROSS_LEAGUE_REPLAY_GATE | STAGED_ONLY (FAIL previo) | **BRANCH_TESTED PASS** (iss037) |
| FEATURE_SNAPSHOT_GATE | STAGED_ONLY | **BRANCH_TESTED PASS** (F1 persistencia) |
| PARLAY_JOINT_PROB_GATE | STAGED_ONLY | **BRANCH_TESTED PASS** (iss038) |
| TEMPORAL_LEAKAGE / HISTORICAL_REPLAY | PASS (prod read-only) | + confirmado en branch (as-of immune) |
| CANONICAL_CONTRACT_GATE (tablas) | STAGED_ONLY | DDL BRANCH-APPLIED (F1/F2); contrato pleno pend. builder |
| BRANCH_EXECUTION_GATE | NOT_RUN | **PARTIAL**: branch creado + iss037/iss038/iss033-core ejecutados; pipeline completo BLOQUEADO por MIGRATIONS_FAILED/sin datos |

## Permanecen READ_ONLY_VERIFIED contra PROD (no reproducibles en branch vacío)
BLOQUE 2b (fn_score_dist real + 42.5k historico), invariantes 383 vectores, agenda universo (241),
dossier coverage, bankroll idempotencia (calcular_bankroll_actual real), grading GAP A (guard
universal + is_truly_final prod), §27 early-payout, market-independence. Todos con datos reales de prod.

## Qué falta EXACTAMENTE para FULL_DATA_SOCCER_ANALYSIS_GATE=PASS
1. Capturar el esquema de PROD en migraciones reproducibles (o `create_branch with_data`) para poder
   correr el PIPELINE COMPLETO en branch — hoy imposible (MIGRATIONS_FAILED, 0 tablas, 0 datos).
2. Ejecutar el builder `build_soccer_prediction_v2_staged` sobre agenda+historico reales en un branch
   con datos y validar: contrato canónico 1-fila/evento, btts_no explícito, O/U línea real, 0 drops.
3. Migrar (cutover, requiere autorización aparte) el builder de prod a as-of + recomponer v_futpro_v2.
4. Frontend (ChatGPT): consumir superficie canónica; exact-SHA sync + smoke.

## Estado
`FULL_DATA_SOCCER_ANALYSIS_GATE=FAIL` (correcto — falta pipeline completo + cutover).
`SOCCER_GATE=FAIL` · `RELEASE_GATE=HOLD` · PROD intacto. NO se declara SOCCER cerrado.
