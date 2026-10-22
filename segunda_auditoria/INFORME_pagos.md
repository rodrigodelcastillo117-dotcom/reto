# Segunda auditoría independiente · Grupo PAGOS (AUD-05, AUD-08, N-01/N-05/N-06, cuotas y prueba gratis)

Material: paquete del commit `7670102` (copia en `/home/user/audit2/pagos/codigo`). Código anterior: `06865cb` extraído con `git archive` en `/home/user/audit2/pagos-old`. Sin tocar producción, Stripe ni secretos. Fecha: 22-oct-2026.

## 0. Veredicto propio

**NO-GO para vender IATOS PRO a $99 MXN.**

- **Lo técnico de AUD-05 está corregido y lo verifiqué yo:** las pruebas fallan con `06865cb` y pasan con `7670102`, y las 4 mutaciones obligatorias las detectan.
- **La certificación comercial (AUD-08) no existe todavía.** Con la configuración de producción que reportó el líder, hoy no se puede cobrar: el checkout responde 503. Si se corrigiera solo el precio, se cobraría con un webhook que no recibe reembolsos ni disputas y con un producto que dice "sin límites".
- Encontré **0 P0, 0 P1 de código, 3 P2 nuevos y 7 P3 nuevos** (sección 3).

## 1. Tabla de hallazgos

