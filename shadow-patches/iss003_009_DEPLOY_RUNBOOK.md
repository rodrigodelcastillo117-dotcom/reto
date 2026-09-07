# RUNBOOK — DEPLOY SQL · ISS-003 / ISS-009 / ISS-009B (Gobernanza MLB)

> **ESTADO: NO DEPLOY.** Este runbook describe *exactamente* el deploy; no lo ejecuta.
> `DEPLOY_RUNBOOK_READY = READY` · `DEPLOY_AUTHORIZATION = PENDING`
> No se toca producción hasta GO explícito del auditor.

---

## 0. INVARIANTES QUE ESTE DEPLOY DEBE MANTENER (no negociables)

- `CURRENT_AUTHORIZED_MODELS = NONE` (0 modelos autorizados) — **antes y después**.
- MLB `economic_authorized = FALSE`, MLB `stake = $0`, MLB no se autoriza.
- No recalibra, no tunea, no toca P (`probabilidad_pct`) ni EV (`ev_pct`), no toca `EXP_OFF` / NB r=5 / features.
- No abre ISS-007, no toca NFL, no añade refactors, no re-despliega frontend.
- Solo cableado / gobernanza: 3 cambios quirúrgicos ya congelados en el artefacto.

**Artefacto congelado:**
`shadow-patches/iss003_009_mlb_governance.sql`
`REVIEWED_SHA = 57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad`
(36 108 bytes)

---

## 1. OBJETOS QUE CAMBIAN (nombres exactos, sin ambigüedad)

| Parte | Objeto | Tipo | Cambio |
|------|--------|------|--------|
| **Parte 1** | `public.v_pick_canonico` | VIEW (`CREATE OR REPLACE`) | (a) arm MLB de `unidos`: `true AS bool` → `false AS bool` (ISS-003a, `calibracion_confiable` MLB fail-closed). (b) `es_pick` pasa a derivarse de `CROSS JOIN LATERAL economic_eligibility_v1(<ctx>)` **1 sola llamada** (`elig.j`). (c) columna **additiva #44** `es_pick_reason text` = `elig.j->>'reason_code'`, propagada m0→m→SELECT top. Las 43 columnas previas **idénticas** en nombre/orden/tipo. |
| **Parte 2** | `public.v_mejores_picks_mlb` | VIEW (`CREATE OR REPLACE`) | `COALESCE(j.confiable, true)` → `COALESCE(j.confiable, false)` (ISS-003b). Añade `economically_eligible` + `reason_code` (2 cols) desde `economic_eligibility_v1`. `nivel` degrada a `'informativo'` cuando no es elegible. Matemática intacta. |
| **Parte 3** | *(ninguno)* | — | **NO EJECUTA.** Solo comentarios: propuesta de `skill_final` en `economic_model_authority` + cambio de `g_skill` en `economic_eligibility_v1`. Requiere su propio deploy atómico + GO independiente. **Fuera de este deploy.** |
| **Parte 4** | `public.analisis_completo` | FUNCTION (`CREATE OR REPLACE` vía DO-block) | DO-block: `pg_get_functiondef` → `replace` del needle `'como_se_calculo', c.razon)` por `'economically_eligible', c.es_pick, 'eligibility_reason_code', c.es_pick_reason, 'como_se_calculo', c.razon)` → `EXECUTE`. Aborta si el needle no es único. **NO** envía `stake_final`. |

**Orden real de dependencias = orden literal del archivo: Parte 1 → Parte 2 → Parte 4.**
Parte 4 (`analisis_completo`) consume `c.es_pick_reason`, columna que **solo existe tras la Parte 1**. Si se ejecutara la Parte 4 antes que la Parte 1, el `CREATE OR REPLACE FUNCTION` fallaría por columna inexistente (fail-closed deseado, aborta la transacción). Ejecutar el archivo de arriba a abajo satisface el orden.

**Baselines observados read-only en prod (hoy, pre-deploy):**
- `v_pick_canonico`: **43 columnas**, sin `es_pick_reason` (confirma no desplegado).
- `v_mejores_picks_mlb`: **22 columnas**.
- `analisis_completo`: **1 overload**, needle ISS-009B **único** (count = 1).
- `economic_model_authority.economic_authorized = TRUE`: **0 filas** (⇒ NONE); MLB: **0**.

---

## 2. TRANSPORTE DEL ARTEFACTO (restricción ambiental — leer antes de ejecutar)

El MCP `execute_sql` corrompe pastes grandes multibyte (split de bytes 0xc2) y el proxy bloquea `curl` a `*.supabase.co` (403 de política). Por eso **el deploy atómico de 36 KB NO debe pegarse por `execute_sql`**. Mecanismos válidos, en orden de preferencia:

