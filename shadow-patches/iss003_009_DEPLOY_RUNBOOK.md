# RUNBOOK — DEPLOY SQL · ISS-003 / ISS-009 / ISS-009B (Gobernanza MLB)

> **ESTADO: NO DEPLOY.** Describe *exactamente* el deploy; no lo ejecuta.
> `DEPLOY_RUNBOOK_DESIGN = PASS` · `DEPLOY_RUNBOOK_EXECUTABLE = READY` · `DEPLOY_AUTHORIZATION = PENDING_USER`
> No se toca producción sin GO explícito del auditor.
> Rev. 2 — incorpora las 6 correcciones del auditor (rollback ejecutable, asserts de dinero reales, paridad P/EV, hardening de `analisis_completo`, SHA del rollback, `SAFE_SQL_TRANSPORT` probado).

---

## 0. INVARIANTES (no negociables)

- `CURRENT_AUTHORIZED_MODELS = NONE` (0 modelos autorizados) — antes y después.
- MLB `economic_authorized = FALSE`, MLB `stake = $0`, MLB no se autoriza.
- No recalibra/tunea, no toca `probabilidad_pct` ni `ev_pct`, no toca `EXP_OFF`/NB r=5/features.
- No abre ISS-007, no toca NFL/NHL/NBA/Tennis, no re-despliega frontend, no refactors.
- Solo cableado/gobernanza: los 3 cambios quirúrgicos ya congelados en el artefacto.

**Artefacto congelado (aprobado):** `shadow-patches/iss003_009_mlb_governance.sql`
`REVIEWED_SHA = 57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad` · 36 108 bytes
(revalidado en esta sesión: `sha256sum` == REVIEWED_SHA → `SHA_DRIFT = FAIL` NO; freeze intacto).

**Artefacto de rollback (generado, real, ejecutable):** `shadow-patches/rollback/iss003_009_rollback.sql`
`ROLLBACK_ARTIFACT_SHA256 = 32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530` · 69 940 bytes (no vacío/truncado; ver §9).

---

## 0.1 FLUJO DEFINITIVO DE EJECUCIÓN (orden y reglas de fallo)

```
VISUAL_FRONTEND_SMOKE_PRE  →  SHA GUARD  →  DEPLOY ATÓMICO  →  ASSERTS DB (A–G)  →  VISUAL_FRONTEND_SMOKE_POST  →  CIERRE
```
- **`VISUAL_FRONTEND_SMOKE_PRE`** (manual): confirmar que el frontend / dossier MLB **carga correctamente** ANTES del deploy. **Si falla → NO DEPLOY.**
- **SHA GUARD** (`run_deploy.sh`): `REVIEWED_SHA` + `ROLLBACK_SHA`. **Si falla (`SHA_DRIFT`) → NO DEPLOY.**
- **DEPLOY ATÓMICO + ASSERTS DB (A–G)**: una transacción; **si cualquier assert DB falla → ROLLBACK automático** (nada queda aplicado).
- **`VISUAL_FRONTEND_SMOKE_POST`** (manual): tras el COMMIT, MLB debe verse como análisis **informativo / no accionable**, **sin** "PICK SUGERIDO". **Si los asserts DB pasan pero POST-SMOKE falla → NO declarar éxito; reportar inconsistencia frontend/backend y mantener el incidente abierto. No improvisar otro cambio.**
- **CIERRE**: solo con PRE-SMOKE ok + SHA ok + asserts DB PASS + POST-SMOKE ok.

Notas de build (documentadas, no re-ejecutar): `LOCAL_TSGO = NOT_APPLICABLE` (repo local sin proyecto TS) · `LOVABLE_FRONTEND_BUILD = PASS @ ba828acc`.

---

## 1. OBJETOS QUE CAMBIAN (nombres exactos)

