# HANDOFF LOVABLE — cierre de identidad/autorización en 3 Edge Functions

Proyecto Supabase: **wpiztubmmmzclhlprgpd** (RETO 13M).
Objetivo: cerrar acceso no autorizado en `scan-betslip`, `analizar-partido` y
`auto-calificar-picks` **sin tocar ninguna lógica de negocio** (modelo, LLM,
análisis, calificación, RONGOL, Beta/Wilson/EV/Kelly, allocator, caps).

> Regla transversal para las 3: **reconstruir y RE-DESPLEGAR la Edge Function
> completa en Supabase** (el build de Deno debe compilar; si falla, NO publicar).
> No basta con editar el archivo en el repo: hay que hacer deploy de cada función
> para que rebundlee su copia de `_shared/auth.ts`.

---

## 0) CAMBIO COMPARTIDO (base de scan-betslip y analizar-partido)

Las funciones que usan autenticación bundlean su propia copia de
`supabase/functions/_shared/auth.ts`. Ese archivo tiene la vulnerabilidad AUTH-0:
prueba el rol de servicio **decodificando** el payload del JWT (no lo valida), así
que cualquiera puede fabricar `{"role":"service_role"}` sin firma y pasar como
servicio.

### Archivo exacto
`supabase/functions/_shared/auth.ts`

### Bloque a REEMPLAZAR (actual, vulnerable)
```ts
function isServiceToken(token: string): boolean {
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  if (service && token === service) return true;
  try {
    const payload = JSON.parse(atob(token.split(".")[1]));
    return payload?.role === "service_role";
  } catch {
    return false;
  }
}
```

### Bloque nuevo (fix AUTH-0 — comparación en tiempo constante, SIN decode)
```ts
/** Comparacion en tiempo constante (evita oraculo de timing sobre la llave). */
function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

/**
 * AUTH-0. SEGURIDAD CRITICA: un service_role se prueba UNICAMENTE con la llave
 * real, comparada en tiempo constante. NUNCA decodificando el payload del JWT y
 * leyendo su 'role' (eso es DECODIFICAR, no VALIDAR, y permite fabricar
 * {"role":"service_role"} sin firma). La rama de usuario normal SI valida
 * (admin.auth.getUser server-side).
 */
function isServiceToken(token: string): boolean {
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  return service.length > 0 && timingSafeEqual(token, service);
}
```

### Qué NO se toca en `_shared/auth.ts`
- `requireCaller(...)` y `unauthorizedResponse(...)` quedan **byte-idénticos**.
- La rama de usuario (`admin.auth.getUser(token)` → busca `usuarios.apodo` por
  `user_id`) NO cambia. Un JWT de usuario real sigue pasando igual que hoy.
- El único cambio es que `isServiceToken` deja de aceptar JWTs forjados.

### Por qué es seguro (equivalencia)
El fix **preserva el comportamiento para toda credencial real**: la service key
real sigue pasando (timingSafeEqual la iguala), y un JWT de usuario real sigue
validando por getUser. Lo único que se elimina es el bypass por JWT forjado. Por
eso ningún llamador legítimo actual se rompe.

> Nota: al corregir la copia canónica del repo, también quedan protegidas
> `construir-parlay-ai` y `settle-betslip` (ya tienen el fix desplegado; esto evita
> que reviertan a la versión vulnerable en su próximo deploy).

---

## 1) scan-betslip  (IDOR de dinero, P0)

- **Versión actual:** 438 · verify_jwt=false · entrypoint
  `supabase/functions/scan-betslip/index.ts`.
- **Cambio esperado de versión:** 438 → **439** (o superior).
- **Archivos a modificar:** SOLO `supabase/functions/_shared/auth.ts`
  (el de la sección 0). **`index.ts` de scan-betslip NO se toca (byte-equivalente).**

### Por qué esto cierra el IDOR
`index.ts` decide el dueño así (línea única, se deja intacta):
```ts
const apodo = caller.isService ? body.apodo : caller.apodo;
```
Hoy `caller.isService` se puede forjar (bypass de `_shared/auth.ts`), y entonces un
atacante manda `body.apodo = "<víctima>"` y escanea/crea bajo la cuenta ajena.
Con el fix de la sección 0, `caller.isService` es `true` **solo** para quien posee
la service key real (llamadores internos de confianza). Un usuario final del
frontend siempre entra por la rama `caller.apodo` (su propio apodo del JWT). IDOR
cerrado **sin cambiar `index.ts`**.

