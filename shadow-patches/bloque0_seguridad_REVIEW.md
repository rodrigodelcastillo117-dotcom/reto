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

## PENDIENTE ANTES DE DEPLOY (no ejecutar sin esto)
1. GO explícito.
2. Correr `bloque0_rollback_bodies.sql` (snapshot de los 4 cuerpos actuales) para el rollback.
3. Verificar en Lovable que ningún cliente llama `upsert_live_scores_guarded`.
4. Correr ADVERSARIAL_TESTS en lab/rollback y confirmar PASS.
5. Aplicar en una sola transacción; re-correr los tests en prod (lecturas + escrituras rolled-back).

**DETENIDO ANTES DE DEPLOY.** Espero tu GO para Bloque 0. Después preparo el GO separado de Bloque 1 (empezando por ISS-006, con la tabla de las 11 soccer ML: P mostrada / P C1 / fuente / EV mostrado / EV económico / eligibility / consumer).