| Parte | Objeto | Tipo | Cambio | Contrato |
|------|--------|------|--------|----------|
| **1** | `public.v_pick_canonico` | VIEW `CREATE OR REPLACE` | `true AS bool`→`false AS bool` (ISS-003a); `es_pick` vía `CROSS JOIN LATERAL economic_eligibility_v1(<ctx>)` **1 llamada**; col additiva **#44 `es_pick_reason text`** | 43→**44** cols; 1–43 idénticas |
| **2** | `public.v_mejores_picks_mlb` | VIEW `CREATE OR REPLACE` | `COALESCE(j.confiable,true)`→`COALESCE(j.confiable,false)` (ISS-003b); +`economically_eligible`,+`reason_code`; `nivel`→`informativo` si no elegible | 22→**24** cols |
| **3** | *(ninguno)* | — | **NO EJECUTA** (solo comentarios: `skill_final`/cambio a `economic_eligibility_v1`). Requiere GO propio. | — |
| **4** | `public.analisis_completo(text)` | FUNCTION `CREATE OR REPLACE` vía DO-block | `pg_get_functiondef`→`replace(needle)`→`EXECUTE`; propaga `economically_eligible=c.es_pick`, `eligibility_reason_code=c.es_pick_reason`; **sin** `stake_final` | firma exacta `analisis_completo(text)`, 1 overload |

**Orden de dependencias = orden literal del archivo: Parte 1 → Parte 2 → Parte 4.** La Parte 4 consume `c.es_pick_reason`, que solo existe tras la Parte 1.

**Baselines observados read-only (pre-deploy, esta sesión):**
`v_pick_canonico`=43 cols (sin `es_pick_reason`); `v_mejores_picks_mlb`=22 cols; `analisis_completo`=1 overload, needle único (=1); `economic_authorized=TRUE`→0 filas (NONE); MLB=0; `v_mejores_picks_mlb` `nivel IN (ojo,fuerte)`=**5 HOY** (bug ISS-009 que cierra la Parte 2 → 0 post-deploy).

---

## 2. `SAFE_SQL_TRANSPORT = BLOCKED` (probado esta sesión) — el deploy lo ejecuta el USUARIO

Prueba real, inocua (no se ejecutó el artefacto):
- `psql` **instalado** (v16.13, `/usr/bin/psql`).
- **Sin credenciales** de DB en la sesión (ni `DATABASE_URL`/`PG*`/`SUPABASE*` en env, ni secretos en disco del proyecto).
- **Sin red** a la DB: TCP a `db.<ref>.supabase.co:5432`, `aws-0-us-east-1.pooler.supabase.com:6543` y `:5432` → **los 3 fallan** (el egress solo permite el proxy HTTPS + MCP).

Conclusión honesta: **desde esta sesión no existe transporte atómico seguro** para el archivo de 36 KB. `execute_sql`/`apply_migration` del MCP corrompen pastes grandes multibyte (0xc2) y están **prohibidos** para el archivo grande; `psql` no puede conectar. **No se busca atajo.**

➡ **El deploy debe correrlo el usuario** con su propio `psql`/SQL-editor y el archivo congelado (SHA verificado). El wrapper de §5 y el POST-VERIFY de §6 son el guion exacto a ejecutar en ese canal.

---

## 3. FASE 0 — FREEZE (sin tocar DB)

```bash
REVIEWED_SHA=57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad
CUR=$(sha256sum shadow-patches/iss003_009_mlb_governance.sql | awk '{print $1}')
[ "$CUR" = "$REVIEWED_SHA" ] && echo "FREEZE OK" || { echo "SHA_DRIFT=FAIL ($CUR)"; exit 1; }
# idem para el rollback:
ROLLBACK_SHA=32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530
[ "$(sha256sum shadow-patches/rollback/iss003_009_rollback.sql|awk '{print $1}')" = "$ROLLBACK_SHA" ] || { echo "ROLLBACK DRIFT"; exit 1; }
```
Si el SHA del artefacto no coincide → **ABORT**, no se toca producción.

---

## 4. FASE 1 — PRECONDITION READ-ONLY (sin DDL) — ABORT si algo falla

