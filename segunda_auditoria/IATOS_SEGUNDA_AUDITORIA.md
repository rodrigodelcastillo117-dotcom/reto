# IATOS AI: segunda auditoría independiente y adversarial (AUD-01 a AUD-08)

**Material auditado:** `iatos_auditoria_cierre_2026-10-22_ligero.zip`, SHA-256 `f105f31e…a0de5c9` (verificado), commit `7670102a050e2db975121c968a95a5962c175b48`. La base productiva declarada es `591a71a`.
**Fecha:** 22-oct-2026. **Producción:** sin cambios. Solo lecturas para comparar el repositorio con la base viva.

## Independencia: cómo se hizo
Quien escribe este informe coordinó el trabajo que se audita, así que no es independiente. Para que la verificación no dependa de sus conclusiones:
- Seis revisores nuevos (qa, prive, reservas, bridge, pagos, transversal) recibieron **solo el ZIP, el código y las reglas del prompt del dueño**, sin el veredicto del coordinador.
- Cada uno trabajó en su propia copia del ZIP. Extrajo el código anterior (`06865cb`) para comprobar que cada prueba fallaba antes y pasa después.
- En cada AUD, cada uno **quitó la corrección (mutación) para comprobar que alguna prueba falla** y escribió casos adversariales nuevos.
- El coordinador comparó el repositorio con producción en modo solo lectura (`INFORME_produccion.md`).

Los informes completos, con comandos, salidas y pruebas nuevas, están en esta carpeta: `INFORME_qa.md`, `INFORME_prive.md`, `INFORME_reservas.md`, `INFORME_bridge.md`, `INFORME_pagos.md`, `INFORME_transversal.md` e `INFORME_produccion.md`.

---

## 1. Reejecución de pruebas: números obtenidos

| Qué | Reclamado | Obtenido | Veredicto |
|---|---|---|---|
| tsc (app) | OK | 0 errores (también tsconfig.node: 0) | VERIFICADO |
| Vitest | 204 archivos, 2258/2258 | **Sin `.env`** (no viene en el ZIP): 198 de 204 archivos, 2113/2113 y **145 pruebas sin cargar**. **Con un `.env` falso:** 204/204 y 2258/2258. En ambos casos, **7 errores no manejados y exit 1** | PARCIAL: el número se reproduce, el "verde" no |
| Build | OK | Sin `.env` falla (`%VITE_SUPABASE_URL%`); con `.env` falso, OK | VERIFICADO con condición |
| deno check | 66/66 | 66/66 | VERIFICADO |
| 16 suites SQL | 0 FALLA | Los 16 conteos coinciden exactamente | VERIFICADO, **con reservas de método** (P2-QA-1 y P2-QA-2) |

**Defectos de método:**
- **P2-QA-1.** `prive/run.sh` reaplica migraciones viejas, así que la suite prueba versiones anteriores de `prive_save_progress` y de `prive_record_paid_period`/`prive_mark_paid_period`. Lo confirmaron por md5 tres auditores distintos. Mutación de prueba: rompiendo `20261024310000:280`, la suite sigue en 140/0.
- **P2-QA-2.** El conteo `grep OK/FALLA` no ve todas las fallas:
  - en `payments`, una aserción fallida sale como `ERROR`;
  - `ops` nunca imprime FALLA (con la mutación aplicada, rc=0);
  - las migraciones rotas imprimen "FALLÓ".
- **P3.** Las pruebas no son herméticas: `priveHub.test.tsx` hace 30 peticiones HTTP reales a `VITE_SUPABASE_URL` (con el `.env` real, eso es la API de producción) y hay 5 más a APIs públicas. Además, `node_modules` no corresponde a `package-lock.json`.

---

## 2. Matriz AUD-01 a AUD-08

