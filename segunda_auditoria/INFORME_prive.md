# Segunda auditoría independiente de IATOS AI · grupo `prive`

- **Material:** paquete del commit `7670102` (copia en `/home/user/audit2/prive/codigo`). El código anterior es `06865cb`, extraído en `/home/user/audit2/prive-old`.
- **Alcance:** AUD-01 (sesiones Privé), REMEMBER (30 días), SES-LS (cookie de sesión del navegador), NEW-01, N-02, pérdida de PRO, cobertura de `prive_require` en las RPC de contenido y discrepancias entre `docs/iatos/cierre/PRIVE.md` y el código.
- **Entorno:** todo se probó en Postgres 16 local (`/tmp/pgsec:55440`) con bases `a2prive_*`, que ya se borraron, y con Vitest local. No se tocó producción.

Sobre "fallaba antes": los cuatro archivos `20261023090*_prive_core_*.sql` son **idénticos** en `06865cb` y en `7670102` (`diff` vacío). Toda la corrección vive en `20261024010000`, `…020000` y `…030000` y en `prive-access/actions.ts`. Por eso el "código viejo" se reprodujo así:

- **SQL:** se aplicaron todas las migraciones de `7670102` **menos** `_aud_prive_` (base `a2prive_antes`). Es portar el código viejo al nuevo.
- **Edge:** se puso el `actions.ts` de `06865cb` en la copia y se restauró después (`cmp` lo confirma).

---

## 1. Resumen

| Concepto | Resultado |
|---|---|
| Suites SQL (bases `a2prive_*`) | prive **140 OK / 0 FALLA**; prive_catalog **110/0**; prive_key **47/0**; privevalor **144/0**; edition **47/0**. Solo aparece el error esperado de pg_cron. Coincide con RESULTADOS_QA |
| Vitest `src/test/prive*` | **29 archivos, 555/555**. El paquete no trae `.env`: sin `VITE_SUPABASE_URL`/`VITE_SUPABASE_PUBLISHABLE_KEY`, 5 archivos no cargan. Con valores ficticios pasan todos |
| `deno check supabase/functions/prive-access/index.ts` | OK |
| `aud_session.sql` con el código viejo portado | **29 OK / 23 FALLA**. 15 fallas son defectos: S04, S05, S07, S07b, S08, S08b, S09, S09b, S09c, S11b, S11c, N01, N01d, N03 y N05. Las otras 8 son errores de una función que todavía no existía (R*) |
| `aud_session.sql` con el código nuevo | **48 OK / 0 FALLA** |
| `priveAccess.test.ts` con el `actions.ts` viejo | **7 FALLA / 31 OK**. Fallan 3 de los 5 casos AUD-01; los otros 4 son canónica, remember (2) y reset. Con el nuevo, 38/38 |
| Mutaciones SQL (17, suite `prive` completa) | **14 detectadas, 3 sobreviven**: M8, M9 y M10, todas en `prive_remember_session` |
| Mutaciones NEW-01 (3) | 3/3 detectadas |
| Mutaciones Edge y cliente (5) | 5/5 detectadas |
| Casos nuevos (`aud2_prive.sql`) | **23 OK, 3 FALLA y 7 INFO**. Las 3 FALLA son el defecto N-02 |
| Carreras reales (dos conexiones) | 2 ventanas de carrera P3 (R1 y R2) |

**Veredictos**

- **AUD-01:** VERIFICADO INDEPENDIENTEMENTE. Cada camino corregido falla con el código viejo, pasa con el nuevo y lo detecta al menos una mutación.
- **NEW-01:** VERIFICADO INDEPENDIENTEMENTE.
- **REMEMBER:** PARCIALMENTE CUBIERTO. El código es correcto, pero la prueba de "propia" (R06) es vacía: la mutación M8 sobrevive.
- **SES-LS (cookie):** PARCIALMENTE CUBIERTO. La regla se cumple solo en el cliente; el servidor no la conoce.
- **N-02:** se REFUTA con evidencia la afirmación "se resuelve con N-01; sigue exigiendo PRO". La concesión se liga sin correo confirmado. Con `mailer_autoconfirm=true`, en el escenario donde el correo también está en `comp_grants`, se probó la cadena completa hasta Privé sin pagar nada: queda **P2 abierto**.

