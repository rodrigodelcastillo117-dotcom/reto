// mejores-picks-diario
// Envía por EMAIL (Resend) el resumen de MEJORES PICKS del día que produce el motor.
// DINERO OFF: solo pick + probabilidad del modelo + nivel de confianza. Sin stake, sin EV, sin Kelly.
// Fuentes money-free: v_reto_mejores_picks_v1 (picks), v_reto_nfl_valor_v1 (valor NFL, prob modelo vs mercado),
//   v_reto_alertas_bajas_v1 (bajas confirmadas). No toca modelo, gate ni récord.
// Audiencia por defecto: solo 'rodelcast' (decisión del dueño). Configurable vía body.apodos. Solo email.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const APP_URL = "https://reto13m.lovable.app";

type Pick = {
  deporte: string;
  partido: string;
  pick: string;
  mercado: string;
  prob_pct: string | number | null;
  nivel_confianza: string | null;
  kickoff: string;
  titulares_fuera: number | null;
  alerta_lesion: boolean | null;
};

function emojiDeporte(d: string): string {
  const k = (d || "").toLowerCase();
  if (k.includes("soccer") || k.includes("fut")) return "⚽";
  if (k.includes("nba") || k.includes("basket")) return "🏀";
  if (k.includes("nhl") || k.includes("hockey")) return "🏒";
  if (k.includes("nfl") || k.includes("americano") || k.includes("football")) return "🏈";
  if (k.includes("mlb") || k.includes("beis") || k.includes("base")) return "⚾";
  if (k.includes("tenis") || k.includes("tennis")) return "🎾";
  return "🏅";
}

function colorNivel(n: string | null): string {
  const k = (n || "").toUpperCase();
  if (k === "ALTA") return "#22c55e";
  if (k === "CONFIABLE") return "#eab308";
  if (k === "FAVORABLE") return "#60a5fa";
  return "#9ca3af";
}

function horaCdmx(iso: string): string {
  try {
    const d = new Date(iso);
    return d.toLocaleTimeString("es-MX", {
      timeZone: "America/Mexico_City",
      hour: "2-digit",
      minute: "2-digit",
      hour12: false,
    });
  } catch {
    return "";
  }
}

function pct(p: string | number | null): string {
  if (p === null || p === undefined) return "";
  const n = typeof p === "string" ? parseFloat(p) : p;
  if (!isFinite(n)) return "";
  return `${n.toFixed(0)}%`;
}

function filaPick(p: Pick): string {
  const emj = emojiDeporte(p.deporte);
  const col = colorNivel(p.nivel_confianza);
  const prob = pct(p.prob_pct);
  const hora = horaCdmx(p.kickoff);
  const lesion = p.alerta_lesion
    ? `<span style="color:#f59e0b;font-size:11px;"> ⚠︎ ${Number(p.titulares_fuera) || 0} baja(s)</span>`
    : "";
  return `
  <tr>
    <td style="padding:10px 12px;border-bottom:1px solid #262626;">
      <div style="font-size:14px;color:#f5f5f5;">${emj} <strong>${p.pick}</strong></div>
      <div style="font-size:12px;color:#9ca3af;margin-top:2px;">${p.partido} · ${p.mercado}${hora ? ` · ${hora}` : ""}${lesion}</div>
    </td>
    <td style="padding:10px 12px;border-bottom:1px solid #262626;text-align:right;white-space:nowrap;">
      <div style="font-size:18px;font-weight:bold;color:${col};">${prob}</div>
      <div style="font-size:10px;color:#6b7280;text-transform:uppercase;">${p.nivel_confianza || ""}</div>
    </td>
  </tr>`;
}

