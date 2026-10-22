# Segunda auditoría independiente · grupo RESERVAS (AUD-02, AUD-03, AUD-06)

Material: paquete del commit `7670102a050e2db975121c968a95a5962c175b48` en `/home/user/audit2/reservas/codigo/`. El código anterior (`06865cb`) está extraído en `/home/user/audit2/reservas-old/`. Fecha: 22-oct-2026. No toqué producción, no hice push ni commits y no envié correos. La función sigue apagada en producción (`ai_reservations_enabled = false`, según los documentos del equipo; yo no la verifiqué en vivo).

## Resumen

| AUD | Defecto original | Código corregido (archivo:línea) | Test exacto | ¿Fallaba antes? | ¿Pasa ahora? | Caso nuevo intentado | Resultado | Veredicto |
|---|---|---|---|---|---|---|---|---|
| AUD-02 | Remitente falsificable: SPF y DKIM con DMARC fail aceptados; `"reservas@casa.mx"@evil.test` leído como el lugar; dos @; varios buzones; dominio padre o sufijo público; From del webhook, del correo descargado y del encabezado sin cruzar. Viejo: `core.ts:181-185` (`bareAddress` laxo), `:191` (`split("@")[1]`), `:210` (acepta el dominio padre), `:214` (`spf && dkim`) | `_shared/ai-reservations/core.ts:187-211` (`bareAddress`), `:217-221` (`domainOf`), `:252-276` (`senderAuthentication`); `service.ts:47-56` (`inboundSenderVerdict`); SQL `20261024170000_aud_reservas_evidence.sql:132-148` (`ai_res_sender_strong`) | `src/test/aiReservationsSenderAuth.test.ts` (30), `aiReservationsService.test.ts` bloque «AUD-02 … de punta a punta» (6), SQL R52 y R57 | **Sí, 12**: SenderAuth 9/30 y Service 3 fallan con el código viejo (ejecutado) | Sí: 30/30 y 22/22; SQL 57/57 | Comentarios RFC 5322, `=?utf-8?`, IDN o punycode, mayúsculas, punto final, varios From, Sender ≠ From, subdominios, valores raros en `authentication`, discrepancias entre los tres From, gmail y **proveedores gratuitos fuera de la lista** | Los casos del hallazgo están corregidos. **Nuevo P1**: con un proveedor gratuito fuera de `FREEMAIL` (live.fr, wanadoo.fr, sfr.fr, yahoo.co.uk, mac.com, infinitummail.com…), otra cuenta del mismo proveedor con DMARC pass pasa como el restaurante (TS y SQL). P3: un DMARC fuera de la lista de valores (`failed`, `permerror`…) no descarta, y el cruce con `headers.from` se omite si el formato cambia | **PARCIALMENTE CUBIERTO** |
| AUD-03 | Confirmaciones ambiguas tomadas como reserva: el código viejo confirmaba con fecha, hora y personas omitidas y aceptaba lo que dijera el modelo. Viejo: `classifier.ts:244-267` | `_shared/ai-reservations/evidence.ts:103-258` (léxico, análisis, contradicciones, `quotedRequestLinked`); `classifier.ts:267-367` (`decideReply`); `core.ts:296-301` (`splitQuotedReply`) | `src/test/aiReservationsConfirmRules.test.ts` (49+1) | **Sí, 46 de 49** fallan con el código viejo (ejecutado; los 3 que pasan son positivos) | Sí: 50/50 | «Confirmado… ¿podría confirmar la hora?», 22/10 contra 10/22 y 3/11, «mañana», personas en letra, cita de nuestro propio correo, portugués e italiano, cita inventada, HTML oculto, **negaciones y cancelaciones** | **Nuevo P2**: con el modelo mintiendo (el mismo supuesto de sus pruebas), «Su reserva aún no está confirmada.», «No hemos reservado su mesa», «Your reservation is not confirmed yet», «Sua reserva não está confirmada», «Su reserva confirmada fue cancelada» → **confirmed**, la base lo acepta y el usuario recibe «confirmó tu reserva por escrito». P2: números de más de 12 en letra y horas en palabras no se leen. P3: texto HTML oculto, fecha 3/11 ambigua | **PARCIALMENTE CUBIERTO** |
| AUD-06 | Una «confirmación» con solo texto de la IA quedaba `confirmed`; el mismo Message-ID se procesaba dos veces. Viejo: `20261023170000_ai_reservations.sql:84-92` (el CHECK solo pedía cita y `verified_sender`), `:608` (`apply_reply` sin evidencia) | Migración `20261024170000_aud_reservas_evidence.sql:63-65` (índice único del hash), `:68-86` (sello del inbound), `:110-120` (solo agregar, **solo UPDATE**), `:157-234` (reglas y trigger `ai_reservations_guard_evidence`), `:240-289` (`attach`), `:302-366` (`apply_reply`); `service.ts:367-394`, `:451-462`; `runtime.ts:62-70` | SQL `supabase/tests/ai_reservations/ai_reservations.sql` R44–R57; `aiReservationsService.test.ts` bloque «AUD-06» (4) | **Sí**: SQL 44 OK, FALLA R45–R52 y R56, y R44/R53/R55/R57 con error; Vitest AUD-06 4/4 fallan (ejecutado) | Sí: SQL 57/57; Vitest 4/4 | Otro Message-ID, `< >` y mayúsculas, DELETE y TRUNCATE con `service_role`, `aires.actor`, reutilizar un inbound, ¿quién llama `apply_reply`? | Deduplicación por Message-ID y trigger verificados (sus mutaciones fallan). **P3**: `DELETE`/`TRUNCATE` de eventos, decisiones e inbound sellado permitidos a `service_role`; `service_role` reescribe una reserva ya confirmada (código, cita, hora) o confirma por el canal `equipo` con `set_config('aires.actor',…)`; `<m@x>` y `m@x` no se tratan como el mismo; un inbound sirve para dos decisiones. `apply_reply`: solo `service_role` (anon y authenticated → 42501) | **PARCIALMENTE CUBIERTO** |