| AUD | Defecto original | Código corregido (archivo:línea) | Test exacto | ¿Fallaba antes? | ¿Pasa ahora? | Caso nuevo intentado | Resultado | Veredicto |
|---|---|---|---|---|---|---|---|---|
| **AUD-01** Sesiones Privé | Sesión aceptada si `auth.sessions` es ilegible o falta (`20261023090100:159,163-164`); cuenta suspendida o borrada; sesión sin ligar (`:214`); unlock sin sesión de Auth | `20261024010000_aud_prive_session_fail_closed.sql:21-40, 27-32, 124-127, 164-165`; `20261024030000:74, 95-98`; `prive-access/actions.ts:98,100` | `supabase/tests/prive/aud_session.sql` (S04–S12, N01–N05), `aud_seg_strength.sql` PS1/PS1b/PS2, `priveAccess.test.ts` "AUD-01" | **Sí**: 29 OK / 23 FALLA con el código viejo; Edge 7 fallan | Sí: 48/48; 38/38; suite 140/0 | Token robado usado desde otra sesión del mismo usuario (C1); sesión refrescada (C2); `session_id` en mayúsculas; carreras con "cerrar todas"; barrido con columna faltante; NFC y espacios en la contraseña; fuerza bruta en paralelo | 14 de 17 mutaciones detectadas. Las 3 que sobreviven están en "recordar 30 días" (M8 y M9 explotables solo junto con otro defecto). P3-3: dos carreras. P3-4: el barrido cierra en masa si falta una columna | **VERIFICADO INDEPENDIENTEMENTE** (núcleo). "Recordar 30 días": PARCIALMENTE CUBIERTO |
| **AUD-02** Remitentes falsificados | SPF y DKIM con DMARC fail aceptados; `"x@casa.mx"@evil`, dos @, dominio padre (`core.ts:181-214` viejo) | `_shared/ai-reservations/core.ts:187-211, 217-221, 252-276`; `service.ts:47-56`; SQL `20261024170000:132-148` | `aiReservationsSenderAuth.test.ts` (30), `aiReservationsService.test.ts` AUD-02 (6), SQL R52/R57 | **Sí**: 9/30 y 3 fallan con el código viejo | Sí: 30/30, 22/22, SQL 57/57 | Comentarios RFC 5322, encoded-words, IDN, varios From, Sender≠From, **correo gratuito no listado** (live.fr, wanadoo.fr, yahoo.co.uk, mac.com…) | **P1:** otra cuenta del mismo proveedor gratuito no listado pasa como el restaurante (`core.ts:212-216, 272-273`; SQL `ai_res_sender_strong`) | **PARCIALMENTE CUBIERTO** (P1 abierto; la función está apagada en producción) |
| **AUD-03** Confirmaciones ambiguas | Fecha, hora y personas omitidas aceptadas; el modelo decidía (`classifier.ts:244-267` viejo) | `evidence.ts:103-258`; `classifier.ts:267-367`; `core.ts:296-301` | `aiReservationsConfirmRules.test.ts` (50) | **Sí**: 46/49 fallan con el código viejo | Sí: 50/50 | Negaciones ("aún no está confirmada", "not confirmed yet"), cancelación de una confirmada, números y horas en letra, 3/11, HTML oculto, cita inventada | **P2:** con el modelo mintiendo, las negaciones y cancelaciones quedan `confirmed` y la base lo acepta (A6). La prueba de "cita inventada" sobrevive sin la corrección | **PARCIALMENTE CUBIERTO** |
| **AUD-04** Booking Bridge | booking-go redirigía a cualquier destino de confianza; IA y cliente colaban `google.com/aclk` firmado | `redirectToken.ts:32,35-37,44,69`; `booking-go/go.ts:109-110`; `allowlist.ts:27,258,272-276`; `resolver.ts:125-144`; `handler.ts:195-200,316-333`; migración `20261024070000:11-31` | `bookingBridgeAudit.test.ts`, `bookingBridgeE2E.test.ts` (4 nuevas), SQL `bridge` AUD04-6 | **Sí**: 17 de 21 y 4 E2E fallan con el código viejo; SQL 41/1 sin la migración | Sí: 136/136; SQL 42/0 | **Colaborador del viaje** pone `aclk` en `restaurantes_json` con `fuente: google_places`; reúso del token; robots.txt del cron | **P2 (A2-01):** se muestra como "Sitio oficial", booking-go lo firma y responde 302 a `aclk→evil`. P3: token reutilizable 30 min; robots.txt sigue redirecciones sin revisarlas | **PARCIALMENTE CUBIERTO** (token: VERIFICADO; origen colaborador: FALLA) |
| **AUD-05** Stripe atómico | Reembolso o disputa antes del periodo; carrera reembolso vs `invoice.paid`; disputa tardía; aviso fallido marcado como hecho; 2ª suscripción silenciosa | `20261024051500_aud_pagos_payment_event_atomic.sql:20-23, 56, 125, 142-156, 168-209, 196-202`; `stripe-webhook/payments.ts:241-243, 271-280`; `handler.ts:143-167` | SQL `payments/stripe_events.sql` AP01–AP21, `run.sh` CC1–CC4; `stripeAtomicity.test.ts` | **Sí**: AP08–AP11, AP15, CC3 y CC4 fallan con el código viejo; AP13, AP14 y AP16 dan ERROR | Sí: 88/0; 199/199 | Precio USD $1; fila sin fin; `past_due`/`paused`; reembolso parcial; doble suscripción que luego termina; factura no localizable; sin administradores | Mutaciones M1, M2 y M4 detectadas. **CC3 no es determinista** (con pausa 0 s, 2 de 10 falsos OK). `stripeAtomicity` es un mock que no detecta M1, M2b ni M4. P3: USD $1 da PRO y suma antigüedad Privé; doble suscripción deja sin PRO; error HTTP de factura → 200 sin revocar | **VERIFICADO INDEPENDIENTEMENTE** (05.4–05.6 e idempotencia); 05.7, 05.8 y 05.10 **PARCIALMENTE CUBIERTOS** |
| **AUD-06** Evidencia de reservas | Una confirmación solo con texto de IA; el mismo Message-ID procesado dos veces (`20261023170000:84-92, 608` viejo) | `20261024170000:63-65, 68-86, 110-120, 157-234, 240-366`; `service.ts:367-394, 451-462`; `runtime.ts:62-70` | SQL `ai_reservations` R44–R57; `aiReservationsService.test.ts` AUD-06 (4) | **Sí**: R45–R52 y R56 FALLA; R44/R53/R55/R57 con ERROR; 4/4 fallan con el código viejo | Sí: 57/57; 4/4 | Message-ID con y sin `< >`; mismo cuerpo con otro ID; DELETE/TRUNCATE por `service_role`; `set_config('aires.actor')` | "Solo agregar" protege UPDATE, **no DELETE ni TRUNCATE**. El guard se salta con `set_config`. Un inbound sirve para dos decisiones (P3). Lo documentado en `IATOS_RESERVAS_IA.md:81` es falso | **PARCIALMENTE CUBIERTO** |
| **AUD-07** Dominios y phishing | "Últimas 2 etiquetas" (`allowlist.ts:106-112` viejo); detector por subcadena | `_shared/booking/psl.ts:29-66`; `psl_data.ts` (fijada); `allowlist.ts:196-242` | Bloque AUD-07 de `bookingBridgeAudit.test.ts` (9) | **Sí**: 8/9 fallan con el código viejo | Sí | 15 familias (IDN, punycode, credenciales, IP octal/hex, `%2e`, backslash, github.io, `.com.mx`, `bookinq`…); PSL contra publicsuffix.org; vectores oficiales | La PSL es **auténtica byte por byte**; 74/77 vectores oficiales (3 diferencias a propósito). **Regresión P3:** con punto final, `google.com./url?q=evil` y `tp.media./click` pasan como fuente confiable. P3: el detector no marca `air-bnb.com`, `googIe.com` ni `tp-media.com` | **PARCIALMENTE CUBIERTO** |
| **AUD-08** Certificación comercial | El GO contradecía la configuración real; el checkout cobraba cualquier precio y moneda | `_shared/stripe-offer.ts:9-43`; `stripe-checkout/index.ts:65-72`; `logic.ts:250-309` | `stripeCheckoutOffer.test.ts` (18) | **Sí**: 18/18 fallan con el código viejo | Sí | M3b: quitar el `if` del 503 (`index.ts:66`); dos peticiones simultáneas; lectura en vivo de `stripe_config` | **M3b sobrevive** (el 503 no tiene prueba). Producción, lectura de hoy: modo TEST, `tax_behavior: unspecified` (el checkout responde 503), producto "sin límites", webhook sin `invoice.paid`, `charge.refunded` ni disputas, API endive frente a acacia | Corrección técnica: **PARCIALMENTE CUBIERTA**. Certificación comercial: **BLOQUEADO** (pendiente del dueño) |