function buildHtml(fecha: string, apodo: string, picks: Pick[], nflValor: any[], bajas: any[]): string {
  const num = (p: Pick) => {
    const n = typeof p.prob_pct === "string" ? parseFloat(p.prob_pct) : (p.prob_pct ?? 0);
    return isFinite(n as number) ? (n as number) : 0;
  };
  const ordenados = [...picks].sort((a, b) => num(b) - num(a));
  const top = ordenados.slice(0, 5);

  const porDeporte = new Map<string, Pick[]>();
  for (const p of ordenados) {
    const arr = porDeporte.get(p.deporte) || [];
    if (arr.length < 4) arr.push(p);
    porDeporte.set(p.deporte, arr);
  }

  const seccionTop = top.length
    ? `
    <h2 style="color:#f5f5f5;font-size:15px;margin:24px 0 8px;">⭐ Top del día</h2>
    <table style="width:100%;border-collapse:collapse;background:#171717;border-radius:10px;overflow:hidden;">
      ${top.map(filaPick).join("")}
    </table>`
    : "";

  const secciones = [...porDeporte.entries()]
    .map(([dep, arr]) => `
    <h2 style="color:#d4d4d8;font-size:14px;margin:22px 0 8px;">${emojiDeporte(dep)} ${dep}</h2>
    <table style="width:100%;border-collapse:collapse;background:#171717;border-radius:10px;overflow:hidden;">
      ${arr.map(filaPick).join("")}
    </table>`)
    .join("");

  const cuerpo = picks.length
    ? seccionTop + secciones
    : `<div style="background:#171717;border-radius:10px;padding:24px;text-align:center;color:#9ca3af;font-size:14px;margin-top:20px;">
         Hoy no hay picks publicables con confianza suficiente. Mejor no forzar.
       </div>`;

  // 🏈 Valor NFL: donde el modelo ve al equipo MÁS probable que el mercado (nuestro único edge comprobado).
  const seccionNfl = (nflValor && nflValor.length)
    ? `
    <h2 style="color:#f5f5f5;font-size:15px;margin:26px 0 8px;">🏈 Valor NFL <span style="color:#6b7280;font-size:11px;">(modelo vs mercado)</span></h2>
    <table style="width:100%;border-collapse:collapse;background:#171717;border-radius:10px;overflow:hidden;">
      ${nflValor.map((v: any) => `
      <tr><td style="padding:10px 12px;border-bottom:1px solid #262626;">
        <div style="font-size:14px;color:#f5f5f5;">🏈 <strong>${v.pick}</strong> <span style="color:#22c55e;font-size:12px;">+${v.ventaja_pp}pp</span></div>
        <div style="font-size:12px;color:#9ca3af;margin-top:2px;">${v.partido} · modelo ${v.prob_modelo_pct}% vs mercado ${v.prob_mercado_pct}% · momio ${v.momio_pick}</div>
      </td></tr>`).join("")}
    </table>
    <p style="margin:6px 2px 0;color:#6b7280;font-size:11px;">NFL es el único mercado donde el modelo le gana al cierre de forma comprobada. "Valor" = el modelo ve al equipo más probable que el mercado, con línea fresca.</p>`
    : "";

  // ⚠️ Bajas confirmadas (Out / Injured Reserve), ya sin contaminación entre deportes.
  const seccionBajas = (bajas && bajas.length)
    ? `
    <h2 style="color:#f5f5f5;font-size:15px;margin:26px 0 8px;">⚠️ Bajas confirmadas</h2>
    <table style="width:100%;border-collapse:collapse;background:#171717;border-radius:10px;overflow:hidden;">
      ${bajas.slice(0, 6).map((b: any) => `
      <tr><td style="padding:8px 12px;border-bottom:1px solid #262626;">
        <div style="font-size:13px;color:#f5f5f5;">${emojiDeporte(b.deporte)} <strong>${b.equipo}</strong> <span style="color:#f59e0b;font-size:11px;">${b.bajas_confirmadas} baja(s)</span> <span style="color:#6b7280;">vs ${b.rival}</span></div>
        <div style="font-size:11px;color:#9ca3af;margin-top:2px;">${String(b.quienes || "").slice(0, 120)}</div>
      </td></tr>`).join("")}
    </table>`
    : "";

  return `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#0a0a0a;font-family:Arial,Helvetica,sans-serif;color:#e5e5e5;">
<div style="max-width:600px;margin:0 auto;padding:20px;">
  <div style="text-align:center;padding:18px 0;border-bottom:2px solid #3b82f6;">
    <h1 style="margin:0;font-size:22px;color:#f5f5f5;">🏆 Mejores picks del día</h1>
    <p style="margin:6px 0 0;color:#9ca3af;font-size:13px;">${fecha} — ${apodo}</p>
  </div>

  ${cuerpo}
  ${seccionNfl}
  ${seccionBajas}

  <div style="background:#13131f;border-radius:10px;padding:14px 16px;margin:24px 0 10px;border:1px solid #27272a;">
    <p style="margin:0;color:#a1a1aa;font-size:12px;line-height:1.5;">
      Estas son <strong>probabilidades del modelo</strong>, no garantías. Sin dinero, sin EV, sin stake.
      El modelo solo supera de forma comprobada al mercado de cierre en NFL; en el resto, úsalo como lectura, no como certeza.
    </p>
  </div>

  <p style="text-align:center;margin:18px 0;">
    <a href="${APP_URL}" style="display:inline-block;background:#3b82f6;color:#fff;text-decoration:none;padding:10px 22px;border-radius:8px;font-size:14px;">Ver en la app</a>
  </p>

  <p style="text-align:center;color:#52525b;font-size:11px;margin-top:24px;">Reto 13M — reto13m.lovable.app</p>
</div>
</body></html>`;
}

