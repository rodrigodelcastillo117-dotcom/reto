// vigilar-sharp-div — watchdog de la fuente sharp frágil (pinnapi) del prototipo de fútbol.
// Emite correo SOLO si pinnapi está caído o devuelve pocos partidos (señal de scraper roto),
// no por "no capturamos nada" (eso es normal en break FIFA). Solo lectura + correo. Dinero OFF.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const jh = { ...cors, "Content-Type": "application/json" };
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");
    const resendKey = Deno.env.get("RESEND_API_KEY") || "";
    const { data: cfg } = await sb.from("reto_config_secreto_v1").select("valor").eq("clave", "pinnapi_key").maybeSingle();
    const KEY = (cfg as any)?.valor;

    let sano = false, nEventos = 0, detalle = "";
    if (!KEY) { detalle = "sin pinnapi_key en config"; }
    else {
      try {
        const r = await fetch("https://pinnapi.com/kit/v1/prematch/fixtures?sport_id=1", { headers: { "x-portal-apikey": KEY } });
        if (!r.ok) { detalle = `pinnapi HTTP ${r.status}`; }
        else {
          const j = await r.json();
          nEventos = (j?.events || []).length;
          sano = nEventos >= 50;              // scraper vivo si trae muchos partidos
          if (!sano) detalle = `pinnapi respondió pero solo ${nEventos} partidos (scraper posiblemente roto)`;
        }
      } catch (e: any) { detalle = "excepción al llamar pinnapi: " + (e?.message || String(e)); }
    }

    // capturas acumuladas (contexto, no dispara alarma)
    const { count } = await sb.from("reto_soccer_sharp_div_v1").select("*", { count: "exact", head: true });

    if (!sano && resendKey) {
      const { data: u } = await sb.from("usuarios").select("email").eq("apodo", "rodelcast").maybeSingle();
      if (u?.email) {
        const html = `<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;padding:20px;background:#0a0a0a;color:#e5e5e5;">
          <h2 style="color:#f59e0b;">⚠️ Watchdog: fuente sharp (pinnapi) caída</h2>
          <p>El prototipo de divergencia sharp de fútbol depende de pinnapi (frágil a propósito). Ahora mismo:</p>
          <p style="background:#1a1a1a;border:1px solid #333;border-radius:8px;padding:12px;"><strong>${detalle}</strong></p>
          <p style="color:#9ca3af;font-size:13px;">Capturas acumuladas hasta ahora: ${count ?? 0}. El prototipo no afecta picks ni récord.
          Si pinnapi no vuelve, saca un key nuevo en pinnapi.com/panel o cambiamos de fuente. Esto NO es una emergencia.</p>
          <p style="color:#52525b;font-size:11px;">Reto 13M — watchdog sharp-div</p></div>`;
        await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendKey}` },
          body: JSON.stringify({ from: "Reto 13M <onboarding@resend.dev>", to: [u.email], subject: "⚠️ Reto 13M — fuente sharp (pinnapi) caída", html }),
        });
      }
    }
    return new Response(JSON.stringify({ ok: true, sano, n_eventos_pinnapi: nEventos, capturas_acumuladas: count ?? 0, detalle, alerta_enviada: !sano }), { headers: jh });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jh });
  }
});
