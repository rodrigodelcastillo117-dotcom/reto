# Segunda auditoría independiente · grupo `bridge` (AUD-04 Booking Bridge, AUD-07 dominios y phishing)

Material: paquete `iatos_auditoria_cierre_2026-10-22_ligero.zip`, commit `7670102` (copia en `/home/user/audit2/bridge/codigo`).
Código anterior: `06865cb`, extraído con `git archive` en `/home/user/audit2/bridge-old` (el repositorio no se tocó).
Fecha: 2026-10-22. Producción no se tocó. No hice commits ni push.

## 0. Resumen

- **AUD-04 · PARCIALMENTE CUBIERTO.** El token de booking-go está bien hecho y lo verifiqué yo: HMAC-SHA256, comparación en tiempo constante, caducidad de 30 min, ligado a intención + usuario + huella SHA-256 del destino + nivel. Las mutaciones de firma, caducidad y huella hacen fallar pruebas. **Pero el arreglo de AUD-04b/04c está incompleto (P2 abierto, A2-01).** Un colaborador del viaje puede escribir en `restaurantes_json` (`fuente: "google_places"`) un redirect opaco de Google (`google.com/aclk?…adurl=`, `/travel/clk/`). El dueño lo ve como **"Sitio oficial"**, con `verified_at`, y booking-go **lo firma y redirige** (302 a `aclk`). Lo demostré con SQL real (el colaborador sí escribe) y con el handler real.
- **AUD-07 · PARCIALMENTE CUBIERTO.**
  - La PSL fijada es **auténtica**: el SHA-256 coincide con la lista que hoy sirve publicsuffix.org (misma VERSION y COMMIT), y al regenerarla sale idéntica byte a byte.
  - El algoritmo pasa **74/77** vectores oficiales (`test_psl.txt`). Las 3 diferencias son a propósito: un TLD que no existe da null.
  - IDN, punycode, credenciales, IP, `javascript:`/`data:`, backslash, subdominio largo, sufijos privados, eTLD de varios niveles, `bookinq.com` y `b00king.com`: todos se rechazan.
  - **Regresión nueva (P3, A2-F1):** con un punto final (`https://www.google.com./url?q=https://evil.io`) un dominio de proveedor salta la regla "solo con sus reglas estrictas" y entra como `trusted_source`. En `06865cb` se marcaba `dominio_sospechoso`. Por el catálogo curado sale **firmado** por booking-go con t=s (A2-06).
- **Pruebas de este grupo:**
  - Vitest 136/136, igual que lo documentado.
  - SQL `bridge`: sin la migración, 41 OK / 1 FALLA (AUD04-6); con ella, 42 OK / 0 FALLA. Coincide con lo documentado.
  - `deno check` de booking-go, booking-bridge y booking-links-cron: exit 0 los tres.
- **Mutaciones obligatorias:** 10 de 11 hacen fallar al menos una prueba. La comparación de firma **no constante** (M1a) no la detecta ninguna, y no puede: es un cambio de tiempo, no de resultado. La revisé en el código y sí es de tiempo constante.
- **Defectos nuevos:** 1 P2 (A2-01), 4 P3 (A2-F1, A2-F2, A2-F3, A2-T1) y 3 observaciones de endurecimiento.

## 1. Tabla por hallazgo