**Defectos nuevos:** 1 × P2 (N-02 ampliado) y 5 × P3. No se encontró ningún P0 ni P1.

---

## 2. Tabla por hallazgo

| AUD | Defecto original | Código corregido (archivo:línea) | Test exacto | ¿Fallaba antes? | ¿Pasa ahora? | Caso nuevo intentado | Resultado | Veredicto |
|---|---|---|---|---|---|---|---|---|
| AUD-01a · `auth.sessions` ilegible, inexistente o sin columna ⇒ se aceptaba | `06865cb` `20261023090100_prive_core_access.sql:159` (`_sid IS NULL OR to_regclass(...) IS NULL → RETURN true`) y `:163-164` (excepciones → `true`) | `20261024010000_aud_prive_session_fail_closed.sql:21-40` (sin uuid → false; `EXCEPTION WHEN OTHERS → false`) | `aud_session.sql` S07, S07b, S08, S08b, S08c | Sí: S07, S07b, S08 y S08b FALLA | Sí | M2 (true si falta la tabla) → S07b y S08 FALLA. M2b (true en la excepción) → S07, S07b, S08 y S08b. M11 (sin `not_after`) → S06 y S08b. Barrido con una columna faltante (`aud2_sweep.sql`) | Mutaciones detectadas. **El barrido cierra en masa** (P3-4) | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01b · cuenta suspendida (`banned_until`) o borrada (`deleted_at`) | Viejo `:161-162`: no se miraba `auth.users` | `…010000:27-32` (JOIN `auth.users`, `deleted_at IS NULL`, `banned_until`) | S04, S05, S05b, S11c | Sí: S04, S05 y S11c | Sí | M3a (sin `banned_until`) → S04 y S11c. M3b (sin `deleted_at`) → S05 | Detectadas. S05 es la única prueba de `deleted_at` | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01c · sesión ajena: `AND s.user_id` | `prive_require` siempre filtró por `user_id`; `prive_auth_session_alive` sí lo tenía en `:161` | `…010000:29` (`s.user_id = $2`); `…030000:74` (`AND s.user_id = v_uid`) | S09c, PS2 (`aud_seg_strength.sql`), P31 | S09c FALLA antes por otra causa (unlock no comprobaba nada) | Sí | M1 (`prive_require` sin `user_id`) → solo PS2. M1b (`alive` sin `user_id`) → solo S09c | Cada una la detecta **una sola prueba**. La liga a la sesión de Auth es una segunda defensa real | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01d · sesión Privé sin ligar (`auth_session_id NULL`) | Viejo `:214` (`IF v_s.auth_session_id IS NOT NULL THEN …`: sin ligar ⇒ se salta la revisión); `090200:208` (unlock sin revisar la sesión) | `…030000:95-98` (sin ligar ⇒ INVALID); `…010000:124-127` (unlock exige sesión viva); `:164-165` (cierra las sesiones sin ligar al aplicarse); `actions.ts:98`, `:100` (401) | S09, S09b, S09c, S11b, PS1b; `priveAccess.test.ts` "AUD-01" | Sí: S09, S09b, S09c y S11b; Edge 3/5 | Sí | M4 (permitir sin ligar) → S09b, S11b y PS1b. M4b (unlock sin `session_id`) → S09. E1 y E2 (Edge) → 2 y 1 FALLA. C1b (JWT sin `session_id`) | Detectadas | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01e · cierre de sesión y cierre global | Ya funcionaba con la sesión ligada (S02 y S03 OK antes) | `…030000:95-98` | S02, S03, S11; C3i (nuevo) | No (REFUTADO en el cierre, de acuerdo) | Sí | C3i: sesión recordada con cierre global | OK | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01f · pérdida de PRO | Ya funcionaba (S12 OK antes) | `prive_require` → `prive_access_code` (`090100:129-142`; `…030000:66-69`) | S12, S12b, S12c, S12d, P10, R05 | No | Sí | M5 (`prive_require` sin `access_code`) → 11 FALLA. M5b (sin `is_pro`) → 8. M5c (90 días → 0) → 13. P-PRO1 (`past_due`) | Detectadas. P-PRO2: al volver PRO, la misma sesión Privé revive (sin barrido programado) | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01g · otro inicio de sesión o dispositivo del MISMO usuario (token robado) | Ya ligado cuando había `session_id` | `…030000:95` (`v_jwt_sid <> v_s.auth_session_id`) | S10, P25; C1 (nuevo) | No para la sesión ligada | Sí | M7 (sin comparar el `session_id`) → P25 y S10. C1: token de A usado desde B → INVALID | **No sirve, y es lo correcto**: el código lo niega | VERIFICADO INDEPENDIENTEMENTE |
| AUD-01h · sesión de Auth refrescada | — | Igual que arriba (se compara `session_id`, no el token) | C2, C2b (nuevos) | n/a | Sí | Otro access token (iat y exp), el mismo `session_id`, `refreshed_at` actualizado | OK. C2c: `session_id` en mayúsculas → INVALID (falla cerrado) | VERIFICADO INDEPENDIENTEMENTE |
| REMEMBER · 30 días (sesión recién abierta y propia; revocación) | Función nueva | `…030000:26-47` (`≤5 min`, `user_id`, alive, `access_code`), `:84` (inactividad de 7 días), `:40` (`created_at + 30 d`) | R01–R07; unit "mantener mi sesión…" | n/a (no existía) | Sí | M6 (sin los 5 min) → R06 y R07. **M8 (sin `user_id`), M9 (sin alive) y M10 (sin `access_code`) → 0 FALLA**. Nuevos: C3 (sesión vieja reactivada), C3b (bloqueada), C3c (Auth cerrada), C3d (idempotente), C3e (cambio de contraseña), C3f (reset), C3g (comprometida), C3h (6 días), C3i (global), **C3j (otra cuenta con derecho vigente)** | Todos OK. C3j detecta M8 y C3c detecta M9 (`salidas/aud2_prive_M8.txt`, `_M9.txt`) | PARCIALMENTE CUBIERTO (prueba R06 insuficiente) |
| SES-LS · cookie de sesión del navegador | `06865cb`: sesión en `localStorage` sin marca | `src/lib/priveSession.ts:38-62`, `:83`, `:106-107` | `priveLib.test.ts` (3) | n/a (regla nueva) | Sí | Mutación del cliente sin `hasBrowserSessionMarker` → 1 FALLA | Detectada. Pero es **solo del cliente**: el token sigue vivo en el servidor (P3-2) | PARCIALMENTE CUBIERTO |
| Fuerza bruta (5→1, 8→5, 10→15, 12→60, 15 bloqueo total; por IP) | Sin cambio (`090200:68-141`) | — | P35–P39; C6, C6b, C6c, C6e (nuevos); R4 (paralelo) | n/a | Sí | Escalera exacta. Correcta durante el bloqueo → LOCKED sin contar. 10 en paralelo → `failed_count`=5 y 5 LOCKED (serializado por `FOR UPDATE`). IP bloqueada también para otra cuenta. C6d: el contador se reinicia a las 24 h, así que caben **14 intentos por día sin bloqueo total**. C6f: sin `PRIVE_IP_SALT` no hay límite por IP. `ip_hash` rota cada día UTC | Diseño documentado: P3-5 informativo | VERIFICADO INDEPENDIENTEMENTE |
| Contraseña canónica (NFC + trim) | — | `actions.ts:125-127`, `:132` | `priveAccess.test.ts` "canónica"; **nuevo** `src/test/aud2_priveCanon.test.ts` (6) | Sí (antes 1 FALLA) | Sí | Mayúsculas ≠ minúsculas. Espacios internos se conservan. Se recortan tab, `\n`, NBSP, U+3000 y U+FEFF. NFD = NFC. **NFKC no** (ancho completo, ligaduras). U+200B no se recorta. Solo espacios → 400. `old` y `new` se canonicalizan | E3 (sin canonicalizar) → 5 FALLA | VERIFICADO INDEPENDIENTEMENTE |
| NEW-01 · invitación viva tras revocar la concesión | Viejo `090100:580-597`: no retiraba la invitación | `20261024020000…:17-37` (`prive_withdraw_invitation`), `:43-68` (`admin_revoke_prive_grant`), `:113-115` (barrido), `:135-142` (limpieza única) | N01, N01b, N01c, N01d, N02, N03, N04, N05 | Sí: N01, N01d, N03 y N05 | Sí | n1 (sin llamar a withdraw) → N01 y N01d. n2 (sin `is_eligible`) → N02 y N04. n3 (sin revocar las invitaciones) → N01, N01d y N03. Nuevos: NEW01-a (otra concesión vigente), NEW01-b (miembro activo por concesión), NEW01-c (pendiente revocada antes del registro) | Todo OK | VERIFICADO INDEPENDIENTEMENTE |
| N-02 · `apply_prive_grant` sin confirmar el correo | `090100:510-533` (sin cambio en `7670102`) | **No corregido** | **Nuevo** `aud2_prive.sql` N02-A, N02-B y N02-C | Sí (en los dos commits) | **FALLA** (3/3) | A: correo sin confirmar → se liga. B: autoconfirm + `comp_grants` → PRO de cortesía + concesión → Privé completo sin pagar. C: `UPDATE OF email` → se liga | Defecto confirmado (P2-1) | **REFUTADO CON EVIDENCIA** ("se resuelve con N-01") / FALLA |
| Cobertura de `prive_require` en las RPC de contenido | — | 44 RPC con `_ps` ejecutables por `authenticated` en el estado final de las migraciones | S01b, S11–S12c (descubren las RPC por catálogo); revisión del código fuente final | — | Sí | Lectura del `prosrc` final de cada una: **las 44 empiezan con `v_uid := public.prive_require(_ps);`** y ninguna llama nada en el `DECLARE`. También se revisaron las funciones sin `_ps` (`prive_teaser`: solo conteos; `admin_*` y `edition_admin_*`: exigen admin; `prive_my_requests` y `prive_request_cancel`: datos propios, por diseño) y las tablas (solo 3 con `SELECT` propio en `edition_*`) | OK. La documentación dice "12 RPC": hoy son 44 (D1) | VERIFICADO INDEPENDIENTEMENTE |