```sql
-- P1 Autorización = NONE
SELECT
  (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE) AS authorized_models,   -- =0
  (SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized IS TRUE AND deporte='baseball') AS mlb_authorized;  -- =0

-- P2 analisis_completo overload guard (HARD): exactamente 1, o ABORT
SELECT count(*) AS overloads FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='analisis_completo';   -- =1  (si <>1 => ABORT)

-- P3 locks / bloqueos sobre los objetos objetivo
SELECT count(*) AS lock_waiters FROM pg_locks l
  JOIN pg_class c ON c.oid=l.relation JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN ('v_pick_canonico','v_mejores_picks_mlb') AND NOT l.granted;  -- =0
SELECT pid, now()-xact_start AS age, left(query,80) q FROM pg_stat_activity
 WHERE datname=current_database() AND pid<>pg_backend_pid() AND state='idle in transaction' ORDER BY xact_start;  -- vacío

-- P4 baseline de contrato (=43 filas) — evidencia
SELECT ordinal_position, column_name, data_type FROM information_schema.columns
 WHERE table_schema='public' AND table_name='v_pick_canonico' ORDER BY ordinal_position;
```
**P5 — ROLLBACK ya generado (§9).** Antes del deploy re-verificar que las defs vivas siguen == las capturadas (drift-guard): recomputar `pg_get_viewdef`/`pg_get_functiondef` de los 5 objetos y comparar contra el rollback; si difieren, **regenerar el rollback y recalcular su SHA** antes de continuar.

---

## 5. FASE 2 — TRANSACCIÓN ÚNICA (`deploy_wrapped.sql`)

> **TURNKEY (listo para correr):**
> - Runner con guard de SHA (recomendado): `bash shadow-patches/deploy/run_deploy.sh` — verifica `REVIEWED_SHA`+`ROLLBACK_SHA`, aborta si `SHA_DRIFT`, y corre el deploy atómico.
> - Deploy directo: `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f shadow-patches/deploy/deploy_iss003_009.sql` (usa `\ir ../iss003_009_mlb_governance.sql`; POST-VERIFY A–G con `PASS` por invariante).
> - Smoke read-only: `shadow-patches/deploy/smoke_post_commit.sql`.
> - Rollback: `bash shadow-patches/deploy/run_rollback.sh` (o `psql -f shadow-patches/rollback/iss003_009_rollback.sql`).

```sql
\set ON_ERROR_STOP on
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;   -- snapshot estable para paridad P/EV
SET LOCAL lock_timeout      = '3s';
SET LOCAL statement_timeout = '60s';

-- 2.0 baselines drift-safe ANTES de la primera DDL (fijan el snapshot)
CREATE TEMP TABLE _vpc_base ON COMMIT DROP AS
  SELECT ordinal_position, column_name, data_type FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';                 -- contrato (43 filas)
CREATE TEMP TABLE _pev_before ON COMMIT DROP AS
  SELECT espn_event_id, mercado, pick_nombre, probabilidad_pct, ev_pct
    FROM public.v_pick_canonico;                                                 -- baseline P/EV
CREATE TEMP TABLE _vmm_before ON COMMIT DROP AS
  SELECT espn_event_id, nivel FROM public.v_mejores_picks_mlb;                   -- baseline visibilidad MLB (assert G)

-- 2.1 === ARTEFACTO CONGELADO, BYTE-EXACTO (SHA 57b7a40...cad) ===
\i shadow-patches/iss003_009_mlb_governance.sql
--      === FIN ARTEFACTO ===  (orden literal = Parte 1 → 2 → 4)

-- 2.2 POST-VERIFY (§6) — dentro de la MISMA transacción, antes del COMMIT.
COMMIT;
```
- El artefacto **no** contiene `BEGIN/COMMIT`; los pone el wrapper → una sola transacción.
- `ON_ERROR_STOP` + ausencia de `COMMIT` al fallar ⇒ **ROLLBACK** automático. **Sin reintento automático.**
- `REPEATABLE READ`: los datos quedan en un snapshot fijo; la única diferencia BEFORE/AFTER es el cambio de definición (lo que queremos medir). La transacción ve su propia DDL (contrato 44 visible; `es_pick_reason` legible tras la Parte 1).
- `CREATE OR REPLACE VIEW` rechaza renombrar/reordenar/cambiar tipo o **quitar** columnas → refuerza el contrato aditivo a nivel motor.

---

## 6. FASE 3 — POST-VERIFY (misma transacción, antes del COMMIT)