---

## 3. Defectos nuevos (P0–P3)

**P0: ninguno. P1: uno.**

| ID | Sev. | Defecto | Dónde | Reproducción | Corrección propuesta |
|---|---|---|---|---|---|
| A2-RES-01 | **P1** | Suplantación del restaurante con un proveedor de correo gratuito no listado | `core.ts:212-216, 272-273`; SQL `ai_res_sender_strong` | `aiReservationsAudit2.test.ts`; `a2_adversarial.sql` | Invertir la lógica: aceptar el dominio solo si el restaurante **no** usa un proveedor compartido, con una lista mantenida de dominios de buzón compartido o la regla "solo dirección exacta" para cualquier dominio no propio. Para AUD-02 (b), comprobar con correos reales que Resend reporta DKIM alineado. |
| A2-01 | P2 | Un colaborador convierte `google.com/aclk→evil` en "Sitio oficial" firmado | `resolver.ts:125,142-144`; `handler.ts:197` | `a2_bridgeE2EAdversarial.test.ts`; `a2_collab.sql` | `fix_bridge_A2-01_A2-F1.diff` (probado: 164/165) |
| A2-RES-02 | P2 | Las negaciones y cancelaciones quedan "confirmed" | `evidence.ts` (vetos) | `aiReservationsAudit2.test.ts` | Vetos léxicos de negación y cancelación (es/en/fr/pt) antes de aceptar |
| A2-RES-03 | P2 | Números y horas en letra no se leen; la confirmación hereda los datos de nuestra solicitud citada | `evidence.ts` | ídem | Parser de números y horas en letra; no heredar datos de la parte citada |
| D-P2-1 / N-01 | P2 | Registrarse (o cambiar el correo) con un correo de la lista de cortesías da PRO permanente | `20261022130000:214-239` | `aud2_pagos_adversarial.sql` X10, X11 | Exigir `email_confirmed_at` en `apply_comp_grant` y activar "Confirm email" |
| P2-1 / N-02 | P2 | Concesión Privé ligada sin correo confirmado; con N-01, **Privé completo sin pagar** | `20261023090100:510-533` | `aud2_prive.sql` N02-A, B, C | Exigir el correo confirmado en el trigger y el token del correo para aceptar (diff en `INFORME_prive.md`) |
| D-P2-2 | P2 | La prueba de 30 días se repite con la misma tarjeta | `stripe-checkout/logic.ts:194-198`; `index.ts:77` | `aud2PagosAdversarial.test.ts` | Revisar la huella de la tarjeta (`payment_method.card.fingerprint`) antes de dar la prueba |
| D-P2-3 | P2 | Un reembolso no quita PRO (falta `charge.refunded` en el webhook) | Configuración de Stripe | Lectura de `stripe_config` | Agregar los 4 eventos que faltan |
| T-P2-1 | P2 | Amistad sin consentimiento, irrevocable de hecho; 25 avisos con texto del atacante | `20260526042412:57-91`; `20260526044222:95-97` | `t_trans.sql` | Solicitud con aceptación, código rotable y límite de avisos |
| T-P2-2 | P2 | Fotos del diario y de momentos con EXIF/GPS en buckets públicos; borrar la entrada no borra la foto | `TripJournal.tsx:62-64,82-85`; `BestMomentsPanel.tsx:142-145` | `a2trans_adversarial.test.ts` | Quitar EXIF como en la Bóveda, bucket privado con URL firmada, borrar el objeto |
| T-P2-3 | P2 | Documentos del viaje huérfanos al borrar el viaje; no entran en el borrado de la dueña | `tripMembership.ts:19-23`; `account_deletion_files` | `t_trans.sql` TRD1 | Borrar los objetos en cascada al borrar el viaje y en el borrado de cuenta |
| T-P2-4 | P2 | Pasaportes visibles para todos los colaboradores | Políticas de `trip_documents` | DOC1, DOC1b | Opción "solo yo" por documento |
| T-P2-5 | P2 | El Aviso de Privacidad promete "borrar el avatar" y no existe esa opción | `Legal.tsx:103`; `generate-avatar` | Lectura | Acción "borrar avatar" o corregir el texto |
| T-P2-6 | P2 | La prueba de AUD-SEG-03 es una regex: reintroducir el bug la deja verde | `audSeguridadEdge.test.ts` | Mutación | Prueba de comportamiento |
| P2-QA-1, 2 | P2 | Método de pruebas (ver §1) | `prive/run.sh`; conteo `grep` | Mutaciones | Quitar la reaplicación; cada suite valida su total esperado |
| N-L1 | P3 (P2 por rastreo) | Cualquier usuario fija cualquier URL como avatar y sus amigos la cargan | `profiles_guard_sensitive`; `Profile.tsx:337-339`; `OnboardingDeep.tsx:282`; producción: `handle_new_user` | SQL `has_column_privilege(...)=true` | Guard de `avatar_url` + servidor como único escritor |

