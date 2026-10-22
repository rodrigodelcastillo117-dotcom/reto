# Segunda auditoría independiente · Grupo `transversal`

Material: paquete del commit `7670102a050e2db975121c968a95a5962c175b48`, copiado en `/home/user/audit2/transversal/`, con `node_modules` enlazado. Fecha: 22-oct-2026.
Método: SQL real en Postgres 16 local (`/tmp/pgsec:55440`), en bases `a2trans_*` con las 127 migraciones aplicadas. Se usó `SET ROLE authenticated` con los claims `request.jwt.claim.sub/role` de otro usuario. También corrí Vitest sobre el código real y mutaciones en mi copia; cada mutación se restauró desde `base/`. No toqué producción. Todas las bases `a2trans_*` quedaron borradas.

**Resumen:** no encontré P0 ni P1. Hay **6 defectos P2** nuevos o reclasificados, todos de privacidad en documentos y datos compartidos, y **9 P3**. Hay **1 prueba insuficiente**: AUD-SEG-03 sobrevive a una mutación. Revisé **22 hallazgos "nuevos"** del documento: los 22 tienen arreglo y prueba en el código, con 6 mutaciones detectadas de 7. La documentación tiene **12 discrepancias** con el código. Mi evaluación por módulo da **12 GO y 8 NO-GO**; el documento dice 14 GO y 6 NO-GO. Paso **Social** y **Viajes** a NO-GO.

---

## 1. Comandos ejecutados y salidas resumidas

| Comando | Resultado |
|---|---|
| `bash work/mkdb.sh a2trans_main`: las 127 migraciones sobre los stubs de `security/` | Un solo error, el esperado: `20260527200005…sql: extension "pg_cron" is not available` |
| `psql -f work/t_trans.sql`: mis casos adversariales (salida en §3) | Todos ejecutados; las observaciones `OBS …` están citadas abajo |
| `run.sh` de `security`, `social`, `boveda`, `edition`, `avatar`, `prive` y `privevalor` (`work/suites.sh`) | 156, 70, 50, 47, 41, 140 y 144 OK, con **0 FALLA**. Coinciden con RESULTADOS_QA. El único error de migración es el de pg_cron |
| `npx vitest run` sobre 13 archivos de la muestra (audSeguridadEdge, priveAccess, externalLinks, stripeAtomicity, aiReservationsSenderAuth, aiReservationsConfirmRules, bookingBridgeAudit, audQuotesOpsCierre, rendimientoIato, avatarFacialHair, priveEmailDeliverability, audSegIdempotency, bovedaFiles) | **13 archivos, 267/267** |
| `npx vitest run src/test/a2trans_adversarial.test.ts`: mi archivo nuevo | **10/10**. Las aserciones afirman el defecto, así que pasar significa que el defecto existe |
| Mutaciones (§5) | 6 de 7 detectadas; 1 sobrevive (AUD-SEG-03) |
| `git -C wanderly-ai-concierge diff --shortstat 06865cb f62466e` (solo lectura) | `17 files changed, 330 insertions(+), 34 deletions(-)`. Coincide con FASE0 |
| `git ls-tree` de las migraciones en `06865cb`, `f62466e` y `7670102` | 104, 104 y 127 archivos |

No ejecuté la batería completa de Vitest (2258), `deno check` ni las otras 9 suites SQL: son del grupo `qa`. Quedan **sin verificar por mí**, no BLOQUEADAS.

---

## 2. Defectos P0–P3

### P2-1 · Social: amistad sin consentimiento, imposible de revocar, que expone datos y permite avisos ilimitados
- **Entrada reproducible** (`work/t_trans.sql`, sección SOCIAL). Beto, un extraño, conoce el código de Ana: es el mismo del enlace `/?ref=` que `InviteFriendsCard` comparte por WhatsApp.
  - `SELECT agregar_amigo_por_codigo('<código de Ana>')` responde `{"ok": true}` y la amistad queda **accepted** (SOC1/SOC1b). Ana recibe **0 avisos** (SOC1c).
  - `amigo_perfil(Ana)` le devuelve a Beto `full_name`, `ciudad_origen`, `pais_origen`, `is_prive`, el ADN, los lugares visitados y lo que tienen en común (SOC2).
  - Ana borra la amistad (SOC3 = 1 fila). Beto la **vuelve a crear al instante** con el mismo código (SOC3b ok).
  - Ana **no puede cambiar su código**: `UPDATE profiles SET invite_code` → "Ese dato del perfil no se puede cambiar desde la app" (SOC4), y no existe ninguna RPC de rotación (SOC4b).
  - Beto llama `invitar_amigo_viaje` 25 veces: Ana recibe **25 avisos** `trip_invite` con un texto que controla el atacante: *"Te agregaron como editor del viaje a Viaje del atacante: abre bit.ly/premio-iatos"* (SOC5).
- **Código vulnerable:**
  - `supabase/migrations/20260526042412_5cb19870-…sql:57-91`: inserta, o actualiza a `accepted`, cualquier fila existente sin importar su estado.
  - `20260526044222_255813f4-…sql:95-97`: `ON CONFLICT DO NOTHING` y, aun así, inserta el aviso cada vez.
  - `20261022141200_sec2_profiles_sensitive_columns.sql`: `invite_code` es inmutable.