```sql
DO $verify$
DECLARE
  ncol int; c44 text; t44 text; ndiff int; ncalls int; n_ovl int;
  ac_ee int; ac_rc int;
  vpc_es_pick int; vmm_reco int; vmm_elig int;
  moh_kelly int; reto_monto int; reto_puede int;
  p_diff int; ev_diff int;
BEGIN
  ---------- A. CONTRATO v_pick_canonico ----------
  SELECT count(*) INTO ncol FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico';
  IF ncol<>44 THEN RAISE EXCEPTION 'FAIL A1 vpc cols=% (exp 44)', ncol; END IF;

  SELECT column_name,data_type INTO c44,t44 FROM information_schema.columns
   WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position=44;
  IF c44 IS DISTINCT FROM 'es_pick_reason' OR t44 IS DISTINCT FROM 'text'
    THEN RAISE EXCEPTION 'FAIL A2 col44=%/%', c44,t44; END IF;

  SELECT count(*) INTO ndiff FROM (
    SELECT ordinal_position,column_name,data_type FROM _vpc_base
    EXCEPT
    SELECT ordinal_position,column_name,data_type FROM information_schema.columns
     WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position<=43) d;
  IF ndiff<>0 THEN RAISE EXCEPTION 'FAIL A3 primeras-43 drift=%', ndiff; END IF;

  SELECT (length(v)-length(replace(v,'economic_eligibility_v1(','')))/length('economic_eligibility_v1(')
    INTO ncalls FROM (SELECT pg_get_viewdef('public.v_pick_canonico'::regclass,true) v) q;
  IF ncalls<>1 THEN RAISE EXCEPTION 'FAIL A4 eev1 calls=% (exp 1)', ncalls; END IF;

  ---------- B. analisis_completo (overload guard + llaves, SIN LIMIT 1) ----------
  SELECT count(*) INTO n_ovl FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
   WHERE n.nspname='public' AND p.proname='analisis_completo';
  IF n_ovl<>1 THEN RAISE EXCEPTION 'FAIL B0 analisis_completo overloads=% (exp 1) ABORT', n_ovl; END IF;
  SELECT (length(d)-length(replace(d,'economically_eligible','')))/length('economically_eligible'),
         (length(d)-length(replace(d,'eligibility_reason_code','')))/length('eligibility_reason_code')
    INTO ac_ee,ac_rc
    FROM (SELECT pg_get_functiondef('public.analisis_completo(text)'::regprocedure) d) q;   -- firma exacta, no LIMIT 1
  IF ac_ee<1 OR ac_rc<1 THEN RAISE EXCEPTION 'FAIL B1 keys ee=% rc=%', ac_ee,ac_rc; END IF;

  ---------- C. CONTRATO v_mejores_picks_mlb ----------
  PERFORM 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='v_mejores_picks_mlb' AND column_name='economically_eligible';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C1 vmm falta economically_eligible'; END IF;
  PERFORM 1 FROM information_schema.columns WHERE table_schema='public'
    AND table_name='v_mejores_picks_mlb' AND column_name='reason_code';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL C2 vmm falta reason_code'; END IF;

  ---------- D. INVARIANTES BAJO NONE ----------
  SELECT count(*) INTO vpc_es_pick FROM public.v_pick_canonico WHERE es_pick IS TRUE;
  IF vpc_es_pick<>0 THEN RAISE EXCEPTION 'FAIL D1 es_pick=true=% (exp 0)', vpc_es_pick; END IF;
  SELECT count(*) INTO vmm_reco FROM public.v_mejores_picks_mlb WHERE nivel IN ('ojo','fuerte');
  IF vmm_reco<>0 THEN RAISE EXCEPTION 'FAIL D2 vmm nivel ojo/fuerte=% (exp 0)', vmm_reco; END IF;
  SELECT count(*) INTO vmm_elig FROM public.v_mejores_picks_mlb WHERE economically_eligible IS TRUE;
  IF vmm_elig<>0 THEN RAISE EXCEPTION 'FAIL D3 vmm economically_eligible=true=% (exp 0)', vmm_elig; END IF;

  ---------- E. DINERO REAL (superficies automáticas en alcance; hoy verificadas =0) ----------
  SELECT count(*) INTO moh_kelly FROM public.mejor_oportunidad_hoy(500) WHERE kelly_pct>0;
  IF moh_kelly<>0 THEN RAISE EXCEPTION 'FAIL E1 mejor_oportunidad_hoy kelly_pct>0=% (exp 0)', moh_kelly; END IF;
  SELECT count(*) INTO reto_monto FROM public.usuarios u
    CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r WHERE r.monto_autorizado>0;
  IF reto_monto<>0 THEN RAISE EXCEPTION 'FAIL E2 reto_picks_hoy monto_autorizado>0=% (exp 0)', reto_monto; END IF;
  SELECT count(*) INTO reto_puede FROM public.usuarios u
    CROSS JOIN LATERAL public.reto_picks_hoy(u.apodo) r WHERE r.puede_apostar IS TRUE;
  IF reto_puede<>0 THEN RAISE EXCEPTION 'FAIL E3 reto_picks_hoy puede_apostar=% (exp 0)', reto_puede; END IF;

  ---------- F. PARIDAD P/EV (BEFORE vs AFTER, bidireccional) ----------
  SELECT count(*) INTO p_diff FROM (
    (SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM _pev_before
     EXCEPT ALL
     SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM public.v_pick_canonico)
    UNION ALL
    (SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM public.v_pick_canonico
     EXCEPT ALL
     SELECT espn_event_id,mercado,pick_nombre,probabilidad_pct FROM _pev_before)) d;
  IF p_diff<>0 THEN RAISE EXCEPTION 'FAIL F1 P_VALUE_DIFF=% (exp 0)', p_diff; END IF;
  SELECT count(*) INTO ev_diff FROM (
    (SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM _pev_before
     EXCEPT ALL
     SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM public.v_pick_canonico)
    UNION ALL
    (SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM public.v_pick_canonico
     EXCEPT ALL
     SELECT espn_event_id,mercado,pick_nombre,ev_pct FROM _pev_before)) d;
  IF ev_diff<>0 THEN RAISE EXCEPTION 'FAIL F2 EV_VALUE_DIFF=% (exp 0)', ev_diff; END IF;

  ---------- G. ISS-009 VISIBILIDAD SEMÁNTICA (obligatorio) ----------
  -- G1 ningún evento MLB desaparece; G2 las ojo/fuerte -> informativo (visibles);
  -- G3 economically_eligible=false; G4 reason_code=MODEL_VERSION_PROVENANCE_MISSING;
  -- G5 stake=0 / sin CTA económica derivada de esos eventos (kelly>0 = 0).
  -- (Ver el bloque completo en shadow-patches/deploy/deploy_iss003_009.sql)

  RAISE NOTICE 'POST-VERIFY OK — contrato/keys/NONE/dinero/paridad P-EV/visibilidad-MLB todos verdes';
END $verify$;
```
> **G (ISS-009 semantic visibility)** — comprobado explícitamente: las **N** filas MLB `ojo/fuerte` (N dinámico según la cartelera del día — 4–5 observadas) **no desaparecen** (G1), quedan **visibles como `informativo`** (G2), con `economically_eligible=false` (G3), `reason_code='MODEL_VERSION_PROVENANCE_MISSING'` = degradación esperada (G4), y **stake=0 sin CTA/autorización económica** derivada de esas filas (G5, ningún evento MLB genera `kelly_pct>0`). El assert es dinámico (`_vmm_before`), no hardcodea N. El POST-VERIFY emite `PASS <id>` por invariante; el primer `FAIL` aborta y hace ROLLBACK.

