// resumen-estado-email
// Correo de "VER TODO": estado de la app en un email. Récord verificado + forma + por mercado +
// CLV + cobertura (próximos partidos por deporte, incluido internacional) + link al tablero.
// Lo dispara un cron (p.ej. recordatorio 17-nov). DINERO OFF. Solo lectura.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const APP_URL = "https://reto13m.lovable.app";

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");
    const resendKey = Deno.env.get("RESEND_API_KEY") || "";
    if (!resendKey) return new Response(JSON.stringify({ error: "RESEND_API_KEY no configurada" }), { status: 500, headers: jsonHeaders });

    let body: any = {}; try { body = await req.json(); } catch { /* vacío */ }
    const apodo = body?.apodo || "rodelcast";

    const { data: tabRow } = await sb.from("v_reto_tablero_validacion_v1").select("data").maybeSingle();
    const t: any = (tabRow as any)?.data || {};
    const { data: cob } = await sb.rpc("reto_cobertura_resumen_v1");
    const c: any = cob || {};
    const { data: u } = await sb.from("usuarios").select("email").eq("apodo", apodo).maybeSingle();
    if (!u?.email) return new Response(JSON.stringify({ error: "sin email para " + apodo }), { status: 404, headers: jsonHeaders });

    const tot = t.totales || {}, f7 = t.forma?.d7 || {}, f30 = t.forma?.d30 || {}, clv = t.clv || {};
    const et = (d: string) => ({ soccer: "⚽ Fútbol", tenis_wta: "🎾 WTA", tenis_atp: "🎾 ATP", nba: "🏀 NBA", nhl: "🏒 NHL", nfl: "🏈 NFL" } as any)[d] || d;
    const filasDep = (t.por_deporte || []).map((d: any) =>
      `<tr><td style="padding:6px 10px;border-bottom:1px solid #262626;color:#f5f5f5;font-size:13px;">${et(d.d)}</td>
       <td style="padding:6px 10px;border-bottom:1px solid #262626;color:#22c55e;font-size:13px;text-align:right;">${d.hit}%</td>
       <td style="padding:6px 10px;border-bottom:1px solid #262626;color:#6b7280;font-size:12px;text-align:right;">${d.n}</td></tr>`).join("");
    const filasMerc = (t.por_mercado || []).map((m: any) => {
      const col = Math.abs(Number(m.sesgo)) <= 2 ? "#22c55e" : "#f59e0b";
      return `<tr><td style="padding:6px 10px;border-bottom:1px solid #262626;color:#f5f5f5;font-size:13px;">${m.m}</td>
       <td style="padding:6px 10px;border-bottom:1px solid #262626;color:#9ca3af;font-size:12px;text-align:right;">dice ${m.dice}% · gana ${m.real}%</td>
       <td style="padding:6px 10px;border-bottom:1px solid #262626;color:${col};font-size:12px;text-align:right;">${m.sesgo>0?"+":""}${m.sesgo}pp</td></tr>`;
    }).join("");
    const intl = (c.internacional || []).map((i: any) => `${i.liga} (${i.n})`).join(" · ") || "ninguna próxima";
    const clvTxt = clv.estado === "recolectando"
      ? `🕐 recolectando (${clv.eventos||0} eventos) — aún sin señal concluyente`
      : `${(clv.clv_pp>0?"+":"")}${clv.clv_pp} pp · le gana al cierre ${clv.gano_cierre_pct ?? "—"}% (${clv.eventos||0} picks · ${clv.alcance||"motor ESPN"}) · ${clv.estado}`;
    const clvSoccer = clv.soccer ? `<br><span style="color:#9ca3af;font-size:12px;">⚽ Fútbol: ${clv.soccer}</span>` : "";

    const html = `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;background:#0a0a0a;font-family:Arial,Helvetica,sans-serif;color:#e5e5e5;">
<div style="max-width:600px;margin:0 auto;padding:20px;">
  <div style="text-align:center;padding:16px 0;border-bottom:2px solid #3b82f6;">
    <h1 style="margin:0;font-size:20px;color:#f5f5f5;">📊 Reto 13M — estado completo</h1>
    <p style="margin:6px 0 0;color:#9ca3af;font-size:13px;">Resumen para ${apodo}</p>
  </div>

  <div style="background:#13131f;border:1px solid #27272a;border-radius:10px;padding:14px 16px;margin-top:16px;">
    <div style="font-size:10px;color:#6b7280;text-transform:uppercase;letter-spacing:.08em;">Récord verificado</div>
    <div style="font-size:14px;color:#e5e5e5;margin-top:6px;line-height:1.6;">
      ✅ <strong>${tot.hit ?? "—"}%</strong> global <span style="color:#6b7280;">(${tot.n ?? 0} picks)</span><br>
      <span style="color:#22c55e;">🔒 Alta confianza ≥70%: <strong>${tot.hit_alta ?? "—"}%</strong></span> <span style="color:#6b7280;">(${tot.n_alta ?? 0})</span><br>
      📈 Forma: 7 días <strong>${f7.hit ?? "—"}%</strong> (${f7.n ?? 0}) · 30 días ${f30.hit ?? "—"}% (${f30.n ?? 0})<br>
      💹 CLV: ${clvTxt}${clvSoccer}
    </div>
  </div>

  <h2 style="color:#f5f5f5;font-size:14px;margin:22px 0 6px;">Por deporte</h2>
  <table style="width:100%;border-collapse:collapse;background:#141414;border-radius:10px;overflow:hidden;">${filasDep}</table>

  <h2 style="color:#f5f5f5;font-size:14px;margin:22px 0 6px;">Por mercado (calibración)</h2>
  <table style="width:100%;border-collapse:collapse;background:#141414;border-radius:10px;overflow:hidden;">${filasMerc}</table>

  <h2 style="color:#f5f5f5;font-size:14px;margin:22px 0 6px;">Cobertura (próximos partidos)</h2>
  <div style="background:#141414;border:1px solid #262626;border-radius:10px;padding:12px 14px;font-size:13px;color:#e5e5e5;line-height:1.7;">
    ⚽ Fútbol club ${c.futbol_club ?? 0} · 🏀 NBA ${c.nba ?? 0} · 🏒 NHL ${c.nhl ?? 0} · 🏈 NFL ${c.nfl ?? 0} · 🎾 Tenis ${c.tenis ?? 0}<br>
    🌍 Internacional: ${intl}<br>
    🏷️ Ligas de fútbol con momios (48h): ${c.ligas_momios ?? 0}
  </div>

  <p style="text-align:center;margin:24px 0 8px;">
    <a href="${APP_URL}/validacion" style="display:inline-block;background:#3b82f6;color:#fff;text-decoration:none;padding:11px 24px;border-radius:8px;font-size:14px;">Ver tablero completo →</a>
  </p>
  <p style="text-align:center;color:#6b7280;font-size:11px;line-height:1.5;">Acertar no es ganar dinero: el CLV es la métrica real de rentabilidad. Sin dinero, sin EV, sin stake.</p>
  <p style="text-align:center;color:#52525b;font-size:11px;margin-top:14px;">Reto 13M — reto13m.lovable.app</p>
</div></body></html>`;

    const r = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendKey}` },
      body: JSON.stringify({ from: "Reto 13M <onboarding@resend.dev>", to: [u.email], subject: "📊 Reto 13M — estado completo de la app", html }),
    });
    return new Response(JSON.stringify({ ok: true, enviado: r.ok, status: r.status, to: u.email }), { headers: jsonHeaders });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jsonHeaders });
  }
});
