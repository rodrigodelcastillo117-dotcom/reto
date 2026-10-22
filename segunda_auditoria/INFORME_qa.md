# Segunda auditoría independiente de IATOS AI · Grupo `qa`

Material: paquete del commit `7670102`, copia en `/home/user/audit2/qa/codigo`. Al terminar, mi copia es idéntica a `/home/user/audit2/base/.../codigo` (`diff -rq`, sin contar `node_modules`). Solo quedan dos cosas de más: el `.env` FALSO que creé y `dist/` del build.
Fecha: 22-oct-2026. Máquina compartida de 4 núcleos; carga entre 1 y 7 durante las corridas.
Salidas completas en `/home/user/audit2/qa/out/`.

## 1. Resumen: números obtenidos frente a los reclamados

| Afirmación (`RESULTADOS_QA.txt` y cierre §6.1) | Reclamado | Obtenido por mí | Veredicto |
|---|---|---|---|
| `tsc --noEmit -p tsconfig.app.json` | OK, 0 errores | OK, exit 0, 0 errores (38 s) | VERIFICADO INDEPENDIENTEMENTE |
| `tsc --noEmit -p tsconfig.node.json` | (no se reclama) | OK, exit 0 | VERIFICADO (extra) |
| `vitest run` con el paquete tal como se entrega (sin `.env`) | 204 archivos, 2258/2258 | **6 archivos FALLAN, 198 pasan; 2113/2113 pruebas** (faltan 145 que nunca corren); 7 errores no manejados; **exit 1** | **REFUTADO CON EVIDENCIA** (sin `.env` no se reproduce) |
| Lo mismo con `--testTimeout=60000` (sin `.env`) | — | Idéntico: 6 FALLAN, 2113/2113, 7 errores, exit 1 | Las fallas no son por tiempo |
| `vitest run` con un `.env` FALSO (`https://example.invalid`), tiempo por defecto | 204, 2258/2258 | 204/204 archivos y 2258/2258 pruebas, **pero 7 "Unhandled Rejection" y exit 1** | PARCIALMENTE CUBIERTO: el conteo coincide, pero `npx vitest run` termina en ROJO (exit 1) |
| Lo mismo con `--testTimeout=60000` y `.env` falso | — | 204/204, 2258/2258, 7 errores, exit 1 | Igual |
| `npm run build` | OK | Sin `.env`: **FALLA** (`[vite:build-html] URI malformed`, `%VITE_SUPABASE_URL%` sin definir). Con el `.env` falso: **OK** (33 s; solo advertencias de tamaño de chunk y de Tailwind) | VERIFICADO con `.env` falso; el paquete por sí solo no compila |
| `deno check` de las funciones | 66/66 | **66/66 OK, 0 FALLA**. Hay 67 carpetas: 66 funciones con `index.ts`, más `_shared` | VERIFICADO INDEPENDIENTEMENTE |
| 16 suites SQL sin FALLA | conteos de la tabla | Los 16 conteos de OK **coinciden exactamente**, con 0 líneas FALLA (tabla §3) | VERIFICADO, con las reservas de §4 sobre cómo se cuenta |

**Veredicto qa.** Los números se reproducen, pero solo si se añade un `.env`, y aun así `vitest run` sale con código 1. La afirmación "2258/2258 pasan" es cierta para el conteo de pruebas. Lo que omite es que la corrida termina en rojo por 7 errores no manejados. También omite que, sin el `.env` real (que se excluyó del ZIP), 145 pruebas de 6 archivos ni siquiera se cargan. Entre ellas están `priveLib`, `priveUiContract`, `priveHub` y `priveInvitation`.

## 2. Vitest en detalle

### 2.1 Corridas