| AUD | Defecto original | Código corregido (archivo:línea) | Test exacto | ¿Fallaba antes? | ¿Pasa ahora? | Caso nuevo intentado | Resultado | Veredicto |
|---|---|---|---|---|---|---|---|---|
| AUD-05.1 eventos repetidos / simultáneos | (sospecha) doble PRO o doble periodo | sin cambio: `apply_stripe_subscription` con `FOR UPDATE` (`20261022130000:102-209`), `UNIQUE(stripe_invoice_id)`, `event_id` PK | `stripe_events.sql` AP01, AP02; `run.sh` CC1, CC2 | No: pasan en `06865cb` (lo ejecuté) | Sí | CC4 con el candado quitado | CC4 sigue OK: lo protege el UNIQUE, no el candado | REFUTADO CON EVIDENCIA (ya era correcto) |
| AUD-05.2 eventos fuera de orden | (sospecha) un evento viejo regresa el estado | relectura en Stripe (`handler.ts:203`) + `stale_event` | AP03–AP05; vitest C1–C3 | No (pasan antes) | Sí | X06: parcial y total al revés, antes del periodo | OK (refunded, 0 días) | REFUTADO CON EVIDENCIA |
| AUD-05.4 reembolso o disputa ANTES del periodo pagado | El periodo nacía `paid`, y un cargo reembolsado contaba para Privé | `20261024051500_aud_pagos_payment_event_atomic.sql:142-156` (reaplica `stripe_payment_events` al insertar) | AP08–AP11 | **Sí**: `06865cb` da FALLA en AP08–AP11 ("periodo=paid dias=20") | Sí | **M4** (quitar la reaplicación), X07, X08 | M4 → AP08–AP11 FALLA; X07/X08 OK | VERIFICADO INDEPENDIENTEMENTE |
| AUD-05.5 carrera reembolso vs `invoice.paid` | Ninguno veía al otro y el periodo quedaba `paid` | candado `pro_paid_period_lock` `:20-23`, usado en `:56`, `:125`, `:182`; `stripe_commit_payment_event` `:168-209`; `payments.ts:271-280` | CC3 (`run.sh:89-103`) | **Sí**: `06865cb` CC3 FALLA (`periodo=paid dias=1 s2=no_period`) | Sí | **M1** (candado vacío); repetí CC3 10 veces con pausa de 0.5 s y de 0 s | M1 → CC3 FALLA 10/10 con 0.5 s, **pero solo 8/10 con 0 s** (2 falsos OK) | VERIFICADO INDEPENDIENTEMENTE, con prueba no determinista (sección 4) |
| AUD-05.6 apertura de disputa entregada después de su cierre | El periodo quedaba `disputed` para siempre | `:196-202` y `:151-153` | AP13; vitest "disputa cerrada (ganada) ANTES…" | Sí (ERROR en SQL; vitest ×) | Sí | X07 (abierta y ganada, ambas antes del periodo) | OK | VERIFICADO INDEPENDIENTEMENTE |
| AUD-05.7 aviso de disputa fallido marcado como hecho | 200 sin aviso | `payments.ts:241-243` | vitest D "disputa perdida…", "disputa abierta…" | Sí (× en `06865cb`) | Sí | X09: **sin administradores** | `notify_admins` = 0, que `index.ts:142` traduce a `campana_ya_enviada`: 200 y nadie se entera | PARCIALMENTE CUBIERTO (D-P3-3) |
| AUD-05.8 segunda suscripción viva cobrada en silencio | Cobro doble invisible | `handler.ts:143-167` | vitest E "segunda suscripción pagada…" | Sí (×) | Sí | X04/X05: después termina o se reembolsa la 1a | La persona queda **sin PRO aunque la 2a sigue cobrando** | PARCIALMENTE CUBIERTO (D-P3-2) |
| AUD-05.9 ciclo de vida | (sospecha) | sin cambio | AP06, AP18–AP20; vitest E1–E4 | No | Sí | X03 (past_due/paused/unpaid/incomplete) | OK: ninguno da PRO | REFUTADO CON EVIDENCIA |
| AUD-05.3 / 05.10 500 en cada paso y reintento | El estado quedaba a medias | contrato `handler.ts:15-17`; commit atómico | vitest D (3 pasos de factura + 8 de reembolso); AP15, AP17 | AP15 FALLA antes | Sí | Factura no localizable (lookup PI→factura con HTTP no-OK) | **200 `reembolso_total_sin_suscripcion`, no revoca y queda registrado como hecho** | PARCIALMENTE CUBIERTO (D-P3-4). Las pruebas D son un **mock en memoria** que imita el SQL |
| Idempotencia por `event_id` | — | `payments.ts:179-181`; SQL `:184-194` | stripePayments "evento duplicado", priveTenure "evento repetido", AP14, CC4 | — | Sí | **M2a** (handler) y **M2b** (SQL) | M2a → 2 FALLA (stripeAtomicity NO la detecta); M2b → AP14 y CC4 FALLA | VERIFICADO INDEPENDIENTEMENTE |
| Firma del webhook | — | `index.ts:37-57`: `constructEventAsync` con stripe@17.7.0 | (sin prueba de la firma en Vitest) | — | — | Leí `stripe-17.7.0/esm/Webhooks.js` y `PlatformFunctions.js` | Tolerancia de 300 s (por omisión); comparación en tiempo constante (`secureCompare`); cuerpo crudo; 401 sin secretos | VERIFICADO por revisión de código (no hay prueba ejecutable) |
| "Ruta anterior si la migración no está" | — | `index.ts:89-102` (regex en `:92`); `missingRpcAsSkip` (`prive-tenure.ts:123-129`) | ninguna | — | — | errores reales que contienen el nombre de la función o "does not exist" | **Se tragan: 200 `migration_pending`, o vuelve la ruta no atómica** (3 casos ×) | FALLA (D-P3-5) |
| AUD-08.2 el checkout cobraba cualquier precio | USD, IVA por fuera, anual | `_shared/stripe-offer.ts:9-43`; `stripe-checkout/index.ts:65-72`; `logic.ts:250-280` | `stripeCheckoutOffer.test.ts` (18) | Sí: 18/18 × en `06865cb` | Sí 18/18 | **M3a** (`priceProblems` → `[]`) y **M3b** (quitar el `if` de `index.ts:66`) | M3a → 11 FALLA; **M3b → 0 FALLA (sobrevive)** | PARCIALMENTE CUBIERTO: la regla está probada; el 503 cableado en `index.ts` no tiene prueba |
| AUD-08 Adaptive Pricing apagado / MXN | Cobró en USD | `logic.ts:264-265` | stripeCheckoutOffer "apaga Adaptive Pricing" | Sí | Sí | `deno check` con los tipos de stripe@17.7.0 | El tipo acepta `adaptive_pricing` y `currency`; el efecto real en Stripe no está probado | CORREGIDO PERO NO VERIFICADO (contra Stripe: BLOQUEADO) |
| AUD-08 expiración de sesiones abiertas | Dos pestañas, dos suscripciones | `logic.ts:287-309`; `index.ts:90-95` | 3 casos con mocks | Sí | Sí | Dos peticiones simultáneas | Carrera sin resolver: las dos listan antes de crear (no ejecutable sin Stripe) | PARCIALMENTE CUBIERTO |
| AUD-08 certificación comercial | GO contradictorio | `STRIPE_CERTIFICACION.md` (procedimiento) | — | — | — | Lectura en vivo del líder (sección 5) | Fases 0–3 sin hacer; 5 desajustes en vivo | BLOQUEADO (dueño). **Certificación comercial pendiente** |
| N-01 `mailer_autoconfirm=true` | Cortesía con un correo ajeno | ninguno (configuración) | — | — | — | X10, X11 (SQL real) | **X10: PRO `comped` sin vencimiento, plan `pro`, sin tope de Iato. X11: también cambiando el correo de una cuenta existente** | FALLA (confirmado en código; la corrección es del dueño) |
| N-04 "Mensajes sin límite" frente a "100 mensajes al mes" | Textos contradictorios | sin cambio: `Pro.tsx:91,95` frente a `planCopy.ts:37` | `planCopy.test.ts` no prohíbe "sin límite" (solo `/ilimitad/`) | — | — | grep | Sigue igual en `7670102` | FALLA (PENDIENTE DEC-01) |
| N-05 suscripción que cobra sin cuenta | 200 silencioso | `handler.ts:154-162` | stripeAtomicity "mejora: una suscripción que cobra sin cuenta…" | Sí (× en `06865cb`) | Sí | mutación (cambiar `unknown_user` en `:154`) | 1 FALLA | VERIFICADO INDEPENDIENTEMENTE |
| N-06 `is_pro` no revisa precio ni pausa | Riesgo residual | sin cambio: `20261022135300_pay_plan_limits_recommended.sql:18-26` | ninguna | — | — | X01, X13 (SQL); vitest de `pause_collection` y precio | **X01: USD $1, `active` → PRO. X13: facturas de USD $1 suman 94 días y dan elegibilidad Privé. El handler no lee `pause_collection` (×)** | FALLA (P3 condicionado al panel) |
| Cuotas atómicas y prueba gratis | — | `reserve_quota`/`commit_quota`; `trial_no_card.sql` | R1–R12, M1–M4, T1–T8, CONCURRENCIA ×2, suite `cost` | — | Sí | prueba con tarjeta en una cuenta nueva | **Otra prueba de 30 días por cada cuenta nueva con la misma tarjeta** (×) | PARCIALMENTE CUBIERTO (D-P2-2) |