- **Por qué P2 y no P3, como dice SEG-N2:**
  - El código circula en enlaces públicos de referidos.
  - Quitar al amigo no sirve, porque no hay bloqueo ni rotación.
  - `is_prive` revela la pertenencia a un club exclusivo.
  - Los avisos sirven para phishing.
  - F-02 (`20261022120000:16-20`) dice haber corregido "amistad sin consentimiento", pero solo cerró la escritura directa: la RPC sigue sin pedirlo.
- **Prueba:** `work/t_trans.sql` (OBS SOC0–SOC5).
- **Corrección propuesta:**
```sql
-- agregar_amigo_por_codigo: crear SOLICITUD, no amistad; no resucitar filas rechazadas/bloqueadas
IF v_existing > 0 THEN
  UPDATE public.friendships SET status = 'accepted', updated_at = now()
   WHERE requester_id = v_otro AND addressee_id = v_me AND status = 'pending';  -- solo aceptar lo que el otro pidió
ELSE
  INSERT INTO public.friendships (requester_id, addressee_id, status) VALUES (v_me, v_otro, 'pending');
  INSERT INTO public.notifications (user_id, type, title, body, related_id, dedup_key)
  VALUES (v_otro, 'friend_request', 'Nueva solicitud de amistad', '…', v_me, 'fr:' || v_me);
END IF;
-- + RPC regenerar_codigo_invitacion() (SECURITY DEFINER, auth.uid()) y estado 'blocked' que agregar_amigo no pueda pisar.
-- invitar_amigo_viaje: avisar solo si la fila de colaborador es NUEVA
INSERT … ON CONFLICT (trip_id, user_id) DO NOTHING RETURNING id INTO v_new;
IF v_new IS NOT NULL THEN INSERT INTO public.notifications … END IF;
```

### P2-2 · Diario y momentos: fotos con EXIF/GPS en buckets públicos que no se borran al eliminar la entrada
- **Entrada:**
  - `storage.buckets`: `journal-photos` y `travel-moments` tienen `public = t` (JR1).
  - `src/pages/TripJournal.tsx:62-64` sube el `File` original y guarda `getPublicUrl`, sin reescribir la imagen ni quitar metadatos. `BestMomentsPanel.tsx:142-145` hace lo mismo. Una foto de iPhone conserva así su EXIF con GPS y queda en una URL pública permanente, también para un colaborador expulsado o para quien reciba el enlace.
  - `TripJournal.tsx:82-85` borra solo la fila de `trip_journal_entries`: **la foto sigue pública**. Ni el dueño del viaje ni el autor tienen en la app un camino para borrarla.
  - Borrar el viaje tampoco la borra (TRD4).
- **Prueba:** `src/test/a2trans_adversarial.test.ts`, bloque "Fotos del diario y de momentos", 3 casos que pasan porque el defecto existe.
- **Comparación:** la Bóveda sí quita el EXIF (`src/lib/boveda/files.ts`). El Aviso de Privacidad solo lo promete para la Bóveda.
- **Corrección propuesta:**
  - Reutilizar `prepareVaultFile` (reescribir la imagen y quitar metadatos) antes de subir en `TripJournal` y `BestMomentsPanel`.
  - En `remove`, borrar también el objeto: `storage.from("journal-photos").remove([pathDe(photo_url)])`.
  - A mediano plazo, buckets privados con URL firmada. Es la corrección sugerida en N1.

### P2-3 · Documentos del viaje: el pasaporte queda huérfano e imborrable al eliminar el viaje
- **Entrada** (`t_trans.sql`, sección BORRADO DEL VIAJE): Ana sube su pasaporte a `trip-documents` y luego borra el viaje con `deleteOwnedTrip`, que hace `DELETE FROM trips`.
  - Los objetos del viaje **siguen en storage** (TRD1 = 2).
  - Ana ya **no puede verlos ni borrarlos**: `DELETE FROM storage.objects … pasaporte-ana` como Ana borra 0 filas y su `SELECT` devuelve 0. Las políticas `trip_documents_obj_select/_delete` exigen `has_trip_access` sobre un viaje que ya no existe.
  - El documento que subió una colaboradora a ese viaje no entra en `account_deletion_files(Ana)` (TRD2 = 0). Solo se borra cuando esa colaboradora borre **su** cuenta (TRD3 = 1).
  - Lo mismo pasa con los boletos y pases de abordar de `ImportPastTrip.tsx:126-138`.
- **Código vulnerable:**
  - `src/lib/tripMembership.ts:19-23`: borra el viaje sin borrar sus archivos.
  - `supabase/migrations/20261022143100_trip_documents.sql:66-80`: las políticas dependen de la fila del viaje.
  - No hay ningún trigger que limpie storage.
- **Corrección propuesta:**
  - Antes del `DELETE` del viaje, listar `trip_documents` y llamar `storage.from('trip-documents').remove(paths)` y lo equivalente para `journal-photos/<*>/<trip>/`.
  - Mejor aún, una función Edge `delete-trip` con la llave de servicio que haga los dos borrados.
  - Agregar a `account_deletion_files` los objetos de `trip-documents` cuyo `trip_document_path_trip(name)` ya no exista en `trips` (huérfanos).

