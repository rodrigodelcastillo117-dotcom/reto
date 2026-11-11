// capturar-sharp-div-futbol  (PROTOTIPO NO VERIFICADO)
// Congela el precio SHARP (Pinnacle vía pinnapi) 1X2 a ~3h del saque para nuestros eventos de fútbol.
// Guarda solo el lado sharp; DK-en-decisión, drift-al-cierre y lado-seleccionado ya los captura
// v2.soccer_publication_market_evidence_v1 -> la validación OOS hace el join por espn_event_id.
// Fuente frágil (scraper de Pinnacle); por eso prototipo. Dinero/EV/Kelly FUERA. No alimenta picks.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const cors = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type" };

function norm(s: string): string {
  return (s || "").normalize("NFD").replace(/[̀-ͯ]/g, "").toLowerCase()
    .replace(/\b(fc|sc|cf|afc|cd|ac|club|de|the)\b/g, " ")
    .replace(/[^a-z0-9]+/g, " ").trim();
}
const toks = (s: string) => new Set(norm(s).split(" ").filter(Boolean));
function overlap(a: Set<string>, b: Set<string>): number { let n = 0; for (const x of a) if (b.has(x)) n++; return n; }

function novig(h: number, d: number, a: number): { ph: number; pd: number; pa: number } | null {
  if (!(h > 1) || !(d > 1) || !(a > 1)) return null;
  const ih = 1 / h, id = 1 / d, ia = 1 / a, s = ih + id + ia;
  return { ph: +(100 * ih / s).toFixed(2), pd: +(100 * id / s).toFixed(2), pa: +(100 * ia / s).toFixed(2) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const jh = { ...cors, "Content-Type": "application/json" };
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "");
    let body: any = {}; try { body = await req.json(); } catch { /* cron manda {} */ }
    const dryRun = body?.dry_run === true;
    const ventanaH = Number(body?.ventana_horas) > 0 ? Number(body.ventana_horas) : 4.5; // ventana de captura (default ~decisión)

    // key del scraper (tabla bloqueada, solo service-role)
    const { data: cfg } = await sb.from("reto_config_secreto_v1").select("valor").eq("clave", "pinnapi_key").maybeSingle();
    const KEY = (cfg as any)?.valor;
    if (!KEY) return new Response(JSON.stringify({ error: "sin pinnapi_key en config" }), { status: 500, headers: jh });

    // eventos de fútbol próximos (con pick) dentro de la ventana, no capturados aún
    const nowIso = new Date().toISOString();
    const finIso = new Date(Date.now() + ventanaH * 3600_000).toISOString();
    const { data: picks, error: ep } = await sb
      .from("reto_pick_snapshot_v1")
      .select("espn_event_id, partido, kickoff")
      .eq("deporte", "soccer").gt("kickoff", nowIso).lte("kickoff", finIso);
    if (ep) return new Response(JSON.stringify({ error: ep.message }), { status: 500, headers: jh });

    // dedup por evento + excluir ya capturados
    const porEvento = new Map<string, any>();
    for (const p of (picks || [])) if (!porEvento.has(p.espn_event_id)) porEvento.set(p.espn_event_id, p);
    const eventos = [...porEvento.values()];
    if (eventos.length === 0) return new Response(JSON.stringify({ ok: true, candidatos: 0, nota: "sin eventos en ventana" }), { headers: jh });

    const ids = eventos.map((e) => e.espn_event_id);
    const { data: ya } = await sb.from("reto_soccer_sharp_div_v1").select("espn_event_id").in("espn_event_id", ids);
    const yaSet = new Set((ya || []).map((r: any) => r.espn_event_id));
    const pendientes = eventos.filter((e) => !yaSet.has(e.espn_event_id));
    if (pendientes.length === 0) return new Response(JSON.stringify({ ok: true, candidatos: eventos.length, pendientes: 0, nota: "todos ya capturados" }), { headers: jh });

    // fixtures pinnapi (1 llamada)
    const fxRes = await fetch("https://pinnapi.com/kit/v1/prematch/fixtures?sport_id=1", { headers: { "x-portal-apikey": KEY } });
    if (!fxRes.ok) return new Response(JSON.stringify({ error: "pinnapi fixtures " + fxRes.status }), { status: 502, headers: jh });
    const fx = await fxRes.json();
    const pfEvents: any[] = fx?.events || [];

    const resultados: any[] = [];
    let guardados = 0;
    for (const ev of pendientes) {
      try {
        const partes = String(ev.partido || "").split(/\s+vs\.?\s+/i);
        if (partes.length !== 2) { resultados.push({ ev: ev.espn_event_id, skip: "partido no parseable", partido: ev.partido }); continue; }
        const hT = toks(partes[0]), aT = toks(partes[1]);
        const koMs = new Date(ev.kickoff).getTime();
        // mejor match: ambos lados comparten >=1 token y kickoff dentro de ±90min
        let best: any = null, bestSc = -1;
        for (const pe of pfEvents) {
          const ph = toks(pe.home || ""), pa = toks(pe.away || "");
          const oh = overlap(hT, ph), oa = overlap(aT, pa);
          if (oh < 1 || oa < 1) continue;
          const dtMin = Math.abs(new Date(pe.starts).getTime() - koMs) / 60000;
          if (dtMin > 90) continue;
          const sc = oh + oa - dtMin / 1000;
          if (sc > bestSc) { bestSc = sc; best = pe; }
        }
        if (!best) { resultados.push({ ev: ev.espn_event_id, skip: "sin match pinnapi", partido: ev.partido }); continue; }

        // odds del evento (1 llamada)
        const mkRes = await fetch(`https://pinnapi.com/kit/v1/prematch/markets?event_id=${best.event_id}`, { headers: { "x-portal-apikey": KEY } });
        if (!mkRes.ok) { resultados.push({ ev: ev.espn_event_id, skip: "markets " + mkRes.status }); continue; }
        const mk = await mkRes.json();
        const ml = mk?.events?.[0]?.periods?.num_0?.money_line;
        if (!ml || ml.home == null || ml.draw == null || ml.away == null) { resultados.push({ ev: ev.espn_event_id, skip: "sin money_line" }); continue; }
        const nv = novig(Number(ml.home), Number(ml.draw), Number(ml.away));
        if (!nv) { resultados.push({ ev: ev.espn_event_id, skip: "odds inválidas", ml }); continue; }

        const minAntes = Math.round((koMs - Date.now()) / 60000);
        const row = {
          espn_event_id: ev.espn_event_id, partido: ev.partido, kickoff: ev.kickoff,
          pinnapi_event_id: String(best.event_id),
          sharp_home_odds: Number(ml.home), sharp_draw_odds: Number(ml.draw), sharp_away_odds: Number(ml.away),
          p_sharp_home: nv.ph, p_sharp_draw: nv.pd, p_sharp_away: nv.pa,
          minutos_antes_kickoff: minAntes,
          match_confianza: bestSc >= 3 ? "exacto" : "difuso",
          fuente_sharp: "pinnapi_pinnacle_prototipo",
        };
        if (dryRun) { resultados.push({ ev: ev.espn_event_id, match: `${best.home} vs ${best.away}`, min_antes: minAntes, ...nv, dryrun: true }); continue; }
        const { error: ei } = await sb.from("reto_soccer_sharp_div_v1").upsert(row, { onConflict: "espn_event_id", ignoreDuplicates: true });
        if (ei) { resultados.push({ ev: ev.espn_event_id, skip: "insert " + ei.message }); continue; }
        guardados++;
        resultados.push({ ev: ev.espn_event_id, match: `${best.home} vs ${best.away}`, min_antes: minAntes, ...nv, guardado: true });
      } catch (e: any) { resultados.push({ ev: ev.espn_event_id, skip: "exc " + (e?.message || String(e)) }); }
    }
    return new Response(JSON.stringify({ ok: true, dry_run: dryRun, candidatos: eventos.length, pendientes: pendientes.length, guardados, resultados }), { headers: jh });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jh });
  }
});