## 2. Mutaciones obligatorias (todas en mi copia, todas restauradas; `cmp` contra `base/` da igual)

| # | Mutación | Cómo | Resultado |
|---|---|---|---|
| M1 | Quitar el candado por factura | `pro_paid_period_lock` → `SELECT pg_sleep(0)` (`mutaciones/m1_sin_candado.sql`) | **CC3 FALLA** (`periodo=paid dias=1 s2=true`). Ninguna otra prueba la detecta. Con 0 s de pausa la detecta solo 8 de 10 veces |
| M2a | Quitar la idempotencia por event id (TS) | `payments.ts:181` → `if (false && prev.data)` | **2 FALLA**: `stripePayments` "evento duplicado" y `priveTenure` "evento repetido". `stripeAtomicity` (35) sigue verde |
| M2b | Quitar la idempotencia por event id (SQL) | borrar `IF NOT FOUND … RETURN duplicate` (`:191-194`) | **AP14 y CC4 FALLA** |
| M3a | Aceptar cualquier precio (regla) | `priceProblems` → `return []` | **11 FALLA** (10 en stripeCheckoutOffer, 1 en stripeConfigProbe) |
| M3b | Aceptar cualquier precio (cableado) | `stripe-checkout/index.ts:66` → `if (false && problems.length)` | **0 FALLA: la mutación sobrevive.** Prueba insuficiente |
| M4 | No reaplicar reembolsos al registrar el periodo | borrar el `FOR … LOOP` (`:143-156`) | **AP08, AP09, AP10, AP11 FALLA** |
| extra | Quitar el aviso N-05 | `handler.ts:154` | 1 FALLA |

## 3. Defectos nuevos

### P2

**D-P2-1 · N-01 confirmado en la base: con `mailer_autoconfirm=true`, quien registre un correo ajeno de `comp_grants` obtiene PRO de cortesía permanente y sin topes. También lo obtiene cambiando el correo de una cuenta que ya existe.**
- **Entrada:**
  - `INSERT INTO comp_grants('vip-ajeno@…')`, y después un registro con ese correo y `email_confirmed_at = now()`, que es lo que hace el autoconfirm.
  - Variante: `UPDATE auth.users SET email = '<correo de comp_grants>'`.
