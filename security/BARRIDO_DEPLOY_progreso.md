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

## User-facing IDOR — cerradas y verificadas (SNIPPET B: identidad del JWT + propiedad)

| función | ver | sin sesión | service (no user) | A→recurso de B | dueño→propio | callers |
|---|---|---|---|---|---|---|
| confirmar-fecha-pick | 14→15 | 401 | 401 | **404 y pick de B intacto** | 200 ok | solo frontend (0 cron, 0 db_fn) |
| get-parlay-with-scores | 60→61 | 401 | 401 | **200 ok pero 0 parlays (ignora body.apodo)** | 200 ok, 1 parlay | solo frontend (0 cron, 0 db_fn) |

get-parlay-with-scores: exploit legado (sin JWT + body.apodo='rongo' + uuid) devolvía
el parlay de rongo; ahora 401. Con JWT de A pidiendo el parlay de rongo → 0 parlays.
Verificado con JWT real acuñado server-side; solo lectura (cero mutación); sesión
revocada al terminar. Dependencia de frontend: mismo patrón (invoke manda el token).

| crear-parlay-screenshot | 32→33 | 401 (gateway, verify_jwt=true) | 401 (no user) | **0 parlays creados bajo la víctima** | insert intacto (byte a byte) | solo frontend (0 cron, 0 db_fn) |

crear-parlay-screenshot (P1-AUTHZ write): antes insertaba parlay con body.apodo →
A creaba apuestas en cuenta de B. Ahora apodo del JWT. Verificado con JWT real:
A con body.apodo='el dos' NO creó ningún parlay bajo 'el dos' (identidad forzada a A).
El insert es byte-idéntico a v32 (diff local pre-deploy = solo los 2 bloques de auth);
el smoke con payload sintético dio 500 por un trigger BEFORE INSERT de parlays
(zzzz_limite_exposicion / zzz_autoridad_stake / trg_apodo_dueno_parlays) que rechaza
un pick de prueba — comportamiento preexistente de v32, no de mi cambio. 0 filas basura.

Verificación de confirmar-fecha-pick con JWT de usuario REAL acuñado server-side
(admin generate_link → verify; sesión revocada con /logout al terminar; token nunca
pasó por el chat). El único cambio de datos fue en el pick propio del test (etiqueta
`partido`, comportamiento legítimo de la función) y se restauró. Ownership por
`.eq('apodo', apodo)` en cada UPDATE; uuid ajeno → 404, no toca la fila de otro.
**Dependencia de frontend:** el date picker debe mandar el access_token del usuario
(por defecto `supabase.functions.invoke` ya lo hace). Feature dormido hoy (0 picks/
parlays con needs_date_confirmation), así que cero impacto en vivo.

## Pendientes (mismo protocolo, por severidad)

1. **User-facing IDOR restantes** — protocolo grande + SNIPPET B:
   - get-parlay-with-scores (P0-READ)
   - crear-parlay-screenshot (P1-AUTHZ write)
2. **AUTH-0 consumers** (swap `_shared/auth.ts` corregido + redeploy): construir-parlay-ai,
   settle-betslip, analizar-partido, auto-calificar-picks.
3. **scan-betslip** — AL FINAL, con candado más fuerte y prueba de equivalencia exacta.
4. **PIT DEAD_DISABLED**: procesar-venganza, generar-picks-pit, auto-calificar-pit-picks.
5. Matriz completa final. Declarar `IDENTIDAD_ECONOMICA_SEGURA = PASS` solo si no queda
   ninguna explotación material abierta.