Números exactos:

- **Vitest de reservas** (8 archivos originales): **161/161** pasan. Con mis 2 archivos nuevos son 10 archivos y **201/201**: mis 40 pruebas pasan porque **documentan el comportamiento defectuoso**.
- **Suite SQL `ai_reservations`**: **57 OK, 0 FALLA** (base `a2reservas_base`).
- **Código viejo con las pruebas nuevas**: SenderAuth 9/30 fallan, ConfirmRules 46/49 fallan, Service 7/22 fallan (3 de AUD-02 y 4 de AUD-06). La suite SQL da 44 OK y el resto FALLA o ERROR.
- **`deno check`**: `reservations-inbound`, `ai-reservations` y `ai-reservations-cron` salen con exit 0. Después restauré `deno.lock` desde `base/`.

Defectos nuevos: **1 P1**, **3 P2** (más 2 riesgos P2 de diseño) y **7 P3**. Ninguno es P0. La función sigue apagada en producción, así que todos aplican al encenderla.

---

## Defectos nuevos

### A2-RES-01 · P1 · Un proveedor gratuito fuera de la lista `FREEMAIL` permite suplantar al restaurante
- **Entrada:** el correo del lugar es `restaurante@live.fr`, descubierto en su sitio web; `contact.ts` acepta cualquier dominio. El atacante abre `atacante@live.fr` y responde en el hilo o por folio. Resend calcula `dmarc: pass` legítimamente para la cuenta del atacante. Resultado: `senderAuthentication` → `verified: true, basis: "dmarc_aligned"`.
- **Vulnerable:**
  - `core.ts:212-216`: la lista es de exclusión y tiene 26 dominios. Faltan, entre otros, `live.fr`, `wanadoo.fr`, `sfr.fr`, `yahoo.co.uk`, `hotmail.it`, `mac.com`, `ymail.com`, `gmx.net`, `web.de`, `mail.com`, `zoho.com`, `yandex.ru`, `outlook.com.mx`, `hotmail.com.mx`, `yahoo.com.ar`, `infinitummail.com` (Telmex), `terra.com.br`, `uol.com.br` y `libero.it`.
  - `core.ts:272-273`: la vía (a) acepta **cualquier buzón** del dominio con DMARC pass.
  - La regla es la misma en SQL: migración `:124-129` y `:146-147`.