- **Código vulnerable:**
  - `20261022130000_pay_stripe_sync_and_atomic_quota.sql:214-239`: el trigger (`:238`) `AFTER INSERT OR UPDATE OF email, email_confirmed_at`.
  - `has_comp_grant` en `:25-38`.
- **Prueba:** `codigo/supabase/tests/payments/aud2_pagos_adversarial.sql`, casos X10 y X11. Resultado: `status=comped plan=pro limite_concierge=NULL`.
- **Qué se obtiene:**
  - PRO sin vencimiento y Members;
  - Iato y análisis sin tope (`pro_limits_enforced=false`);
  - la concesión Privé pendiente de ese correo queda ligada a la cuenta (N-02). Para entrar a Privé hace falta el token de invitación, que va al buzón real; eso lo revisa el grupo prive.
- **No verificado en vivo:** que GoTrue aplique sin confirmación el cambio de correo con autoconfirm. Así lo hace su código fuente.
- **Corrección:** Auth → "Confirm email" ON, y además endurecer la base. Parche propuesto:
  ```diff
  - AFTER INSERT OR UPDATE OF email, email_confirmed_at ON auth.users
  + AFTER INSERT OR UPDATE OF email_confirmed_at ON auth.users   -- solo al confirmar
  + -- y en apply_comp_grant/has_comp_grant exigir email_confirmed_at > created_at + interval '1 second'
  +     -- o NEW.confirmed_via = 'email_link' (no un autoconfirm)
  ```

**D-P2-2 · La prueba de 30 días con tarjeta se puede repetir sin fin: una cuenta nueva con la misma tarjeta recibe otra prueba. PRO en prueba es plan `pro` y hoy no tiene topes.**
- **Entrada:** registrar otra cuenta (con autoconfirm, el correo puede ser inventado) y pasar al checkout con la misma tarjeta.
- **Código vulnerable:**
  - `stripe-checkout/logic.ts:194-198`: `trialEligible` solo mira la fila y el customer de esa cuenta.
  - `index.ts:77-79`: crea un customer nuevo por `user.id`.
  - `20261022135300:73-80`: la prueba de Stripe cuenta como `pro`.
- **Prueba:** `codigo/src/test/aud2PagosAdversarial.test.ts`, "una cuenta NUEVA de la misma persona…" (×).
- **Corrección:** en `checkout.session.completed` o `customer.subscription.created`, si la huella (`payment_method.card.fingerprint`) ya tuvo prueba, poner `trial_end=now` (o una regla de Radar). Además, encender `pro_limits_enforced` o dar a la prueba con tarjeta los topes de `trial`.

**D-P2-3 · Sin `charge.refunded` ni disputas en el endpoint de producción (lectura del líder), la política publicada no se cumple.**
- `Legal.tsx:197` promete: "Si te reembolsamos un cargo completo, la suscripción se cancela y el acceso PRO… termina".
- Hoy, un reembolso desde el panel no cancela la suscripción ni quita PRO, y Stripe vuelve a cobrar el mes siguiente.
- Una disputa no avisa a nadie: se pierde el plazo para responder y la disputa perdida no revoca nada.
- El código está bien; es configuración. Por eso lo cuento como bloqueante comercial (sección 5), no como defecto de código.

### P3

1. **D-P3-1 · N-06, ampliado.** `is_pro` da PRO a cualquier suscripción `active`, de cualquier precio o moneda (X01). Una fila `active` con `current_period_end` NULL da PRO indefinido (X02; no la produce el SDK fijado en acacia, pero no hay defensa). Facturas de cualquier precio cuentan para los 90 días de Privé (X13: USD $1 → 94 días, elegible). El handler no transmite `pause_collection` (vitest ×).
   - **Código vulnerable:** `20261022135300:18-26`, `handler.ts:91-110`.
   - **Corrección:** guardar `pause_collection` y en `is_pro` exigir `price_id = <config>` o `currency='MXN'`, y `current_period_end IS NOT NULL` para `active`. En `prive_record_paid_period`, contar solo `currency='MXN' AND amount_paid >= 9900`, o el precio configurado.