Sobre la pregunta 6 del método:

- **SQL:** las pruebas ejecutan las funciones reales con `SET ROLE authenticated` y `request.jwt.claims`. Pero `auth.sessions` y `auth.users` son **stubs locales** (`supabase/tests/security/01_supabase_stubs.sql`), no GoTrue.
- **Producción:** no se pudo comprobar que `postgres` lee esas tablas ni que GoTrue borra la fila al cerrar sesión y conserva el `session_id` al refrescar. Queda **BLOQUEADO**: requiere lectura en producción.
- **Edge (`priveAccess.test.ts`):** prueba `actions.ts` real con dependencias simuladas.

---

## 3. Defectos nuevos

### P2-1 · N-02 ampliado: una concesión Privé pendiente se liga a quien registre o cambie ese correo, sin confirmarlo; "Confirm email" no lo resuelve

**Código vulnerable:** `supabase/migrations/20261023090100_prive_core_access.sql:510-533`.

- `apply_prive_grant` hace `IF NEW.email IS NOT NULL THEN UPDATE prive_grants SET user_id = NEW.id …` sin mirar `email_confirmed_at`.
- El trigger es `AFTER INSERT OR UPDATE OF email`.
- Contraste: `apply_comp_grant` (`20261022130000…:214-239`) **sí** exige `email_confirmed_at IS NOT NULL`.
- Se suma `prive_accept_invitation(_user, NULL)` (`090100:347-397`), que acepta en la app sin el token del correo. Así nunca se demuestra que la persona controla el buzón.