| Corrida | Archivos | Pruebas | Errores no manejados | exit | Duración |
|---|---|---|---|---|---|
| A. sin `.env`, tiempo por defecto (5 s) | 6 fallan / 198 pasan | 2113/2113 | 7 | 1 | 134 s |
| B. sin `.env`, `--testTimeout=60000` | 6 fallan / 198 pasan | 2113/2113 | 7 | 1 | 166 s |
| C. `.env` falso, tiempo por defecto | 204/204 | 2258/2258 | 7 | 1 | 261 s |
| D. `.env` falso, `--testTimeout=60000` (con un contador de aserciones temporal) | 204/204 | 2258/2258 | 7 | 1 | — |
| E. `.env` falso, `--testTimeout=60000` (con un registro de `fetch` temporal) | 204/204 | 2258/2258 | 7 | 1 | — |

- **Fallas por tiempo: ninguna** en todas las corridas. Con esta carga, las pruebas que `CALIDAD_PRUEBAS.md` §4 marca como frágiles por tiempo pasaron.
- **Fallas reales sin `.env` (6 archivos):** `priveEdition.test.ts`, `priveHub.test.tsx`, `priveInvitation.test.tsx`, `priveLib.test.ts`, `priveUiContract.test.ts` y `tripSavings.test.ts`.
  - Causa: `Error: supabaseUrl is required.`, lanzado en `src/integrations/supabase/client.ts:12`. Esos archivos importan, directa o indirectamente, el cliente real de Supabase sin simularlo.
  - Las corrí solas: `vitest run src/test/priveLib.test.ts src/test/tripSavings.test.ts` da "2 failed, no tests" sin `.env`, y 46/46 con el `.env` falso. Son deterministas, no dependen de la carga.
- **Errores no manejados (7, en TODAS las corridas):** `TypeError: supabase.from(...).select(...).eq(...).not is not a function`.
  - Dónde se lanza: `src/components/booking/TripBookingIntents.tsx:23`.
  - Qué pruebas los provocan: 6 vienen de `src/test/tripSelectionsPersist.test.tsx` y 1 de `src/test/godtierTripDetail.test.tsx`.
  - Causa: el mock de Supabase de esas pruebas (`tripSelectionsPersist.test.tsx:22`) no implementa `.not()`.
  - Consecuencia: el componente de intenciones de reserva revienta en cada render de esas pruebas, y las pruebas pasan de todos modos. Ninguna detectaría un error real en ese componente.
  - Corriendo solos esos 2 archivos se reproduce igual: 7 pasan, 7 errores, exit 1.

### 2.2 Las pruebas hacen peticiones HTTP reales (no son herméticas)

Para medirlo instalé un registro temporal de `fetch` en mi copia (corrida E; ya lo borré). Durante la suite salieron **35 peticiones reales**:

- 30 desde `priveHub.test.tsx` a `${VITE_SUPABASE_URL}/rest/v1/trips?...` (16) y `/rest/v1/profiles?select=active_trip_id&id=eq.u1` (14). La causa es que `useActiveTrip` y `profileActiveTrip` no están simulados.
- 4 desde `doubleSubmit.test.tsx` a `https://open.er-api.com/v6/latest/USD`.
- 1 desde `dashboardActiveTrip.test.tsx` a `https://geocoding-api.open-meteo.com/...`.

Con el `.env` real del repositorio, que apunta a **producción**, cada `vitest run` manda unas 30 lecturas anónimas a la API de producción de Supabase. Es el mismo tipo de fuga que el "incidente de medición" del cierre §3.11, pero en la suite de pruebas. Además, las pruebas pasan aunque la red falle: con `example.invalid` todas esas peticiones fallaron y nadie lo notó. Ver §5, P3-QA-2.

### 2.3 Calidad estática de las pruebas de Vitest

- `it.skip`, `.only`, `.todo`, `xit`, `fit`, `skipIf`, `runIf` y `.fails`: **0**. Lo busqué con `grep` en `src/**`. Además, el JSON de Vitest reporta 0 pendientes y 0 todo.
- `expect(true)`, `expect(1)` y similares: **0**.
- Pruebas sin aserciones: **0 de 2258**. Lo medí con `expect.getState().assertionCalls` en un `afterEach` temporal. Distribución: 465 con 1 aserción, 538 con 2, 384 con 3, 327 con 4 y 544 con 5 o más.
- Snapshots: 4 `toMatchSnapshot` en `emailSystem.test.ts` (líneas 196, 252, 269 y 329). Uno es solo snapshot (l.196); los otros 3 tienen además aserciones explícitas. `CALIDAD_PRUEBAS.md` dice 3 (1 + 2).
- `.catch(() => {})`: 1 (`googleMapsLoader.test.ts:71`), como dice el documento.
- 69 archivos simulan `@/integrations/supabase/client` (el documento dice 59).
- Las pruebas no prueban RLS ni funciones Edge reales. Eso coincide con lo que admite el documento.

