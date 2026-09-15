# ISS-025 — RLS / seguridad: DISEÑO de hardening (no ejecutar en bloque)

> Principio: **cerrar superficie de escritura y de lectura innecesaria SIN romper el acceso anónimo del frontend.** El front nuevo (Lovable d243f279) lee SOLO los contratos públicos V2 + un puñado de vistas factuales. Todo lo demás no debería ser legible por `anon`. Pero activar RLS en 107 tablas de golpe rompe PostgREST para el front → se hace por fases, midiendo qué toca `anon` de verdad.

## Estado medido (advisors de Supabase, 2026-09-09, prod `wpiztubmmmzclhlprgpd`)
| Lint | Nivel | Cuenta | Qué significa |
|---|---|---|---|
| `rls_disabled_in_public` | ERROR | 107 tablas | tablas públicas sin RLS, legibles por `anon` vía PostgREST |
| `security_definer_view` | ERROR | 67 vistas | vistas SECURITY DEFINER (corren con permisos del creador, saltan RLS) |
| `rls_enabled_no_policy` | INFO | 1 | RLS activado sin policy → niega todo (ok si es intencional) |
| `function_search_path_mutable` | WARN | — | funciones sin `search_path` fijo (riesgo de hijack) |
| `extension_in_public` | WARN | — | extensión instalada en `public` |
| `materialized_view_in_api` | WARN | — | matview expuesta en la API |
| `anon_security_definer_function_executable` | WARN | — | `anon` puede ejecutar función SECURITY DEFINER |
| `authenticated_security_definer_function_executable` | WARN | — | idem `authenticated` |
| `auth_leaked_password_protection` | WARN | — | protección de contraseñas filtradas apagada (setting de Auth) |

## Ya aplicado (zero-risk, no rompe lecturas) ✅
- `public.v_futpro_v2`, `public.v_analisis_v2`, `public.v_reto13m_daily`: **REVOKE INSERT/UPDATE/DELETE/TRUNCATE/REFERENCES/TRIGGER** de `anon`+`authenticated`; **GRANT SELECT** conservado. (Cierra la escritura sobre vistas contrato; las vistas son de solo-lectura por naturaleza pero los grants abiertos eran una bandera roja.)

## Fases propuestas (ejecutar con el usuario despierto, verificando login + lecturas del front tras cada fase)

### Fase 1 — Inventario de acceso real de `anon` (medir antes de cortar)
- Revisar `query_logs`/PostgREST para listar qué tablas/vistas consulta `anon` en 24-48h.
- Cruzar contra la ALLOWLIST del front: `v_futpro_v2`, `v_analisis_v2`, `v_reto13m_daily`, `escudos_evento`, `v2.team_logo`, `agenda_espn` (lectura de cartelera), y las auth/bankroll propias del usuario (con RLS por `auth.uid()`).
- Entregable: lista "TABLAS QUE ANON TOCA" vs "TABLAS QUE ANON NO NECESITA".

### Fase 2 — Quitar de la API lo que `anon` no necesita (más simple que RLS)
Para cada tabla que `anon` NO necesita (respaldos `bt_*`, `*_pendiente`, staging, tablas de modelo interno):
```sql
REVOKE SELECT ON public.<tabla> FROM anon;              -- la saca de PostgREST para anon
-- opcional también authenticated si es puramente interna:
-- REVOKE SELECT ON public.<tabla> FROM authenticated;
```
Esto la retira de la API pública sin necesidad de policies. Es el 80% de las 107.

### Fase 3 — RLS + policy de solo-lectura pública donde SÍ se necesita lectura anónima
Para tablas que el front lee directo (si las hay tras Fase 1):
```sql
ALTER TABLE public.<tabla> ENABLE ROW LEVEL SECURITY;
CREATE POLICY "select_publico" ON public.<tabla> FOR SELECT TO anon, authenticated USING (true);
```

### Fase 4 — Tablas de usuario (bankroll, picks, parlays): RLS por dueño
```sql
ALTER TABLE public.<tabla_usuario> ENABLE ROW LEVEL SECURITY;
CREATE POLICY "dueño_lee"     ON public.<t> FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "dueño_escribe" ON public.<t> FOR ALL    TO authenticated USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());
```
**Dinero (picks/parlays/bankroll/montos) NUNCA legible por `anon` ni por otro usuario.** Este es el hueco más grave: si esas tablas están hoy sin RLS y con SELECT a `anon`, cualquiera lee montos ajenos. Prioridad tras el inventario.

### Fase 5 — SECURITY DEFINER views (67)
- Las vistas contrato curadas (`v_futpro_v2`, etc.) pueden quedar DEFINER **si** las tablas base quedan bloqueadas a `anon` (Fase 2), porque son la única puerta curada. Alternativa: recrearlas `SECURITY INVOKER` + policies de lectura en las base.
- Revisar que ninguna vista DEFINER exponga columnas de dinero de otros usuarios.

### Warnings
- `function_search_path_mutable`: `ALTER FUNCTION ... SET search_path = public, pg_temp;` por función.
- `anon/authenticated_security_definer_function_executable`: `REVOKE EXECUTE ... FROM anon;` en funciones internas.
- `extension_in_public`: mover extensiones a schema `extensions`.
- `materialized_view_in_api`: `REVOKE SELECT` de `anon` sobre la matview si no la usa el front.
- `auth_leaked_password_protection`: activar en el panel de Auth (setting, no SQL).

## Coordinación con auditor
La seguridad/RLS está listada como área donde el auditor puede intervenir (diseño primero). Task #105 ("cerradas las 2 vistas de dinero abiertas a internet y 43 respaldos") es trabajo previo/del auditor en la misma dirección. Este doc es el plan por fases; la ejecución de Fases 2-5 se hace con el usuario despierto para verificar que login + cartelera + análisis + RETO 13M siguen leyendo bien tras cada corte.

## Regla de oro
Ninguna fase se aplica si no se verificó primero (Fase 1) que no rompe una lectura que el front necesita. Fail-safe: si hay duda de si `anon` necesita una tabla, se prueba en una migración reversible y se revisa el front antes de continuar.