**Reproducción** (`supabase/tests/prive/aud2_prive.sql`, bloque N-02; salida en `salidas/aud2_prive.txt`):

- **A.** `admin_grant_prive('invitada-a@…')` → `pending_signup`. Se inserta en `auth.users` una fila con ese correo y `email_confirmed_at = NULL`, que es lo que GoTrue hace al registrarse con "Confirm email" ON. Resultado: la concesión queda ligada a la cuenta sin confirmar (FALLA N02-A).
- **B.** Con `mailer_autoconfirm=true` (producción hoy, N-01) y el correo también en `comp_grants`:
  1. el atacante se registra y queda `subscriptions.status='comped'`;
  2. `prive_evaluate_eligibility` lo invita;
  3. `prive_accept_invitation(uid, NULL)` → `ok:true`;
  4. fija su contraseña y desbloquea;
  5. `prive_require` → **OK**: Privé completo sin pagar (FALLA N02-B).

  Sin `comp_grants`, le basta pagar PRO (99 MXN): la concesión salta los 90 días.
- **C.** Una cuenta existente cambia su correo al de una invitada pendiente → la concesión se liga (FALLA N02-C). Que GoTrue aplique el cambio sin confirmación depende de su configuración de cambio seguro de correo: no se verificó en producción (BLOQUEADO).