| AUD | Defecto original | Código corregido (archivo:línea) | Test exacto | ¿Fallaba antes? | ¿Pasa ahora? | Caso nuevo intentado | Resultado | Veredicto |
|---|---|---|---|---|---|---|---|---|
| AUD-04a token atado al destino | booking-go redirigía a cualquier destino guardado que pasara `checkTrustedSource` (`06865cb` `booking-go/go.ts:30`; claims sin huella `redirectToken.ts:28`) | `_shared/booking/redirectToken.ts:32,35-37,44,69`; `booking-go/go.ts:109-110`; `booking-bridge/index.ts:109-111` | `bookingBridgeAudit.test.ts` › "booking-go: el token queda atado…" (6 casos) | Sí: 5 de 6 ✗ contra `06865cb` (solo "destino intacto" ✓) | Sí | Firma con un carácter cambiado en 7 posiciones; `u` cambiado a otro usuario (A2-05); reúso del token (A2-04) | Rechaza firma o usuario alterados. **El token se puede reusar** dentro de los 30 min (3 salidas, `redirect_count=3`) | **VERIFICADO INDEPENDIENTEMENTE** (con la observación A2-T1, P3) |
| AUD-04b redirect opaco firmado | IA o cliente colaban `google.com/aclk`, que se firmaba (`06865cb` `resolver.ts:127`, `handler.ts:262`) | `allowlist.ts:27,258,272-276`; `resolver.ts:125-135`; `handler.ts:195-200` | E2E "el cliente no puede hacer que booking-go firme un redirect de anuncios"; unidad "lo que escribió la IA o mandó el cliente…" | Sí (E2E portado al arnés viejo: 4 ✗ / 24 ✓) | Sí | **Mismo `aclk` / `/travel/clk` puesto por un colaborador en `restaurantes_json` con `fuente: "google_places"`** | **FALLA**: etiqueta "Sitio oficial", `verified_at` presente, `go_url` firmado, booking-go devuelve `302 → https://www.google.com/aclk?…adurl=https%3A%2F%2Fevil.io%2Fpago` | **PARCIALMENTE CUBIERTO** (solo cubre `ai`/`client`; ver A2-01) |
| AUD-04c colaborador → "Sitio oficial" falso | Sitio de phishing del colaborador visto como oficial | `resolver.ts:142-144,190,206-208`; `offers.ts:411-417` | E2E "un sitio fuera de la lista blanca que viene del viaje…" | Sí | Sí | El mismo, con un dominio que pasa la lista estricta (`aclk`) en vez de uno desconocido | **FALLA**: `editableTripData` solo marca "sin verificar" si `v.trust === "trusted_source"`. Con un `allowlist` sale "Sitio oficial" | **PARCIALMENTE CUBIERTO** (A2-01) |
| AUD-04d salida al destino de otra acción | Con una intención viva, otra acción llevaba al destino anterior | `handler.ts:316-333` | E2E "si ya hay una intención viva…" | Sí | Sí | Mutación M5 (quitar la comparación de huella) | 2 pruebas fallan | **VERIFICADO INDEPENDIENTEMENTE** |
| AUD-04e cambio de destino sin rastro | El historial no registraba cambios de `target_url` | `supabase/migrations/20261024070000_aud_bridge_target_trace.sql:11-31` | `supabase/tests/bridge/bridge.sql` AUD04-6 | Sí (base sin la migración: 41 OK / 1 FALLA AUD04-6) | Sí (42 OK / 0 FALLA) | Revisión: si cambian estado **y** destino a la vez, se registra el evento pero sin la nota "Destino: A → B" | No explotable hoy: handler.ts:323 alinea sin cambiar estado | **VERIFICADO INDEPENDIENTEMENTE** |
| AUD-04f/g/h `localhost.`, TLD falso, `%2F`, saltos http en el cron | `06865cb` `allowlist.ts:106-112` (registrable de 2 etiquetas); `linkcheck.ts:74` | `allowlist.ts:188-192,245,257`; `linkcheck.ts:76-80` | "esquemas, credenciales, IPs…", "rutas de google.com…", "booking-links-cron no sigue saltos…" | Sí | Sí | `%2e` (rechazado), `%252e%252e%252f` doble codificado (pasa), y **robots.txt pedido con `redirect:"follow"`** | El doble codificado pasa (sin efecto salvo que el proveedor decodifique dos veces). robots.txt **sí sigue** saltos sin revisarlos (A2-F3) | **PARCIALMENTE CUBIERTO** (A2-F3, P3) |
| AUD-04j `target=_blank` sin `rel` | Reverse tabnabbing | `src/lib/externalLinks.ts:36-44` | `externalLinks.test.ts` (4) | No se puede ejecutar: `src/lib/externalLinks.ts` no existe en `06865cb` (import falla) | Sí (4/4) | `javascript:`, `data:`, `tel:`, `download` | Correcto | **CORREGIDO PERO NO VERIFICADO** antes/después (función nueva). Comportamiento actual correcto |
| AUD-07 dominio registrable y phishing | "Últimas 2 etiquetas" (`06865cb` `allowlist.ts:106-112`); detector por subcadena (`:153-159`) | `_shared/booking/psl.ts:29-66`; `psl_data.ts` (fijada); `allowlist.ts:196-242` | Bloque "AUD-07" de `bookingBridgeAudit.test.ts` (9) | Sí: 8 ✗ / 1 ✓ contra `06865cb` | Sí | Los 15 tipos de caso del brief (sección 2); vectores oficiales; regeneración de la PSL | Pasan todos menos **punto final en dominio de proveedor** (A2-F1, regresión) y 7 falsos negativos del detector (A2-F2) | **PARCIALMENTE CUBIERTO** |
| AUD-07 PSL auténtica | No había PSL | `psl_data.ts:5-9,13` | "la copia de la PSL está fijada" (solo comprueba el **formato** del encabezado) | Sí (el archivo no existía) | Sí | Descarga de publicsuffix.org (solo lectura) y regeneración con su script | SHA-256 `8228e4bd…0755` = el de la lista oficial de hoy (VERSION 2026-10-20_08-40-56_UTC, COMMIT 5dd321ff…). Regenerada: **idéntica byte a byte**. Vectores oficiales: 74/77 (3 diferencias a propósito) | **VERIFICADO INDEPENDIENTEMENTE** |