1. **`psql` con el archivo en disco** (recomendado, atómico, sin corrupción):
   ejecutar el *wrapper* de §4 con `\i` al artefacto congelado. `psql` transfiere el archivo intacto; `\set ON_ERROR_STOP on` + `BEGIN/COMMIT` explícitos dan todo-o-nada.
2. **Supabase SQL Editor**: pegar el *wrapper* de §4 con el contenido del artefacto embebido (verificar SHA del archivo fuente **antes** de copiar; el editor no corrompe el paste del navegador como sí lo hace el MCP).

**No** usar `apply_migration` del MCP para el payload de 21 KB de la Parte 1 sin verificación por chunks md5 — riesgo de corrupción; no cumple "atómico en una transacción" de forma limpia.

---

## 3. FASE 0 — FREEZE DEL ARTEFACTO (antes de todo; sin tocar DB)

```bash
CURRENT_SHA=$(sha256sum shadow-patches/iss003_009_mlb_governance.sql | awk '{print $1}')
REVIEWED_SHA=57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad
test "$CURRENT_SHA" = "$REVIEWED_SHA" && echo "FREEZE OK — DEPLOYED_SHA == REVIEWED_SHA" \
  || { echo "ABORT — SHA MISMATCH: $CURRENT_SHA"; exit 1; }
```

**Condición:** `CURRENT_SHA == REVIEWED_SHA`. Si no coincide → **ABORT**, no se toca producción. Este check se repite justo antes de invocar `psql`/pegar en el editor.

---

## 4. FASE 1 — PRECONDITION READ-ONLY (sin DDL)

Correr como SELECT (read-only). **ABORT** si cualquiera falla; no continuar a la transacción.

```sql
-- P1  Autorización = NONE  (esperado: authorized_models=0, mlb_authorized=0)
SELECT
  (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE) AS authorized_models,
  (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE AND deporte='baseball') AS mlb_authorized;
-- ABORT si authorized_models <> 0  OR  mlb_authorized <> 0

-- P2  Lock waiters sobre los objetos objetivo (esperado: 0)
SELECT count(*) AS lock_waiters
  FROM pg_locks l
  JOIN pg_class c     ON c.oid = l.relation
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname='public'
   AND c.relname IN ('v_pick_canonico','v_mejores_picks_mlb')
   AND NOT l.granted;
-- ABORT si lock_waiters <> 0

-- P3  Sesiones idle-in-transaction que bloquearían el AccessExclusiveLock del CREATE OR REPLACE VIEW (esperado: vacío)
SELECT pid, state, now()-xact_start AS xact_age, left(query,80) AS q
  FROM pg_stat_activity
 WHERE datname=current_database() AND pid<>pg_backend_pid()
   AND state='idle in transaction'
 ORDER BY xact_start;
-- ABORT si hay filas (resolver antes; no forzar)

-- P4  Baseline de contrato v_pick_canonico (esperado: 43 filas) — guardar como evidencia
SELECT ordinal_position, column_name, data_type
  FROM information_schema.columns
 WHERE table_schema='public' AND table_name='v_pick_canonico'
 ORDER BY ordinal_position;
```

**P5 — Capturar definiciones vivas para rollback (read-only; guardar a disco ANTES de la transacción):**

```sql
-- Guardar cada salida a shadow-patches/rollback/<obj>_live_<YYYYMMDD-HHMM>.sql
SELECT 'CREATE OR REPLACE VIEW public.v_pick_canonico AS ' || pg_get_viewdef('public.v_pick_canonico'::regclass, true) || ';';
SELECT 'CREATE OR REPLACE VIEW public.v_mejores_picks_mlb AS ' || pg_get_viewdef('public.v_mejores_picks_mlb'::regclass, true) || ';';
SELECT pg_get_functiondef(p.oid)
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='analisis_completo';   -- ya es CREATE OR REPLACE FUNCTION completo
```

> `pg_get_viewdef` devuelve solo el cuerpo `SELECT`; por eso se antepone `CREATE OR REPLACE VIEW ... AS` para que el archivo de rollback sea ejecutable tal cual. `pg_get_functiondef` ya devuelve la sentencia completa.
> **Nada de DDL en esta fase.**

---

## 5. FASE 2 — TRANSACCIÓN ÚNICA (wrapper de deploy)

Archivo `deploy_wrapped.sql` (scaffolding del runbook; el artefacto entra intacto vía `\i`):

```sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '45s';

-- 2.0  Snapshot drift-safe del contrato ANTES de la primera DDL (para assert A3)
CREATE TEMP TABLE _vpc_base ON COMMIT DROP AS
  SELECT ordinal_position, column_name, data_type
    FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';

-- 2.1  === ARTEFACTO CONGELADO, BYTE-EXACTO (SHA 57b7a40...cad) ===
--      Orden literal = orden de dependencias: Parte 1 → Parte 2 → Parte 3(doc) → Parte 4
\i shadow-patches/iss003_009_mlb_governance.sql
--      === FIN ARTEFACTO ===

-- 2.2  POST-VERIFY (§6) va aquí, dentro de la MISMA transacción, antes del COMMIT.
--      (bloque DO $verify$ ... $verify$; — ver §6)

COMMIT;
```

Notas:
- El artefacto **no** contiene `BEGIN/COMMIT`; los pone el wrapper → todo en una sola transacción.
- `\set ON_ERROR_STOP on`: cualquier error (incluido `RAISE EXCEPTION` del POST-VERIFY o un `lock_timeout`) detiene el script; al no llegarse al `COMMIT`, la transacción **revierte** al cerrar la sesión. **No hay reintento automático.**
- Con Supabase SQL Editor: sustituir la línea `\i ...` por el contenido del artefacto (SHA verificado antes de copiar) y pegar el POST-VERIFY donde indica 2.2.
- `CREATE OR REPLACE VIEW` toma `AccessExclusiveLock`; si un lector lo retiene, espera hasta `lock_timeout=3s` y aborta (fail-fast deseado).
- El propio motor ya protege el contrato: `CREATE OR REPLACE VIEW` **rechaza** renombrar/reordenar/cambiar tipo de columnas existentes; solo permite añadir al final. Refuerza A2/A3.

---

## 6. FASE 3 — POST-VERIFY DENTRO DE LA TRANSACCIÓN (antes del COMMIT)

Un solo bloque; cualquier fallo hace `RAISE EXCEPTION` → aborta → **ROLLBACK** (no se corrige sobre la marcha).

```sql
DO $verify$
DECLARE
  ncol int; c44 text; t44 text; ndiff int; ncalls int;
  ac_ee int; ac_rc int; mlb_eligible int; vmm_reco int; vmm_elig int;
BEGIN
  ---------- A. CONTRATO v_pick_canonico (estructural, determinista) ----------
  SELECT count(*) INTO ncol FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
  IF ncol <> 44 THEN RAISE EXCEPTION 'FAIL A1 v_pick_canonico cols=% (exp 44)', ncol; END IF;

  SELECT column_name, data_type INTO c44, t44 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position=44;
  IF c44 IS DISTINCT FROM 'es_pick_reason' OR t44 IS DISTINCT FROM 'text'
    THEN RAISE EXCEPTION 'FAIL A2 col44=%/% (exp es_pick_reason/text)', c44, t44; END IF;

  -- primeras 43 idénticas al baseline (nombre+orden+tipo)
  SELECT count(*) INTO ndiff FROM (
    SELECT b.ordinal_position, b.column_name, b.data_type FROM _vpc_base b
    EXCEPT
    SELECT c.ordinal_position, c.column_name, c.data_type
      FROM information_schema.columns c
     WHERE c.table_schema='public' AND c.table_name='v_pick_canonico' AND c.ordinal_position <= 43
  ) d;
  IF ndiff <> 0 THEN RAISE EXCEPTION 'FAIL A3 primeras-43 drift rows=%', ndiff; END IF;

  -- economic_eligibility_v1 llamada EXACTAMENTE 1 vez en la def
  SELECT (length(v)-length(replace(v,'economic_eligibility_v1(','')))
           / length('economic_eligibility_v1(')
    INTO ncalls
    FROM (SELECT pg_get_viewdef('public.v_pick_canonico'::regclass, true) AS v) q;
  IF ncalls <> 1 THEN RAISE EXCEPTION 'FAIL A4 economic_eligibility_v1 calls=% (exp 1)', ncalls; END IF;

  ---------- B. analisis_completo propaga las llaves ----------
  SELECT
    (length(d)-length(replace(d,'economically_eligible','')))/length('economically_eligible'),
    (length(d)-length(replace(d,'eligibility_reason_code','')))/length('eligibility_reason_code')
    INTO ac_ee, ac_rc
    FROM (SELECT pg_get_functiondef(p.oid) AS d FROM pg_proc p
            JOIN pg_namespace n ON n.oid=p.pronamespace
           WHERE n.nspname='public' AND p.proname='analisis_completo' LIMIT 1) q;
  IF ac_ee < 1 OR ac_rc < 1
    THEN RAISE EXCEPTION 'FAIL B1 analisis_completo keys ee=% rc=%', ac_ee, ac_rc; END IF;

  ---------- C. CONTRATO v_mejores_picks_mlb ----------
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_mejores_picks_mlb' AND column_name='economically_eligible';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C1 vmm falta economically_eligible'; END IF;
  PERFORM 1 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_mejores_picks_mlb' AND column_name='reason_code';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C2 vmm falta reason_code'; END IF;

  ---------- D. INVARIANTES DE DATO BAJO NONE (slate-independientes) ----------
  -- Bajo NONE (model_version NULL/MISSING) es_pick debe ser false para TODO el universo
  SELECT count(*) INTO mlb_eligible FROM public.v_pick_canonico WHERE es_pick IS TRUE;
  IF mlb_eligible <> 0 THEN RAISE EXCEPTION 'FAIL D1 es_pick=true count=% (exp 0)', mlb_eligible; END IF;

  SELECT count(*) INTO vmm_reco FROM public.v_mejores_picks_mlb WHERE nivel IN ('ojo','fuerte');
  IF vmm_reco <> 0 THEN RAISE EXCEPTION 'FAIL D2 vmm nivel ojo/fuerte count=% (exp 0)', vmm_reco; END IF;

  SELECT count(*) INTO vmm_elig FROM public.v_mejores_picks_mlb WHERE economically_eligible IS TRUE;
  IF vmm_elig <> 0 THEN RAISE EXCEPTION 'FAIL D3 vmm economically_eligible=true count=% (exp 0)', vmm_elig; END IF;

  RAISE NOTICE 'POST-VERIFY OK — contrato 44/es_pick_reason, 1 call, keys propagadas, MLB/global eligible=0';
END $verify$;
```