**Límites:** se materializa cuando corre `prive_evaluate_eligibility` (`prive-cron` no está programado; hoy lo dispara el dueño) o cuando el admin vuelve a llamar `admin_grant_prive`, que invita a `v_grant.user_id` si es PRO.

**Corrección propuesta:**

```diff
--- a/supabase/migrations/20261023090100_prive_core_access.sql   (nueva migración que redefine)
 CREATE OR REPLACE FUNCTION public.apply_prive_grant()
 ...
-  IF NEW.email IS NOT NULL THEN
+  IF NEW.email IS NOT NULL AND NEW.email_confirmed_at IS NOT NULL THEN
     UPDATE public.prive_grants SET user_id = NEW.id
      WHERE email = lower(NEW.email) AND user_id IS NULL AND revoked_at IS NULL;
 ...
 DROP TRIGGER IF EXISTS on_auth_user_prive_grant ON auth.users;
 CREATE TRIGGER on_auth_user_prive_grant
-  AFTER INSERT OR UPDATE OF email ON auth.users
+  AFTER INSERT OR UPDATE OF email, email_confirmed_at ON auth.users
   FOR EACH ROW EXECUTE FUNCTION public.apply_prive_grant();
```

Además, porque `autoconfirm` hace que `email_confirmed_at` no pruebe nada:

```diff
 -- prive_accept_invitation: una membresía basis='grant' ligada por registro exige el token del correo
-  IF _token_hash IS NOT NULL THEN
+  IF _token_hash IS NULL AND EXISTS (SELECT 1 FROM public.prive_memberships m
+       WHERE m.user_id = _user AND m.basis = 'grant' AND m.status = 'invited') THEN
+    RETURN jsonb_build_object('ok', false, 'code', 'NO_INVITATION');  -- abrir desde el enlace del correo
+  END IF;
+  IF _token_hash IS NOT NULL THEN
```

### P3-1 · REMEMBER: la prueba R06 ("propia") es vacía

- **Dónde:** `supabase/tests/prive/aud_session.sql:449`, `(aud.remember(11, :'t12e'))->>'ok' = 'false'`.
- **Problema:** la cuenta 11 ya perdió PRO en S12 y S12d. `prive_remember_session` responde `PRIVE_NOT_PRO` antes de llegar al filtro `AND user_id = _user` (`…030000:34`).
- **Mutación M8** (quitar `user_id`): 140 OK / 0 FALLA en la suite `prive`.
- **M9 y M10** tampoco se detectan. Ahí la defensa en profundidad (`prive_require`) hace que no sean explotables, pero la afirmación documentada no tiene prueba.
- **Prueba que lo demuestra:** `aud2_prive.sql` C3j (detecta M8; `salidas/aud2_prive_M8.txt`) y C3c (detecta M9).
- **Corrección:** usar en R06 una segunda cuenta con derecho vigente, como C3j.

### P3-2 · La cookie "se cierra al cerrar el navegador" es solo una regla del cliente

- **Dónde:** `src/lib/priveSession.ts:106-108`.
- **Problema:** sin la marca, el cliente borra el token local, pero **no** avisa al servidor (`lock`). La sesión Privé sigue válida en el servidor hasta 2 h sin uso o 12 h, ligada a una sesión de IATOS que en una computadora compartida sigue abierta. Quien lea `localStorage` (devtools, perfil copiado) antes de que la app lo descarte puede usar el token con las RPC.
- **Corrección propuesta:** en `readPriveSession`, cuando se descarta por falta de la marca, disparar `prive-access {action:"lock"}` con ese token (mejor esfuerzo). También cabe acortar la inactividad de la sesión normal.