2. **D-P3-2 · Doble suscripción.** Después del aviso, si termina o se reembolsa la 1a, la persona queda sin PRO aunque la 2a sigue cobrando (X04, X05). Nadie relee las demás suscripciones del customer.
   - **Código vulnerable:** `apply_stripe_subscription` (`20261022130000:171-176`) y `revoke_paid_access` (`20261022146100:71-105`).
   - **Corrección:** cuando la suscripción de la fila deja de estar viva, listar en Stripe (`subscriptions.list({customer,status:'active'})`) y aplicar la viva.
3. **D-P3-3 · Disputas sin destinatario.** Si `admins` está vacío, `notify_admins` devuelve 0, que se lee como `campana_ya_enviada`: 200 y nadie se entera (X09; vitest ×).
   - **Código vulnerable:** `index.ts:142`, `20261022146100:115-131`.
   - **Corrección:** que `notify_admins` distinga "sin destinatarios" (−1) de "ya enviado" y que el webhook lo trate como `fallido`.
4. **D-P3-4 · Reembolso con la factura no localizable.** Si `invoiceForPaymentIntent` recibe un HTTP no-OK, devuelve `null` (`index.ts:127`). El reembolso total queda como `reembolso_total_sin_suscripcion` con 200: no revoca y Stripe no reintenta (vitest ×).
   - **Corrección:** `if (!res.ok) throw new Error(...)` y devolver `null` solo si la respuesta es 200 con la lista vacía.
5. **D-P3-5 · El fallback "si la migración no está" falla abierto.** Las regex `…|does not exist|<nombre de la función>` (`index.ts:92`, `prive-tenure.ts:124`) convierten en éxito (`migration_pending`, 200) cualquier error con "does not exist" o con el nombre de la función. Eso incluye los `RAISE` propios de la función y un error de schema cache justo después de migrar, que además reactiva la ruta no atómica. Probado con 3 casos ×.
   - **Corrección:** comparar solo `code === 'PGRST202'` o `'42883'` sobre la función de nivel superior, y quitar el fallback ahora que la migración está aplicada.
6. **D-P3-6 · N-04 sigue abierto.** `Pro.tsx:91` dice "Mensajes sin límite" y `:95` "Sin límite", mientras `planCopy.ts:37` dice "100 mensajes con Iato al mes". `planCopy.test.ts:23-30` no prohíbe "sin límite". El producto en Stripe dice "sin límites" y el checkout **no** lo bloquea: `productProblems` solo lo usa `stripe_config`.
7. **D-P3-7 · Contacto de reembolsos sin buzón.** El único canal para pedir reembolsos y cancelaciones es `hola@traveliatos.life` (`Legal.tsx:19, 187, 203`). Ese dominio no tiene MX (MAIL-01), así que los mensajes rebotan: la política de reembolso no se puede ejercer por correo.

## 4. Pruebas insuficientes o engañosas

- **CC1–CC4 y las dos "CONCURRENCIA" de cuotas no son deterministas.** Usan `sleep 0.5` (`run.sh:32, 50, 66`) y no comprueban que la sesión 2 de verdad haya llegado a mitad de la transacción. Con el código correcto el resultado no depende del orden, así que nunca fallan en falso. Pero con la mutación M1 y la máquina cargada (lo simulé con 0 s de pausa) CC3 dio **2 OK falsos de 10**: `mutaciones/cc3_loop.sh`. Corrección: antes de lanzar la sesión 2, esperar a que `pg_stat_activity` muestre la sesión 1 en `pg_sleep` (o a que tenga el candado en `pg_locks`), y afirmar que la sesión 2 esperó.
- **CC2 y CC4 no protegen el candado.** Pasan sin él gracias a `UNIQUE(stripe_invoice_id)` y a la PK `event_id`. El candado lo protege una sola prueba: CC3.
- **`stripeAtomicity.test.ts` es un mock en memoria que reimplementa el SQL** (líneas 1-12, 60-180). No detectó M1, M2b ni M4 (solo el SQL las detecta) y tampoco M2a, porque su mock de `commitPaymentEvent` ya deduplica.
- **El 503 de `stripe-checkout/index.ts` no tiene ninguna prueba** (M3b sobrevive). Tampoco la tienen `stripe-portal` (N-03, "sin prueba automática", confirmado) ni el fallback de `index.ts:89-102`.
- **Los fixtures son de acacia o basil;** no hay ningún payload con la forma de `2026-09-30.endive`.
- `planCopy.test.ts` deja pasar "sin límite" y "Sin límite" (N-04).

## 5. AUD-08: lo técnico verificado frente a la certificación comercial pendiente

