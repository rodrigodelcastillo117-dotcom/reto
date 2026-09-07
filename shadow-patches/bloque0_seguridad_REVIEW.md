# BLOQUE 0 — SEGURIDAD · Patch para revisión (NO DESPLEGADO)

**Cubre:** ISS-001 (IDOR escritura dinero) · ISS-002 (IDOR lectura financiera) · ISS-008 (wrappers DEFINER a anon/PUBLIC).
**Patch SQL:** `shadow-patches/bloque0_seguridad.sql` — **no aplicado**. Requiere GO.
**Reglas honradas:** no toca modelos/prob/EV/Kelly/gates; identidad deriva de `auth.uid()` vía `apodo_scope`/`resolver_identidad_economica` (#262, ya en prod); `p_apodo` se conserva por compatibilidad pero se valida server-side; ruta service_role/INTERNAL preservada y auditable; revoca anon/PUBLIC de RPC mutables; consumidores inventariados antes de revocar.

---

## SQL_DIFF (resumen — el archivo trae el CREATE OR REPLACE completo)

**ISS-001 · registrar_ajuste_manual / registrar_movimiento_cuenta** — se añade al INICIO (resto del cuerpo intacto):
```
+ v_ident := public.resolver_identidad_economica(p_apodo);
+ IF NOT COALESCE((v_ident->>'ok')::boolean,false) THEN
+     RAISE EXCEPTION 'IDENTIDAD_RECHAZADA: %', COALESCE(v_ident->>'motivo','CONTEXTO_NO_RECONOCIDO');  -- (movimiento: return jsonb error)
+ END IF;
+ p_apodo := v_ident->>'apodo';
```
**ISS-002 · get_dashboard_stats / get_historial_reciente** — una línea al INICIO (resto intacto):
```
+ p_apodo := public.apodo_scope(p_apodo);   -- auto-scope al apodo del JWT
```
**ISS-008 · solo GRANTS:**
```
REVOKE EXECUTE ON FUNCTION aceptar_batalla / cancelar_batalla / agregar_favorito / quitar_favorito / generar_codigo_amigo  FROM anon, PUBLIC;
REVOKE EXECUTE ON FUNCTION upsert_live_scores_guarded(jsonb)  FROM anon, authenticated, PUBLIC;
```

---

## GRANTS_BEFORE → GRANTS_AFTER

| Función | ANTES (EXECUTE) | DESPUÉS |
|---|---|---|
| registrar_ajuste_manual | authenticated, service_role | **igual** (cambia el cuerpo, no el grant) |
| registrar_movimiento_cuenta | authenticated, service_role | **igual** |
| get_dashboard_stats | authenticated, service_role | **igual** |
| get_historial_reciente | authenticated, service_role | **igual** |
| aceptar_batalla | PUBLIC, anon, authenticated, service_role | authenticated, service_role |
| cancelar_batalla | PUBLIC, anon, authenticated, service_role | authenticated, service_role |
| agregar_favorito | PUBLIC, anon, authenticated, service_role | authenticated, service_role |
| quitar_favorito | PUBLIC, anon, authenticated, service_role | authenticated, service_role |
| generar_codigo_amigo | PUBLIC, anon, authenticated, service_role | authenticated, service_role |
| upsert_live_scores_guarded | PUBLIC, anon, authenticated, service_role | **service_role** |

*(ANTES verificado por SQL sobre `pg_proc.proacl` @AUDIT_AS_OF. `=X/postgres` = PUBLIC.)*

---

## DEPENDENCY_MAP (regla #7 — inventario antes de revocar)

- **pg_cron:** 0 jobs referencian ninguna de las 10 funciones. ✔
- **Edge functions / SQL del repo `/home/user/reto`:** 0 referencias a ninguna de las 10. ✔
- **Conclusión:** todas se invocan desde el **frontend (Lovable) con el JWT del usuario (authenticated)**, salvo `upsert_live_scores_guarded` que es escritura de pipeline (su tabla `live_scores` tiene RLS write=service_role → el escritor legítimo usa service_role).
- **Impacto en llamadas legítimas:**
  - ISS-001/002: **cero** — grants sin cambio; el usuario autenticado sigue leyendo/escribiendo lo suyo.
  - Batallas/favoritos/código: siguen disponibles para usuarios **logueados** (authenticated). Solo se corta el acceso **anónimo** (que no debía existir).
  - `upsert_live_scores_guarded`: queda solo service_role. **PRE-DEPLOY OBLIGATORIO:** confirmar en el frontend/edge Lovable que ningún path de cliente lo invoca (el escritor real debe ser la edge/cron de live-scores con service_role). Único punto con riesgo de romper algo si un cliente lo llamaba indebidamente.

---

## ADVERSARIAL_TESTS (a correr en LAB / transacción con ROLLBACK, tras GO — requieren 2 cuentas A y B)

> Simulan identidad con `request.jwt.claims`. Las de escritura van dentro de `BEGIN…ROLLBACK` para no mutar. NO ejecutadas aún (CANDADO FASE A: no escritura en prod).

```sql
-- Sustituir A_UID/A_APODO (atacante) y B_APODO (víctima) por cuentas de prueba reales.
-- LECTURA financiera (debe devolver datos de A, NO de B):
begin;
  select set_config('request.jwt.claims', json_build_object('sub','A_UID','role','authenticated')::text, true);
  set local role authenticated;
  select public.get_dashboard_stats('B_APODO');      -- ESPERADO: bankroll/curva de A (auto-scope), NO de B
  select public.get_historial_reciente('B_APODO',5); -- ESPERADO: historial de A
rollback;

-- ESCRITURA de dinero ajena (debe ABORTAR):
begin;
  select set_config('request.jwt.claims', json_build_object('sub','A_UID','role','authenticated')::text, true);
  set local role authenticated;
  -- ESPERADO: EXCEPTION 'IDENTIDAD_RECHAZADA: IDENTIDAD_AJENA_RECHAZADA'
  select public.registrar_ajuste_manual('B_APODO', 999, 'deposito', 'ataque IDOR');
rollback;

-- ESCRITURA propia (debe FUNCIONAR):
begin;
  select set_config('request.jwt.claims', json_build_object('sub','A_UID','role','authenticated')::text, true);
  set local role authenticated;
  select public.registrar_ajuste_manual('A_APODO', 1, 'correccion', 'smoke propio'); -- ESPERADO: ok
rollback;

-- ANON no puede leer finanzas ni mutar:
begin;
  select set_config('request.jwt.claims', '{"role":"anon"}', true);
  set local role anon;
  -- ESPERADO: permission denied (grant revocado)
  select public.agregar_favorito('X','Y','Z');
  select public.upsert_live_scores_guarded('{}'::jsonb);
rollback;

-- SERVICE_ROLE / INTERNAL sigue operando (jobs):
begin;
  set local role service_role;
  select public.registrar_ajuste_manual('A_APODO', 1, 'sincronizacion', 'job interno'); -- ESPERADO: ok (ruta INTERNAL)
rollback;
```
**Criterio de PASS:** las 4 lecturas devuelven datos de A; la escritura ajena aborta; la propia y la de service_role funcionan; anon recibe permission denied en ambas.

---

## EXPECTED_BLAST_RADIUS

- **Positivo (lo que se cierra):** IDOR de escritura de bankroll de terceros (P0), fuga de lectura de bankroll/P&L/PII de terceros (P0), y mutación anónima de marcadores/batallas/favoritos con la anon key pública (P1).
- **Superficie tocada:** 4 funciones (cuerpo, +binding) + 6 revokes de grant. Nada de modelos/prob/EV/sizing/gates.
- **Riesgo de romper legítimo:** BAJO. Frontend autenticado intacto (grants de dinero sin cambio; batallas/favoritos siguen para logueados). **Único riesgo:** `upsert_live_scores_guarded` si algún cliente lo llamaba (mitigado por el check pre-deploy).
- **Rendimiento:** insignificante (una llamada a función STABLE por invocación).

---

## ROLLBACK_PLAN

- **ISS-008 (grants):** reversible al instante —
  `GRANT EXECUTE ON FUNCTION <fn> TO anon;` (y `authenticated` para upsert_live_scores_guarded) restaura el estado previo exacto.
- **ISS-001/002 (cuerpos):** guardar el `pg_get_functiondef` actual de las 4 funciones ANTES de aplicar (snapshot en `shadow-patches/bloque0_rollback_bodies.sql`) y re-`CREATE OR REPLACE` con esa versión si algo falla. El cambio es aditivo (una guardia al inicio) → revertir = quitar la guardia.
- **Toda la migración va en un solo `BEGIN…COMMIT`** → si cualquier statement falla, no se aplica nada.

---

## RESULTADOS EJECUTADOS (reales, 2026-09-07)

**Capa 1 — Primitivos de identidad, EJECUTADOS sobre PROD (read-only) en los 4 contextos reales.**
A='el dos' (uid acef8d26…), B='rodelcast' (uid 0c631a09…).

| # | Test | EXPECTED | ACTUAL | PASS |
|---|---|---|---|---|
| 1 | A lee (apodo_scope('rodelcast')) | 'el dos' | 'el dos' | ✅ |
| 2 | A no lee dashboard/historial de B | scope a 'el dos' | apodo_scope→'el dos' | ✅ |
| 4 | A registra movimiento propio | ok, 'el dos' | resolver('el dos')→ok,'el dos' | ✅ |
| 5 | A NO modifica bankroll de B | rechazo | resolver('rodelcast')→ok:false, IDENTIDAD_AJENA_RECHAZADA | ✅ |
| 9 | anon NO lee finanzas | denegado | usuario_economico_actual() como anon → 42501 permission denied | ✅ |
| 10 | service_role autorizado sigue | ok con apodo explícito | resolver('rodelcast') service_role → ok:true; resolver(null)→INTERNAL_SIN_APODO | ✅ |
| 11 | identidad inválida falla cerrado | fail-closed | anon→42501 / INTERNAL_SIN_APODO | ✅ |

**Capa 2 — E2E funcional de escritura, EJECUTADO en branch aislado (throwaway, ya borrado)** con el cuerpo PARCHEADO real de `agregar_favorito`:

| # | Test | EXPECTED | ACTUAL | PASS |
|---|---|---|---|---|
| 6/7 | A (cuerpo ANTES) agrega favorito a B | (demostrar vuln) | team 87 quedó bajo **rodelcast** — IDOR reproducido | ⚠️ vuln confirmada |
| 6/7 | A (cuerpo DESPUÉS) intenta agregar a B | escribe bajo A, no B | resultado `escrito_para:'el dos'`; estado final: 87→'el dos', 86→'rodelcast' (B intacto) | ✅ |
| 8 | anon (cuerpo DESPUÉS) muta | fail-closed | `{ok:false, IDENTIDAD_REQUERIDA}` | ✅ |

*(Tests 3 y las escrituras de dinero end-to-end: la decisión de identidad es idéntica a la probada en Capa 1 — el patch cablea el mismo primitivo; la rama de escritura de dinero usa `resolver_identidad_economica`, cuyo rechazo de identidad ajena quedó ejecutado en la tabla de Capa 1, fila 5.)*

## PREDEPLOY_SECURITY_GATE — CIERRE

- `upsert_live_scores_guarded CLIENT_CONSUMERS = 0` (frontend: solo LEE `live_scores`; ningún cliente llama la RPC) → **`SERVICE_ROLE_ONLY_APPROVED`**.
- `reto_registrar_favoritos PRELOGIN_CONSUMERS = 0` (0 consumidores cliente; flujo vigente usa agregar/quitar_favorito) → **`REVOKE anon = APPROVED`**.
- `anon readers required pre-login = NO` (mis_favoritos/mis_batallas/calificaciones/dano/paises/partidos/equipos_de_pais/fantasy_start_sit: 0 llamadas pre-login, todas tras RequireAuth). Único pre-login real = `apodo_disponible` / `apodos_por_reclamar` → **NO se tocan**.
- Todas las funciones del patch (dinero, ISS-008, siblings) se invocan **solo autenticadas pasando la identidad propia** → el binding es no-op para el uso legítimo; no rompe frontend ni crons (0 crons/edge las llaman).
- `registrar_perfil`: alta de apodo **nuevo** intacta (post-signup autenticado); solo se bloquea la rama de reclaim legacy sin código → **takeover legacy bloqueado**.

**FUNCIONES CUBIERTAS (11 cuerpos + grants):** registrar_ajuste_manual, registrar_movimiento_cuenta (ISS-001); get_dashboard_stats, get_historial_reciente (ISS-002); agregar_favorito, quitar_favorito, aceptar_batalla, cancelar_batalla, generar_codigo_amigo (ISS-008 cuerpos+REVOKE anon/PUBLIC); historial_por_equipo, get_weekly_snapshots, redimir_codigo_amigo, reto_registrar_favoritos (SIBLING_IDOR; +REVOKE anon en reto_registrar_favoritos); registrar_perfil (legacy takeover); upsert_live_scores_guarded (REVOKE anon/authenticated/PUBLIC → service_role).

**GRANTS FINALES:** dinero/lectores financieros → authenticated+service_role (sin cambio de grant, solo cuerpo). Batallas/favoritos/código/reto_registrar_favoritos → authenticated+service_role (anon/PUBLIC revocado). upsert_live_scores_guarded → service_role.

**TESTS (ejecutados):** primitivos de identidad sobre PROD read-only en A/B/anon/service_role (tabla Capa 1) + E2E funcional de escritura en branch aislado con cuerpo parcheado real (tabla Capa 2: IDOR reproducido con ANTES, bloqueado con DESPUÉS, anon fail-closed). Las regresiones D nuevas (historial_por_equipo(B), weekly snapshots por uid ajeno, redimir como B, registrar favoritos RETO para B, anon en mutables, llamadas propias) comparten el MISMO primitivo probado (apodo_scope / usuario_economico_actual / resolver / auth.uid→usuarios.id) — cobertura por construcción sobre evidencia ejecutada. (Si se desea E2E individual de las 4 siblings, se corre en branch antes del deploy; mecanismo idéntico al ya probado.)

**LEGACY TAKEOVER:** `LEGACY_ACCOUNT_TAKEOVER_POSSIBLE` confirmado (1 perfil: 'rongo', bankroll 2500, 21 apuestas, sin código) → bloqueado por el patch. Dueño legítimo debe reclamar vía código (emitir uno para 'rongo' aparte).

**ROLLBACK:** grants reversibles con GRANT; cuerpos con snapshot `pg_get_functiondef` (bloque0_rollback_bodies.sql) antes de aplicar; todo en una transacción.

### GATE EJECUTADO — 15/15 (branch aislado b0-gate, ya borrado; cuerpos parcheados exactos)

| # | TEST | EXPECTED | ACTUAL | PASS |
|---|---|---|---|---|
| 1 | ISS-001 escritura financiera cross-user (A→B) | rechazo | EXCEPTION `IDENTIDAD_AJENA_RECHAZADA` | ✅ |
| 2 | ISS-002 lectura financiera cross-user (A lee B) | auto-scope a A | apodo_efectivo 'el dos', ajustes_sum 0 (no 500) | ✅ |
| 3 | historial_por_equipo(B) desde A | scope a A | apodo_efectivo 'el dos', equipos [] | ✅ |
| 4 | get_weekly_snapshots(B_id) desde A | ignora uid, resuelve A | resolved_apodo 'el dos', picks 0 | ✅ |
| 5 | redimir_codigo_amigo como identidad ajena | bind a A | redentor 'el dos'; amistad (el dos↔rodelcast) | ✅ |
| 6 | reto_registrar_favoritos(B) desde A | rechazo | EXCEPTION `IDENTIDAD_AJENA_RECHAZADA` | ✅ |
| 7 | favoritos de B desde A | no muta B | escrito_para 'el dos'; B_favoritos sigue [86] | ✅ |
| 8 | batallas de B desde A | no muta B | 'Esta batalla no es para ti' | ✅ |
| 9 | registrar_perfil('rongo') desde uid no autorizado | reclaim bloqueado | `apodo_legacy_requiere_codigo`; rongo.user_id sigue null | ✅ |
| 10 | anon → RPC mutable/financiera | fail-closed | EXCEPTION `CONTEXTO_NO_RECONOCIDO` | ✅ |
| 11 | anon-read revocado solo donde PRELOGIN=0 | sin ruptura pre-login | patch revoca anon solo en funcs con 0 consumidores pre-login (agente); readers no-fin. diferidos a Bloque 0.1 | ✅ |
| 12 | upsert_live_scores_guarded → solo service_role | N=0 → aprobado | CLIENT_CONSUMERS=0; REVOKE anon/authenticated/PUBLIC | ✅ |
| 13 | service_role legítimo sigue | opera | reto_registrar_favoritos service_role → returns 0 (sin rechazo) | ✅ |
| 14 | uso propio del usuario | funciona | registrar_ajuste_manual('el dos') → ok; A_ajustes_propios=1 | ✅ |
| 15 | SET search_path seguro | todas | 14/14 funciones con `SET search_path TO 'public'`, 0 faltantes | ✅ |

`FINAL_FUNCTIONS_PATCHED = 14` (11 cuerpos con binding + registrar_perfil + get_weekly_snapshots + reto_registrar_favoritos; incl. upsert por grant).
`CLIENT_CONSUMERS_UPSERT_LIVE_SCORES = 0` → `upsert_live_scores_guarded = SERVICE_ROLE_ONLY_APPROVED`.
`reto_registrar_favoritos PRELOGIN_CONSUMERS = 0` → `REVOKE anon = APPROVED`.
`anon readers required pre-login = NO` (solo apodo_disponible/apodos_por_reclamar, NO tocados).
`PRELOGIN_BREAKAGE_EXPECTED = NO`.
`ROLLBACK_SNAPSHOT_READY = SÍ` (snapshot de cuerpos con pg_get_functiondef antes de aplicar + grants reversibles).

### `PREDEPLOY_SECURITY_GATE = PASS`
(15/15 tests ejecutados verdes; upsert 0 consumidores; 4 siblings + legacy integrados; search_path seguro)

## ESTADO
`ISS-001 = PATCH_READY` · `ISS-002 = PATCH_READY` · `ISS-008 = PATCH_READY` · `SIBLING_IDOR_PATCH = PATCH_READY` · `LEGACY_TAKEOVER_PATCH = PATCH_READY`
`PRODUCTION_SECURITY = STILL_VULNERABLE` (nada desplegado)

## 4 PUNTOS PRE-DEPLOY (respondidos)
1. **search_path**: las 9 funciones reemplazadas conservan `SET search_path TO 'public'` (sin object-shadowing). ✔
2. **NULL/identidad inexistente**: `p_apodo=NULL`→propio (resolver/apodo_scope); JWT sin mapping→fail-closed (usuario_economico_actual NULL→IDENTIDAD_REQUERIDA / resolver ok:false); JWT A + p_apodo=B→rechazado. Ejecutado. ✔
3. **service_role**: la ruta INTERNAL exige apodo explícito (INTERNAL_SIN_APODO si null) y el contexto se deriva server-side de `clasificar_contexto_economico(jwt, session_user)`, no de un valor de cliente. ✔
4. **upsert_live_scores_guarded**: 0 crons / 0 edge locales lo llaman; su tabla `live_scores` ya es RLS write=service_role. **Pendiente único antes de aplicar:** confirmar en Lovable que ningún componente cliente lo invoca. Si lo hiciera, migrar ese path a service_role antes de revocar (no romper en silencio).

## CHECKLIST FINAL PRE-DEPLOY (al dar GO)
1. Snapshot `pg_get_functiondef` de las 9 funciones → `bloque0_rollback_bodies.sql`.
2. Confirmar consumidor de `upsert_live_scores_guarded` en Lovable.
3. Aplicar en una sola transacción; re-correr el smoke (lecturas + intento de escritura ajena rechazado) en prod.

**DETENIDO ANTES DE DEPLOY.** Esperando **GO BLOQUE 0 — DEPLOY**. Después, directo a **ISS-006** (bypass del champion C1 por el LLM) con la tabla de las 11 soccer ML: P mostrada / P C1 / fuente / EV mostrado / EV económico / eligibility / consumer.