## 2. Casos nuevos de AUD-07 pedidos en el brief (resultado con 7670102)

Pruebas en `codigo/src/test/a2_aud07Adversarial.test.ts`. Cada caso se pasó por `checkAllowlisted`, `checkUntrusted` y `checkTrustedSource`.

| Caso | Entrada | Resultado |
|---|---|---|
| IDN cirílico | `https://www.bookіng.com/` (і cirílica), `https://www.аirbnb.com/` | Pasa a `xn--…`; rechazado (`dominio_sospechoso` en la vía confiable) ✓ |
| "ı" sin punto | `https://bookıng.com/` | Queda `xn--bookng-s9a.com`; rechazado ✓ |
| Punycode mixto | `https://xn--bookng-9wa.com/`, `https://www.xn--bking-gra.com/` | Rechazado ✓ |
| Punto final | `https://www.booking.com./` | Estricta ✗ y confiable ✓ (es el mismo booking.com) |
| Punto final en proveedor | `https://www.google.com./url?q=https://evil.io`, `…/aclk?adurl=`, `https://tp.media./click?u=https://evil.io` | **Aceptado como `trusted_source`** ✗ (A2-F1) |
| Mayúsculas | `https://WWW.BOOKING.COM:443/` | Normaliza a `https://www.booking.com/` ✓ |
| Credenciales | `https://booking.com@evil.io/` | `credenciales_en_url` ✓ |
| Puerto | `:8443` | `puerto` ✓ (`:443` se normaliza) |
| IP decimal, octal, hex | `3232235521`, `0300.0250.0.1`, `0xC0A80001` | `host_no_publico` ✓ |
| `javascript:` / `data:` | también en mayúsculas mezcladas | `no_https` ✓ |
| `%2e` | `/maps/%2e%2e/url?q=…` | Rechazado ✓ |
| Doble codificación | `/maps/%252e%252e%252furl?q=…` | **Pasa** (observación O2) |
| Backslash | `https://evil.io\@booking.com` | `caracteres_invalidos` ✓ |
| Subdominio largo | `booking.com.evil.io`, `opentable.com.mx.evil.io` | `dominio_sospechoso` ✓. `booking.com.evil.test`: `host_no_publico` (`.test` no está en la PSL) |
| Sufijos privados | `booking.github.io`, `bookingcom.blogspot.com` | El registrable es el propio subdominio; detectado ✓ |
| eTLD de varios niveles | `a.b.example.com.mx` → `example.com.mx`; `a.b.co.uk` → `b.co.uk` | ✓ |
| Marca recién registrada | `bookinq.com`, `b00king.com`, `boooking.com`, `bokking.com`, `booklng.com`, `0pentable.com` | Detectados ✓ |
| Falsos negativos del detector | `air-bnb.com`, `vlator.com`, `reesy.com`, `resyy.com`, `googIe.com` (→ `googie.com`), `deltaairlines-mx.com`, `tp-media.com` | **No detectados** (A2-F2) |