### P2-4 · Pasaportes visibles a todos los colaboradores, sin opción "solo yo"
- **Entrada:** Caro es colaboradora aceptada. Lee la fila `kind='pasaporte'` de Ana (DOC1) y el objeto del pasaporte en storage (DOC1b).
  - No existe ninguna columna ni política "privado" (DOC1c).
  - `invitar_amigo_viaje` siempre crea el rol `editor`, y `has_trip_access` no distingue roles.
  - Por P2-1, cualquiera que obtenga un código puede volverse amigo. El dueño todavía tiene que invitarlo al viaje, así que el riesgo es de ingeniería social y no automático.
- **Lo que sí funciona:** la invitación pendiente (DOC2) y los extraños (DOC3) no ven nada. La colaboradora no puede borrar el pasaporte de Ana (DOC4).
- **Código:** `20261022143100_trip_documents.sql:40-42` y `66-68`.
- **Corrección propuesta:** columna `visibility text NOT NULL DEFAULT 'viaje' CHECK (visibility IN ('viaje','solo_yo'))`, con valor por omisión `'solo_yo'` para `kind='pasaporte'`. En la política SELECT de la tabla y de `storage.objects`: `AND (visibility = 'viaje' OR uploaded_by = auth.uid())`.

### P2-5 · El Aviso de Privacidad promete borrar el avatar y no existe cómo hacerlo
- **Entrada:** `src/pages/Legal.tsx:103` dice: *"Puedes eliminar tu avatar y tu foto desde tu perfil."*
  - `supabase/functions/generate-avatar/index.ts` solo tiene las acciones `crear` y `elegir` (línea 76).
  - La única referencia a "Quitar" en `AvatarCreator.tsx:301` quita una selfie de la lista que todavía no se sube.
  - El avatar, que se parece a la persona por diseño (juez de parecido ≥ 72), vive **público** en `travel-moments/avatars/<uid>/`. La imagen base queda en `avatar-private`.
  - Solo el borrado de la cuenta los elimina.
- **Prueba:** `a2trans_adversarial.test.ts`, "Avatar: la promesa del Aviso de Privacidad".
- **Corrección propuesta:** acción `{action:"eliminar"}` en `generate-avatar`. Debe borrar `avatar_profiles.current_path` (público), `base_path` y las variantes (privadas), poner `profiles.avatar_url = NULL` y quitar los recuerdos. Agregar un botón en `Profile.tsx`. Si eso no se hace, corregir el texto legal.

### P2-6 · Prueba insuficiente de AUD-SEG-03 (contexto del dueño en la lista de equipaje)
- **Mutación:**
  - En `supabase/functions/generar-packing-list/index.ts:254` y `256` cambié `.eq("id", userId)` por `.eq("id", (trip as any).user_id)` en el perfil, y `.eq("user_id", userId)` por `.eq("user_id", trip.user_id)` en `ai_user_preferences`. Con eso vuelve a mandarse el perfil y el ADN del **dueño** cuando llama un colaborador.
  - `npx vitest run src/test/audSeguridadEdge.test.ts`: **11/11 pasan**.
  - La prueba (`src/test/audSeguridadEdge.test.ts:81-86`) es una expresión regular sobre el texto: solo busca la forma literal `.eq("id", trip.user_id)` y no revisa `ai_user_preferences`.
- **Severidad:** P2 como hueco de regresión, porque el defecto original es P2.
- **Corrección propuesta:** extraer la construcción del contexto a `access.ts` (`contextQueries(callerId)`) y probarla con un cliente simulado que registre los filtros. Como mínimo, afirmar que las tres consultas usan `userId`.

### P3-1 · Bóveda: el GPS sobrevive en JPEG con MPF cuando el navegador no decodifica la foto
- **Defecto:** `src/lib/boveda/files.ts:49` conserva APP2, donde viven ICC y **MPF**. La línea 85 copia todo desde el SOS, **incluida una segunda imagen pegada después del EOI** (vista previa o profundidad de iPhone y Android) con su propio APP1 EXIF. `jpegHasMetadata` se detiene en el primer SOS y no lo detecta.
- **Alcance:** solo afecta la ruta de respaldo, cuando falla `createImageBitmap`.
- **Prueba:** `a2trans_adversarial.test.ts`, "MPF (APP2) + segunda imagen…" y "ruta de respaldo…". El GPS sigue en los bytes que se suben.
- **Corrección propuesta:** cortar en el primer EOI (`FF D9`) después del SOS, quitar APP2 cuando empiece con `MPF\0` y, en la ruta de respaldo, rechazar la foto si quedan bytes después del EOI.

### P3-2 · Bóveda: los PDF se suben sin limpiar
- **Defecto:** `files.ts:159` sube el PDF tal cual, con `/Author`, `/Creator` (nombre de la app escáner) y XMP.
- **Prueba:** `a2trans_adversarial.test.ts`, "un PDF se sube tal cual".
- **Aviso de Privacidad:** solo promete limpiar las "fotos", así que el texto es correcto, pero conviene limpiar el Info dict o avisarlo en pantalla.