async function sendEmail(resendKey: string, to: string, subject: string, html: string) {
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendKey}` },
    body: JSON.stringify({
      from: "Reto 13M <onboarding@resend.dev>",
      to: [to],
      subject,
      html,
    }),
  });
  const txt = await r.text();
  return { status: r.status, body: txt };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const resendKey = Deno.env.get("RESEND_API_KEY") || "";
    if (!resendKey) {
      return new Response(JSON.stringify({ error: "RESEND_API_KEY not configured" }), { status: 500, headers: jsonHeaders });
    }
    const sb = createClient(supabaseUrl, serviceKey);

    let body: any = {};
    try { body = await req.json(); } catch { /* cron manda {} o nada */ }
    const apodos: string[] = Array.isArray(body?.apodos) && body.apodos.length ? body.apodos : ["rodelcast"];

    const now = new Date();
    const cdmx = new Date(now.toLocaleString("en-US", { timeZone: "America/Mexico_City" }));
    const fecha = cdmx.toLocaleDateString("es-MX", { timeZone: "America/Mexico_City", weekday: "long", day: "numeric", month: "long" });
    const y = cdmx.getFullYear();
    const m = String(cdmx.getMonth() + 1).padStart(2, "0");
    const d = String(cdmx.getDate()).padStart(2, "0");
    const finDiaUtcIso = new Date(`${y}-${m}-${d}T23:59:59-06:00`).toISOString();
    const nowIso = now.toISOString();
    const win4Iso = new Date(now.getTime() + 4 * 86400000).toISOString();

    const { data: picks, error } = await sb
      .from("v_reto_mejores_picks_v1")
      .select("deporte, partido, pick, mercado, prob_pct, nivel_confianza, kickoff, titulares_fuera, alerta_lesion")
      .gte("kickoff", nowIso)
      .lte("kickoff", finDiaUtcIso);

    if (error) {
      return new Response(JSON.stringify({ error: error.message }), { status: 500, headers: jsonHeaders });
    }
    const lista = (picks || []) as Pick[];

    // 🏈 Valor NFL (próximos 4 días, solo VALOR con línea fresca)
    const { data: nflRaw } = await sb
      .from("v_reto_nfl_valor_v1")
      .select("partido, pick, prob_modelo_pct, prob_mercado_pct, ventaja_pp, momio_pick, valor, edad_linea_h, kickoff")
      .eq("valor", "VALOR")
      .lte("edad_linea_h", 36)
      .gte("kickoff", nowIso)
      .lte("kickoff", win4Iso)
      .order("ventaja_pp", { ascending: false });
    const nflValor = (nflRaw || []);

    // ⚠️ Bajas confirmadas (juegos de hoy)
    const { data: bajasRaw } = await sb
      .from("v_reto_alertas_bajas_v1")
      .select("deporte, equipo, rival, bajas_confirmadas, quienes, kickoff")
      .gte("kickoff", nowIso)
      .lte("kickoff", finDiaUtcIso)
      .order("bajas_confirmadas", { ascending: false })
      .limit(6);
    const bajas = (bajasRaw || []);

    const results: any[] = [];
    for (const apodo of apodos) {
      const { data: u } = await sb.from("usuarios").select("apodo, email, activo").eq("apodo", apodo).maybeSingle();
      if (!u || !u.email) { results.push({ apodo, skip: "sin email" }); continue; }

      const html = buildHtml(fecha, apodo, lista, nflValor, bajas);
      const subject = `🏆 Reto 13M — Mejores picks del ${cdmx.toLocaleDateString("es-MX", { timeZone: "America/Mexico_City", day: "numeric", month: "short" })} (${lista.length})`;
      const res = await sendEmail(resendKey, u.email, subject, html);
      results.push({ apodo, email: u.email, picks: lista.length, nfl_valor: nflValor.length, bajas: bajas.length, send: res.status });
    }

    return new Response(JSON.stringify({ ok: true, fecha, total_picks: lista.length, nfl_valor: nflValor.length, bajas: bajas.length, results }), { headers: jsonHeaders });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jsonHeaders });
  }
});