**P3 (resumen; detalle en cada informe):**
- **AUD-07:** regresión con punto final (A2-F1); detector de marcas incompleto (A2-F2); robots.txt sigue saltos (A2-F3); token reutilizable (A2-T1).
- **Reservas:** `service_role` puede borrar la evidencia o saltarse el guard; la dedupe de Message-ID es incompleta; el correo "revísalo tú" conserva los enlaces del atacante.
- **Pagos:** USD $1 da PRO y antigüedad (N-06); doble suscripción deja sin PRO; un error HTTP de factura se registra con 200 sin revocar; el fallback se traga errores reales; N-04 ("sin límite" frente a "100 mensajes"); `hola@` sin MX.
- **Privé:**
  - prueba R06 inútil;
  - la cookie no cierra la sesión en el servidor;
  - dos carreras con "cerrar todas";
  - el barrido cierra en masa si falta una columna;
  - 14 intentos al día sin bloqueo total;
  - sin `PRIVE_IP_SALT`, no hay límite por IP.
- **Edición sin conexión:**
  - se lee sin la contraseña Privé;
  - no se borra al revocar el acceso;
  - no tiene vencimiento;
  - la caché de viajes del SW no lleva al usuario en la llave.
- **Bóveda:** GPS en JPEG MPF; PDF sin limpiar; números completos de tarjeta aceptados en notas.
- **Otros:**
  - `journal-photos` permite plantar objetos en la carpeta de un viaje ajeno;
  - `photo_url` libre;
  - 5 migraciones con hora inválida;
  - `profiles_tier_audit` sobrevive al borrado de cuenta.