### P3-3 · Carreras entre revocar y usar o desbloquear

Se probaron con dos conexiones reales (`scripts/race.sh`, `salidas/carreras.txt`):

- **R1.** Una RPC (`prive_home`) empezó a las 18:11:53.862 durante una transacción de "cerrar todas" que confirmó a las 18:11:55.852. `prive_require` se bloqueó en el `UPDATE last_seen_at` (`…030000:103`), siguió y **entregó los datos después del COMMIT de la revocación**. La ventana es de una petición en vuelo.
- **R2.** "Cerrar todas mis sesiones" mientras corre un `prive_unlock`: la sesión nueva sobrevive (1 viva).
- **R3** (recordar durante una revocación) y **R4** (10 desbloqueos en paralelo): correctos.
- **Corrección propuesta:** en `prive_require`, `SELECT … FOR SHARE` de la sesión (o volver a leer `revoked_at` después del `UPDATE`). En `prive_revoke_sessions`, tomar antes un candado de la fila de `prive_credentials` (`FOR UPDATE`), que es el mismo que toma `prive_unlock`.

### P3-4 · El barrido sí cierra en masa si `auth.sessions` se lee pero falla una columna

- **Dónde:** `…030000:139-147` (y `…020000:100-108`). Solo revisa `has_table_privilege('auth.sessions')`.
- **Prueba:** `aud2_sweep.sql` renombra `auth.users.deleted_at` dentro de una transacción. `prive_sweep()` cerró **3/3 sesiones** con `auth_session_gone` (`salidas/aud2_sweep.txt`). El código dice "no conviene cerrar en masa por un problema de permisos": la protección es incompleta. Solo afecta disponibilidad, y hoy no corre porque `prive-cron` no está programado.
- **Corrección propuesta:** antes del `UPDATE`, probar `prive_auth_session_alive` sobre una sesión de Auth conocida y viva, o revisar también `has_column_privilege` de `banned_until`, `deleted_at` y `not_after`. Si una sola sesión falla, abortar el bloque.

### P3-5 · Escalera de fuerza bruta: 14 intentos por día sin bloqueo total; sin `PRIVE_IP_SALT` no hay límite por IP

- **Dónde:** `090200:79` (reinicio a las 24 h).
- **C6d:** 42 fallos en 3 "días" → `hard_locked=false`.
- **C6f:** sin sal, `ip_hash` es nulo y nunca hay bloqueo por IP. Además, el `ip_hash` incluye el día UTC (`prive-core.ts:29-33`): a medianoche UTC el bloqueo por IP desaparece.
- **Riesgo:** bajo con contraseñas de 12 o más bytes y la revisión HIBP. Es una decisión de diseño documentada en parte. `PRIVE_IP_SALT` en producción sigue BLOQUEADO (secretos).

### P3-6 (calidad de pruebas) · `prive/run.sh` prueba versiones viejas de 3 funciones

- **Dónde:** `supabase/tests/prive/run.sh:13`. Vuelve a aplicar `2026102309*` y `_aud_prive_`, pero no `20261024051500_aud_pagos_payment_event_atomic.sql` (redefine `prive_record_paid_period` y `prive_mark_paid_period`, AUD-05) ni `20261024310000_privekey_plans.sql` (redefine `prive_save_progress`, PK-01).
- **Prueba:** en la base de la suite, `prive_save_progress` vuelve a la versión **sin** `dna_consent` (md5 `051682be…` → `6492f9d9…`). CAL-02 sigue incompleto.
- **Mitigación verificada:** corrí prive.sql, aud_session.sql y aud_seg_strength.sql sobre el estado final sin volver a aplicar nada (`scripts/run_fiel.sh`): **140 OK / 0 FALLA**. No oculta una falla hoy.
- **Corrección propuesta:** volver a aplicar todas las migraciones posteriores a `20261023090000`, en orden.

---

## 4. Pruebas insuficientes o engañosas (mutaciones)

Suite `prive` completa por mutación (`scripts/loop_mut.sh`, `mutaciones/resumen.txt`). El archivo de la copia se restauró después de cada una, y se comprobó contra `base/`.

