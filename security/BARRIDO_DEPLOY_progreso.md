# Barrido de despliegue por MCP — progreso medido (opción 2)

Fecha: 6-sep-2026. Canal: Claude despliega los fixes por MCP, función por función,
con verificación inmediata después de cada deploy. Todas las pruebas son MEDIDAS
(HTTP real vía `net.http_post` desde Postgres), no argumentadas.

Principio del guard "solo interno" (SNIPPET A): `timingSafeEqual(token, SUPABASE_SERVICE_ROLE_KEY)`.
NUNCA se decodifica el `role` de un JWT. Medido: `public.sk()` == vault
`service_role_key` == env `SUPABASE_SERVICE_ROLE_KEY` (los 3, 41 chars, formato
`sb_secret_`), por eso los llamadores internos siguen pasando.

## Protocolo proporcional al riesgo

- función pequeña → inventario de callers + diff/deploy + test (sin-cred 401, JWT
  falso service 401, service real pasa).
- función grande que toca datos económicos → inventario de callers (probar que los
  legítimos usan service key real; si hay consumidor user-facing/authenticated, PARAR)
  → prueba de equivalencia exacta (deployado menos los 2 bloques == fuente previa)
  → exploit test → smoke no destructivo → confirmar que ningún dato cambió salvo lo
  que la llamada de prueba deba hacer.

## SNIPPET A — cerradas y verificadas (6/6)

| función | ver | sin-cred | JWT falso service | service real | equivalencia | callers (todos service key) |
|---|---|---|---|---|---|---|
| recalibrate-model-weights | 62→63 | 401 | 401 | 200 ok | pequeña | cron 145 ✓ |
| detect-user-patterns | 14→15 | 401 | 401 | 200 patrones | media | cron 83 (estaba SIN key → arreglado) |
| log-scan-result | 16→17 | 401 | 401 | 400 apodo req | pequeña | edge→edge scan-betslip (pendiente confirmar header al llegar a scan-betslip) |
| reconectar-picks-huerfanos | 14→15 | 401 | 401 | 200 dry_run | **diff exacto = 0 bloques de negocio** | cron 116 ✓ |
| oraculo-premium | 15→16 | 401 | 401 | 200 (sin LLM/sin write) | **diff = solo los 2 bloques** | cron 107 (estaba SIN key → arreglado) |
| enviar-notificacion-push | 236→237 | 401 | 401 | 200 "No push subscriptions" | reemplazo de auth débil | disparar_push_notificacion / enviar_alerta / trigger_enviar_push_notificacion, todos service key |

### Crons reparados por el inventario de callers (habrían quedado en 401)
- jobid 83 (detect-user-patterns): agregado `Authorization: Bearer public.sk()`.
- jobid 107 (oraculo-premium): agregado `Authorization: Bearer public.sk()`.
- jobid 116 (reconectar), 145 (recalibrate): ya mandaban la key.

Ningún smoke mutó datos: reconectar con `dry_run:true`, oraculo con id inexistente,
push con apodo inexistente.

## Pendientes (mismo protocolo, por severidad)

1. **User-facing IDOR (P0-WRITE / P0-READ)** — protocolo grande + SNIPPET B (identidad del JWT + propiedad):
   - confirmar-fecha-pick (P0-WRITE IDOR)
   - get-parlay-with-scores (P0-READ)
   - crear-parlay-screenshot (P1-AUTHZ write)
2. **AUTH-0 consumers** (swap `_shared/auth.ts` corregido + redeploy): construir-parlay-ai,
   settle-betslip, analizar-partido, auto-calificar-picks.
3. **scan-betslip** — AL FINAL, con candado más fuerte y prueba de equivalencia exacta.
4. **PIT DEAD_DISABLED**: procesar-venganza, generar-picks-pit, auto-calificar-pit-picks.
5. Matriz completa final. Declarar `IDENTIDAD_ECONOMICA_SEGURA = PASS` solo si no queda
   ninguna explotación material abierta.