### P3-3 · Bóveda: número completo de tarjeta, CVV y vencimiento en texto libre, proyectados al contexto de IA
- **Entrada:**
  - Como Ana: `INSERT INTO vault_items (section,kind,title,notes,issuer) VALUES ('tarjeta','tarjeta','Visa 4111 1111 1111 1111 exp 12/29 cvv 123','PAN 4111111111111111','Banco 4111111111111111')` → 1 fila.
  - `user_vault_benefits.credit_cards` queda así: `[{"bank":"Banco 4111111111111111","card_name":"Visa 4111 1111 1111 1111 exp 12/29 cvv 123",…}]`. Esa tabla la leen concierge-chat, analizar-viaje, buscar-promociones y packing-list.
- **Código:** `20261023190000_boveda.sql:48`, `49` y `61` (solo revisan la longitud). Los CHECK `vault_items_card_no_pan/no_expiry` solo miran `number`, `expires_on` y `valid_from`.
- **Por qué importa:** `Legal.tsx:102` dice *"Nunca pedimos ni almacenamos números completos de tarjeta, CVV ni fechas de vencimiento."*
- **Corrección propuesta:** `CHECK (section <> 'tarjeta' OR (coalesce(title,'')||coalesce(issuer,'')||coalesce(notes,'')||coalesce(tier,'')) !~ '\d[\d -]{11,}\d')` y lo mismo en el cliente.

### P3-4 · The Private Edition sin conexión: se lee sin la contraseña Privé y sobrevive a la revocación
- **Ruta sin protección:** `src/App.tsx:171` monta `/prive/edicion/sin-conexion` fuera de `ProtectedRoute` y `PriveRoot`. `EditionOfflinePage.tsx` toma el uid de `localStorage` (`storedUserId`) y muestra las copias sin pedir la sesión Privé, que es una cookie de sesión del navegador (NEW-P1). Quien tenga el teléfono desbloqueado lee el contenido Privé sin la contraseña.
- **Revocación sin efecto:** la reconciliación (`EditionOfflinePage.tsx:64`) hace `return` si `!r.ok`. Con Privé revocado, el PRO vencido o la sesión caducada, la copia **no se borra nunca**. No hay vencimiento (TTL) de las copias ni de las licencias offline.
- **Aislamiento entre cuentas:** depende solo de que la app filtre por un hash del uid. Las imágenes se guardan por URL en una caché compartida.
- **Prueba:** `a2trans_adversarial.test.ts`, "Lectura offline de The Private Edition".
- **Corrección propuesta:**
  - Borrar el paquete cuando `r.code ∈ {PRIVE_NOT_PRO, PRIVE_REVOKED, PRIVE_NOT_MEMBER}`.
  - Agregar `expires_at` a cada paquete, por ejemplo 30 días o el fin del periodo pagado.
  - Pedir un PIN o la contraseña Privé una vez por arranque de la app, aun sin red, guardando un verificador local.

### P3-5 · `journal-photos`: un extraño puede plantar objetos en la carpeta de un viaje ajeno
- **Entrada:** Beto sube `journal-photos/<Beto>/<viaje de Ana>/plantada.jpg`: 1 fila (JR2). Caro, miembro del viaje, ve ese objeto al listar (JR2b). El objeto sigue ahí después de borrar el viaje (TRD4).
- **Código:** la política `journal_photos_insert` (`20260526205422_…sql:81-82`) solo revisa `foldername[1] = uid` y no el viaje.
- **Corrección propuesta:** `AND (storage.foldername(name))[2] ~ '^[0-9a-f-]{36}$' AND public.has_trip_access(((storage.foldername(name))[2])::uuid, auth.uid())`.

### P3-6 · `photo_url` acepta cualquier URL (SEG-N4), confirmado
- **Entrada:** Caro inserta una entrada con `photo_url = 'https://evil.test/pixel.gif?who=ana'`: 1 fila (JR4). Le llega a Ana como `<img>`, que sirve de píxel de rastreo.
- **Corrección propuesta:** `CHECK (photo_url IS NULL OR photo_url LIKE '<SUPABASE_URL>/storage/v1/object/public/journal-photos/%')`.

### P3-7 · Borrado de cuenta: queda historial ligado a la cuenta borrada
- **Entrada:** después de `purge_account_data(Eli)`, un barrido de todas las tablas de `public` por el uid de Eli encuentra `profiles_tier_audit=1` (DEL2); esa tabla usa `profile_id`, no `user_id`.
- **Lo demás sí se limpia:** no quedan amistades, saludos ni avisos con su nombre (DEL3 y DEL3b vacíos), y los archivos de los 6 buckets se cubren por el prefijo de la ruta (boveda D1 OK).
- **Corrección propuesta:** `DELETE FROM public.profiles_tier_audit WHERE profile_id = p_user_id;` en `purge_account_data`.

### P3-8 · Migraciones con versiones inválidas o fechadas en el futuro
- **Hora inválida:** 5 archivos tienen una hora fuera de rango:
  - `20261022146000`, `146100`, `146200` y `146300` (hora 14:60–14:63);
  - `20261024310000_privekey_plans` (hora **31**).
- **Fechas futuras:** las 23 migraciones de "hoy" (22-oct) llevan versiones del **24 y 25 de octubre**. Cualquier migración que se cree mañana con la hora real (`20261023…`) quedará ordenada antes que ellas, y `supabase db push` la rechazará por estar fuera de orden o la aplicará en un orden distinto con `--include-all`.
- **Corrección propuesta:** para lo que viene, versionar con la fecha real (`supabase migration new`) y documentar la excepción.