### Diff mínimo exacto
El de la sección 0 (en `_shared/auth.ts`). Nada más.

### Lógica de negocio que NO se toca
Todo scan-betslip salvo la resolución de identidad: OCR, parsing del boleto,
ligas_master, ESPN, cálculo de patas/momios, inserts de picks/parlays, RONGOL,
ruta de ledger, llamadas salientes. `index.ts` queda **byte a byte** igual.

### Callers legítimos (verificados, compatibles)
- Frontend: `SmartUploadButton.tsx` (invoke con JWT de usuario) → rama de usuario,
  sin cambio.
- Internos que lo referencian (`run_health_check`, etc.): si mandan service key
  real, pasan; si no, ya recibían 401 hoy. El fix no rompe ninguno.

---

## 2) analizar-partido  (abuso de costo: corre el LLM)

- **Versión actual:** 496 · verify_jwt=false · entrypoint
  `supabase/functions/analizar-partido/index.ts`.
- **Cambio esperado de versión:** 496 → **497** (o superior).
- **Archivos a modificar:** SOLO `supabase/functions/_shared/auth.ts`
  (el de la sección 0). **`index.ts` de analizar-partido NO se toca.**

### Por qué esto cierra el abuso
`index.ts` ya está gateado con:
```ts
await requireCaller(req, { requireApodo: false });
```
No hay IDOR (0 usos de `caller.apodo`/`caller.isService` en la lógica). El agujero
es que hoy un JWT forjado pasa el gate y dispara el LLM (costo). Con el fix de la
sección 0, el forjado ya no pasa: quedan solo service key real y usuarios
autenticados reales (el frontend `ParlayCard.tsx` lo llama con JWT de usuario, y
sigue funcionando por `requireApodo:false`).

### Diff mínimo exacto
El de la sección 0 (en `_shared/auth.ts`). Nada más.

### Lógica de negocio que NO se toca
System prompt, modelo, llamadas al LLM (`callAI`), medidor `af-meter.ts`,
análisis, escritura de resultados. Cero cambios de contenido.

### Callers legítimos (verificados, compatibles)
- DB (service key real): `disparar_reanalisis_prepartido`,
  `reanalizar_analisis_vacios`, `trigger_analizar_partido_async` → pasan.
- Frontend `ParlayCard.tsx` (JWT de usuario) → pasa (requireApodo:false).

> Residual conocido (NO en alcance de este handoff): analizar-partido sigue siendo
> disparable por cualquier usuario autenticado (por diseño actual `requireApodo:false`).
> Restringirlo a solo-servicio sería un cambio de contrato/lógica y va aparte.

---

## 3) auto-calificar-picks  (grader ABIERTO — decisión del auditor: AUTHENTICATED_ONLY)

- **Versión actual:** 424 · verify_jwt=false · entrypoint
  `supabase/functions/auto-calificar-picks/index.ts`.
- **Cambio esperado de versión:** 424 → **425** (o superior).
- **Archivos a modificar:** `supabase/functions/auto-calificar-picks/index.ts`
  (agregar 1 import + 1 gate). Usa la copia corregida de `_shared/auth.ts`
  (sección 0). **No se toca ninguna lógica de calificación.**

### Hallazgo que define el candado
La función hoy NO tiene gate (grader abierto a internet). Pero **3 pantallas
autenticadas del frontend la invocan con el JWT del usuario**:
`AddPickForm.tsx:771`, `Historial.tsx:942`, `ParlayCard.tsx:519`
(`supabase.functions.invoke("auto-calificar-picks", ...)`). Un candado
"solo service key" las rompería (401). Decisión del auditor: **AUTHENTICATED_ONLY**
= acepta service key real **O** un JWT de usuario válido. Cierra el acceso
anónimo/forjado (abuso de costo + correos) y mantiene los 3 botones "calificar
ahora" funcionando. Cero cambios de frontend.

### Diff mínimo exacto (2 inserciones)

**(a) Import — agregar junto a los imports de arriba del archivo:**
```ts
import { requireCaller, unauthorizedResponse } from "../_shared/auth.ts";
```