## 3. Suites SQL (Postgres 16 local, `/tmp/pgsec:55440`, bases `a2qa_<suite>`, todas borradas al final)

Comando: `su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash supabase/tests/<s>/run.sh a2qa_<s>"`, con las 16 en secuencia (`/home/user/audit2/qa/out/run_sql.sh`).

Cómo conté:
- `OK` = líneas que empiezan por `^OK`.
- `FALLA` = líneas que contienen `FALLA` (el método del MANIFIESTO).
- Además conté `ERROR` aparte y revisé a mano cada línea que no era OK.

| Suite | Reclamado | OK obtenido | FALLA | Otras líneas ERROR | Inesperado |
|---|---|---|---|---|---|
| ai_reservations | 57 | 57 | 0 | 0 | — |
| avatar | 41 | 41 | 0 | 0 | — |
| boveda | 50 | 50 | 0 | 0 | — |
| bridge | 42 | 42 | 0 | 0 | — |
| concierge2 | 7 | 7 | 0 | 0 | — |
| cost | 16 | 16 | 0 | 0 | — |
| edition | 47 | 47 | 0 | 0 | — |
| members_more | 30 | 30 | 0 | 1 (pg_cron) | — |
| ops | "sin FALLA" | **0** (no imprime OK) | 0 | 6 (pg_cron + 4 `permission denied` esperados de T1/T2 + 1) | Comparé T1–T9, C1 y la concurrencia a mano: todos coinciden con lo esperado entre corchetes |
| payments | 88 | 88 | 0 | 0 | — |
| prive | 140 | 140 | 0 | 0 | — |
| prive_catalog | 110 | 110 | 0 | 1 (pg_cron) | — |
| prive_key | 47 | 47 | 0 | 1 (pg_cron) | — |
| privevalor | 144 | 144 | 0 | 1 (pg_cron) | — |
| security | 156 | 156 | 0 | 8: pg_cron, 4 `permission denied` de A2–A5, 1 "Solo el dueño del viaje…" (L5/L6, esperado) y 2 `permission denied` de profiles_tier (esperados) | Las líneas A1–A5, L1–L7, D1–D6 y T1–T7 (unas 30) no son "OK" y no entran en las 156; las revisé a mano y son correctas |
| social | 70 | 70 | 0 | 1 (pg_cron) | — |

Única migración que falla en local: `20260527200005_…sql:45` (`CREATE EXTENSION pg_cron`), en las 16 suites. La línea 46 (`pg_net`) tampoco se aplica en local.

**Fuera de las "16 suites".** Hay dos archivos que ningún `run.sh` ejecuta: `supabase/tests/security/trip_expediente.sql` y `security/trip_quotes.sql`.
- Los corrí a mano.
- Sobre la base de `security`, como indica `IATOS_TEST_MATRIX.md`, `trip_expediente` da **2 discrepancias** contra lo esperado entre corchetes:
  - D5 `[2|2]: 2|3`;
  - D8 `[0|0]: 0|1`.
- La causa es contaminación de datos, no un defecto: `aud_seguridad.sql:117` deja el objeto `a7000000-…/pasaporte.pdf` en el bucket `trip-documents`.
- Sobre una base limpia, solo con las migraciones en orden, los 27 casos coinciden.
- `trip_quotes` Q1–Q11 coincide; las únicas diferencias son cosméticas (`t`/`true`).

Conclusión: estas pruebas están sin mantenimiento y quedan fuera del conteo que se presenta como cobertura.