Contra `06865cb`, 3 de los 4 grupos de casos "resistentes" fallan, así que el arreglo sí mejoró. El punto final en `google.com.` **pasaba la prueba en el código viejo** (lo marcaba `dominio_sospechoso`). Es una regresión.

## 3. Defectos nuevos

### A2-01 · P2 · Un redirect opaco de Google puesto por un colaborador sale firmado por IATOS como "Sitio oficial"
- **Entrada reproducible**:
  1. Un colaborador aceptado (rol editor) hace UPDATE de `trips.restaurantes_json = [{"nombre":"Sobrino de Botín","fuente":"google_places","place_id":"ChIJx","website":"https://www.google.com/aclk?sa=l&ai=x&adurl=https%3A%2F%2Fevil.io%2Fpago"}]`. Lo probé en SQL real: `/home/user/audit2/bridge/a2_collab.sql` respondió `A2-SQL colaborador SÍ escribió website=aclk y fuente=google_places`, porque `trips_collab_columns_guard` lo permite.
  2. El dueño abre la opción: `resolve` devuelve `official_website` con `label: "Sitio oficial"`, `verified_at: "2026-10-22T10:00:00Z"`, sin aviso de "no verificado" y con `processor` "Google Hotels".
  3. `start_booking` devuelve un `go_url` firmado (t=a), y `resolveGo` responde `302 → https://www.google.com/aclk?sa=l&ai=x&adurl=https%3A%2F%2Fevil.io%2Fpago`, `reason: ok`.
  4. Pasa lo mismo con `https://www.google.com/travel/clk/f?pcurl=…` (A2-02).

  Quien compra un anuncio de Google obtiene un `aclk` válido que lleva a su dominio. Es el mismo caso de "lavado" de AUD-04b, ahora por el camino de AUD-04c.
- **Código vulnerable (7670102)**:
  - `supabase/functions/_shared/booking/resolver.ts:125`: `UNTRUSTED = ["ai","client"]` no incluye `google_places`, así que `check()` usa `checkTrustedSource`, que acepta `aclk` por la lista estricta.
  - `resolver.ts:142-144`: `editableTripData` exige `v.trust === "trusted_source"`, y un `allowlist` no se marca "sin verificar".
  - `supabase/functions/booking-bridge/handler.ts:197`: `signTier` usa `checkAllowlisted` (no `checkUntrusted`) para `google_places`.
  - En `06865cb` también pasaba (`resolver.ts:127`, `handler.ts:262`): el defecto no se cerró.
- **Prueba**: `/home/user/audit2/bridge/codigo/src/test/a2_bridgeE2EAdversarial.test.ts` › A2-01, A2-02. Fallan con 7670102 y pasan con el diff propuesto.
- **Corrección propuesta**: `/home/user/audit2/bridge/fix_propuesto/fix.diff`. Con ella, las 136 pruebas del bridge y los A2-01/02/03/06 pasan (164/165; la única que falla es A2-F2, que es heurística).