- **Prueba:**
  - `/home/user/audit2/reservas/codigo/src/test/aiReservationsAudit2.test.ts`, «DEFECTO P1: correo gratuito FUERA de la lista FREEMAIL», 19 dominios → `verified=true`.
  - SQL `/home/user/audit2/reservas/codigo/supabase/tests/ai_reservations_a2/a2_adversarial.sql` A8a y A8b → `ai_res_sender_strong('atacante@live.fr','resto@live.fr',pass) = true`, y lo mismo con wanadoo.fr.
- **Impacto:** este remitente es «fuerte». Con él, una confirmación falsa queda `confirmed` en la base, sin que intervenga Claude, si el atacante escribe «Confirmamos su reserva para 4 personas el 3 de noviembre a las 20:30». El usuario recibe además el correo «confirmó tu reserva por escrito».
- **Corrección propuesta:** con DMARC, aceptar un buzón distinto solo si el dominio es del lugar. Es decir, el dominio registrable del correo coincide con el del `venue_website`, y no basta con estar o no en una lista. En cualquier otro caso, exigir la dirección exacta.
```diff
--- a/supabase/functions/_shared/ai-reservations/core.ts
-export function senderAuthentication(fromHeader: unknown, venueEmail: string | null | undefined, auth: AuthResults): SenderVerdict {
+export function senderAuthentication(fromHeader: unknown, venueEmail: string | null | undefined, auth: AuthResults,
+  opts: { venueOwnsDomain?: boolean } = {}): SenderVerdict {
@@
-  if (!(fd === vd || fd.endsWith(`.${vd}`))) return out(null, ["domain_mismatch"]);
-  if (res.dmarc === "pass") return out("dmarc_aligned", []);
+  if (!(fd === vd || (opts.venueOwnsDomain === true && fd.endsWith(`.${vd}`)))) return out(null, ["domain_mismatch"]);
+  // Otro buzón del dominio solo si el dominio es del lugar (= dominio de su sitio web); si no, dirección exacta.
+  if (res.dmarc === "pass" && (exact || opts.venueOwnsDomain === true)) return out("dmarc_aligned", []);
```
El servicio debe pasar `venueOwnsDomain = registrable(host(venue_website)) === registrable(vd)`, y la base debe guardar ese dato en la fila para que `ai_res_sender_strong` aplique la misma regla. Lo mínimo inmediato es exigir `f = v` también en la vía DMARC.

### A2-RES-02 · P2 · El léxico determinista no detecta negaciones ni cancelaciones; la base y el correo al usuario las aceptan
- **Entrada:**
  - Respuesta en nuestro hilo (con token) que cita nuestra solicitud sin cambios.
  - Texto del restaurante: `Su reserva aún no está confirmada.`. Variantes: `No hemos reservado su mesa todavía.`, `No le hemos apartado la mesa.`, `Su reserva confirmada fue cancelada.`, `Your reservation is not confirmed yet.`, `We have not confirmed your booking.`, `Your confirmed booking has been cancelled.`, `Sua reserva não está confirmada.`, `Não confirmamos a reserva.`.
  - El modelo responde `outcome: confirmed`, `booking_held: true`, sin datos «afirmados». Es el mismo supuesto de «modelo que miente» que usan las pruebas de AUD-03.
