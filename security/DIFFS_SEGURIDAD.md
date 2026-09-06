# Diffs exactos de seguridad — para aplicar por el pipeline del auditor

Fecha: 6-sep-2026. Todos los edge functions viven en Supabase/Lovable, no en este
repo. Aplica cada diff en `supabase/functions/<slug>/index.ts` y redeploya.
Ninguno cambia matematica/negocio: solo frontera de identidad/autorizacion.

Regla de oro que implementan todos:
- user-facing: identidad SIEMPRE del JWT (`auth.getUser`), nunca de `body.apodo/id`.
- por id: validar propiedad server-side.
- crons/internas: service token REAL (comparacion contra la llave, no decode).

---

## GRUPO 0 — AUTH-0 (ya entregado): `_shared/auth.ts`

Reemplaza `isServiceToken` por `security/_shared_auth.FIXED.ts` (comparacion en
tiempo constante; sin rama de decode). Cubre a: `construir-parlay-ai`,
`settle-betslip`, `scan-betslip`, `analizar-partido`, `auto-calificar-picks`,
`live-day-dashboard` (ya v19). Redeploya CADA UNA tras cambiar el source.
NO requieren cambios adicionales en su index.ts.

---

## SNIPPET A — guard "solo interno" (para crons expuestos sin auth)

Insertar como PRIMERA linea dentro de `Deno.serve(async (req) => {` (despues del
manejo de OPTIONS si existe). Usa el nombre de headers CORS que ya tenga el archivo
(`CH`, `corsHeaders`, etc.):

```ts
  // SEGURIDAD: solo contexto interno (service_role real, comparacion directa).
  {
    const _svc = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const _tok = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
    if (!_svc || _tok !== _svc) {
      return new Response(JSON.stringify({ error: "solo interno" }),
        { status: 401, headers: { ...CH, "Content-Type": "application/json" } });
    }
  }
```

Aplicar SNIPPET A tal cual a:
- **detect-user-patterns**  (cron; hoy devuelve pnl/insights de cualquier apodo sin auth)
- **recalibrate-model-weights**  (hoy reescribe model_weights sin auth)
- **reconectar-picks-huerfanos**  (cron; abuso de costo)
- **oraculo-premium**  (cron; quema creditos Anthropic)
- **enviar-notificacion-push**  (hoy solo checa que exista Bearer; permite push a cualquier apodo)
- **log-scan-result**  (telemetria; hoy escribe scan_logs con apodo arbitrario)

Los crons ya se invocan con `Bearer ${SERVICE_KEY}` desde pg_cron/otras edges, asi
que el guard no rompe el uso interno. El front NO llama a ninguna de estas.

---

## SNIPPET B — helper de identidad por JWT (para user-facing)

Agregar una vez por archivo user-facing (usa el cliente service ya creado, `supabase`):

```ts
async function apodoDeJWT(req: Request): Promise<string | null> {
  const tok = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!tok) return null;
  const { data } = await supabase.auth.getUser(tok);
  if (!data?.user) return null;
  const { data: u } = await supabase.from("usuarios")
    .select("apodo").eq("user_id", data.user.id).maybeSingle();
  return u?.apodo ?? null;
}
```

---

## confirmar-fecha-pick  (P0-WRITE IDOR; verify_jwt=false)

1) Insertar SNIPPET B.
2) Al inicio del `try` (tras `const body = await req.json();`), resolver identidad
   y exigir propiedad; y en CADA update agregar `.eq('apodo', apodo)`:

```ts
    const apodo = await apodoDeJWT(req);
    if (!apodo) return new Response(JSON.stringify({ error: 'No autorizado' }),
      { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });
```

- Rama pick:   `.update({...}).eq('id', target_id)`  ->  `.update({...}).eq('id', target_id).eq('apodo', apodo)`
- Rama parlay: al leer el parlay, `.eq('id', target_id)` -> `.eq('id', target_id).eq('apodo', apodo)`
  y en el update final tambien `.eq('id', target_id).eq('apodo', apodo)`.

Asi, un uuid ajeno no matchea y no se toca la apuesta de otro.

---

## get-parlay-with-scores  (P0-READ; verify_jwt=false)

Hoy: `const apodo = typeof body.apodo === "string" ? body.apodo.trim() : "";`
Reemplazar por identidad del JWT (ignorar body.apodo):

```ts
  const apodo = await apodoDeJWT(req);
  if (!apodo) return json({ ok: false, error: "no_autorizado" }, 401);
```

(Agregar SNIPPET B; el `json()` helper ya existe en el archivo.) El resto queda
igual: las queries ya filtran `.eq("apodo", apodo)`, ahora con el apodo correcto.

---

## crear-parlay-screenshot  (P1-AUTHZ write; verify_jwt=true pero sin getUser)

Hoy toma `apodo` del body y hace `apodo.toLowerCase()`. Reemplazar la fuente:

1) Insertar SNIPPET B.
2) Tras `const { picks_extracted, apuesta, momio_total, apodo, ganancia_neta } = await req.json();`
   agregar:

```ts
    const apodoReal = await apodoDeJWT(req);
    if (!apodoReal) return Response.json({ error: 'No autorizado' }, { status: 401 });
```

3) Cambiar `const apodoNorm = apodo.toLowerCase();`
   por        `const apodoNorm = apodoReal.toLowerCase();`
   (el `apodo` del body deja de tener autoridad.)

---

## procesar-venganza — NO tocar (DEAD)

Medido: `pit_jugadores` y `pit_picks` NO existen en la base. La funcion siempre
responde 404; el IDOR no es explotable. Si el juego PIT se reactiva, aplicar
ownership por `apodo` antes de reactivarla. Igual para `generar-picks-pit` /
`auto-calificar-pit-picks` (mismas tablas inexistentes): verificar antes de usar.

---

## leaderboard-roi — ticket aparte (PUBLIC_LEADERBOARD_DATA_MINIMIZATION)

No es hotfix. Quitar del payload publico los campos de tamano de banca:
`avg_stake`, `max_stake`, `total_apostado`, `drawdown_max`/`drawdown_actual` en $.
Conservar ranking, ROI %, WR, N, CLV %, rachas. `ganancia_neta` en $: decision de
producto (reportar, no asumir).

---

## Verificacion (Claude, en vivo, cuando publiques cada una)

- crons con SNIPPET A: sin Authorization -> 401; con service real -> 200.
- user-facing: JWT A + recurso propio -> OK; JWT A + id/apodo de B -> rechazo;
  sin sesion -> 401. Baseline funcional del usuario legitimo intacto.
- AUTH-0 (grupo 0): JWT falso `{"role":"service_role"}` -> 401 en cada una.