## 4. Inspección crítica de la QA

### 4.1 Re-aplicación de migraciones fuera de orden: oculta regresiones (demostrado)

Doce `run.sh` vuelven a aplicar migraciones viejas **después** de la pasada completa, así que la base final no es la de producción. Lo analicé con el script `scratchpad/qa/stale.py`, que extrae funciones, políticas, triggers y vistas por archivo y simula el orden. Encontré objetos con una versión distinta a la de producción en dos suites:

- **`prive`**, 3 funciones (confirmado en la base con `md5(pg_get_functiondef)`: 3 de 343 funciones difieren de una base aplicada solo en orden):
  - `prive_record_paid_period` y `prive_mark_paid_period`: la suite prueba la versión de `20261023090300`, **anterior a la corrección AUD-05** (`20261024051500_aud_pagos_payment_event_atomic.sql`).
  - `prive_save_progress`: la suite prueba la versión de `20261023090200`, **anterior a la corrección PK-01** (`20261024310000_privekey_plans.sql`).
- **`ops`**, 2 funciones: `clear_active_trip_on_collab_removed` y `trips_quote_basis_guard` quedan como en `2026102213*`. `CALIDAD_PRUEBAS.md` lo documenta.

**Mutación que lo demuestra.**
- En mi copia rompí `prive_save_progress` dentro de `20261024310000_privekey_plans.sql:280`: cambié `greatest(welcome_version_seen, …)` por `coalesce(_welcome_version, 0)`, de modo que la versión de bienvenida puede retroceder.
- `prive/run.sh` normal sigue dando **140 OK, 0 FALLA**: la mutación queda oculta, porque la re-aplicación restaura la versión vieja.
- Mi variante sin re-aplicación (`/home/user/audit2/qa/variantes/sup/tests/prive/run.sh`) da **139 OK, 1 FALLA: P50**.
- Restauré el archivo y verifiqué con `diff` contra `base`.
- Sin mutación, la variante en orden también da 140 OK. Hoy no hay una regresión oculta, pero la suite `prive` no protege las versiones de producción de esas 3 funciones.
- La "corrección" de CAL-02 (re-aplicar también `20261024*_aud_prive_*`) es **incompleta**: no cubre `aud_pagos` ni `privekey_plans`.

En `ai_reservations`, `avatar`, `boveda`, `bridge`, `concierge2`, `cost`, `edition`, `members_more`, `privevalor`, `social` y `payments` el análisis no encontró objetos con una versión distinta.

### 4.2 El método de conteo del MANIFIESTO no detecta todas las fallas (demostrado)

- **`ops` nunca puede dar FALLA.** Imprime valores observados y esperados, sin veredicto, y el método `grep -c '^OK'` siempre da 0.
  - Mutación: `GRANT EXECUTE ON claim_tracked_flights(integer,interval) TO authenticated` en la base de `ops`.
  - Resultado: T1 pasó de `permission denied` a devolver `6` (un usuario cualquiera reclama vuelos), y la suite siguió con `rc=0`, 0 OK y 0 FALLA.
  - Solo una persona que compare a mano los corchetes lo notaría. En `security` pasa lo mismo con A*/L*/D*/T*, igual que en `trip_quotes` y `trip_expediente`.
- **`payments` (y `cost`/`concierge2`) imprimen `ERROR:`, no `FALLA`.**
  - 105 aserciones (`RAISE EXCEPTION 'Q1a …'`, etc.) en `payments.sql`, `quota_reservations.sql`, `plan_limits*.sql` y `trial_no_card.sql` salen como `ERROR:  F4 {...}`. Con `ON_ERROR_STOP=1`, además, se salta el resto del archivo.
  - Repetí la mutación M1 de `CALIDAD_PRUEBAS.md`: `>=` → `>` en `20261022135300_pay_plan_limits_recommended.sql:210`.
  - Resultado: **OK 88 → 68; 3 `ERROR` (F4, P5b, L3b), que `grep FALLA` no cuenta**. La única "FALLA" visible fue L7, por un efecto colateral.
  - Restauré el archivo y verifiqué con `diff`.