- **Vulnerable:**
  - `evidence.ts:103-114`: `CONFIRM_RE` encuentra `confirmad[oa]`, `hemos reservado`, `confirmed`, `esta confirmad…`.
  - `evidence.ts:122`: la regla `negation` solo cubre `no (tenemos|hay|podemos|…)`, `not available`, etc. No incluye `no está confirmad`, `no hemos`, `not confirmed`, `have not`, `não`, ni cancelaciones.
  - `classifier.ts:297`: la frase de confirmación se busca solo en la cita.
  - `classifier.ts:277`: la cita puede ser una subcadena; el modelo cita «está confirmada» de «no está confirmada».
  - La base no evalúa el sentido de la cita: migración `:174-175` solo pide que la cita esté en el texto.
- **Prueba:**
  - `aiReservationsAudit2.test.ts`, bloque «DEFECTO P2: negaciones…»: 9 frases → `confirmed`, más la subcadena.
  - De punta a punta, con el arnés del servicio (base de datos falsa): `/home/user/audit2/reservas/codigo/src/test/aiReservationsAudit2Service.test.ts` → `status: confirmed`, y el correo al usuario dice «Reserva confirmada por Casa Oaxaca» y «confirmó tu reserva por escrito», citando «Su reserva aún no está confirmada.».
  - SQL real: `a2_adversarial.sql` A6 → `apply_reply` con esa cita y condiciones `thread_quote` → **OK, status=confirmed**.
- **Corrección propuesta:**
```diff
--- a/supabase/functions/_shared/ai-reservations/evidence.ts
-  ["negation", /\bno (?:tenemos|hay|podemos|...
+  ["negation", /\b(?:no|nao|not|never|ya no|aun no|todavia no|(?:have|has|is|are|was|were)(?:n't| not)|ne\s+\w+\s+pas)\b(?:\W+\w+){0,3}?\W+(?:confirm|reserv|apart|book|agend|registr)\w*|\bno (?:tenemos|hay|podemos|...
+  ],
+  ["cancel", /\b(cancelad[oa]s?|cancelamos|cancel(?:l)?ed|cancelling|annulee?s?|annulons|cancelad[ao]|anulad[oa])\b/],
```
Además, en `decideReply`, la cita que confirma debe ser una oración completa del texto (no una subcadena), y si `a.hedges` incluye `cancel`, el resultado debe ser `ambiguous` o `declined`. La base debería guardar `rules_version` y rechazar las versiones anteriores a la corrección.

### A2-RES-03 · P2 · Personas y horas en palabras no se leen; en nuestro hilo, la cita de la solicitud «rellena» lo que el restaurante cambió
- **Entrada:** en nuestro hilo, y con el modelo omitiendo `stated_*`:
  - `Confirmado, mesa para quince personas.` (se pidieron 4);
  - `Confirmado, los esperamos a las nueve.` (se pidieron las 20:30);
  - `Confirmado para las 9.`.
  
  Los tres quedan `confirmed` para 4 personas a las 20:30.
- **Vulnerable:**
  - `evidence.ts:22-26`: los números en letra llegan solo hasta 12.
  - `evidence.ts:41-50`: «a las 9» sin am/pm o «de la noche», o «a las nueve», no cuenta como hora.
  - `classifier.ts:257-259`: `thread_quote` cubre fecha, hora y personas si no hay contradicción detectada.
- **Prueba:** `aiReservationsAudit2.test.ts`, «DEFECTO P2: personas en letra > 12…».
- **Corrección propuesta:** extender `NUM_WORDS` hasta 20 (y «veinte»). Tratar `a las N` / `at N` / `à N` como una mención de hora; si no coincide con la solicitada, es contradicción. Y cuando la base es `thread_quote`, exigir que el texto del restaurante no tenga números ni palabras numéricas sin explicar.