---

## 4. Pruebas insuficientes o engañosas (con mutación)

| Prueba | Problema demostrado |
|---|---|
| Suite `prive` | Prueba versiones viejas de 3 funciones; rompiendo `20261024310000:280` sigue en 140/0 |
| Conteo `grep OK/FALLA` (16 suites) | `payments` reporta las fallas como ERROR; `ops` nunca falla; "FALLÓ" no se cuenta |
| `stripeAtomicity.test.ts` | Mock en memoria que reimplementa el SQL: no detecta M1, M2b ni M4 |
| CC3 (concurrencia) | No determinista: 2 de 10 falsos OK con pausa 0 s |
| `stripeCheckoutOffer.test.ts` | Quitar el 503 de `index.ts:66` no hace fallar nada |
| R06 "recordar solo una sesión propia" | Usa una cuenta sin PRO: responde `PRIVE_NOT_PRO` antes del filtro |
| `aiReservationsConfirmRules` "cita inventada" | Pasa sin la corrección; la protege un fixture grabado |
| R53 / R55 (reservas) | No prueban `< >` ni DELETE/TRUNCATE |
| `audSeguridadEdge.test.ts` (AUD-SEG-03) | Una regex sobre el texto: reintroducir el bug la deja verde |
| Detección única | M1 y M1b (Privé), `endsWith` e IDN (bridge): una sola aserción cada una |
| Vitest | Exit 1 por 7 errores no manejados (mock sin `.not` en `tripSelectionsPersist.test.tsx:22`) |