- **Las migraciones rotas no salen como "FALLA".**
  - `security/run.sh` las imprime como `FALLÓ …`, y `grep FALLA` no encuentra "FALLÓ".
  - `ai_reservations`, `bridge`, `edition`, `payments` y `prive` mandan además la salida completa de la pasada de migraciones a `/dev/null`.
- **Ninguna suite comprueba su propio total esperado.** Un bloque que deja de ejecutarse solo reduce el conteo de OK, y los totales esperados viven únicamente en `RESULTADOS_QA.txt`.
- `security/run.sh:520` filtra con `grep -v 'violates row-level security'` todas las líneas de error por RLS de `aud_seguridad.sql`, sean esperadas o no.

### 4.3 Entorno de la QA distinto del documentado

El MANIFIESTO dice `npm ci`, pero el `node_modules` compartido lo instaló **Deno** (estructura `node_modules/.deno/…`, guiada por `deno.lock`), con versiones distintas a las de `package-lock.json`:

| Paquete | `package-lock.json` | Instalado |
|---|---|---|
| `@supabase/supabase-js` | 2.112.3 | 2.118.0 |
| `vite` | 5.4.19 | 5.4.21 |
| `typescript` | 5.8.3 | 5.9.3 |

Mis resultados (y probablemente los del equipo) no corresponden a una instalación con `npm ci`.

### 4.4 ¿Coincide `CALIDAD_PRUEBAS.md`?

- **Coincide** en lo cualitativo:
  - 0 skip/only/todo;
  - 0 `expect(true)`;
  - 0 pruebas sin aserciones;
  - el `.catch` legítimo;
  - `bookingBridgeE2E` como simulación;
  - la re-aplicación en `ops`.
- **Está desactualizado:**
  - habla de 177 archivos, 1,791 pruebas y 11 suites, frente a 204, 2258 y 16 hoy;
  - cuenta 59 mocks de Supabase (hoy 69) y 3 snapshots (hoy 4).
- **No menciona:**
  - los 7 errores no manejados ni el exit 1;
  - la dependencia del `.env` (6 archivos, 145 pruebas);
  - las peticiones HTTP reales (30 a la URL de Supabase del `.env`);
  - que `prive` sigue probando versiones viejas de funciones de AUD-05 y PK-01;
  - que el método de conteo no ve `ERROR` ni `FALLÓ`;
  - que `trip_expediente`/`trip_quotes` están fuera de las suites y `trip_expediente` ya no cuadra sobre la base de `security`.

## 5. Defectos nuevos del área QA (P0–P3)

No hay P0 ni P1.

**P2-QA-1 · La suite `prive` prueba versiones obsoletas de funciones corregidas (AUD-05, PK-01).**
- Entrada: `supabase/tests/prive/run.sh:13-16`, que re-aplica `2026102309*.sql` después de la pasada completa.
- Prueba: la mutación de §4.1, con la variante en `/home/user/audit2/qa/variantes/sup/tests/prive/run.sh`.
- Corrección propuesta:
```diff
--- supabase/tests/prive/run.sh
-for f in "$DIR"/../../migrations/2026102309*.sql "$DIR"/../../migrations/20261024*_aud_prive_*.sql; do
+# Idempotencia: re-aplicar y DESPUÉS volver a aplicar todas las posteriores, para terminar en el estado de producción.
+for f in "$DIR"/../../migrations/2026102309*.sql $(ls "$DIR"/../../migrations/*.sql | awk -F/ '$NF > "20261023090399"'); do
```
- Aplicar lo mismo en `ops/run.sh` (re-aplicar después todas las posteriores a `2026102213*`). Como alternativa, verificar la idempotencia en una base aparte.

