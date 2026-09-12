# AUTH-0 — Handoff de remediación (pipeline del auditor)

**Fecha:** 6-sep-2026. **Severidad:** P0 sistémico. Decisión: aplica el fix por
tu pipeline (Lovable/Supabase), donde vive el código real de las Edge Functions.
Yo verifico AUTH-0B en cada una cuando publiques.

## Qué reemplazar
Archivo: `supabase/functions/_shared/auth.ts`
Reemplaza `isServiceToken` por la versión de `security/_shared_auth.FIXED.ts`
(agrega `timingSafeEqual` y **elimina** la rama que decodifica el JWT).

Diff conceptual (3 líneas que importan):
```
- if (service && token === service) return true;
- try { const p = JSON.parse(atob(token.split(".")[1])); return p?.role === "service_role"; } catch { return false; }
+ return service.length > 0 && timingSafeEqual(token, service);
```
La rama de usuario NO cambia (`admin.auth.getUser` ya valida server-side).

## ORDEN CRÍTICO (no invertir)
1. Aplica el fix a `_shared/auth.ts` en el source PRIMERO.
2. Redeploya. Si redeployas CUALQUIER consumidor con el source viejo,
   **revierte** el arreglo (cada función empaqueta su propia copia).
   En particular `live-day-dashboard` ya está corregida en prod (v19) por MCP:
   si tu pipeline la redeploya con el `_shared/auth.ts` viejo, la vuelve a abrir.

## Qué redeployar
TODA función que haga `import ... from "../_shared/auth.ts"`.
Consumidores confirmados en el barrido hasta ahora:
- live-day-dashboard  (ya v19; re-mirror del source de todos modos)
- construir-parlay-ai  (explotable: isService?body.apodo)
- settle-betslip       (explotable: salta check de propiedad)
- scan-betslip         (explotable: isService?body.apodo)
- analizar-partido     (bundlea auth; uso por confirmar)
- auto-calificar-picks (bundlea auth; grader)
La forma segura: redeploya el proyecto completo tras el fix del source.

## Verificación (yo la corro cuando publiques)
Por cada función, con un JWT falso `alg:none` `{"role":"service_role"}` sin firma:
- AUTH-0B  -> debe dar 401 (hoy daba 200/paso).
- Servicio real (llave) -> 200.
- Usuario real + su apodo -> 200 propio; + apodo ajeno -> rechazo/ignora.

## Fixes SEPARADOS (no dependen de auth.ts; también por tu pipeline)
- `crear-parlay-screenshot` (P1-AUTHZ, write): verify_jwt=true pero inserta parlay
  con `body.apodo` sin validar contra el JWT. Debe resolver identidad por
  auth.uid()/requireCaller y NO confiar en body.apodo.
- `get-parlay-with-scores` (P0-READ, gated por uuid): verify_jwt=false, `apodo`
  del cuerpo sin auth. Debe exigir sesión y derivar apodo del JWT.