---

## 5. Discrepancias entre documentación y código

- **Ejecución de pruebas.** "2258/2258" se presenta como verde, pero vitest termina con exit 1 y necesita un `.env` que no viene en el ZIP.
- **Privé.**
  - "12 RPC de contenido": son 44, y todas exigen `prive_require` (verificado).
  - CAL-02 "corregido": incompleto.
  - "N-02 se resuelve con N-01": falso.
  - La cookie no cierra la sesión en el servidor.
- **Reservas.**
  - "Un trigger rechaza escrituras directas incluso con la llave de servicio" (`IATOS_RESERVAS_IA.md:81`) y "solo agregar/sellado": falso para DELETE, TRUNCATE y `set_config`.
  - "SPF solo nunca basta" y "el modelo no decide": ambos parciales.
- **Bridge.**
  - AUD-04c "lo del viaje sigue sin firmarse": falso para URLs de la lista estricta.
  - AUD-04h "el cron no sigue saltos": falso para robots.txt.
- **Pagos.** AUD-05 "500 en cada paso converge": no cuando falla la búsqueda de la factura.
- **Avatar.** "`avatar_url` solo la escribe el servidor": la app la escribe desde el navegador.
- **SEGURIDAD.md.** Conteos desactualizados:
  - buckets: dice 4, son 6;
  - SECURITY DEFINER: dice 180, son 257;
  - funciones que ejecuta `authenticated`: dice 44, son 90.
  Además, menciona una tabla `travel_documents` que no existe, y F-02 se da por corregido cuando no lo está.
- **CALIDAD_PRUEBAS.md.** Cifras de una versión anterior (177 archivos, 1,791 pruebas).

## 6. Repositorio frente a producción (lectura en vivo)

- **Coinciden byte por byte** 16 funciones críticas (AUD-01, 05, 08, cuotas, acceso a viajes y borrado de cuenta); también 339 de 343 funciones, los buckets y los permisos de ejecución.
- **D1.** **50 políticas solo en producción** (creadas fuera de git). En `expenses` y `user_visits` **anulan la verificación de acceso al viaje** de `20261022141600_sec2_trip_id_checks.sql`. Impacto: integridad de datos propios (P3).
- **D2.** `handle_new_user`, `ensure_ai_prefs`, `on_trip_insert_dna` y `on_visit_insert_dna` son distintas del repositorio. `handle_new_user` copia `avatar_url` del metadato que manda quien se registra.
- **D3.** 14 migraciones aplicadas pero sin registro, más 32 registradas con otra versión. Riesgo: un `db push` falla (P3).

## 7. Evaluación propia por módulo