**P2-QA-2 · El conteo de las suites SQL no detecta fallas en `ops` ni las `ERROR:` de `payments`/`cost`/`concierge2`, ni migraciones `FALLÓ`.**
- Pruebas: las dos mutaciones de §4.2.
- Corrección propuesta:
  - que cada `run.sh` termine con `exit 1` si hay `FALLA|FALLÓ|ERROR` no esperados o si el número de OK es distinto del esperado, guardado en el propio script;
  - convertir `ops` al formato OK/FALLA (`t_ok(nombre, observado = esperado)`);
  - en `payments`, `sed 's/^ERROR/FALLA ERROR/'` como ya hacen otras suites.

**P3-QA-1 · `npx vitest run` termina con exit 1 (7 Unhandled Rejections) aunque reporta 2258/2258.**
- Lugar: el mock de `src/test/tripSelectionsPersist.test.tsx:22`, que no implementa `.not`.
- Corrección propuesta:
```diff
-      select: () => api, eq: () => api, order: () => api, limit: () => api, in: () => api,
+      select: () => api, eq: () => api, not: () => api, order: () => api, limit: () => api, in: () => api,
```
- Revisar también `godtierTripDetail.test.tsx`, o simular `TripBookingIntents`.

**P3-QA-2 · Pruebas no herméticas: dependen del `.env` y hacen peticiones reales (producción con el `.env` real).**
- Lugares: 6 archivos importan el cliente real; `priveHub.test.tsx` hace 30 GET a `/rest/v1/trips` y `/rest/v1/profiles`; `doubleSubmit` y `dashboardActiveTrip` llaman a APIs externas.
- Corrección propuesta:
  - en `vitest.config.ts`, `test.env: { VITE_SUPABASE_URL: "http://127.0.0.1:9", VITE_SUPABASE_PUBLISHABLE_KEY: "test" }`;
  - en `src/test/setup.ts`, un `fetch` que falle ante cualquier URL no simulada (`globalThis.fetch = () => { throw new Error("red no permitida en pruebas") }`);
  - simular `useActiveTrip` en `priveHub.test.tsx`.

**P3-QA-3 · `trip_expediente.sql` y `trip_quotes.sql` no están en ningún `run.sh`.**
- Sobre la base de `security`, `trip_expediente` da D5/D8 distintos de lo esperado (contaminación de `aud_seguridad.sql:117`).
- Corrección propuesta: llamarlas desde `security/run.sh` **antes** de `aud_seguridad.sql`, o usar un viaje o bucket aislado, en formato OK/FALLA.

**P3-QA-4 · El paquete no se puede verificar tal como se entrega.**
- Sin `.env`, el build falla y 145 pruebas no corren.
- Además, `node_modules` no corresponde a `npm ci` con `package-lock.json`.
- Corrección propuesta: incluir un `.env.example` con valores falsos y documentarlo en el MANIFIESTO.

## 6. Pruebas insuficientes o engañosas (con mutación)

| Prueba | Mutación | Resultado | Lectura |
|---|---|---|---|
| `prive/prive.sql` P50 (vía `prive/run.sh`) | `prive_save_progress` sin `greatest` en `20261024310000:280` | run.sh normal: 140 OK / 0 FALLA. En orden: 139 / 1 FALLA | **Engañosa**: la re-aplicación oculta la regresión |
| `ops/flight_watch_claim.sql` T1 | GRANT de `claim_tracked_flights` a `authenticated` | rc=0, 0 FALLA; la salida pasó a `6` | **Insuficiente**: no hay veredicto automático |
| `payments/*.sql` (M1) | `>=` → `>` en `20261022135300:210` | 68 OK, 3 `ERROR` sin "FALLA" (+ L7 FALLA colateral) | Se detecta solo si alguien compara el número de OK |
| `tripSelectionsPersist`, `godtierTripDetail` | ninguna: ya fallan | 7 rechazos no manejados, pruebas en verde | **Engañosas**: el componente revienta sin que la prueba lo vea |

## 7. AUD del área qa

El grupo `qa` no tiene un AUD propio. Su objeto son las afirmaciones de QA del cierre (§6.1) y de `CALIDAD_PRUEBAS.md`:

