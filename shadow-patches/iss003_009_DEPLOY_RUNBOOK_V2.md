# RUNBOOK V2 — DEPLOY SQL · ISS-003 / ISS-009 / ISS-009B (Gobernanza MLB)

> **ESTADO: NO DEPLOY.** `DEPLOY_RUNBOOK_V2_DESIGN = PASS` · `DEPLOY_AUTHORIZATION = PENDING_USER`
> Rev. V2 — corrige el defecto posicional que hizo abortar el intento de deploy y endurece los asserts.

---

## 0. POR QUÉ EXISTE V2

El intento de deploy de V1 abortó en la Parte 2 con:

```
ERROR: cannot change name of view column "nivel" to "economically_eligible"
```

`CREATE OR REPLACE VIEW` en PostgreSQL solo permite **añadir columnas al final**: las
preexistentes deben conservar nombre, tipo **y posición**. V1 insertaba
`economically_eligible`/`reason_code` en las posiciones 15/16, desplazando `nivel` de 15 a 17.

Defecto **determinista**: V1 no era ejecutable en ningún entorno. La transacción revirtió
sola y producción quedó intacta (auditoría post-failure: `PRODUCTION_PERSISTENT_CHANGE = NONE`).

**V1 `57b7a40…d4cad` queda RETIRED / DO_NOT_DEPLOY.**

---

## 1. ARTEFACTOS V2

| Rol | Archivo | SHA-256 |
|---|---|---|
| Artefacto | `shadow-patches/iss003_009_mlb_governance_v2.sql` | `15642eb149c065fb4cbd21c9c918cbe145f90064ee5975b4721ca38eaeb4be52` |
| Wrapper | `shadow-patches/deploy/deploy_iss003_009_v2.sql` | (ver §6) |
| Runner | `shadow-patches/deploy/run_deploy_v2.sh` | (ver §6) |
| Rollback primario (semántico, NO CASCADE) | `shadow-patches/rollback/iss003_009_semantic_rollback.sql` | `ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b` |
| Rollback secundario (estructural) | `shadow-patches/rollback/iss003_009_rollback.sql` | `32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530` |

**Los rollbacks NO cambian en V2.** Ambos ya usan el patrón correcto
(`SELECT sub.*, NULL::boolean AS economically_eligible, NULL::text AS reason_code`), es decir,
apéndice al final — que es exactamente el contrato que V2 produce. El rollback ya era
V2-compatible; era el artefacto V1 el que discrepaba de su propio rollback.

⚠ **El rollback estructural contiene `DROP VIEW public.v_pick_canonico CASCADE` (línea 565)**,
que arrastra 3 dependientes. Por eso es **secundario/offline**: usar siempre el primario semántico.

---

## 2. ÚNICO CAMBIO FUNCIONAL V2 vs V1

En la Parte 2, las dos columnas nuevas se mueven al final del SELECT. Las expresiones se
trasladan **byte a byte**; no se reescribe ninguna. No cambia P, EV, Kelly, modelos,
thresholds ni autoridad económica.

### Evidencia ordinal — `v_mejores_picks_mlb`

| # | BEFORE (vivo) | AFTER (V2) | |
|---|---|---|---|
| 1–14 | espn_event_id … calibrado | idénticas | OK |
| **15** | **nivel** | **nivel** | OK (V1 lo desplazaba a 17) |
| 16–22 | detalle … pick_es_favorito | idénticas | OK |
| 23 | — | economically_eligible (boolean) | nueva, al final |
| 24 | — | reason_code (text) | nueva, al final |

### Evidencia ordinal — `v_pick_canonico`

| # | BEFORE (vivo) | AFTER (V2) | |
|---|---|---|---|
| 1–43 | espn_event_id … zona | idénticas | OK |
| 44 | — | es_pick_reason (text) | nueva, al final |

La Parte 1 ya era correcta en V1; no se tocó.

---

## 3. PREFLIGHT READ-ONLY — GUARD OBLIGATORIO

⚠ **`PGOPTIONS='-c default_transaction_read_only=on'` NO es garantía.** La conexión pasa por
el pooler de Supabase (`...pooler.supabase.com`), que **descarta silenciosamente** los
parámetros de arranque: `SHOW transaction_read_only` devuelve `off` aunque se haya pedido `on`.

Usar **siempre** el guard explícito y **exigir `on`** antes de auditar:

```sql
BEGIN READ ONLY;
SHOW transaction_read_only;   -- DEBE devolver 'on'; si no -> ABORT
-- ... consultas de auditoría ...
ROLLBACK;
```

`run_deploy_v2.sh` ejecuta este guard automáticamente y aborta con exit 4 si no devuelve `on`.

### Precondiciones (ABORT si alguna falla)