Cobertura vs criterios del auditor:
- **44 columnas** → A1. **col 44 = es_pick_reason text** → A2. **primeras 43 idénticas** → A3. **1 llamada** → A4.
- **calibracion_confiable MLB != hardcode TRUE** → garantizado por Parte 1 (`false AS bool`) + A4 (una sola vía de gate) + D1/D2/D3 (ningún MLB elegible/recomendado). *(La verificación por-fila de `calibracion_confiable` de un juego MLB concreto es parte del SMOKE §8, porque depende del calendario del día.)*
- **analisis_completo con economically_eligible + eligibility_reason_code** → B1.
- **eligible=true count = 0 / MLB economic picks = 0 / stake>0 = 0** → D1/D2/D3 (bajo NONE, `stake` MLB = 0 por construcción: ninguna superficie dimensiona sin elegibilidad).
- **P / EV intactos** → Parte 1/2 no tocan `probabilidad_pct` ni `ev_pct`; A3 prueba que esas columnas no cambian en `v_pick_canonico`.

> Si **cualquier** assert falla → la excepción aborta la transacción → **ROLLBACK**. No se edita el artefacto en caliente; se corrige el artefacto en frío, se recongela SHA, y se reinicia el runbook.

---

## 7. FASE 4 — COMMIT

- Solo si **todos** los asserts pasaron (el bloque `DO $verify$` terminó con `NOTICE ... OK` y sin excepción):
  ```sql
  COMMIT;
  ```
- Si hubo error de lock/timeout o assert: **ROLLBACK** (automático por ON_ERROR_STOP / cierre de sesión). **Sin reintento automático.** Diagnosticar, resolver la causa, reiniciar desde FASE 0.

---

## 8. FASE 5 — SMOKE POST-COMMIT (READ-ONLY, conexión nueva)