| AUD | Defecto original | Código corregido | Test exacto | ¿Fallaba antes? | ¿Pasa ahora? | Caso nuevo intentado | Resultado | Veredicto |
|---|---|---|---|---|---|---|---|---|
| QA §6.1 tsc | — | — | `tsc -p tsconfig.app.json` / `tsconfig.node.json` | n/a | Sí, 0 errores | también `tsconfig.node.json` | OK | VERIFICADO INDEPENDIENTEMENTE |
| QA §6.1 Vitest | — | — | `npx vitest run` | n/a | 2258/2258 solo con `.env`; exit 1 | sin `.env`; tiempo de 60 s; registro de `fetch`; contador de aserciones | 2113/2113 y 6 archivos en FALLA sin `.env`; 7 errores no manejados; 35 peticiones HTTP reales | PARCIALMENTE CUBIERTO |
| QA §6.1 build | — | — | `npm run build` | n/a | Sí, con `.env` falso | sin `.env` | FALLA sin `.env` | VERIFICADO (con `.env` falso) |
| QA §6.1 deno | — | — | `deno check` × 66 | n/a | 66/66 | conteo real de carpetas | 66 + `_shared` | VERIFICADO INDEPENDIENTEMENTE |
| QA §6.1 SQL | — | — | 16 `run.sh` | n/a | conteos idénticos, 0 FALLA | mutaciones en prive, ops y payments; variante en orden; suites excluidas | se ocultan fallas (§4.1, §4.2) | PARCIALMENTE CUBIERTO |
| CAL-02 | re-aplicación fuera de orden | `prive/run.sh` re-aplica `aud_prive_*` | `prive/run.sh` | — | — | mutación en `20261024310000` | sigue oculta | **REFUTADO CON EVIDENCIA** (corrección incompleta) |

## 8. BLOQUEADO

- Reproducir exactamente con el `.env` real y con `npm ci`: el `.env` se excluyó del paquete, y `node_modules` es compartido e instalado por Deno. No ejecuté `npm ci`, porque habría modificado el `node_modules` compartido. Usé un `.env` FALSO evidente:
```
VITE_SUPABASE_URL=https://example.invalid
VITE_SUPABASE_PUBLISHABLE_KEY=FALSO-auditoria-qa-no-es-una-llave
VITE_SUPABASE_PROJECT_ID=falso-auditoria-qa
```
- Verificar el commit `591a71a` (donde el líder dice haber corrido la QA): está fuera del material; solo audité `7670102`.

## 9. Comandos ejecutados (resumen)

```
npx tsc --noEmit -p tsconfig.app.json           → exit 0 (out/tsc_app.txt)
npx tsc --noEmit -p tsconfig.node.json          → exit 0 (out/tsc_node.txt)
npx vitest run [--testTimeout=60000] --reporter=default --reporter=json
                                                → ver §2.1 (out/vitest_*.txt|json)
npm run build                                   → sin .env FALLA; con .env falso OK (out/build_*.txt)
deno check --quiet supabase/functions/<fn>/index.ts ×66
                                                → 66 OK (en una copia aislada en el scratchpad, para no
                                                   escribir en el node_modules compartido; el deno.lock de
                                                   mi copia quedó intacto)
su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash supabase/tests/<s>/run.sh a2qa_<s>" ×16
                                                → out/sql/<s>.txt
variante en orden y mutaciones                  → out/sql/prive_enorden.txt, prive_mut_*.txt,
                                                   payments_mut_M1.txt, ops_mut_grant.txt
excluidas                                       → out/sql/excluida_trip_*.txt
DROP DATABASE de las 21 bases a2qa_*            → 0 restantes
```

## 10. Incidencia del auditor

Para comprobar si `node_modules` era de solo lectura, ejecuté `touch node_modules/.qa_write_test`. El comando funcionó: el enlace apunta a `/home/user/wanderly-ai-concierge/node_modules`, y ese directorio **no** es de solo lectura. Borré el archivo vacío segundos después y no hice ningún otro cambio en ese repositorio. Al ver que se podía escribir, corrí `deno check` en una copia aislada para no crear nada en `node_modules/.deno`.
