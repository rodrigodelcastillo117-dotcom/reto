// ============================================================================
// SHADOW / PROPUESTA — edge function `log-scan-result` v18
// ============================================================================
// NO DESPLEGADO. Reemplazo propuesto para el index.ts vivo (v17), a la espera
// de GO explícito de deploy.
//
// PROBLEMA (v17, 6-sep AUTH-0/SNIPPET A): la guarda "solo interno" exige el
// SERVICE_ROLE_KEY como Bearer. Pero el ÚNICO llamador es el frontend
// (SmartUploadButton.tsx, 3 sitios fire-and-forget), que manda la anon key +
// el JWT del usuario, nunca el service_role. Resultado: 401 en TODAS las
// llamadas del frontend → la telemetría de scan_logs del frontend
// (match_rate, casa, imagen) está 100% muerta desde el 6-sep. (El 401 es
// inerte para la UI: las 3 llamadas son .catch(()=>{}) no-await, así que NO
// causa la pantalla en blanco.)
//
// El AUTH-0 respondía a un P2-WRITE real: v16 aceptaba un `apodo`/`image_url`
// arbitrarios del body = INSERT no autenticado con identidad falsificable.
//
// FIX (identidad desde el JWT, modelo Bloque 0 / #262):
//   * Se exige un JWT de usuario válido (no anon, no service_role del cliente).
//   * El `apodo` NO se toma del body: se resuelve con usuario_economico_actual()
//     (auth.uid() -> usuarios.user_id) bajo el contexto del usuario. Cierra el
//     P2-WRITE (ya no se confía en el apodo del cliente).
//   * picks/casa/image_url/scan_duration siguen viniendo del body: no son
//     identidad, es telemetría del escaneo.
//   * El INSERT se hace con service_role pero con el apodo YA resuelto del JWT.
// verify_jwt se deja en false: la verificación es explícita aquí y devuelve
// JSON limpio (alternativa: poner verify_jwt=true y dejar que el gateway
// rechace; se prefiere el control en código).
// ============================================================================
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ch = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: ch });

  const authz = req.headers.get("Authorization") || "";
  if (!authz) {
    return new Response(JSON.stringify({ error: "auth requerido" }),
      { status: 401, headers: { ...ch, "Content-Type": "application/json" } });
  }

  const url  = Deno.env.get("SUPABASE_URL") || "";
  const anon = Deno.env.get("SUPABASE_ANON_KEY") || "";
  const svc  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

  // Cliente en CONTEXTO DEL USUARIO: auth.uid() sale del JWT recibido.
  const asUser = createClient(url, anon, {
    global: { headers: { Authorization: authz } },
    auth: { persistSession: false },
  });

  // Identidad económica desde el JWT. El body NO decide de quién es el scan.
  const { data: apodoResuelto, error: identErr } = await asUser.rpc("usuario_economico_actual");
  if (identErr || !apodoResuelto) {
    return new Response(JSON.stringify({ error: "sin identidad economica" }),
      { status: 401, headers: { ...ch, "Content-Type": "application/json" } });
  }

  try {
    const body = await req.json();
    const { picks, casa, image_url, scan_duration_ms } = body;
    // image_url se ALMACENA como dato, nunca se fetch-ea server-side. Guarda básica
    // de formato/longitud: solo https y <=2048 chars, si no -> null.
    const img = (typeof image_url === "string" && image_url.length <= 2048 && /^https:\/\//i.test(image_url))
      ? image_url : null;
    const supabase = createClient(url, svc);
    const arr = picks || [];
    const matched = arr.filter((p: any) => p.espn_event_id).length;
    const failed = arr.length - matched;
    const rate = arr.length > 0 ? matched / arr.length : 0;
    const pm = arr.map((p: any) => ({
      partido: p.partido, espn_id: p.espn_event_id || null, liga: p.liga,
      pick: p.pick_desc, home: p.espn_home_team, away: p.espn_away_team,
    }));
    await supabase.from("scan_logs").insert({
      apodo: apodoResuelto,                 // <- del JWT, no del body
      picks_matching: pm, total_picks: arr.length, matched_picks: matched,
      failed_picks: failed, match_rate: rate, casa: casa || null,
      image_url: img, scan_duration_ms: scan_duration_ms || null,
      error: body.error || null,
    });
    return new Response(JSON.stringify({ logged: true, match_rate: rate, matched, failed }),
      { headers: { ...ch, "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ error: "log failed" }),
      { status: 500, headers: { ...ch, "Content-Type": "application/json" } });
  }
});