### Riesgos de diseño P2 (la regla declarada es así, pero la documentación la presenta como más fuerte)
- **A2-RES-04 · P2 · «SPF solo nunca basta» no es exacto.** DMARC `pass` puede salir solo de SPF alineado, y la vía (a) lo acepta para **cualquier buzón y cualquier subdominio**. Ejemplos: `{spf:pass, dkim:fail, dmarc:pass}` con `otro@casaoaxaca.com.mx` → verificado (TS y SQL A8d); `cualquiera@tienda.casaoaxaca.com.mx` → verificado. En un hosting compartido con un SPF permisivo (`include:` del proveedor), un tercero del mismo servidor pasa DMARC por SPF. La corrección de A2-RES-01 (dirección exacta o dominio del lugar, sin subdominios arbitrarios) también reduce este riesgo.
- **A2-RES-05 · P2 · La vía (b) (dirección exacta + DKIM `pass` sin DMARC fail) depende de una semántica de Resend que nadie ha comprobado.** Esa semántica es: `dkim: pass` solo si el firmante coincide con el From, y `dmarc: gray` con `p=none`. gmail.com publica `p=none`. Si Resend reporta `dkim: pass` para una firma válida de otro dominio, cualquiera suplantaría `resto@gmail.com` con DMARC `gray`. El equipo lo marca como PENDIENTE; queda **BLOQUEADO** para mí, porque comprobarlo exige correos reales y está prohibido.

### P3
1. **A2-RES-06 · Valores de DMARC fuera de la lista no descartan.** `{dkim:pass, dmarc:"failed"|"permerror"|"temperror"|"reject"|"quarantine"|"none"|["fail"]}` con la dirección exacta → verificado. Lugar: `core.ts:225-229` y `:262`; SQL `:140-141`. Pruebas: `aiReservationsAudit2.test.ts` «DEFECTO P3: un DMARC fuera del enum…» y SQL A8c. Corrección: tratarlos como falla cerrada.
   ```diff
   -  if (res.dmarc === "fail" || res.dmarc === "processing_failed") return out(null, [`dmarc_${res.dmarc}`]);
   +  if (res.dmarc !== "pass" && res.dmarc !== "gray") return out(null, [`dmarc_${res.dmarc}`]);
   ```
   En SQL: `IF dmarc NOT IN ('pass','gray') THEN RETURN false; END IF;`.
2. **A2-RES-07 · El cruce con el From crudo se omite en silencio.** Ocurre si `headers` llega como lista `[{name,value}]` o con la clave `FROM` (`service.ts:50-53`). Prueba: «DEFECTO P3: si headers viene como lista…». Corrección: leer las claves sin distinguir mayúsculas, aceptar la forma de lista, exigir exactamente un From y, si `headers` existe pero no se puede leer, marcar `header_from_unreadable` y no verificar.
3. **A2-RES-08 · HTML sin parte de texto: el texto oculto (`display:none`) cuenta como escrito.** `htmlToText` (`core.ts:309-321`) no quita lo oculto. Un HTML cuyo texto visible es «Gracias, en breve le escribimos.» queda `confirmed` por la frase oculta. Prueba: «DEFECTO P3: HTML … display:none». Corrección: si no hay `text`, no confirmar (`ambiguous`), o quitar los elementos con `display:none`, `visibility:hidden`, `font-size:0` o `max-height:0`.
4. **A2-RES-09 · Fechas dd/mm y mm/dd ambiguas se resuelven a favor de la confirmación.** «Confirmed … on 3/11» (11 de marzo en EE. UU.) se toma como 3 de noviembre (`evidence.ts:174-177`). Prueba: caso «otra fecha en otro formato». Corrección: si la fecha es ambigua (los dos candidatos son válidos y distintos), no darla por escrita.
5. **A2-RES-10 · El sello de «solo agregar» no cubre DELETE ni TRUNCATE.** Como `service_role`, DELETE de `ai_reservation_events`, DELETE y TRUNCATE de `ai_reservation_decisions`, y DELETE de un `ai_reservation_inbound` sellado devuelven **OK**. Queda una reserva `confirmed` con 0 decisiones (A3a-c, A4a-c). Además, `status`, `outcome` y `duplicate_of` del inbound sellado se pueden reescribir. Lugar: migración `:85-86` y `:116-120` (solo `BEFORE UPDATE`). Corrección:
   ```sql
   REVOKE UPDATE, DELETE, TRUNCATE ON public.ai_reservation_events, public.ai_reservation_decisions FROM service_role;
   REVOKE DELETE, TRUNCATE ON public.ai_reservation_inbound FROM service_role;  -- el ON DELETE CASCADE corre como dueño
   -- y añadir status/outcome/duplicate_of al guard cuando OLD.status IN ('done','duplicate','late')
   ```