```sql
BEGIN READ ONLY;
SHOW transaction_read_only;                                                     -- 'on'
SELECT count(*) FROM public.economic_model_authority WHERE economic_authorized; -- 0
SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND p.proname='analisis_completo';                    -- 1
SELECT count(*) FROM pg_locks l JOIN pg_class c ON c.oid=l.relation
  JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname='public' AND c.relname IN ('v_pick_canonico','v_mejores_picks_mlb')
   AND NOT l.granted;                                                           -- 0
SELECT count(*) FROM pg_stat_activity WHERE datname=current_database()
   AND pid<>pg_backend_pid() AND state='idle in transaction';                   -- 0
ROLLBACK;
```

**Nota operativa:** el pooler puede devolver `FATAL: (EAUTHQUERY) auth_query secret check timed out`
de forma transitoria. Ocurre **antes** de abrir transacción alguna; reintentar es seguro.

---

## 4. ASSERTS A–I (endurecidos en V2)

| Bloque | Qué prueba | Novedad V2 |
|---|---|---|
| A | Contrato `v_pick_canonico`: 44 cols, #44 additiva, 1–43 idénticas, eev1 llamada 1 vez | — |
| B | `analisis_completo`: 1 overload, propaga ambas llaves | — |
| C | **Compatibilidad ordinal de `v_mejores_picks_mlb`**: 24 cols, 1–22 idénticas en posición/nombre/tipo, nuevas solo en 23/24 | **NUEVO — es el guard que faltaba** |
| D | Bajo NONE: `es_pick`=0, `ojo/fuerte`=0, `economically_eligible`=0 | — |
| E | Dinero: `mejor_oportunidad_hoy`, `reto_picks_hoy` | **clasifica cobertura** |
| F | Paridad P/EV bidireccional | — |
| G | Visibilidad semántica MLB (G1–G5) | **G2/G5 clasifican cobertura** |
| H | **Autoridad económica autoritativa, independiente de cartelera** | **NUEVO** |
| I | **ISS-003a: `calibracion_confiable` MLB = FALSE, con cobertura medida** | **NUEVO** |

### 4.1 Cobertura vacía ≠ cobertura real

Los asserts económicos ya no se declaran PASS a secas. Cada uno reporta **filas evaluadas**
y **violaciones**, y se clasifica:

- `PASS_NONEMPTY` — filas > 0 y violaciones = 0 → **cobertura sustantiva**.
- `PASS_EMPTY_COVERAGE` — filas = 0 → demuestra que no apareció dinero en esa consulta, pero
  **NO es cobertura real**. Se cuenta y se lista en el resumen final.
- `FAIL` — violaciones > 0 → excepción → ROLLBACK total.

Motivo: en el estado observado, `public.usuarios` devuelve 0 filas y `mejor_oportunidad_hoy(500)`
devuelve 0 filas, así que **E1/E2/E3/G5 de V1 pasaban sobre conjunto vacío** sin ejercer nada.

### 4.2 Fuentes económicas autoritativas (bloque H)

Identificadas por inspección read-only, **no inventadas**:

| Fuente | Tipo | Papel |
|---|---|---|
| `public.economic_model_authority` | tabla | **Registro autoritativo.** 0 filas ⇒ `CURRENT_AUTHORIZED_MODELS = NONE` |
| `public.economic_model_authorized(deporte,mercado,fuente,model_version)` | función | Lee el registro; devuelve `false` sin fila autorizada |
| `public.economic_eligibility_v1(jsonb)` | función | Gate único; `g_auth` delega en la anterior |

Sondas (no dependen de partidos ni usuarios):

- **H1/H2** — 0 modelos autorizados; 0 autorizados para `baseball`.
- **H3** — ctx MLB real (`model_version=NULL`, EV=99) ⇒ `eligible=false`, `MODEL_VERSION_PROVENANCE_MISSING`.
- **H4 (adversarial)** — ctx forzado con `model_version='v99.9'` **y `model_skill='SKILL_PASS'`** y todos
  los gates en verde ⇒ sigue `eligible=false` con `ECONOMIC_MODEL_UNAUTHORIZED`. Cierra
  explícitamente la superficie de bypass que documenta la Parte 3 del artefacto.
- **H5** — `economic_model_authorized('baseball',…)` = `false`.
- **H6** — gate `model_skill` = `false` ⇒ `MODEL_SKILL = INSUFFICIENT`.

### 4.3 Sobre `edge_confiable` / EDGE_RELIABILITY

**No existe como objeto físico** en la base (0 columnas, 0 referencias en código). Es una
**convención semántica** del review: `mm.confiable` conserva significado de *edge* y **no** se
remapea a `calibracion_confiable`. Se verifica **estáticamente** sobre el artefacto:

- `COALESCE(j.confiable, false)` presente (línea 536) — edge preservado, NULL=FAIL (ISS-003b).
- `false AS bool` en el arm MLB (línea 178) — `calibracion_confiable` fail-closed (ISS-003a).
- 0 ocurrencias de un remap `confiable → calibracion_confiable`.

No se fabrica un assert runtime sobre una columna inexistente.

---

## 5. EJECUCIÓN

```bash
export DATABASE_URL='postgresql://…'          # no pegar en chat
bash shadow-patches/deploy/run_deploy_v2.sh   # SHA guard -> preflight guard -> deploy atómico
# OK    -> psql "$DATABASE_URL" -f shadow-patches/deploy/smoke_post_commit.sql
# FALLO -> ya revirtió solo; el rollback primario solo si hay cambio persistente demostrado
```

Exit codes: `0` APPLIED · `2` SHA_DRIFT · `3` assert FAIL (revertido) · `4` guard read-only no verificable.

---

## 6. VALIDACIÓN REALIZADA

- Sintaxis shell (`bash -n`): PASS · SHA incrustado coherente con el archivo: PASS
- Paréntesis balanceados y dollar-quotes pareados en artefacto y wrapper: PASS
- Compatibilidad ordinal de ambas vistas: PASS (tablas §2)
- 0 DML · 0 `DROP … CASCADE` en artefacto y wrapper V2
- 17/17 objetos dependientes existen en producción (verificado read-only)
- Diff V1↔V2 limitado al bloque movido (9 líneas) + comas + cabecera

**`RUNTIME_DDL_VALIDATION = PASS`** (DDL, ordinal, dependencias, asserts, rollback)

Laboratorio: clúster PostgreSQL **17.11 local efímero** (prod es 17.6 — misma major, que es
la que fija la semántica de `CREATE OR REPLACE VIEW`), arrancado con `initdb` + `pg_ctl`,
**solo socket unix** (`listen_addresses=''`), sin puerto TCP, sin servicio y sin daemon.
Schema replicado con `pg_dump --schema-only` (lectura pura, **sin datos**).

**Fidelidad verificada:** los md5 de `pg_get_viewdef`/`pg_get_functiondef` de los 4 objetos
críticos (`v_pick_canonico`, `v_mejores_picks_mlb`, `analisis_completo`,
`economic_eligibility_v1`) son **idénticos** entre lab y producción.

| Test | Qué prueba | Resultado |
|---|---|---|
| T1 | V1 (RETIRED) debe fallar por incompatibilidad ordinal | **PASS** — mismo error, misma línea 554; rollback total (43/22) |
| T2 | V2 aplica con asserts A–I | **PASS** — COMMIT |
| T3 | Compatibilidad ordinal runtime | **PASS** — `nivel` en 15; nuevas en 23/24; `es_pick_reason` en 44 |
| T5 | Rollback primario semántico | **PASS** — comportamiento restaurado, columnas aditivas inertes |
| T6 | Re-apply V2 tras rollback (idempotencia) | **PASS** (tras corregir A3/C2, ver abajo) |
| T7 | Assert FAIL revierte TODO | **PASS** — Partes 1, 2 y 4 sin rastro |

Reproducible con: `bash shadow-patches/tests/lab_runtime_validation.sh <socket> <template>`

### Defecto encontrado y corregido por el runtime (A3/C2)

T6 falló inicialmente con `FAIL A3 primeras-43 drift=1`. Causa: tras un rollback semántico,
`v_pick_canonico` conserva la columna aditiva #44 inerte, y A3 comparaba el baseline
**completo** (44 filas) contra `ordinal_position<=43` del estado actual → un elemento sin
pareja → FAIL espurio que habría **bloqueado un re-deploy legítimo tras rollback**. `C2` tenía
el mismo defecto para 23/24. Ambos se acotaron al rango de columnas preexistentes
(`WHERE ordinal_position<=43` / `<=22`). Es un fallo *fail-closed* (no habría causado daño),
pero solo aparece en ejecución: es exactamente lo que la validación estática no podía ver.

### Limitación honesta de la cobertura

El lab **no tiene datos** (por política: "no uses datos sensibles de producción"). Por tanto
los asserts dependientes de cartelera/usuarios se ejecutaron sobre conjunto vacío y se
reportan como **`PASS_EMPTY_COVERAGE`**, no como PASS sustantivo:

`E1` `E2` `E3` `G2` `G5` `I1` — 6 asserts sin cobertura real en el lab.

Los que sí tuvieron cobertura sustantiva en lab: **A1–A4, B0–B1, C1–C4, D1–D3, F1–F2, G1, G3,
G4, H1–H6**. En producción, `I1` sí tiene cobertura real (140 filas MLB observadas read-only)
y `G2`/`G5` dependerán de la cartelera del día.

**Lo que sigue sin validarse en runtime:** el comportamiento de los asserts económicos con
datos reales. Solo se ejercitará en el deploy real contra producción.