```diff
--- supabase/functions/_shared/booking/resolver.ts
-  const v = untrusted ? checkUntrusted(c.url) : checkTrustedSource(c.url);
+  let v = untrusted ? checkUntrusted(c.url) : checkTrustedSource(c.url);
+  // Un dato editable del viaje (google_places) tampoco puede salir por un redirect opaco.
+  if (c.trust === "google_places" && v.ok && v.provider?.redirector === "opaque") v = { ok: false, reason: "redirect_sin_destino_visible" };
@@ function editableTripData
-  return v.ok && v.trust === "trusted_source" && c.trust === "google_places";
+  return v.ok && c.trust === "google_places";
--- supabase/functions/booking-bridge/handler.ts (signTier)
-  if ((trust === "ai" || trust === "client" ? checkUntrusted(url) : checkAllowlisted(url)).ok) return "allowlist";
+  if ((trust === "ai" || trust === "client" || trust === "google_places" ? checkUntrusted(url) : checkAllowlisted(url)).ok) return "allowlist";
```

### A2-F1 · P3 (regresión de AUD-07) · El punto final en un dominio de proveedor salta la regla "proveedor solo con reglas estrictas"
- **Entrada**:
  - `checkTrustedSource("https://www.google.com./url?q=https://evil.io")` devuelve `ok:trusted_source`.
  - `checkTrustedSource("https://tp.media./click?u=https://evil.io")`: lo mismo, y el destino `u` nunca se revisa.
  - `checkTrustedSource("https://www.google.com./aclk?adurl=…")`: lo mismo.
  - En `06865cb`, las dos de google.com daban `dominio_sospechoso`. La de tp.media ya pasaba antes.
- **Causa**:
  - `allowlist.ts:300` compara `hostMatches(host, p.domain)` con el host **con** punto final (no coincide).
  - Después, `looksLikeBrandImpersonation` (`allowlist.ts:218-220`) normaliza con `asciiHost`, que **quita** el punto (`psl.ts:37`), ve "google.com" como proveedor real y devuelve false ("no imita"). `basicCheck` (`allowlist.ts:187-192`) no rechaza el punto final, salvo en `localhost.`.
- **Impacto demostrado**:
  - A2-06: un `booking_url` del catálogo curado con `https://www.google.com./url?q=…` sale **firmado** (t=s), y booking-go devuelve `302 → https://www.google.com./url?q=https%3A%2F%2Fevil.io%2Fpago`.
  - A2-03: por `google_places` (colaborador) sale como "Sitio web del lugar (sin verificar)", con el aviso "revisa que www.google.com. sea el sitio del lugar". Ese texto hace parecer confiable un redirect.
- **Prueba**: `codigo/src/test/a2_aud07Adversarial.test.ts` › A2-F1; `a2_bridgeE2EAdversarial.test.ts` › A2-03, A2-06.
- **Corrección** (incluida en `fix.diff`): en `basicCheck`, `if (host.endsWith(".")) return { ok: false, reason: "host_no_publico" };`. Otra opción: comparar `PROVIDERS` contra `asciiHost(host)` en `checkTrustedSource:300`.

### A2-F2 · P3 · Falsos negativos del detector de marcas (heurístico)
- `air-bnb.com`, `vlator.com` (l por i en una marca de 6 letras), `reesy.com`, `resyy.com`, `googIe.com`, `deltaairlines-mx.com` y `tp-media.com` pasan como "fuente confiable".
- Causas: la distancia de edición solo aplica a marcas de 7 letras o más (`allowlist.ts:238`); `1→l/i` no incluye `l→i` (`:197-199`); los guiones dentro de la marca no se quitan; las marcas "token" solo cuentan como palabra completa.
- El riesgo ya está declarado ("el detector es heurístico"), y solo afecta a datos del catálogo, del escaneo y de `google_places`.
- **Prueba**: `a2_aud07Adversarial.test.ts` › A2-F2.
- **Corrección**: comparar también el esqueleto sin guiones (`label.replace(/-/g,"")`), agregar `l→i` e `I→l` a los esqueletos, y usar distancia 1 para marcas de 5 letras o más con la misma inicial (validarlo contra la lista de sitios reales de las pruebas).