**(b) Gate — insertarlo INMEDIATAMENTE después del bloque OPTIONS y ANTES de
`const startTime = Date.now();`.**

Contexto actual (se conserva tal cual):
```ts
serve(async (req) => {
  armAfReportAuto("auto-calificar-picks");
  afSinPresupuesto = false; // los aislados tibios reutilizan las globales
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startTime = Date.now();
```

Queda así (solo se añade el bloque del gate):
```ts
serve(async (req) => {
  armAfReportAuto("auto-calificar-picks");
  afSinPresupuesto = false; // los aislados tibios reutilizan las globales
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  // AUTHENTICATED_ONLY: exige service role key real O un JWT de usuario valido.
  // Cierra el grader abierto a internet sin romper los invoke del frontend.
  // NO cambia la logica de calificacion.
  try {
    await requireCaller(req, { requireApodo: false });
  } catch {
    return unauthorizedResponse(corsHeaders);
  }

  const startTime = Date.now();
```

### Lógica de negocio que NO se toca
Todo lo de calificación: carga de `ligas_master`, resolución de partidos, ESPN,
cálculo de resultados/grades, escritura de picks/parlays, correos Resend, timeouts,
`MAX_PICKS`. Solo se añade el gate de entrada.

### Callers legítimos (compatibles con AUTHENTICATED_ONLY)
- Frontend autenticado: AddPickForm, Historial, ParlayCard (JWT de usuario) → pasan.
- Edge→edge con cliente de service key (p.ej. `crear-parlay-screenshot`,
  health-check) → pasan.
- Sin credenciales / JWT forjado / anónimo → **401** (era el agujero).

> ANTES de desplegar: confirmar en el repo (frontend `src/` + edge) que no exista
> ningún llamador que invoque esta función SIN sesión (anónimo). Con AUTHENTICATED_ONLY
> ese caso pasa a 401 por diseño.

---

## PRUEBAS POST-DEPLOY (exactas, medidas — mismas para verificar identidad)

Para cada función, contra
`https://wpiztubmmmzclhlprgpd.supabase.co/functions/v1/<slug>`:

| # | Caso | Cómo | Resultado esperado |
|---|---|---|---|
| A | Sin credenciales | POST sin header `Authorization` | **401** |
| B | JWT forjado service_role | `Authorization: Bearer <TOKEN_FORJADO>` (abajo) | **401** (antes: pasaba) |
| C | Service key real | `Authorization: Bearer <SUPABASE_SERVICE_ROLE_KEY>` | **pasa el gate** (llega a la lógica; 200 o 400 por body faltante — NO 401) |
| D | Usuario real (JWT) | `Authorization: Bearer <access_token de usuario>` | scan-betslip/analizar-partido/auto-calificar-picks: **pasa** (no 401) |

Extra específicas:
- **scan-betslip (IDOR):** con JWT de usuario A y `body.apodo = "<apodo de B>"` →
  el escaneo/creación debe usar el apodo de **A**, nunca el de B. Verificar en BD
  que no se creó/afectó nada bajo B.
- **auto-calificar-picks:** repetir caso A (sin sesión) → **401**; caso D (usuario
  logueado) → pasa (los 3 botones del frontend siguen calificando).

**TOKEN_FORJADO para el caso B (JWT service_role sin firma válida):**
```
eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaXNzIjoiZm9yZ2VkIiwic3ViIjoiYXR0YWNrZXIifQ.ZmFrZV9zaWduYXR1cmU
```

### Versiones esperadas tras deploy
- scan-betslip: 438 → 439+
- analizar-partido: 496 → 497+
- auto-calificar-picks: 424 → 425+

---

## Checklist de cierre (para marcar IDENTIDAD_ECONOMICA_SEGURA = PASS)
- [ ] `_shared/auth.ts` corregido (timingSafeEqual, sin decode).
- [ ] scan-betslip redeploy · caso B = 401 · IDOR A→B = no afecta a B.
- [ ] analizar-partido redeploy · caso B = 401 · DB callers y ParlayCard siguen OK.
- [ ] auto-calificar-picks redeploy (AUTHENTICATED_ONLY) · caso A = 401 · 3 botones OK.
- [ ] Matriz A/B/C/D verde en las 3.