**Corrección técnica verificada en código y pruebas:**
- MXN 9900, `inclusive`, mensual, licensed y activo (`priceProblems`);
- `currency=mxn` y `adaptive_pricing.enabled=false` en la sesión;
- expiración de sesiones abiertas (con mocks);
- prueba con tarjeta solo con historial limpio de esa cuenta (D-P2-2);
- prueba sin tarjeta apagada y probada (T1–T8);
- derechos PRO, cancelación al fin del periodo y reembolso total → revocación: la lógica es correcta (AP07, AP18–AP20, X12: la pérdida de PRO arrastra Privé, `PRIVE_NOT_PRO`, y el plan pasa a `free`).

**Certificación comercial pendiente (BLOQUEADO; la hace el dueño):**

| Estado en vivo (líder) | Qué implica en el código |
|---|---|
| Modo TEST | Nadie puede pagar. `stripe_config` solo lo advierte ("Modo" sale `ok:true`, con aviso); el 503 lo causa el precio |
| `tax_behavior: unspecified` | `priceProblems` → `price_mismatch` → **503**: hoy no se vende nada. Si se quitara la protección, con `automatic_tax` Stripe usaría el comportamiento por omisión de la cuenta; si es `exclusive`, cobraría $114.84 |
| El producto dice "sin límites" | Sale en el checkout, el portal y los recibos. El checkout **no** lo bloquea. Contradice "100 mensajes" (N-04) |
| Faltan `invoice.paid`, `charge.refunded` y las dos de disputa | PRO sigue funcionando por `customer.subscription.*` (la renovación mueve `current_period_end`; `past_due` → `active` llega como `updated`). **Sin `invoice.paid` (ni `invoice.payment_succeeded`) no se registra ningún periodo pagado:** la antigüedad de Privé por pago nunca crece (solo con `prive-tenure-backfill`). Sin `charge.refunded`, un reembolso no revoca ni cancela, y Stripe sigue cobrando. Sin disputas, no hay aviso ni revocación (D-P2-3) |
| API `2026-09-30.endive` frente a `acacia` | Casi todo se **relee** con el SDK fijado en acacia (suscripción, factura, cargo de la disputa, PaymentIntent). Del payload solo se usan: `id`, `client_reference_id`/`metadata`/`subscription` del checkout; el `customer.subscription.deleted` completo (con el respaldo `items[].current_period_end`); la suscripción de la factura (`parent.subscription_details`, ya contemplado); en `charge.refunded`, `refunded`/`amount`/`amount_refunded`/`payment_intent` (la falta de `invoice` desde basil se resuelve con el PaymentIntent). No encontré un campo que se rompa con basil. **Endive es posterior a lo que conozco y no hay fixture endive: no verificable.** `stripe_config` lo marca como problema |
| El portal no enlaza privacidad ni términos; sin registro de IVA en MX | Solo avisos en `stripe_config`. El recibo no desglosa el IVA y Stripe no emite CFDI |

**Lista mínima de bloqueantes para vender PRO a $99 MXN:**
1. Precio live MXN 99.00 mensual `inclusive`, y los secretos `sk_live`/`whsec` live/`price` live del mismo modo, con `stripe_config` en `ok:true, mode:"live"`.
2. Webhook live con los 9 eventos de `REQUIRED_WEBHOOK_EVENTS` y la versión `2024-12-18.acacia` fijada (o una certificación explícita de endive con payloads reales).
3. Quitar "sin límites" del producto y resolver N-04 (texto o `pro_limits_enforced`).
4. Supabase Auth "Confirm email" ON (D-P2-1/N-01), antes de encender cualquier prueba.
5. Fase 1 (T0–T15) y Fase 3: una compra real de $99 reembolsada que muestre `reembolso_total_revocado`, firmadas.
6. Un buzón que reciba en `hola@` (MX) o un canal de reembolso que funcione (D-P3-7).
7. Comprobar que `admins` tiene al menos un registro y `HEALTH_ALERT_EMAIL` (D-P3-3).

Antes de abrir al público, recomendado (sin bloquear una venta controlada):
- límite de pruebas por tarjeta (D-P2-2);
- arreglar D-P3-4 y D-P3-5;
- una prueba del 503 de `index.ts`;
- CC3 determinista.

## 6. Discrepancias entre la documentación y el código