### A2-F3 · P3 · booking-links-cron pide robots.txt siguiendo redirecciones sin revisarlas
- `supabase/functions/booking-links-cron/linkcheck.ts:62` hace `doFetch(<origin>/robots.txt, { redirect: "follow" })`. Si un sitio del catálogo redirige robots.txt a `http://…`, a una IP o a un host interno, el cron lo pide.
- Esto contradice AUD-04h ("tampoco se sigue un salto a http, a una IP o a un host interno"). La respuesta solo decide permitir o negar, así que el impacto es una petición ciega.
- **Prueba**: `a2_aud07Adversarial.test.ts` › A2-F3 (registra `{"u":"https://quintonil.com/robots.txt","redirect":"follow"}`).
- **Corrección**: `redirect: "manual"` y, si llega un 3xx, tratar robots.txt como ausente (o seguirlo con el mismo lazo que valida con `checkTrustedSource` + el mismo registrable).

### A2-T1 · P3 · El token de booking-go no es de un solo uso
- Durante 30 minutos, el mismo `go_url` redirige las veces que se quiera (A2-04: `ok ok ok`, `redirect_count=3`). booking-go acepta `REDIRECTED_TO_PROVIDER` en `index.ts:142` y en el RPC.
- Es un token al portador: no lleva sesión, por diseño, porque booking-go tiene `verify_jwt=false`. Además lleva en base64 los UUID de la intención y del usuario.
- El impacto es bajo: el destino es el legítimo y está firmado. Solo infla `redirect_count` y expone el UUID del usuario a quien vea el enlace.
- **Corrección**: si se quiere uso único, agregar un `jti` y marcarlo como usado en `booking_intent_mark_redirected` (permitir HEAD sin consumirlo). Y/o firmar un identificador opaco en lugar de `u` en claro.

### Observaciones de endurecimiento (sin explotación demostrada)
- **O1**: `providerFor` acepta **cualquier subdominio** de google.com para `/maps`, `/travel/*` y `/aclk` (p. ej. `https://sites.google.com/maps/x` pasa como Google Maps). Conviene restringirlo a `www.google.com` y `maps.google.com`.
- **O2**: `ENCODED_PATH_TRICK` (`allowlist.ts:245`) no detecta la doble codificación `%252e`/`%252f`.
- **O3**: los proveedores sin `paths` (booking.com, omio.com, aerolíneas, wa.me…) aceptan cualquier ruta. Un open redirect propio del proveedor no se detecta.

  **Qué pasa si el proveedor redirige a otro lado:** booking-go no hace `fetch`, solo responde un 302. Los saltos posteriores los sigue el navegador y IATOS no los controla.
  - tp.media nunca queda como destino guardado: `resolver.ts:133` lo desenvuelve, y `u` duplicado (`?u=booking&u=evil`) se resuelve al primero, de forma coherente.
  - El riesgo restante es el `aclk` de A2-01.

## 4. Pruebas insuficientes o engañosas (mutaciones en mi copia; restauradas y comprobadas con `cmp` contra base)

Runner: `/home/user/audit2/bridge/mutaciones/run_mut.py`. Salida: `/home/user/audit2/bridge/mutaciones/resultados_mutaciones.txt`. Corre 6 archivos y 130 pruebas: bookingBridgeAudit, bookingBridge, bookingBridgeE2E, bookingLinkCheck, externalLinks y affiliateLinks.

| Mutación | Archivo | Pruebas que fallan | Lectura |
|---|---|---|---|
| M1a comparación de firma **no constante** (`expected !== given`) | redirectToken.ts:59-61 | **0** | Ninguna prueba funcional puede verlo. El código revisado sí es de tiempo constante (XOR sobre los 43 caracteres canónicos, `:59-60`). Un cambio a `!==` no lo detectaría nada |
| M1b firma ignorada | redirectToken.ts:61 | 3 | Detectada |
| M1c solo 8 caracteres de firma | redirectToken.ts:60 | 3 | Detectada |
| M2 sin caducidad | redirectToken.ts:70 | 2 | Detectada |
| M2b TTL de un año | redirectToken.ts:12 | 2 | Detectada |
| M3a `hostMatches` con `endsWith(domain)` sin punto | allowlist.ts:157 | 1 | Detectada por **una sola** aserción (`evil-booking.com`). Ninguna prueba estricta prueba `evilbooking.com` / `notbooking.com` con `checkAllowlisted` |
| M3b cron con `endsWith(últimas 2 etiquetas)` | linkcheck.ts:76 | 1 | Detectada (wixsite) |
| M3c registrable = 2 etiquetas | psl.ts:65 | 5 | Detectada |
| M4a sin normalización IDN en `asciiHost` | psl.ts:33 | 1 | Detectada solo por `www.bücher.de`. En la ruta real, `basicCheck` ya normaliza con el parser WHATWG |
| M4b sin chequeo `xn--` | allowlist.ts:224 | 2 | Detectada |
| M5 sin comparar la huella en booking-go | go.ts:109 | 2 | Detectada |