Mapa de criterios del auditor → asserts:
- **A1/A2/A3/A4**: 44 cols · col44=`es_pick_reason text` · primeras 43 idénticas · `economic_eligibility_v1` 1 llamada.
- **B0/B1**: overload_count=1 (ABORT si ≠1, sin `LIMIT 1`; usa `analisis_completo(text)::regprocedure`) · keys propagadas.
- **C1/C2**: `v_mejores_picks_mlb` con `economically_eligible`+`reason_code`.
- **D1/D2/D3**: NONE → 0 es_pick, 0 nivel ojo/fuerte, 0 economically_eligible.
- **E1/E2/E3 (dinero real, no "por construcción")**: `mejor_oportunidad_hoy(500).kelly_pct>0=0`; `reto_picks_hoy(apodo).monto_autorizado>0=0` y `puede_apostar=0` sobre TODOS los usuarios reales. *(Hoy verificado =0; son invariantes bajo NONE.)*
- **F1/F2 (paridad P/EV)**: `EXCEPT ALL` bidireccional BEFORE↔AFTER bajo `REPEATABLE READ` ⇒ `P_VALUE_DIFF=0`, `EV_VALUE_DIFF=0`. **El invariante es temporal dentro del mismo snapshot: `EV_BEFORE_DEPLOY == EV_AFTER_DEPLOY` y `P_BEFORE_DEPLOY == P_AFTER_DEPLOY`.** NO depende de ningún valor absoluto de EV (Athletics u otro): `ev_pct` es determinista `f(prob, momio)` y el momio de mercado se recaptura en vivo (`momio_capturado_at`), por lo que su valor absoluto varía entre observaciones/días (LIVE_ODDS_CHANGE / DIFFERENT_ROW) — eso NO es del deploy. La paridad exige que el deploy no cambie P/EV de NINGUNA fila en el instante del deploy, sea cual sea su valor.