### P3-9 · Notas SEG-N5, N6, N8 y N11 confirmadas en el código
- **N5:** `generar-packing-list/index.ts:293`, `344` y `355` devuelven `detail` con el texto del proveedor de IA o el error de la base. `place-photo/index.ts:87` y `100` devuelven `raw`.
- **N6:** `cron-auth.ts:14` llama `listUsers`.
- **N11:** `stripe-checkout`, `stripe-portal` y `push-subscribe` tienen 0 `enforceRateLimit`.
- **N8:** CORS `*` (revisión de código).
- Las mantengo en P3.

### Lo que intenté romper y resistió (con SQL real)
- **Bóveda:**
  - Una colaboradora no lee filas ni objetos de la Bóveda (BV1 y BV1b = 0).
  - Un extraño no sube a la ruta de Ana ni a su propia carpeta con el `item_id` de Ana (BV2 y BV3: RLS).
  - No se puede mover (UPDATE) un objeto ajeno (BV4 = 0).
  - Una ruta en mayúsculas no pasa (BV5).
  - `anon` recibe `permission denied`.
- **Privé y Edición:** el contenido de la Edición no tiene GRANT a clientes; solo las RPC `prive_edition_*` con `prive_require`. `edition_images_map` solo devuelve licencias `approved` y no la puede ejecutar `authenticated`. La suite `edition` (E01: un FREE recibe `PRIVE_NOT_PRO` por API directa) dio 47/47.
- **Reservas IA:** con `app_flags.ai_reservations_enabled = false`, `ai_reservation_create_intent` como `service_role` responde `{"ok": false, "code": "FEATURE_DISABLED"}`. `authenticated` recibe `permission denied`. `app_flags` no tiene GRANT a clientes y `app_flag()` no la pueden ejecutar `anon` ni `authenticated`.

---

## 3. Pruebas y archivos nuevos (en mi copia)
- `/home/user/audit2/transversal/work/t_trans.sql`: casos SOC, DOC, JR, BV, DEL y TRD. Se corre con `su postgres -c "./q.sh -f t_trans.sql"` sobre una base hecha con `work/mkdb.sh`.
- `/home/user/audit2/transversal/codigo/src/test/a2trans_adversarial.test.ts`: 10 casos (EXIF con MPF, PDF, diario y momentos, avatar, offline).
- `/home/user/audit2/transversal/work/suite_*.txt`, `mut1.txt` y `mut2.txt`: salidas completas.

---

## 4. Módulos sin internet y riesgos en iPhone

**Prueba en iPhone real: BLOQUEADA.** No hay dispositivo iOS ni Safari en esta máquina. Esto es lo que habría que probar en un iPhone real (iOS 17 y 18, en Safari y como app instalada en la pantalla de inicio):

1. **Purga a los 7 días (ITP).** En Safari, como sitio, sin interacción durante 7 días se borran Cache Storage, localStorage y el registro del SW. Hay que confirmar que la copia descargada desaparece y que la app lo dice. Como app instalada no aplica: confirmar ese caso por separado.
2. **`navigator.storage.persist()`.** Ver qué devuelve en cada modo y si `estimate()` reporta la cuota real. El código estima 600 KB por imagen.
3. **Primera visita sin red.** Probar el SW recién instalado sin red, con el modo avión activado justo después de "Guardar sin conexión". `warmAppShell` guarda la app, pero el arranque depende de que el SW controle la navegación.
4. **Ruta sin conexión.** Abrir `/prive/edicion/sin-conexion` en modo avión después de un arranque en frío y con la sesión de Supabase vencida, porque el token se refresca al volver la red. Comprobar que `SIGNED_OUT` no borra las copias de forma inesperada.
5. **PDF.** Probar `downloadPdf` con `a.download` sobre un `blob:`. En Safari normal abre la vista previa o "Descargas". Como app instalada, la descarga con `blob:` históricamente falla o abre un visor sin botón de regreso. Probar también la memoria de jsPDF con 16 piezas e imágenes, porque hay riesgo de que se cierre la pestaña.
6. **Imágenes y CORS.** Comprobar que el CDN de Pexels responde con `Access-Control-Allow-Origin` y `content-type: image/*`, porque si no `saveOfflinePack` falla con `reason: "image"`. Comprobar también que `URL.createObjectURL` funciona en el lector offline.
7. **Cerrar sesión con el SW sin controlar la página.** `postMessage` a `controller` es nulo en la primera carga; confirmar que se borran `iatos-data-v1` y `iatos-edition-v1`.
8. **Cache de viajes compartida.** `public/sw.js:116-121` guarda `/rest/v1/trips` con una llave que **no incluye al usuario**. Si se cambia de cuenta sin `SIGNED_OUT`, por ejemplo con el almacenamiento borrado a medias, la segunda cuenta vería sin red los viajes de la primera. Hay que probar el cambio de cuenta en el mismo teléfono.