| Mutación | FALLA | Pruebas que la detectan |
|---|---|---|
| M1 `prive_require` sin `AND s.user_id = v_uid` | 1 | PS2 |
| M1b `alive` sin `s.user_id = $2` | 1 | S09c |
| M2 `alive`=true si falta la tabla | 2 | S07b, S08 |
| M2b `alive`=true en la excepción | 4 | S07, S07b, S08, S08b |
| M3a sin `banned_until` | 2 | S04, S11c |
| M3b sin `deleted_at` | 1 | S05 |
| M4 `require` acepta sin ligar | 3 | S09b, S11b, PS1b |
| M4b unlock sin `session_id` | 1 | S09 |
| M5 `require` sin `access_code` (PRO, 90 días) | 11 | P06 P07 P10 P12 P15 P17 P18 S12 S12c S12d R05 |
| M5b sin `is_pro` | 8 | P10 P10b P15 S12 S12b S12c S12d R05 |
| M5c 90 días → 0 | 13 | P01 P04 P06 P07 P17 P18 P23d P50 N01 N01c N01d N03 N05 |
| M6 remember sin los 5 min | 2 | R06, R07 |
| M7 `require` sin comparar el `session_id` del JWT | 2 | P25, S10 |
| **M8 remember sin `user_id`** | **0** | ninguna: R06 es vacía (C3j nuevo la detecta) |
| **M9 remember sin alive** | **0** | ninguna (C3c nuevo la detecta) |
| **M10 remember sin `access_code`** | **0** | ninguna (defensa en profundidad; no explotable) |
| M11 `alive` sin `not_after` | 2 | S06, S08b |
| NEW-01 n1, n2, n3 | 2, 2, 4 | N01/N01d · N02/N04 · N01/N01d/N03 |
| Edge E1 (sin chequeo de `session_id`), E2 (sin traducir `AUTH_SESSION_INVALID`), E3 (sin canónica), E4 (remember sin `ok`) | 2, 1, 5, 1 | `priveAccess.test.ts` y `aud2_priveCanon.test.ts` |
| Cliente: sin la marca de la cookie | 1 | `priveLib.test.ts` |

Otras fragilidades:

- M1, M1b, M3b y M4b las detecta una sola prueba cada una.
- `aud_session.sql` N05 hace `\ir` de `…020000` y `…030000` a mitad de la suite. Una mutación aplicada a la base y no al archivo se revierte para R* y lo que sigue. Las mutaciones de este informe se hicieron sobre los archivos para evitarlo.

---

## 5. Discrepancias entre la documentación y el código

- **D1.** `IATOS_CIERRE…` §2, `PRIVE.md` y §4 dicen "las 12 RPC de contenido". El catálogo final tiene **44** RPC con `_ps`; S11 imprime "44 rpc". Todas empiezan con `prive_require`.
- **D2.** Los números de línea de `PRIVE.md` están corridos. Dice `prive_auth_session_alive` l. 19–46, `prive_require` l. 49–110, `prive_unlock` l. 112–162 y cierre de sesiones sin ligar l. 166. En el archivo son 16–41, 45–101, 109–158 y 164–165.
- **D3.** `PRIVE.md` (REMEMBER) dice "solo… propia… R06 OK". La prueba no ejercita "propia" (M8 sobrevive).
- **D4.** `IATOS_CIERRE…` §3.4 y §8 sobre N-02 dicen "PENDIENTE (se resuelve con N-01; sigue exigiendo PRO para entrar)". `apply_prive_grant` no mira `email_confirmed_at`, a diferencia de `apply_comp_grant`. El PRO puede ser de cortesía (`comped`, sin vencimiento) por `comp_grants`. Ver P2-1.
- **D5.** `PRIVE.md` dice que el barrido está "protegido contra cierre masivo si `auth.sessions` es ilegible". Es parcial: ver P3-4.
- **D6.** `PRIVE.md` (SES-LS) dice que la cookie "recupera el cierre al cerrar el navegador". Solo en el cliente: ver P3-2.
- **D7.** Antes/después de `aud_session.sql`: el reporte dice 22 OK / 14 FALLA. Yo medí 29/23 sobre el código viejo portado. Las 15 fallas de defecto coinciden con las 14 del reporte más N05, que prueba la limpieza de la propia migración. El resto son errores de la función nueva. Es consistente.
- **D8.** CAL-02 dice "`prive/run.sh` corregido". Sigue probando versiones viejas de `prive_save_progress` y `prive_*_paid_period` (P3-6).
- **D9.** RESULTADOS_QA: sin `.env` en el paquete, 5 archivos de Vitest de Privé no cargan (`supabaseUrl is required`). Hay que exportar valores ficticios para reproducir.

