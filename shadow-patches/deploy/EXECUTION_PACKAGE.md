# EXECUTION PACKAGE — ISS-003 / ISS-009 / ISS-009B

> Ejecutar SOLO cuando exista `DATABASE_URL` a PROD (transporte SQL atómico por archivo).
> No contiene credenciales. No modifica el SQL congelado. Un solo comando, atómico, con rollback.
> Estado hasta que exista transporte: `SAFE_SQL_TRANSPORT = BLOCKED`, `DEPLOY_AUTHORIZATION = PENDING_USER`.

---

## PRECHECK (antes de exportar DATABASE_URL)

```bash
cd <repo-root>
git rev-parse --abbrev-ref HEAD        # -> claude/reto-13m-espn-matches-3uknie
git status --short                      # -> vacío (working tree limpio)

# FREEZE del artefacto congelado (DEBE coincidir; si no: SHA_DRIFT=YES -> NO DEPLOY)
sha256sum shadow-patches/iss003_009_mlb_governance.sql
# esperado: 57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad

# FREEZE del rollback (DEBE coincidir)
sha256sum shadow-patches/rollback/iss003_009_rollback.sql
# esperado: 32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530
```
`VISUAL_FRONTEND_SMOKE_PRE` (manual): abrir el dossier MLB en el frontend y confirmar que **carga sin errores**. Si falla → **NO DEPLOY**.

---

## EXACT COMMAND

```bash
DATABASE_URL='postgresql://<user>:<pass>@<host>:5432/postgres' \
  bash shadow-patches/deploy/run_deploy.sh
```
- `run_deploy.sh` primero verifica `REVIEWED_SHA` + `ROLLBACK_SHA` (aborta antes de conectar si hay `SHA_DRIFT`), luego aplica el artefacto congelado **en una sola transacción** con `psql -v ON_ERROR_STOP=1`, corriendo el POST-VERIFY A–G antes del COMMIT.
- No hay reintento automático. No pega el archivo grande (usa `\ir`). No imprime credenciales.

---

## EXPECTED OUTPUT (éxito)

```
SHA_DRIFT=NO  (artefacto y rollback congelados OK)
Aplicando deploy atómico ...
NOTICE:  PASS A1 v_pick_canonico = 44 columnas
NOTICE:  PASS A2 col44 = es_pick_reason text
NOTICE:  PASS A3 primeras 43 columnas idénticas
NOTICE:  PASS A4 economic_eligibility_v1 llamada 1 sola vez
NOTICE:  PASS B0 analisis_completo overload_count = 1
NOTICE:  PASS B1 analisis_completo propaga economically_eligible + eligibility_reason_code
NOTICE:  PASS C1/C2 v_mejores_picks_mlb con economically_eligible + reason_code
NOTICE:  PASS D1 v_pick_canonico es_pick=true = 0
NOTICE:  PASS D2 v_mejores_picks_mlb nivel ojo/fuerte = 0
NOTICE:  PASS D3 v_mejores_picks_mlb economically_eligible=true = 0
NOTICE:  PASS E1 mejor_oportunidad_hoy kelly_pct>0 = 0
NOTICE:  PASS E2 reto_picks_hoy monto_autorizado>0 = 0 (todos los usuarios)
NOTICE:  PASS E3 reto_picks_hoy puede_apostar = 0 (todos los usuarios)
NOTICE:  PASS F1 P_VALUE_DIFF = 0
NOTICE:  PASS F2 EV_VALUE_DIFF = 0
NOTICE:  INFO G0 filas MLB ojo/fuerte pre-deploy = <N dinámico>
NOTICE:  PASS G1 ningún evento MLB desapareció (0)
NOTICE:  PASS G2 las <N> MLB ojo/fuerte quedan visibles como informativo
NOTICE:  PASS G3 economically_eligible=false en toda la MLB
NOTICE:  PASS G4 reason_code=MODEL_VERSION_PROVENANCE_MISSING en toda la MLB
NOTICE:  PASS G5 stake=0 / sin CTA económica derivada de las filas MLB
NOTICE:  ==== POST-VERIFY OK: A/B/C/D/E/F/G todos PASS -> COMMIT permitido ====
COMMIT
DEPLOY=APPLIED  (todos los asserts PASS; COMMIT hecho)
```