6. **A2-RES-11 · `service_role` salta el guard de `ai_reservations`.** Le basta `set_config('aires.actor', …)`, porque el valor lo puede fijar cualquier sesión. Así reescribe una reserva **ya confirmada** (código `FALSO-1`, cita «Confirmamos todo», hora 23:45; A7) o la pasa a `confirmed` por el canal `equipo` con evidencia de texto libre, sin funciones ni correo (A7b). Esto contradice `IATOS_RESERVAS_IA.md:81` y el encabezado de `20261023170000_ai_reservations.sql:11-13`. Corrección: `REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.ai_reservations FROM service_role;` (todo pasa por RPC SECURITY DEFINER), o en el guard `IF current_user = 'service_role' THEN RAISE …`. Y, una vez en `confirmed`, congelar `confirmation`, `confirmation_code`, `requested_local` y `party_size`.
7. **A2-RES-12 · Message-ID con y sin `< >` y reutilización del inbound.**
   - `lower(btrim())` no quita los `< >` (migración `:243`): `<a1@casa71.mx>` y `a1@casa71.mx` → `duplicate=false` (A1b). Las mayúsculas y los espacios sí se normalizan (A1a).
   - El mismo cuerpo con otro Message-ID se procesa otra vez (A2), porque `body_sha256` no es único.
   - `apply_reply` acepta un segundo resultado para el mismo inbound: primero `ambiguous` y luego `confirmed` → `confirmed`, con 2 decisiones (A9).
   
   Corrección: `v_mid := lower(btrim(_e->>'message_id', ' <>'))`. En `apply_reply`, `IF i.status <> 'processing' OR EXISTS(SELECT 1 FROM ai_reservation_decisions WHERE inbound_id=_inbound_id) THEN RAISE …`.
8. **A2-RES-13 · El correo «revísalo tú» de un remitente NO verificado reenvía los enlaces del atacante.** `redactExcerpt` (`core.ts:328-337`) quita correos, teléfonos y tarjetas, pero no URLs. El extracto «pague aquí: https://pago-casaoaxaca.evil.test/…» llega desde el dominio de IATOS. Prueba: «DEFECTO P3: el extracto conserva enlaces». Corrección: con `unverified`, no incluir el extracto o quitar las URLs (`/https?:\/\/\S+/g → "[enlace]"`).

Falsos negativos, que no son vulnerabilidades:
- Comentario RFC 5322 después de la dirección: `reservas@casa.mx (Casa)`.
- Correo del lugar en IDN Unicode: nunca verificable.
- Punto final en el dominio.
- `casa.oaxaca@gmail.com` frente a `casaoaxaca@gmail.com`.
- Respuestas escritas debajo de la cita.

---

## ¿Los correos al usuario pueden decir «confirmado» sin evidencia?

- `userConfirmedEmail` solo sale cuando `decision.outcome === "confirmed"` **y** la base aceptó la transición (`service.ts:496-508`). La base recalcula el remitente, la cita, las condiciones y la decisión registrada. Contra el escenario original (cita y `verified_sender` escritos por la IA), la base rechaza (R45), y la mutación que quita el trigger lo demuestra (S5: 8 FALLA).
- **Sí, en dos casos**:
  - (1) Con A2-RES-02, el correo «Casa Oaxaca confirmó tu reserva por escrito» sale citando «Su reserva aún no está confirmada.»: la base acepta la cita porque solo comprueba que esté en el texto (prueba de punta a punta y SQL A6).
  - (2) Con A2-RES-01, un atacante con una cuenta del mismo proveedor gratuito no listado produce una confirmación con todas las comprobaciones verdes.