---

## 6. Comandos ejecutados (salidas en `/home/user/audit2/prive/salidas/`)

```bash
# Código viejo
mkdir -p /home/user/audit2/prive-old && git -C /home/user/wanderly-ai-concierge archive 06865cb | tar -x -C /home/user/audit2/prive-old
diff prive-old/supabase/migrations/20261023090{0,1,2,3}00_prive_core_*.sql prive/codigo/...   # vacío (idénticos)

# Suites oficiales (bases a2prive_<suite>)
su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash supabase/tests/<suite>/run.sh a2prive_<suite>"
#   prive 140/0 · prive_catalog 110/0 · prive_key 47/0 · privevalor 144/0 · edition 47/0   (suite_*.txt)

# Vitest
VITE_SUPABASE_URL=http://localhost:54321 VITE_SUPABASE_PUBLISHABLE_KEY=dummy npx vitest run src/test/prive --testTimeout=60000
#   29 archivos, 555/555 (vitest_prive.txt)
deno check --quiet supabase/functions/prive-access/index.ts   # OK

# Antes y después de AUD-01 (scripts/mkdb.sh, scripts/run_aud.sh)
mkdb.sh a2prive_base <codigo>                  # todas las migraciones
mkdb.sh a2prive_antes <codigo> '_aud_prive_'   # código viejo portado
run_aud.sh a2prive_antes … aud_session_sin_ir.sql  # 29 OK / 23 FALLA (aud_session_ANTES.txt)
run_aud.sh a2prive_base  … aud_session.sql         # 48 OK / 0     (aud_session_DESPUES.txt)
# Edge viejo: actions.ts de 06865cb + priveAccess.test.ts → 7 FALLA / 31 (priveAccess_ANTES.txt)

# Mutaciones
scripts/loop_mut.sh M1 … M11   # mutaciones/resumen.txt
run_aud.sh a2prive_base … aud_session.sql scripts/n{1,2,3}.sql   # aud_session_NEW01_n*.txt

# Casos nuevos
run_aud.sh a2prive_base … aud2_prive.sql          # 23 OK, 3 FALLA (N-02), 7 INFO (aud2_prive.txt)
run_aud.sh a2prive_base … aud2_prive.sql m8.sql   # C3j FALLA (detecta M8)
run_aud.sh a2prive_base … aud2_prive.sql m9.sql   # C3c FALLA (detecta M9)
run_aud.sh a2prive_base … aud2_sweep.sql          # barrido cierra 3/3 (aud2_sweep.txt)
scripts/race.sh a2prive_base                       # carreras R1–R4 (carreras.txt)
scripts/run_fiel.sh                                # prive en el estado final: 140/0
npx vitest run src/test/aud2_priveCanon.test.ts    # 6/6

# Limpieza: DROP DATABASE de todas las a2prive_* (quedan 0); migraciones, priveSession.ts y actions.ts iguales a base/.
```

**Archivos nuevos en mi copia:**

- `supabase/tests/prive/aud2_prive.sql`
- `supabase/tests/prive/aud2_sweep.sql`
- `supabase/tests/prive/aud_session_sin_ir.sql` (aud_session sin los `\ir`, para la corrida "antes")
- `src/test/aud2_priveCanon.test.ts`
- `scripts/*` (mkdb, run_aud, mutar.py, loop_mut, race, run_fiel, m8/m9/n1–n3.sql)

**BLOQUEADO (requiere producción):**

- que `postgres` lea `auth.sessions` y `auth.users(banned_until, deleted_at)`;
- la semántica real de GoTrue: el `session_id` al refrescar, el borrado de la fila al cerrar sesión, el cambio de correo con autoconfirm y un nuevo registro sobre una cuenta sin confirmar;
- que exista `PRIVE_IP_SALT`;
- que `cf-connecting-ip` no se pueda falsificar en el gateway.