| # | Módulo | Veredicto | Razón |
|---|---|---|---|
| 1 | Auth | **NO-GO** | `mailer_autoconfirm` + N-01/N-02 |
| 2 | Iato / concierge | GO | Primer texto en vivo pendiente de medir |
| 3 | Cotizaciones | GO | — |
| 4 | Viajes | **NO-GO** | Fotos con GPS en buckets públicos; documentos huérfanos y visibles a todos (T-P2-2/3/4) |
| 5 | Importar viajes | GO condicionado | Hereda T-P2-3 |
| 6 | Avatar | **NO-GO** | URL arbitraria (N-L1); promesa de borrado falsa; modelo no probado en vivo |
| 7 | Travel DNA / personalización | GO | — |
| 8 | Social | **NO-GO** | Amistad sin consentimiento (T-P2-1) |
| 9 | Gastos | GO | P3: políticas de producción |
| 10 | Members Only | GO | — |
| 11 | Bóveda | GO condicionado | P3 de metadatos y números en notas |
| 12 | Privé acceso / sesión | GO condicionado | AUD-01 verificado; N-02 P2 abierto |
| 13 | Privé reimaginado | GO | — |
| 14 | The Key | GO | — |
| 15 | Drops / Insider / Passport | GO | — |
| 16 | The Private Edition | **NO-GO** | Sin aprobación editorial; offline sin contraseña Privé; iPhone real BLOQUEADO |
| 17 | Reservas IA | **NO-GO** | P1 A2-RES-01 + 2 P2 (apagada en producción) |
| 18 | Booking Bridge | **NO-GO** | P2 A2-01 (phishing marcado como "Sitio oficial") |
| 19 | Pagos / Stripe | **NO-GO** | Certificación bloqueada; D-P2-1/2/3 |
| 20 | Correo | **NO-GO** | Sin MX; DMARC sin rua |

**Total: 9 GO, 3 GO condicionado y 8 NO-GO** (el documento de cierre decía 14 GO y 6 NO-GO).

## 8. GO/NO-GO para vender PRO a $99 MXN

### **NO-GO.**
"0 P0 y 0 P1 en código" no se sostiene: hay **un P1** (reservas, función apagada) y **más de 15 P2**. Y aunque se corrigiera todo el código, **hoy no se puede vender**: Stripe está en modo TEST y el checkout responde 503 por la protección de precio.

## 9. Lista mínima de bloqueantes para vender PRO

**Configuración (el dueño):**
1. Stripe en modo live con precio de MXN 99.00 mensual, IVA incluido; llave, secreto del webhook y precio del mismo modo; `stripe_config` con `ok:true` y `mode:"live"`.
2. Webhook con los 9 eventos (incluidos `invoice.paid`, `charge.refunded`, `charge.dispute.created` y `charge.dispute.closed`) y versión `2024-12-18.acacia`, o certificación explícita de endive.
3. Quitar "sin límites" del producto y resolver N-04 en la app.
4. Activar "Confirm email" en Supabase Auth.
5. Que `hola@traveliatos.life` reciba correo (registro MX) y DMARC con rua.
6. Firmar las Fases 1–3 de `STRIPE_CERTIFICACION.md`, con una compra real de $99 reembolsada.

**Código (se puede hacer ya, con pruebas, sin tocar producción hasta tener el OK):**
7. N-01 y N-02: `email_confirmed_at` en `apply_comp_grant` y `apply_prive_grant`, y token del correo para aceptar.
8. D-P2-2: huella de tarjeta para la prueba de 30 días.
9. A2-01 y A2-F1 (Booking Bridge): `fix_bridge_A2-01_A2-F1.diff`.
10. T-P2-1 (amistad con aceptación), T-P2-2 (EXIF y bucket privado), T-P2-3/4 (documentos del viaje), T-P2-5 (avatar), N-L1 (guard de avatar).
11. Pruebas: quitar la reaplicación de `prive/run.sh`; cada suite SQL valida su total; prueba del 503 del checkout; CC3 determinista; vitest con exit 0 y sin red.
12. Producción: eliminar las políticas `*_own` que anulan las verificaciones de viaje (o pasarlas a git) y registrar las 14 migraciones.

**No bloquean vender PRO, pero sí encender sus funciones:** Reservas IA (P1 + P2), The Private Edition (aprobación editorial y prueba en iPhone real).