```sql
-- S1  Las superficies existen y no rompen (conteos; ninguna excepción)
SELECT 'v_pick_canonico'          AS obj, count(*) AS n FROM public.v_pick_canonico
UNION ALL SELECT 'v_mejores_picks_mlb',      count(*) FROM public.v_mejores_picks_mlb
UNION ALL SELECT 'v_super_pick',             count(*) FROM public.v_super_pick
UNION ALL SELECT 'reto_picks_hoy',           count(*) FROM public.reto_picks_hoy
UNION ALL SELECT 'mejor_oportunidad_hoy',    count(*) FROM public.mejor_oportunidad_hoy
UNION ALL SELECT 'mejor_oportunidad_hoy_v2', count(*) FROM public.mejor_oportunidad_hoy_v2
UNION ALL SELECT 'favoritos_bien_pagados',   count(*) FROM public.favoritos_bien_pagados;
-- (analisis_completo es FUNCTION con parámetros; su prueba estructural es B1 §6.
--  Su prueba de payload viva es el SMOKE VISUAL del dossier en frontend — ver S4.)

-- S2  CASO OBLIGATORIO — Athletics ML (columnas reales de v_pick_canonico)
SELECT deporte, home, away, mercado, pick_nombre,
       ev_pct,                 -- EV medido; debe permanecer intacto (~ +25.07)
       calibracion_confiable,  -- MLB ⇒ false (ISS-003a)
       es_pick,                -- ⇒ false (no elegible bajo NONE)
       es_pick_reason          -- razón real (p.ej. MODEL_VERSION_PROVENANCE_MISSING)
  FROM public.v_pick_canonico
 WHERE deporte='baseball'
   AND (home ILIKE '%Athletics%' OR away ILIKE '%Athletics%')
 ORDER BY ev_pct DESC;
-- Esperado por fila: es_pick=false, es_pick_reason no nulo, calibracion_confiable=false,
--                    ev_pct SIN cambio. Si no hay juego de Athletics hoy, usar cualquier MLB.

-- S3  Autorización sigue en NONE tras el commit
SELECT count(*) AS authorized_models FROM public.economic_model_authority WHERE economic_authorized IS TRUE;
-- esperado: 0
```

**S4 — SMOKE VISUAL DEL DOSSIER (frontend, ya desplegado `ba828acc`):**
Abrir un dossier de un partido MLB. Con el backend ya emitiendo `economically_eligible=false` por mercado, debe verse **"ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"** y **no** "🎯 PICK SUGERIDO". (Antes del deploy SQL, el flag no existe → `undefined` → fail-closed → mismo resultado visual; tras el deploy, el flag llega explícito con su motivo.)

---

## 9. FASE 6 — PLAN DE ROLLBACK (preparado; NO ejecutar salvo fallo crítico post-commit)

El rollback restaura los objetos desde las **defs vivas capturadas en P5** (FASE 1). No se improvisa SQL.

```sql
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='45s';
\i shadow-patches/rollback/v_pick_canonico_live_<STAMP>.sql       -- CREATE OR REPLACE VIEW ... (def previa)
\i shadow-patches/rollback/v_mejores_picks_mlb_live_<STAMP>.sql   -- CREATE OR REPLACE VIEW ... (def previa)
\i shadow-patches/rollback/analisis_completo_live_<STAMP>.sql     -- CREATE OR REPLACE FUNCTION ... (def previa)
COMMIT;
```

- **Orden de rollback = inverso de dependencias:** primero restaurar `analisis_completo` (que referencia `es_pick_reason`) y **luego** `v_pick_canonico`, para no dejar la función apuntando a una columna que el rollback de la vista elimina. → **Ejecutar `analisis_completo_live` ANTES de `v_pick_canonico_live`.** (Reordenar los `\i` en consecuencia.)
- Ejecutar **solo** ante fallo crítico observado *después* del COMMIT (un smoke que revele regresión real). Un fallo *dentro* de la transacción ya revierte solo — ahí no se usa este plan.

---

## 10. NO HACER durante este deploy

- ❌ Autorizar modelos · ❌ recalibrar MLB · ❌ tocar P (`probabilidad_pct`) / EV (`ev_pct`) · ❌ cambiar `EXP_OFF`
- ❌ ejecutar la Parte 3 (skill_final / cambio a `economic_eligibility_v1`) — requiere GO propio
- ❌ abrir ISS-007 · ❌ tocar NFL · ❌ añadir refactors · ❌ re-desplegar frontend
- ❌ reintento automático tras lock/timeout · ❌ editar el artefacto en caliente · ❌ fabricar `stake=$0`

---

## 11. GATE DE AUTORIZACIÓN (checklist previo al GO)

- [ ] `FREEZE`: `CURRENT_SHA == REVIEWED_SHA` (§3)
- [ ] `PRECONDITION`: P1 (NONE) · P2 (0 waiters) · P3 (0 idle-in-tx) · P4 (43 cols) · P5 (defs capturadas) (§4)
- [ ] `deploy_wrapped.sql` listo con `\i` al artefacto SHA-verificado + POST-VERIFY embebido (§5–6)
- [ ] `ROLLBACK` preparado desde P5, orden inverso (§9)
- [ ] Smoke frontend `ba828acc` confirmado por el auditor (§8 S4)
- [ ] **GO explícito del auditor** → recién entonces ejecutar §3→§7, luego §8

**Estado:** `DEPLOY_RUNBOOK_READY = READY` · `DEPLOY_AUTHORIZATION = PENDING` · **NO DEPLOY.**