- Recomendación de defensa en profundidad: en `handleInbound`, enviar la confirmación solo si `after.status === "confirmed"`, no según `decision.outcome`.

---

## Mutaciones (obligatorias), en mi copia y restauradas

Verifiqué la restauración con `cmp` contra `base/`.

| # | Mutación | Dónde | Pruebas que fallan | ¿Protege? |
|---|---|---|---|---|
| M1 | Aceptar SPF solo (`spf === "pass"` con el dominio del lugar → verificado) | `core.ts` tras `:265` | 5 (SenderAuth 3, Core 2) | Sí |
| S1 | Aceptar SPF solo en SQL | migración `:147` | R56, R57 | Sí |
| M2 | Ignorar DMARC fail | `core.ts:262` | 3 (SenderAuth 2, Service 1) | Sí |
| S2 | Ignorar DMARC fail en SQL | migración `:141` | R52, R57 | Sí |
| M3 | Quitar el chequeo de cita textual (`quotes = cls.evidence_quotes`) | `classifier.ts:277` | **1** (`aiReservationsClassifier.test.ts` «model_invents_quote») | Sí, pero **frágil** (ver abajo) |
| S3 | Quitar `quote_not_in_original` | migración `:174-175` | R46 (más R47–R50 y R52 en cascada) | Sí |
| M4 | Quitar la dedupe en el servicio | `service.ts:461` | 1 (Service «el mismo Message-ID…») | Sí (contra la base falsa) |
| S4 | Quitar la dedupe en SQL (índice no único y sin detección) | migración `:64`, `:264-266` | R53 | Sí |
| S5 | Quitar el trigger `ai_reservations_guard_evidence` | migración `:232-234` | 8: R44, R45, R46–R50, R52 | Sí |

## Pruebas insuficientes o engañosas

1. **`aiReservationsConfirmRules.test.ts:99-102`** («el modelo agrega una cita que no está en el correo») **sigue pasando con M3**. Falla por otra razón (`stated_date_unsupported`), no por la cita. Solo protege el fixture grabado `model_invents_quote`.
2. **R55** prueba únicamente UPDATE; no prueba DELETE ni TRUNCATE (A2-RES-10). **R53** normaliza mayúsculas y espacios, pero no los `< >` (A2-RES-12).
3. **R57 y `aiReservationsSenderAuth.test.ts`** no prueban ningún proveedor gratuito fuera de la lista (A2-RES-01), ni valores de DMARC fuera de la lista de valores (A2-RES-06).
4. **`aiReservationsService.test.ts` (AUD-02 y AUD-06 de punta a punta)** corre sobre una base de datos falsa (`fakeDb`) que **imita** a `attach` y `apply_reply`; su `apply_reply` solo mira `verified_sender && quote`. La regla real del trigger solo se ejerce en SQL. El comentario del archivo lo admite.
5. **ConfirmRules** no tiene ningún caso de negación de la frase de confirmación («no está confirmada», «not confirmed») ni de cancelación (A2-RES-02).

## Discrepancias entre la documentación y el código

- `IATOS_RESERVAS_IA.md:56`, `RESERVAS.md` y el encabezado de `aiReservationsSenderAuth.test.ts` dicen «SPF solo nunca basta». En el código, DMARC pass obtenido solo por SPF alineado se acepta para cualquier buzón y subdominio (A2-RES-04).
- `IATOS_RESERVAS_IA.md:81` y `20261023170000_ai_reservations.sql:12-13` dicen que «un trigger rechaza escrituras directas incluso con la llave de servicio». **Refutado**: con `set_config('aires.actor',…)`, `service_role` escribe directamente (A7, A7b).
- `RESERVAS.md` («Sellado … no se reescribe ni con service_role») y RES-N8 («solo-agregar») no son ciertos para DELETE ni TRUNCATE (A3, A4).
- `RESERVAS.md` dice que «el modelo no decide». En el código, `decideReply` solo confirma si el modelo dice `confirmed` y luego aplica vetos; los vetos no cubren las negaciones (A2-RES-02).
- `RESERVAS.md` («SQL 57/57», «161/161», «12 fallan», «46 de 49») y el cierre (AUD-06 «4 fallan → 4/4»): **los reproduje y coinciden**.