**Qué depende de la aprobación editorial pendiente:**
- Todo el contenido de `20261025100200_edition_seed_n01.sql` nace en `pending_review` y con licencia `pending`.
- `edition_is_live` exige `published` o `scheduled` vencido, y `edition_images_map` exige licencia `approved`.
- Sin la aprobación del editor no hay edición visible, ni copia offline, ni PDF (las imágenes requieren `allow_offline` o `allow_pdf`), ni Flight Edition, ni "Comprobar enlaces" (`edition-link-check`, solo administradores).

**Un FREE o PRO sin Privé no lee contenido protegido:** VERIFICADO. La suite `edition` dio 47/47 (E01 y siguientes) y las tablas `edition_*` no tienen GRANT. La lista completa de RPC ejecutables por `authenticated` está revisada en §2. El único camino que se salta la contraseña Privé es el **local** (P3-4).

---

## 5. Mutaciones (en mi copia, restauradas)

| Corrección | Mutación | Prueba | Resultado |
|---|---|---|---|
| AUD-SEG-02 (`mark-visited`) | `__rl = {allowed:true}` | audSeguridadEdge | **Detectada**: 2 fallan |
| AUD-SEG-04 (`tripIdForTracking`) | `return raw` | audSeguridadEdge | **Detectada**: 1 falla |
| AUD-SEG-03 (`canWritePackingList`) | `return true` | audSeguridadEdge | **Detectada**: 1 falla |
| AUD-SEG-03 (contexto del prompt) | perfil y ADN del dueño | audSeguridadEdge | **SOBREVIVE**: 11/11 (P2-6) |
| NEW-P4 (`request_reset` sin correo) | quitar `EMAIL_UNAVAILABLE` | priveAccess | **Detectada**: 1 falla |
| AUD-SEG-01 (`journal_update`) | quitar `has_trip_access` | suite `security` | **Detectada**: FALLA SG7, SJ5, SJ6 y SJ3 |
| Bóveda: INSERT de storage exige la fila propia | quitar `EXISTS(vault_items…)` | suite `boveda` | **Detectada**: FALLA F7, X5, X8, C4 y D1 |

---

## 6. Muestra de "hallazgos nuevos" que el documento da por corregidos (22 revisados)

| ID | Arreglo en el código (archivo:línea) | Prueba que existe | ¿Mutación? | Veredicto |
|---|---|---|---|---|
| NEW-01 | `20261024020000_aud_prive_grant_revoke_invitation.sql` | `supabase/tests/prive/aud_session.sql:311` (N01d) | — (suite prive 140 OK) | VERIFICADO INDEPENDIENTEMENTE (pasa) |
| SES-LS | `src/lib/priveSession.ts:42-58` (cookie de sesión) | priveLib/priveHub | — | CORREGIDO PERO NO VERIFICADO (no hice mutación) |
| NEW-P4 | `prive-access/actions.ts:226` | `priveAccess.test.ts:342` | Sí, detectada | VERIFICADO INDEPENDIENTEMENTE |
| RES-N1 | `_shared/ai-reservations/core.ts` (`bareAddress`) | `aiReservationsSenderAuth.test.ts:64-68` | — | CORREGIDO PERO NO VERIFICADO (es del grupo reservas) |
| RES-N3 | `evidence.ts` | `aiReservationsConfirmRules.test.ts:70-80` | — | CORREGIDO PERO NO VERIFICADO |
| RES-N4 | `20261024170000` | `ai_reservations.sql:412` (R53) | — | CORREGIDO PERO NO VERIFICADO |
| RES-N8 | `20261024170000` | `ai_reservations.sql:425` (R55) | — | CORREGIDO PERO NO VERIFICADO |
| AUD-04j | `src/lib/externalLinks.ts:37-41` | `externalLinks.test.ts:45` | — | VERIFICADO (pasa) |
| BR-N1 | `booking-go/go.ts:42-43` | `bookingBridgeAudit.test.ts:236` | — | CORREGIDO PERO NO VERIFICADO |
| N-03 | `stripe-portal/index.ts:56-58` | ninguna (el documento lo admite) | — | CORREGIDO SIN PRUEBA, como dice el documento |
| N-05 | `stripe-webhook` | `stripeAtomicity.test.ts:535` | — | CORREGIDO PERO NO VERIFICADO |
| AUD-SEG-01 | `20261024010100:7-11` | `aud_seguridad.sql:134-141` | Sí, detectada | VERIFICADO INDEPENDIENTEMENTE |
| AUD-SEG-02 | `mark-visited/index.ts:111-114` (la línea coincide) | `audSeguridadEdge.test.ts:56,62` | Sí, detectada | VERIFICADO INDEPENDIENTEMENTE |
| AUD-SEG-03 | `generar-packing-list/access.ts`, `index.ts:241-257` | `audSeguridadEdge.test.ts:72-86` | Una detectada, otra sobrevive | PARCIALMENTE CUBIERTO (P2-6) |
| AUD-SEG-04 | `track-flight/rules.ts:43-55`, `index.ts:72-76` | `audSeguridadEdge.test.ts:89-98` | Sí, detectada | VERIFICADO INDEPENDIENTEMENTE |
| AUD-SEG-05 | `20261024200200`, `_shared/idempotency.ts` | `action_idempotency.sql` (15 IK), `audSegIdempotency.test.tsx` (7) | — | VERIFICADO (pasa) |
| AUD-IATO-01 | `concierge-chat/turn.ts:55` (`TURN_BUDGET_MS = 120_000`) | rendimientoIato | — | CORREGIDO PERO NO VERIFICADO |
| AUD-IATO-06 | `concierge-chat/index.ts:641` (`brake: accountBrake`) | rendimientoIato | — | CORREGIDO PERO NO VERIFICADO |
| AUD-OPS-08 | `price-watch-cron/rules.ts:74-77` | audQuotesOpsCierre | — | CORREGIDO PERO NO VERIFICADO |
| REND-N7 | reset antes de error | `rendimientoIato.test.ts:246`: expresión regular sobre el texto del código | — | PARCIALMENTE CUBIERTO (prueba por texto) |
| PK-01 | `20261024310000_privekey_plans.sql:227` | `prive_key/*.sql` D1–D3 | — | CORREGIDO PERO NO VERIFICADO |
| PV-01 | `20261024100000_privevalor_drops.sql:28-29` | P53 | — | VERIFICADO (REVOKE presente) |
| PV-02 | privevalor | `privevalor.sql:288` (V17), `375` (Z01) | — | VERIFICADO (suite 144 OK) |
| AV-06 | `_shared/avatar-prompts.ts:28-29` | `avatarFacialHair.test.ts` (3) | — | VERIFICADO (pasa) |
| MAIL-03 | plantillas de Privé | `priveEmailDeliverability.test.ts` (33) | — | VERIFICADO (pasa) |
| CAL-04 | `concurrent_rate_limit.sh:10-14` (`pg_stat_activity`) | security R4 | — | VERIFICADO (la suite pasa) |
| SEG-MEJ | `generar-packing-list/access.ts:17` (`vaultSummary`) | audSeguridadEdge | — | VERIFICADO (pasa) |