Otras debilidades de las pruebas:
- "la copia de la PSL está fijada" solo comprueba que el encabezado **tenga** VERSION/COMMIT/SHA256 con el formato correcto. No comprueba que las reglas correspondan a esa lista. Lo comprobé aparte (sección 1). Recomiendo que la prueba recalcule el hash de las reglas o compare contra vectores oficiales (`a2_pslOfficial.test.ts`).
- `bookingBridgeE2E.test.ts` es una simulación en memoria (ya reconocido como CAL-03). Las reglas de `booking_intents` sí están en `bridge.sql` (42 casos reales).
- Ninguna prueba combina una fuente editable (`google_places`) con una URL de la lista estricta (A2-01), ni el punto final en un dominio de proveedor (A2-F1).

## 5. Discrepancias entre documentación y código

1. **`BRIDGE.md` AUD-04c** dice "sigue sin firmarse en booking-go (se abre directo)" para sitios que vienen del viaje. Es **falso** cuando la URL pasa la lista estricta: `aclk` y `/travel/clk` salen firmados y como "Sitio oficial" (A2-01).
2. **`BRIDGE.md` AUD-04b** y la sección 2 del documento de cierre presentan el lavado por redirect opaco como VERIFICADO. Solo está cerrado para `trust` `ai` y `client`.
3. **`BRIDGE.md` AUD-04h** y el comentario de `linkcheck.ts:77` dicen que no se piden saltos a http/IP/internos. robots.txt sí los sigue (A2-F3).
4. **`allowlist.ts:298-300`** dice que un dominio de proveedor "solo vale con sus reglas estrictas". No se cumple con el punto final (A2-F1).
5. Conteo "antes": `BRIDGE.md` dice que `bookingBridgeAudit` + `externalLinks` daban **18 ✗ / 7 ✓** contra `f62466e`. Contra `06865cb` (el commit auditado) medí `bookingBridgeAudit` **17 ✗ / 4 ✓**, y `externalLinks.test.ts` **no carga** (el módulo no existe). La diferencia se explica porque `f62466e` es un commit posterior. E2E portado al arnés viejo: **4 ✗ / 24 ✓**, igual que lo documentado.
6. La sección 4 del documento de cierre dice que la credencial en URL, IP, CRLF y los homógrafos están refutados. Lo confirmé. "Token… de otro usuario" también (A2-05).

## 6. Comandos ejecutados y salidas