## Comandos ejecutados (salidas resumidas)

```
# Código viejo
mkdir -p /home/user/audit2/reservas-old && git -C /home/user/wanderly-ai-concierge archive 06865cb | tar -x -C /home/user/audit2/reservas-old
ln -sfn /home/user/wanderly-ai-concierge/node_modules /home/user/audit2/reservas-old/node_modules

# Vitest, código nuevo
cd /home/user/audit2/reservas/codigo && npx vitest run src/test/aiReservations --testTimeout=60000
  → 8 archivos, 161/161 (con mis 2 archivos nuevos: 10 archivos, 201/201)

# Pruebas nuevas contra el código viejo (copiadas a reservas-old/src/test)
npx vitest run src/test/aiReservationsSenderAuth.test.ts        → 9 failed | 21 passed (30)
npx vitest run src/test/aiReservationsConfirmRules.old.test.ts  → 46 failed | 3 passed (49)  (sin el bloque «Mejora», que importa evidence.ts)
npx vitest run src/test/aiReservationsService.new.test.ts       → 7 failed | 15 passed (22)

# SQL
su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash supabase/tests/ai_reservations/run.sh a2reservas_base"  → 57 OK, 0 FALLA
(suite nueva sobre el esquema viejo) run.sh a2reservas_old → 44 OK; FALLA R45–R52, R56; ERROR attach/sender_strong inexistentes
(mutaciones S1..S5) a2reservas_s1..s5 → S1: FALLA R56,R57 · S2: R52,R57 · S3: R46(+5) · S4: R53 · S5: 8 FALLA
(adversarial) bash supabase/tests/ai_reservations_a2/run.sh a2reservas_adv → A1a dup=true; A1b dup=false; A2 dup=false;
   A3a/A3b/A3c OK; A6 OK status=confirmed; A4a/A4b OK; A4c decisiones=0 status=confirmed; A7 OK → T23:45 FALSO-1;
   A7b OK/OK; A5 apply_reply/attach/transition: anon=false authenticated=false service_role=true; A5b 42501;
   A8a-d true; A9 venue_replied → confirmed, decisiones=2

# Deno
deno check --quiet supabase/functions/{reservations-inbound,ai-reservations,ai-reservations-cron}/index.ts → exit 0 ×3 (deno.lock restaurado desde base/)

# Limpieza
DROP DATABASE a2reservas_{base,old,s1,s2,s3,s4,s5,adv} → hecho
```

Archivos nuevos en mi copia:
- `/home/user/audit2/reservas/codigo/src/test/aiReservationsAudit2.test.ts` (37 pruebas)
- `/home/user/audit2/reservas/codigo/src/test/aiReservationsAudit2Service.test.ts` (3, de punta a punta con la base falsa)
- `/home/user/audit2/reservas/codigo/supabase/tests/ai_reservations_a2/{run.sh,a2_adversarial.sql}`

En el código viejo dejé las copias de las pruebas: `/home/user/audit2/reservas-old/src/test/aiReservationsSenderAuth.test.ts`, `aiReservationsConfirmRules.old.test.ts`, `aiReservationsService.new.test.ts` y `supabase/tests/ai_reservations/ai_reservations.sql` reemplazado por la versión nueva.

**BLOQUEADO:** la forma real de `authentication`, `headers` y `message_id` de Resend Receiving, y la semántica de DKIM `pass` / DMARC `gray` (A2-RES-05). Comprobarlas exige correos reales, y está prohibido.