Conteo: los 22 tienen arreglo y prueba en el código, salvo N-03, que no tiene prueba y el documento lo dice. Hay 1 PARCIALMENTE CUBIERTO por mutación (AUD-SEG-03) y 1 cubierto solo por una prueba de texto (REND-N7).

---

## 7. Discrepancias entre la documentación y el código

1. **SEGURIDAD.md, Barrido 3:** dice "almacenamiento (4 buckets)" y "account_deletion_files cubre los 4 buckets". El código tiene **6 buckets**: también `travel-vault` y `avatar-private`. La cobertura de los 6 existe gracias a la regla de prefijo, pero el documento está desactualizado.
2. **SEGURIDAD.md:** dice "`journal-photos` y `travel-moments` … con nombres no adivinables (UUID)". En `travel-moments` el nombre es `${uid}/${Date.now()}-${Math.random().toString(36).slice(2,8)}` (`BestMomentsPanel.tsx:142`): **no es un UUID**.
3. **SEGURIDAD.md:** habla de 64 funciones Edge, de 180 SECURITY DEFINER, de que `authenticated` ejecuta 44, y de 89 tablas con 119 políticas. El código final tiene **66 funciones**: `avatar-evolve` y `edition-link-check` no están en la tabla del Barrido 4. Tiene **257** SECURITY DEFINER (las 257 fijan `search_path`), **90** ejecutables por `authenticated` y por 1 `anon`, y **114 tablas con 139 políticas**. El §4 del documento de cierre repite "180 de 180".
4. **SEGURIDAD.md, SR4:** habla de "pasaporte en `travel_documents`" como si fuera una tabla. No existe esa tabla: es una columna jsonb de `user_vault_benefits`, que `vault_sync_legacy` deja en `[]`.
5. **Cierre §3.5 y SEGURIDAD N1–N3:** las clasifica como "P3, decisión de producto". Con la evidencia de §2, N1 (con EXIF y fotos que no se borran), N2 (sin revocación y con avisos ilimitados) y N3 (más el pasaporte huérfano) son **P2**.
6. **F-02 (`20261022120000:16`):** dice que "Una amistad accepted se podía crear sin el consentimiento" y que quedó corregido. La RPC `agregar_amigo_por_codigo` todavía crea `accepted` sin consentimiento.
7. **Legal.tsx:103:** promete borrar el avatar y la foto desde el perfil, y esa función no existe (P2-5).
8. **Cierre §5, módulo 11 (Bóveda), "últimos 4 dígitos":** solo se impone en la columna `number`. El texto libre acepta un número completo con CVV y se proyecta a la IA (P3-3).
9. **AUD-03, "Fallaban 46 de 49 → 49/49":** el archivo `aiReservationsConfirmRules.test.ts` tiene hoy **50** pruebas (50/50). La diferencia es de conteo.
10. **FASE0_ESTADO.md:** dice "Migraciones del repo sin aplicar: 0" con 90 registradas, pero el repo en `f62466e` tenía **104** archivos (lo verifiqué con `git ls-tree`). Esas dos cifras solo cuadran si 14 archivos están aplicados sin registro o con otra versión. El cierre (§6.2) lo reconoce como "diferencia de 14". FASE0 no lo explica.
11. **El cierre llama al estado de los interruptores "último leído"**, pero no lo volvió a leer al cierre (§6.3). En el código, el interruptor de Reservas IA sí es del lado del servidor (§2) y la afirmación se sostiene.
12. **SEGURIDAD.md, Barrido 4, "Toda función con verify_jwt=true valida además al usuario":** es correcto en las dos funciones que no estaban en la tabla. `edition-link-check` usa `getAuthUser` y `edition_is_admin`, y `avatar-evolve` usa `isAuthorizedCron` o `getUser`. No es un defecto, pero la tabla está incompleta.