---

## SUCCESS CRITERIA

- `run_deploy.sh` termina con **exit 0** y `DEPLOY=APPLIED`.
- Aparecen **todos** los `PASS A1…G5` y el `COMMIT`.
- Sólo entonces: `POST_DEPLOY_ASSERTS = PASS`. (Antes de ejecutar, los asserts son `NOT_RUN`.)

---

## FAILURE CRITERIA

- `SHA_DRIFT=YES` → el runner hace **exit 2 sin conectar**. No se tocó prod. Regenerar/restaurar el artefacto correcto; NO editar el SQL.
- Cualquier `FAIL <id>` en el POST-VERIFY → la transacción hace **ROLLBACK automático** (nada queda aplicado); el runner termina **exit 3** con `DEPLOY=ABORTED`. Diagnosticar el `FAIL`; **no** reintentar ciego, **no** hotfix, **no** editar el SQL.
- Error de `lock_timeout`/`statement_timeout` → ROLLBACK; reintentar solo manualmente tras confirmar que no hay sesiones bloqueantes.

---

## POST-SMOKE

`VISUAL_FRONTEND_SMOKE_POST` (manual): abrir dossier MLB → debe verse **"ANÁLISIS INFORMATIVO — NO APUESTA AUTORIZADA"**, **sin** "PICK SUGERIDO" ni CTA de apuesta ni stake.
Read-only backend (opcional):
```bash
psql "$DATABASE_URL" -f shadow-patches/deploy/smoke_post_commit.sql
```
- Si **asserts DB = PASS pero POST-SMOKE visual falla**: NO declarar éxito. Registrar `DEPLOYED_DB_VERIFIED_UI_INCONSISTENT`, reportar inconsistencia frontend/backend, mantener incidente abierto, **no improvisar** otro cambio.

---

## ROLLBACK COMMAND (solo ante fallo crítico POST-COMMIT)

**PRIMARIO — SEMANTIC (NO CASCADE), preserva disponibilidad:**
```bash
DATABASE_URL='postgresql://<user>:<pass>@<host>:5432/postgres' \
  bash shadow-patches/deploy/run_rollback.sh
```
- Verifica `SEMANTIC_ROLLBACK_SHA` y restaura el **comportamiento** pre-deploy vía `CREATE OR REPLACE` (sin DROP): `analisis_completo` → def previa; `v_mejores_picks_mlb`/`v_pick_canonico` → lógica previa envuelta, conservando las columnas aditivas como inertes (NULL). **No dropea nada** → las 3 vistas dependientes, grants y owners quedan intactos.

**SECUNDARIO — STRUCTURAL (DROP CASCADE), solo offline:**
```bash
DATABASE_URL='...' bash shadow-patches/deploy/run_rollback.sh --structural
```
- Verifica `ROLLBACK_ARTIFACT_SHA` y restaura el esquema bit-a-bit (43/22 cols) con `DROP … CASCADE` + recrear subárbol + owners/reloptions/grants. Cascade auditado exhaustivo: `CASCADE_DROPPED_SET == ROLLBACK_RECREATED_SET` (3 vistas), `FULL_STRUCTURAL_ROLLBACK=SAFE`. Úsalo solo en ventana controlada.
- Un fallo dentro del deploy ya revierte solo (no requiere ningún rollback). Usa el rollback solo si un smoke post-COMMIT revela regresión real.

```
SEMANTIC_ROLLBACK_SHA   = ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b
STRUCTURAL_ROLLBACK_SHA = 32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530
```

---

## ANCLAS (freeze)

```
SQL_ARTIFACT_SHA      = 57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad
ROLLBACK_ARTIFACT_SHA = 32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530
INVARIANTES           = CURRENT_AUTHORIZED_MODELS=NONE · MLB_ECONOMIC_AUTHORIZED=FALSE · MLB_STAKE=$0
```
Si el SQL congelado cambia por cualquier razón → `SHA_DRIFT=YES`, `READY_FOR_EXECUTION=NO`, detener.
