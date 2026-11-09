// vigilar-crons
// Watchdog de las tareas CRÍTICAS del sistema (reto_cron_salud_v1). Corre cada pocas horas.
// SOLO envía email si algo está mal (tarea inactiva, último estado != succeeded, fallos en 24h,
// o lleva demasiado sin correr para su cadencia). Si todo está bien, no molesta. DINERO OFF.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Máximo de horas sin correr tolerado por tarea (diarias ~26h; semanales ~7.5 días).
const MAX_H: Record<string, number> = {
  "mejores-picks-diario-7am": 26,
  "ingestar-odds-multicasa-am": 26,
  "ingestar-odds-soccer-am": 26,
  "reto-clv-snapshot-diario": 26,
  "reto-recalibrar-auto-semanal": 180,
  "reto-recalibrar-platt-semanal": 180,
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");
    const resendKey = Deno.env.get("RESEND_API_KEY") || "";

    const { data: rows, error } = await sb.rpc("reto_cron_salud_v1");
    if (error) throw error;

    const problemas = (rows || []).filter((r: any) => {
      const estadoMal = r.ultimo_status && String(r.ultimo_status) !== "succeeded";
      const fallos = Number(r.fallos_24h) > 0;
      const nuncaCorrio = r.ultimo_run == null;
      const viejo = r.horas_desde != null && Number(r.horas_desde) > (MAX_H[r.jobname] ?? 48);
      return !r.activo || estadoMal || fallos || nuncaCorrio || viejo;
    });

    let emailEnviado = false;
    if (problemas.length > 0 && resendKey) {
      // destinatario: el dueño (rodelcast)
      const { data: u } = await sb.from("usuarios").select("email").eq("apodo", "rodelcast").maybeSingle();
      if (u?.email) {
        const filas = problemas.map((p: any) => {
          const motivo = !p.activo ? "INACTIVA"
            : p.ultimo_run == null ? "nunca corrió"
            : (p.ultimo_status && p.ultimo_status !== "succeeded") ? `último: ${p.ultimo_status}`
            : Number(p.fallos_24h) > 0 ? `${p.fallos_24h} fallo(s) en 24h`
            : `sin correr hace ${p.horas_desde}h`;
          return `<tr><td style="padding:8px 12px;border-bottom:1px solid #262626;color:#f5f5f5;font-size:13px;"><strong>${p.jobname}</strong></td>
            <td style="padding:8px 12px;border-bottom:1px solid #262626;color:#f59e0b;font-size:12px;">${motivo}</td></tr>`;
        }).join("");
        const html = `<!DOCTYPE html><html><body style="margin:0;background:#0a0a0a;font-family:Arial,sans-serif;color:#e5e5e5;">
          <div style="max-width:600px;margin:0 auto;padding:20px;">
            <h1 style="font-size:18px;color:#f59e0b;">⚠️ Reto 13M — aviso del sistema</h1>
            <p style="font-size:13px;color:#a1a1aa;">Una o más tareas automáticas necesitan revisión. El resto sigue corriendo.</p>
            <table style="width:100%;border-collapse:collapse;background:#141414;border-radius:10px;overflow:hidden;">${filas}</table>
            <p style="font-size:11px;color:#6b7280;margin-top:14px;">Watchdog automático · solo te escribe cuando hay algo que revisar. Sin dinero, sin picks.</p>
          </div></body></html>`;
        const r = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendKey}` },
          body: JSON.stringify({ from: "Reto 13M <onboarding@resend.dev>", to: [u.email], subject: `⚠️ Reto 13M — ${problemas.length} tarea(s) con problema`, html }),
        });
        emailEnviado = r.ok;
      }
    }

    return new Response(JSON.stringify({ ok: true, revisadas: (rows || []).length, problemas: problemas.map((p: any) => p.jobname), email_enviado: emailEnviado }), { headers: jsonHeaders });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jsonHeaders });
  }
});