### Repo frente a producción (para que el líder lo cruce)
- 127 archivos de migración, **sin versiones duplicadas** (comprobado con `ls | awk -F_ '{print $1}' | sort | uniq -d`, que no devuelve nada).
- 104 tienen versión ≤ `20261023180000` (la última registrada en FASE0) y 23 son posteriores: las 23 "de hoy", con fechas del 23 al 25 de octubre.
- **Candidatas a no estar registradas** (14 = 104 − 90):
  - **6 casi seguras**: las retroactivas `restore_*`, agregadas en `ec18a35` (17-oct) y `707e9e1` (21-oct) con versiones antiguas para "reconstruir el esquema vivo desde cero": `20260429220000_restore_missing_schema_baseline`, `20260525234500_restore_ai_prefs_dna_columns`, `20260525235000_restore_missing_schema_views_indexes`, `20260526042000_restore_profiles_invite_code`, `20260824040000_restore_dna_helper_functions` y `20261018110000_restore_app_only_columns`.
  - **4 con versión inválida**: `20261022146000_sec2_members_pro_access`, `20261022146100_sec2_stripe_payment_integrity`, `20261022146200_sec2_deletion_requests` y `20261022146300_sec_concierge_requests_server_only`.
  - **Las 4 restantes** probablemente están entre las escritas a mano del 17 y 18 de octubre (`20261017050000`, `20261017101000`, `20261017170000`, `20261018090000`, `20261018120000`) si Lovable las registró con otra versión.
  - Es una hipótesis: hay que comparar contra `supabase_migrations.schema_migrations`.
- Entre las 23 nuevas, `20261024310000_privekey_plans` tiene la hora 31 (inválida).

---

## 8. Mi evaluación por módulo (20)

| # | Módulo | Mi veredicto | Razón |
|---|---|---|---|
| 1 | Auth | **NO-GO** | `mailer_autoconfirm` (N-01) es de producción y no lo puedo verificar desde el código (BLOQUEADO). Coincido con el documento |
| 2 | Iato / concierge | GO | No encontré P0, P1 ni P2 abiertos fuera de la prueba débil de AUD-SEG-03 (P2-6, solo de cobertura). La latencia en vivo no está medida |
| 3 | Cotizaciones | GO | Fuera de mi alcance profundo; no encontré evidencia en contra |
| 4 | Viajes | **NO-GO** | P2-2 (fotos del diario públicas con GPS que no se borran), P2-3 (pasaportes huérfanos e imborrables al borrar el viaje), P2-4 (pasaporte visible a todos los colaboradores) y P3-5/P3-6. La planeación del viaje sí está bien |
| 5 | Importar viajes | GO (condicionado) | `import_past_trip` es correcto (`user_id = auth.uid()`, candado, validación). Hereda P2-3 y P2-4 porque sube los boletos y pases de abordar, con nombre y PNR, a `trip-documents` |
| 6 | Avatar | **NO-GO** | El modelo no está probado en vivo, según el documento. Además P2-5: el borrado prometido no existe y el avatar está en un bucket público |
| 7 | Travel DNA | GO | PK-01 cubierto (D1–D3) |
| 8 | Social | **NO-GO** | P2-1: amistad sin consentimiento e irrevocable, que expone `is_prive`, la ciudad, el ADN y los lugares, y permite avisos ilimitados con texto del atacante |
| 9 | Gastos | GO | Lectura cruzada negada (SX); no encontré defectos |
| 10 | Members Only | GO | Fuera de mi alcance; NEW-P3 queda como decisión documentada |
| 11 | Bóveda | GO | RLS y storage resistieron (BV1–BV6) y las mutaciones se detectan. Quedan P3-1, P3-2 y P3-3 |
| 12 | Privé acceso / sesión | GO | La suite prive dio 140/140. Los riesgos de producción son los del documento |
| 13 | Privé reimaginado | GO | La prueba en Safari e iOS está BLOQUEADA aquí |
| 14 | The Privé Key | GO | Fuera de alcance; no encontré nada en contra |
| 15 | Drops / Insider / Passport | GO | privevalor dio 144/144 |
| 16 | The Private Edition | **NO-GO** | El editor no ha aprobado, el uso sin conexión no está probado en iOS (BLOQUEADO) y queda P3-4 (sin contraseña Privé y sin revocación) |
| 17 | Reservas IA | **NO-GO** | Apagada a propósito. El interruptor es real y del lado del servidor (edge + SQL); falta la prueba con un correo real |
| 18 | Booking Bridge | GO | Fuera de alcance |
| 19 | Pagos / Stripe | **NO-GO** | AUD-08 BLOQUEADO y Stripe en TEST |
| 20 | Correo | **NO-GO** | Sin MX ni DMARC con reportes (BLOQUEADO, DNS) |

**Total: 12 GO y 8 NO-GO.** Frente al documento, Viajes y Social pasan a NO-GO por P2 de privacidad que el equipo dejó como P3 "de producto".