Superficies de dinero **fuera de alcance** (no dependen de los objetos que cambian → el deploy no puede alterarlas; no se asertan aquí): `v_super_pick.kelly_pct_sugerido`, `favoritos_bien_pagados.fraccion`. Ver §11.

---

## 7. FASE 4 — COMMIT

`COMMIT;` solo si el bloque `DO $verify$` terminó con `NOTICE ... OK` sin excepción. Cualquier fallo → **ROLLBACK** (automático). **Sin reintento automático** de lock/timeout.

---

## 8. FASE 5 — SMOKE POST-COMMIT (READ-ONLY, conexión nueva)

```sql
-- S1 superficies vivas no rompen
SELECT 'v_pick_canonico' o,count(*) n FROM public.v_pick_canonico
UNION ALL SELECT 'v_mejores_picks_mlb',count(*) FROM public.v_mejores_picks_mlb
UNION ALL SELECT 'v_super_pick',count(*) FROM public.v_super_pick
UNION ALL SELECT 'v_oraculo_canonico',count(*) FROM public.v_oraculo_canonico
UNION ALL SELECT 'mejor_oportunidad_hoy',count(*) FROM public.mejor_oportunidad_hoy(500);
-- reto_picks_hoy/favoritos_bien_pagados requieren args; analisis_completo es FUNCTION(text) — smoke de payload = dossier frontend (S4)

-- S2 Athletics ML (columnas reales)
SELECT deporte,home,away,mercado,pick_nombre,ev_pct,calibracion_confiable,es_pick,es_pick_reason
  FROM public.v_pick_canonico
 WHERE deporte='baseball' AND (home ILIKE '%Athletics%' OR away ILIKE '%Athletics%')
 ORDER BY ev_pct DESC;
-- esperado: es_pick=false, es_pick_reason no nulo, calibracion_confiable=false, ev_pct intacto

-- S3 NONE persiste
SELECT count(*) authorized_models FROM public.economic_model_authority WHERE economic_authorized IS TRUE;  -- 0
```
**`VISUAL_FRONTEND_SMOKE_POST` (manual, PENDING_USER):** tras el COMMIT, abrir dossier MLB en el frontend (`ba828acc`) y confirmar que MLB aparece como **análisis informativo / no accionable** ("ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"), **sin** "PICK SUGERIDO" ni CTA de apuesta.
> Si los asserts DB pasaron pero `VISUAL_FRONTEND_SMOKE_POST` falla: **NO declarar éxito** — reportar inconsistencia frontend/backend y **mantener el incidente abierto**. No improvisar otro cambio.

---

## 9. FASE 6 — ROLLBACK (preparado; NO ejecutar salvo fallo crítico POST-COMMIT)

> **ROLLBACK PRIMARIO = SEMANTIC, NO CASCADE** (`shadow-patches/rollback/iss003_009_semantic_rollback.sql`,
> SHA `ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b`, `bash run_rollback.sh`).
> Restaura el COMPORTAMIENTO pre-deploy vía `CREATE OR REPLACE` (sin DROP): `analisis_completo`→def previa;
> `v_mejores_picks_mlb`/`v_pick_canonico`→lógica previa envuelta, conservando las columnas aditivas como
> inertes (NULL). **No dropea nada** → las 3 vistas dependientes, grants y owners quedan intactos
> (`RESTORE_BEHAVIOR + PRESERVE_AVAILABILITY + NO_CASCADE`). Cuerpos validados read-only (parse/plan OK).
>
> **ROLLBACK SECUNDARIO = STRUCTURAL, DROP CASCADE** (`iss003_009_rollback.sql`, SHA `32656fb3…3530`,
> `bash run_rollback.sh --structural`, solo offline). **Auditoría de cascada (catálogo, read-only):**
> `CASCADE_DEPENDENCY_COUNT=3` = {`lab_dq_medicion_v1`, `v_lab_dq_capturas_faltantes`, `v_oraculo_canonico`}
> (depth 1, sin nivel-2/matviews/tablas). `CASCADE_DROPPED_SET == ROLLBACK_RECREATED_SET` ⇒
> `FULL_STRUCTURAL_ROLLBACK = SAFE`. Aun así, por disponibilidad el primario es el semántico.

