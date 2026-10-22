# Repositorio (7670102) frente a producción: verificación de solo lectura (22-oct-2026, ~18:30 UTC)

Método:
1. Base local `a2lead_ord`, construida con TODAS las migraciones del ZIP en orden (`supabase/tests/security/run.sh`, sin reaplicaciones).
2. Huella de cada función pública (md5 de prosrc + SECURITY DEFINER + search_path), cada política (md5 de qual|with_check + roles), cada tabla (RLS on/off), los permisos EXECUTE de anon/authenticated, los buckets y los triggers.
3. Las mismas consultas en producción vía `query_database`, sin escribir nada.
4. Comparación con `diff` y orden C.

## Resultado

### Coinciden byte por byte
16 funciones críticas: `prive_require`, `prive_unlock`, `prive_auth_session_alive`, `prive_withdraw_invitation`, `admin_revoke_prive_grant`, `apply_prive_grant`, `stripe_commit_payment_event`, `is_pro`, `prive_search`, `prive_status`, `reserve_quota`, `has_trip_access`, `purge_account_data`, `apply_comp_grant`, `prive_save_progress` y `prive_add_to_trip`.
- Además: 339 de las 343 funciones públicas, los 6 buckets, los permisos EXECUTE y el estado de RLS de todas las tablas.

### Diferencias (producción ≠ repositorio)

**D1. Producción tiene 50 políticas que no están en el repositorio.** Son `*_own` creadas fuera de git (patrón de Lovable), en: ai_user_preferences, behavioral_insights, concierge_requests, expenses, notifications, profiles, recomendaciones, travel_profiles, trips, user_vault_benefits, user_visits y `storage.objects` (`recibos_*`).
- Son PERMISIVAS: se combinan con OR con las del repositorio.
- **Efecto comprobado en `expenses` y `user_visits`.** En el repositorio, INSERT/UPDATE exigen `(trip_id IS NULL OR has_trip_access(trip_id, auth.uid()))` (migración `20261022141600_sec2_trip_id_checks.sql`). En producción, `expenses_insert_own` / `user_visits_insert_own` solo piden `auth.uid() = user_id`, así que **la verificación de acceso al viaje queda anulada en producción**.
- Hoy nadie lee esas filas por `trip_id` con privilegios elevados (todas las lecturas filtran por `user_id`). Por eso el impacto es integridad de datos propios: **P3**. Pero es una corrección de seguridad declarada que no está vigente.
- Las demás `*_own` no amplían nada: `profiles` y `user_vault_benefits` no tienen GRANT de INSERT; en `trips` son idénticas a las del repositorio.

**D2. Cuatro funciones distintas en producción:** `handle_new_user`, `ensure_ai_prefs`, `on_trip_insert_dna` y `on_visit_insert_dna`. La versión de producción no viene de ninguna migración registrada.
- `handle_new_user` (producción) copia `raw_user_meta_data->>'avatar_url'` a `profiles.avatar_url` al registrarse. Ese metadato lo controla quien se registra (`signUp({ options: { data } })`).

**D3. 14 migraciones del repositorio sin fila en `supabase_migrations.schema_migrations`:**
- 20260429220000, 20260525234500, 20260525235000, 20260824040000, 20261017050000, 20261017101000, 20261017170000, 20261018090000, 20261018110000, 20261018120000, 20261021090000, 20261022090000, 20261022120000 (y una más del mismo bloque).
- Sus objetos SÍ existen (se comprobaron: badges, mis_amigos, ensure_ai_prefs, account_deletion_files, price_watches, admins, referrals, comp_grants con su trigger, health_checks, las políticas journal_photos_read_members y travel_moments_read_own, y trips_guard_owner).
- 32 migraciones más están registradas con una versión que difiere en segundos del archivo.
- Riesgo: un `supabase db push` intentaría reaplicarlas. `20260824040000` usa `CREATE FUNCTION` sin `OR REPLACE`: fallaría. **P3, deriva de despliegue.**

### Defecto nuevo encontrado al verificar el avatar

**N-L1 (P3; P2 si se considera el rastreo). Cualquier usuario puede poner cualquier URL como avatar, y sus amigos la cargan.**
- **Cómo se reproduce:** como `authenticated`, `UPDATE profiles SET avatar_url='https://rastreador.example/p.gif' WHERE id=auth.uid();` funciona. `has_column_privilege('authenticated','public.profiles','avatar_url','UPDATE') = true` y `profiles_guard_sensitive` (repositorio = producción) no protege `avatar_url`. En producción también se puede fijar al registrarse (D2).
- **Efecto:** `amigo_perfil`, Social y la postal de 2 avatares muestran esa URL con `<img>`. Los navegadores de los amigos hacen la petición (rastreo de IP y hora) o muestran contenido inapropiado.
- **Discrepancia con la documentación:** `AVATAR_VIAJES.md` dice "profiles.avatar_url, escrita solo desde el servidor". Sin embargo, `src/pages/Profile.tsx:337-339` y `src/pages/OnboardingDeep.tsx:282` la escriben desde el navegador.
- **Corrección propuesta:**
  1. Migración: en `profiles_guard_sensitive`, rechazar cambios de `avatar_url` hechos por `anon`/`authenticated`. Alternativa: `REVOKE UPDATE(avatar_url)` con GRANT por columna.
  2. `handle_new_user` sin copiar `avatar_url` del metadato.
  3. Quitar las dos escrituras del cliente (`generate-avatar` ya guarda con la llave de servicio).
  4. Prueba SQL: authenticated no puede cambiar `avatar_url`; `service_role` sí.

### Método de pruebas (hallazgo de calidad)

**Q-L1 (P3). La suite `prive/run.sh` no prueba el estado que corre en producción.** Después de aplicar todas las migraciones, reaplica `2026102309*.sql` y `20261024*_aud_prive_*.sql`. Comprobado: `prive_save_progress` queda distinta (md5 `6492f9d9…` en la suite frente a `051682be…` en orden real y en producción), porque se reaplica la versión anterior a la corrección de `dna_consent` de `20261024310000_privekey_plans.sql`. Las pruebas de Privé validan esa función en una versión que no es la de producción.
- La corrección sí está probada en la suite `prive_key`, que no reaplica.
- **Propuesta:** quitar la reaplicación (probar la idempotencia en una base aparte) o reaplicar TODAS las migraciones posteriores en orden.