```
# Código viejo
mkdir -p /home/user/audit2/bridge-old && git -C /home/user/wanderly-ai-concierge archive 06865cb | tar -x -C /home/user/audit2/bridge-old
ln -sfn /home/user/wanderly-ai-concierge/node_modules /home/user/audit2/bridge-old/node_modules

# Vitest (7670102)
cd /home/user/audit2/bridge/codigo && npx vitest run src/test/bookingBridgeAudit.test.ts src/test/bookingBridge.test.ts \
  src/test/bookingBridgeE2E.test.ts src/test/bookingLinkCheck.test.ts src/test/bookingActionsUi.test.tsx \
  src/test/externalLinks.test.ts src/test/affiliateLinks.test.ts --testTimeout=60000
→ 7 archivos, 136/136 ✓ (Audit 21, Bridge 67, E2E 28, LinkCheck 6, ActionsUi 6, externalLinks 4, affiliateLinks 4)

# Pruebas nuevas contra 06865cb (copiadas como src/test/a2_*.test.ts en bridge-old)
→ a2_bookingBridgeAudit: 21 pruebas, 17 ✗ / 4 ✓; a2_externalLinks: no carga (falta @/lib/externalLinks)
→ a2_E2E_port (E2E viejo + 4 AUD-04 nuevas): 4 ✗ / 24 ✓

# Pruebas adversariales nuevas (7670102)
npx vitest run src/test/a2_aud07Adversarial.test.ts src/test/a2_bridgeE2EAdversarial.test.ts src/test/a2_pslOfficial.test.ts
→ 38 pruebas: 31 ✓ / 7 ✗ (A2-F1, A2-F2, A2-F3, A2-01, A2-02, A2-03, A2-06 = defectos)
→ con fix.diff aplicado (luego revertido): 164/165 ✓ (solo A2-F2, heurística)

# SQL (Postgres 16 local, /tmp/pgsec:55440)
su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash supabase/tests/bridge/run.sh a2bridge_after"  → 42 OK, 0 FALLA
# base sin 20261024070000 (copia en /home/user/audit2/bridge/sql_before)
su postgres -c "PGHOST=/tmp/pgsec PGPORT=55440 bash /home/user/audit2/bridge/sql_before/tests/bridge/run.sh a2bridge_before"
→ 41 OK, 1 FALLA (AUD04-6 … ∅→READY_TO_BOOK | READY_TO_BOOK→REDIRECTED_TO_PROVIDER, sin "Destino:")
psql -d a2bridge_after -f /home/user/audit2/bridge/a2_collab.sql
→ "A2-SQL colaborador SÍ escribió website=aclk y fuente=google_places en restaurantes_json"
DROP DATABASE a2bridge_after; DROP DATABASE a2bridge_before   → 0 bases a2bridge_* restantes

# Deno 2.1.4
deno check --quiet supabase/functions/{booking-go,booking-bridge,booking-links-cron}/index.ts → exit 0 los tres
# deno.lock cambió al chequear; restaurado desde base (cmp idéntico al original)

# PSL (solo lectura)
curl https://publicsuffix.org/list/public_suffix_list.dat → 200, 338010 B; VERSION 2026-10-20_08-40-56_UTC, COMMIT 5dd321ff…
sha256 → 8228e4bdac6024c058a1e67859157e468a2613b826b53de0e5cae298e1b70755 (= psl_data.ts)
node update_psl.mjs (copia con salida en el scratchpad) current.dat → cmp con psl_data.ts: IDÉNTICO
curl …/publicsuffix/list/5dd321ff…/tests/test_psl.txt → 77 vectores: 74 iguales; 3 a propósito (example.example → null)

# Mutaciones
python3 -I /home/user/audit2/bridge/mutaciones/run_mut.py <id>   (11 mutaciones, ver sección 4)
```

## 7. Archivos de esta auditoría

- `/home/user/audit2/bridge/codigo/src/test/a2_bridgeE2EAdversarial.test.ts`: A2-01…A2-06 con el handler y booking-go reales.
- `/home/user/audit2/bridge/codigo/src/test/a2_aud07Adversarial.test.ts`: los casos del brief y A2-F1, A2-F2, A2-F3.
- `/home/user/audit2/bridge/codigo/src/test/a2_pslOfficial.test.ts`: los vectores oficiales de la PSL.
- `/home/user/audit2/bridge/a2_collab.sql`: prueba SQL de que el colaborador escribe el `website`.
- `/home/user/audit2/bridge/fix_propuesto/fix.diff`: la corrección de A2-01 y A2-F1.
- `/home/user/audit2/bridge/mutaciones/`: el runner, los resultados y las salidas SQL antes/después.
- `/home/user/audit2/bridge/psl_oficial/`: `current.dat` (publicsuffix.org) y `test_psl.txt`.