### (secundario) restauración estructural bit-a-bit

Archivo: `shadow-patches/rollback/iss003_009_rollback.sql` (69 940 bytes, SHA `32656fb3…3530`). Generado DB-side desde las defs vivas PRE-DEPLOY. **Ejecutable en orden correcto** (código, no solo nota):

```
BEGIN;  (lock_timeout 3s, statement_timeout 60s)
  1) CREATE OR REPLACE FUNCTION public.analisis_completo(text) ...      -- función late-bound, primero
  2) DROP VIEW public.v_mejores_picks_mlb;  CREATE OR REPLACE VIEW ...  -- 24→22 (0 vistas dependientes)
  3) DROP VIEW public.v_pick_canonico CASCADE;                          -- 44→43 (CREATE OR REPLACE no quita columnas)
     CREATE OR REPLACE VIEW public.v_pick_canonico ...
     CREATE OR REPLACE VIEW public.lab_dq_medicion_v1 ...               -- recrear 3 dependientes del CASCADE
     CREATE OR REPLACE VIEW public.v_lab_dq_capturas_faltantes ...
     CREATE OR REPLACE VIEW public.v_oraculo_canonico ...
  4) ALTER VIEW ... OWNER TO ...; ALTER VIEW ... SET (...); GRANT ... (146 GRANTs)  -- el DROP los borró; se reponen
COMMIT;
```
Notas críticas del rollback (asimetría con el deploy):
- El deploy usa `CREATE OR REPLACE` (aditivo, **preserva** grants/owner). El rollback **debe** `DROP` para quitar columnas ⇒ pierde owner/reloptions/grants ⇒ **se reponen dentro del mismo archivo** (capturados). Orden: analisis_completo → v_mejores_picks_mlb → v_pick_canonico (+cascade), como pide el auditor.
- `DROP VIEW public.v_pick_canonico CASCADE` elimina y recrea también `lab_dq_medicion_v1`, `v_lab_dq_capturas_faltantes`, `v_oraculo_canonico` (subárbol verificado; sin nivel-2).
- Antes de usarlo, re-verificar (P5) que las defs vivas siguen == las capturadas; si hubo cambios ajenos, regenerar el rollback + recalcular SHA.

---

## 10. NO HACER

❌ Autorizar modelos · ❌ recalibrar MLB · ❌ tocar P/EV/calibración/EXP_OFF · ❌ ejecutar la Parte 3
❌ abrir ISS-007 · ❌ tocar NFL/NHL/NBA/Tennis · ❌ refactors · ❌ re-desplegar frontend
❌ reintento automático tras lock/timeout · ❌ editar el artefacto en caliente · ❌ fabricar `stake=$0`
❌ `execute_sql`/paste manual de los 36 KB (transporte BLOCKED — lo corre el usuario por psql/editor)

---

## 11. AUDITORÍA ESTÁTICA DE BYPASS (tarea 5) — read-only, `GLOBAL_BYPASS_SWEEP = PASS (MLB)`

Barrido de todas las vistas + funciones de `public` por: `calibracion_confiable`, `COALESCE(confiable, true)`, `PICK SUGERIDO`, `FUERTE`, `ELITE`, `APOSTAR`, `economically_eligible`, `es_pick`, `es_pick_reason`, `eligibility_reason_code`.

Clasificación (superficies relevantes a gobernanza MLB):

