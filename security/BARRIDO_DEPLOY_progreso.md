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

### LEGIT_PATH = PASS (causa raíz medida, no argumentada)
El 500 se capturó con una subtransacción que reproduce el insert EXACTO del edge
(mismas 8 columnas: apodo, fecha, picks_ids, picks_data, apuesta, momio_total,
resultado, ganancia_neta), con ROLLBACK — no se persistió nada. El error es del
guard de negocio RONGOL `zzzz_limite_exposicion` / `tg_limite_exposicion`:
  "PARLAY SIN MODELO CONJUNTO VALIDADO: no se autoriza exposicion nueva de $X ...
   Motivo de la ruta de ledger: no declara ninguna ruta de ledger"
`ruta_ledger(NEW)` exige `origen='ticket_escaneado'` (+ scan válido) u
`origen='registro_externo_manual'` (+ stake_sobre_techo_razon >=15 chars). El edge
NO envía `origen`/`scan_id` (destructura solo picks_extracted/apuesta/momio_total/
apodo/ganancia_neta) y rechaza `apuesta=0` antes del insert (línea 257 `!apuesta`),
así que TODO parlay con dinero por esta función topa con el guard — en v32 y en v33
por igual (columnas del insert idénticas). NO es regresión del cambio de auth.

Evidencia del estado real de producción: 6 parlays creados desde que el guard vive
(5-sep) llevan `origen='ticket_escaneado'`, `autoridad_economica='LEDGER_EXTERNO'`,
scan_id presente — la única ruta de creación viva pasa por ledger (NO por
crear-parlay-screenshot). Los 53 previos (jul24–sep4) tienen origen=null (anteceden
al guard).

Prueba POSITIVA de que el insert de v33 es sano y respeta la identidad (subtransacción
con ROLLBACK): el MISMO insert + una ruta de ledger declarada
(`origen='registro_externo_manual'`, razón >=15) → `DIAG2_OK rows=1 apodo=rodelcast`.
Es decir: cuando el guard de negocio se satisface, el insert de v33 crea la fila bajo
la identidad del JWT (rodelcast), no bajo body.apodo. Confirmado: la única puerta que
gatea el caso sin-ruta es el guard RONGOL (intacto, zona no-tocar), no mi cambio.

Limpieza post-prueba: 0 filas basura (SEC_DIAG/SEC_LEGIT/razón de smoke = 0), sesión
de JWT acuñado revocada (/auth/v1/logout → 204), tabla temporal `public.lab_tok`
y funciones `_diag_cps_insert*` eliminadas. Token nunca pasó por el chat.

VEREDICTO: identidad/IDOR CERRADO y sin regresión funcional. El "no puede crear
parlay con dinero" NO es efecto de la seguridad; es el guard RONGOL preexistente que
exige ruta de ledger (relacionado con #212, zona intocable).

Verificación de confirmar-fecha-pick con JWT de usuario REAL acuñado server-side
(admin generate_link → verify; sesión revocada con /logout al terminar; token nunca
pasó por el chat). El único cambio de datos fue en el pick propio del test (etiqueta
`partido`, comportamiento legítimo de la función) y se restauró. Ownership por
`.eq('apodo', apodo)` en cada UPDATE; uuid ajeno → 404, no toca la fila de otro.
**Dependencia de frontend:** el date picker debe mandar el access_token del usuario
(por defecto `supabase.functions.invoke` ya lo hace). Feature dormido hoy (0 picks/
parlays con needs_date_confirmation), así que cero impacto en vivo.

## AUTH-0 consumers (swap de `_shared/auth.ts` corregido: timingSafeEqual, sin decode)

| función | ver | sin auth | JWT falso service | service/dueño real | tamaño | estado |
|---|---|---|---|---|---|---|
| live-day-dashboard | (v19) | 401 | 401 | OK | — | CERRADA (sesión previa) |
| construir-parlay-ai | 263→264 | 401 | **401** | service 400 s/apodo; user A 200 (cache) | ~15KB | **CERRADA + verificada** |
| settle-betslip | 48→49 | 401 | **401 (leía boleto ajeno)** | service 400 s/imagen | ~15KB | **CERRADA + verificada** |
| analizar-partido | — | — | — | — | **239KB** | BLOQUEADA por tamaño; exposición = **abuso de costo** (corre el LLM), SIN IDOR (0 usos de caller.apodo/isService en la lógica) |
| scan-betslip | — | — | — | — | **182KB** | BLOQUEADA por tamaño; **IDOR confirmado** (isService?body.apodo). Reservada para el final |

Index desplegado **verbatim** (copiado byte a byte del fetch); solo se cambió `_shared/auth.ts`.
Callers verificados: construir-parlay-ai = solo frontend; settle-betslip = frontend;
analizar-partido = 3 funciones DB (disparar_reanalisis_prepartido, trigger_analizar_partido_async,
reanalizar_analisis_vacios) todas con service key real (compatibles con el fix).

### CORRECCIÓN de inventario
- **auto-calificar-picks NO es AUTH-0 consumer**: 0 usos de requireCaller/_shared/auth.ts
  (bundlea af-meter.ts). Es un **grader ABIERTO** (verify_jwt=false, sin gate de entrada;
  el único Authorization es saliente a Resend). Exposición = abuso de costo (disparar grading +
  correos). Necesita SNIPPET A. 157KB → también bloqueada por tamaño.

## BLOQUEO DE CANAL (grave, requiere decisión del auditor)

El único canal de deploy disponible es `deploy_edge_function` (MCP, contenido **inline**).
No hay Supabase CLI, ni Deno, ni `SUPABASE_ACCESS_TOKEN` en el entorno. Los archivos de
150KB+ (analizar-partido 239KB, scan-betslip 182KB, auto-calificar-picks 157KB) **no se pueden
reproducir inline byte-perfecto de forma confiable**, y como el rollback exigiría la misma
reproducción, un deploy fallido no se podría revertir con seguridad. Por eso NO se despliegan.
Opciones para cerrarlos:
1. Pipeline/Lovable que redeplegue esas funciones cambiando `_shared/auth.ts` (canal nativo para archivos grandes).
2. Proveer Supabase CLI + `SUPABASE_ACCESS_TOKEN` en el entorno → `supabase functions deploy` desde disco (exacto, sin transcripción).

## crear-parlay-screenshot: LEGIT_PATH = PASS
IDOR cerrado y verificado. El 500 del fixture se midió a causa raíz: es el guard de
negocio RONGOL `zzzz_limite_exposicion` (exige ruta de ledger), preexistente e idéntico
en v32/v33 — NO es regresión del cambio de auth. Prueba positiva (rollback): con ruta de
ledger declarada, el insert de v33 crea la fila bajo la identidad del JWT (rodelcast).
Detalle completo en la sección de arriba. (Requisito del auditor cumplido.)

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