- `PAGOS.md` y el cierre cuentan AUD-05 como VERIFICADO sin matices. La parte de "aviso de disputa" no cubre el caso sin administradores, y "doble suscripción" deja sin PRO a quien paga la 2a después de cancelar la 1a.
- `STRIPE_CERTIFICACION.md` §3.2 dice que el webhook "funciona aunque la migración no esté (usa la ruta anterior…)". Cierto, pero esa ruta reintroduce la carrera CC3 y el fallback también se activa con errores que no son de una migración faltante.
- `CIERRE…md` §4 da por REFUTADA la sospecha "falla a mitad deja la suscripción a medias". En la ruta de reembolsos hay un 200 posible sin efecto (D-P3-4).
- `CIERRE…md` §3.5 CAL-04 dice "pruebas frágiles por tiempo… CORREGIDO" (solo `concurrent_rate_limit.sh`). `payments/run.sh` sigue con `sleep 0.5`, y en el cierre se presentan como pruebas de concurrencia.
- `planCopy.ts:24` (`TRIAL_CONDITIONS`): "una por persona". En código es una por cuenta (con tarjeta) o una por correo normalizado (sin tarjeta).
- N-06 se describe como "controlado por el panel", pero el checkout no revisa el producto y la antigüedad de Privé cuenta cualquier precio (X13).

## 7. Comandos ejecutados (salidas resumidas)

| Comando | Resultado |
|---|---|
| `su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash supabase/tests/payments/run.sh a2pagos_pay"` (7670102) | **88 OK, 0 FALLA, 0 ERROR** |
| Mismo `run.sh` y `stripe_events.sql` nuevos copiados a `06865cb` (`a2pagos_payold`) | 78 OK. FALLA: AP08, AP09, AP10, AP11, AP15, CC3 (`s2=no_period`), CC4. ERROR (función inexistente) en AP13, AP14 y AP16 |
| `bash supabase/tests/cost/run.sh a2pagos_cost` | **16 OK + 3 "ok"**, 0 FALLA |
| `mutaciones/stripe_only.sh` con M1, M2b, M4 (sobre un template con todas las migraciones) | 24/25 (CC3 FALLA) · 23/25 (AP14, CC4) · 21/25 (AP08–AP11) |
| `mutaciones/cc3_loop.sh` | M1: 0.5 s → 0 OK de 10; 0 s → **2 OK de 10**. Código correcto: 10/10 con 0 s y con 0.5 s |
| `npx vitest run` (15 archivos: stripe×6, priveTenure, healthChecks, healthAlerts, quota, serpQuota, proGateError, proStatusCard, planCopy, usePlanConfig) `--testTimeout=60000` | **15 archivos, 199/199** |
| Las mismas pruebas nuevas en `06865cb` | stripeAtomicity 6 × (C carrera, C disputa, D ×2, E duplicado, E N-05); stripeCheckoutOffer 18/18 ×; stripeConfigProbe no carga (archivo inexistente) |
| Mutaciones TS: M2a, M3a, M3b, N-05 | 2 × · 11 × · **0 ×** · 1 × |
| `npx vitest run src/test/aud2PagosAdversarial.test.ts` | 9/9 × (defectos demostrados: pausa, precio, livemode/cuenta sin revisar, factura no localizable, disputa sin destinatario, 3 fallbacks, prueba repetible) |
| `psql -f supabase/tests/payments/aud2_pagos_adversarial.sql` | OK: X03, X06, X07, X08, X12 · DEFECTO: X01, X02, X04, X05, X09, X10, X11, X13 |
| `deno check --quiet` de stripe-webhook, stripe-checkout, stripe-portal y health-check | **4/4 rc=0**, sin salida. `deno.lock` cambió y lo restauré desde `base/` (`cmp` igual) |
| `npm pack stripe@17.7.0` (lectura de la firma) | `DEFAULT_TOLERANCE: 300`; `secureCompare` en tiempo constante |

No se pudo ejecutar (**BLOQUEADO**):
- nada contra Stripe real: Adaptive Pricing, `sessions.expire`, Stripe Tax, payloads endive y livemode real;
- nada contra Supabase Auth real: el cambio de correo con autoconfirm.

Bases `a2pagos_*` borradas (0 restantes).

Archivos: `mutaciones/` (mutantes, scripts y salidas), `codigo/supabase/tests/payments/aud2_pagos_adversarial.sql`, `codigo/src/test/aud2PagosAdversarial.test.ts`.