| Objeto | Token | Clase | Nota |
|--------|-------|-------|------|
| `v_pick_canonico` | es_pick, `economic_eligibility_v1`, calib | **CANONICAL_GATED** | fuente del gate; post-deploy 1 llamada + es_pick_reason |
| `v_mejores_picks_mlb` | `COALESCE(confiable,true)` HOY | **CANONICAL_GATED (post-deploy)** | la Parte 2 lo pasa a `false` + gate por `economic_eligibility_v1` |
| `decision_pick_v1` | `economic_eligibility_v1`, ee | **CANONICAL_GATED** | autoridad de decisión |
| `mejor_oportunidad_hoy(_v2)` | es_pick, ee | **CANONICAL_GATED** | filtra por es_pick; `kelly_pct>0`=0 bajo NONE (verif.) |
| `reto_picks_hoy__base` | es_pick | **CANONICAL_GATED** | `monto_autorizado>0`=0 / `puede_apostar`=0 (verif. 4 usuarios) |
| `rongol_veto__base` | es_pick | **CANONICAL_GATED** | veto consume es_pick |
| `filtro_pick` | es_pick | **CANONICAL_GATED** | helper del gate |
| `v_oraculo_canonico` | es_pick, calib | **CANONICAL_GATED** | dependiente de v_pick_canonico (consume es_pick) |
| `analisis_completo(text)` | "PICK SUGERIDO"/ee (post) | **INFORMATIONAL_ONLY** | backend propaga flag; el wording accionable lo decide el frontend fail-closed |
| `favoritos_bien_pagados` | ee | **INFORMATIONAL/OUT-OF-SCOPE** | no depende de objetos del deploy; `fraccion` por su propio path |
| `v_super_pick` | (APOSTAR/ELITE txt) | **OUT-OF-SCOPE** | no depende de v_pick_canonico/v_mejores_picks_mlb |
| `picks_recomendados_hoy(_raw)` | (recomendación) | **OUT-OF-SCOPE (fútbol legacy)** | joins ligamx/API-Football; 0 MLB; ver #201/#202/#204 |
| `picks_premium` | (nivel/ELITE) | **OUT-OF-SCOPE (fútbol legacy)** | fixture_id/ligamx; sin `deporte`; 0 MLB |
| `futbol_que_falta_por_caer` | `COALESCE(confiable,true)` | **OUT-OF-SCOPE (fútbol)** | fail-open de calibración **de fútbol**; no MLB; adjacente a ISS-003 pero fuera de ISS-003/009 |
| resto (`*parlay*`,`fantasy_*`,`nfl_*`,`kelly_*`,`track_*`,…) | "APOSTAR"/"ELITE" texto | **INFORMATIONAL/MANUAL_ONLY** | texto UI / builders manuales; sin gate MLB automático |

**Resultado: 0 `BYPASS_OPEN` para MLB.** Ninguna superficie presenta MLB como PICK/ELITE/APOSTAR con dinero automático sin pasar por `es_pick`/`economic_eligibility_v1`. Observación adjacente (NO bloqueante, fuera de ISS-003/009): las superficies **de fútbol** `picks_recomendados_hoy`, `picks_premium`, `futbol_que_falta_por_caer` recomiendan por su propio motor (no por la autoridad económica) — es la brecha de gobernanza de fútbol ya rastreada (#201/#202/#204/#206), no un bypass MLB.

---

## 12. GATE DE AUTORIZACIÓN

- [x] `FINAL_DEPLOY_ARTIFACT` congelado; `REVIEWED_SHA` revalidado (freeze intacto)
- [x] `ROLLBACK_ARTIFACT` real, ejecutable, orden correcto, SHA calculado, no vacío
- [x] `SAFE_SQL_TRANSPORT` probado → **BLOCKED** (lo ejecuta el usuario por psql/editor)
- [x] POST-VERIFY con asserts reales de contrato, NONE, **dinero** y **paridad P/EV**
- [x] `analisis_completo` con overload guard (ABORT si ≠1) + firma exacta (sin LIMIT 1)
- [x] `GLOBAL_BYPASS_SWEEP = PASS (MLB)`
- [ ] `VISUAL_FRONTEND_SMOKE_PRE` = **PENDING_USER** (dossier MLB carga OK, ANTES del deploy — si falla, NO DEPLOY)
- [ ] `VISUAL_FRONTEND_SMOKE_POST` = **PENDING_USER** (tras deploy: MLB informativo/no accionable, sin "PICK SUGERIDO")
- [ ] `LOCAL_TSGO = NOT_APPLICABLE` · `LOVABLE_FRONTEND_BUILD = PASS @ ba828acc`
- [ ] **GO explícito del auditor** → recién entonces ejecutar el flujo §0.1

**Estado:** `DEPLOY_RUNBOOK_EXECUTABLE = READY` · `DEPLOY_AUTHORIZATION = PENDING_USER` · **NO DEPLOY.**
