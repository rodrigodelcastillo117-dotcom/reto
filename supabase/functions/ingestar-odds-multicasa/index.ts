// ingestar-odds-multicasa
// Trae momios MONEYLINE (h2h) de VARIAS casas desde The Odds API (the-odds-api.com) y los guarda
// en reto_odds_multicasa_v1 para LINE SHOPPING. Requiere el secreto ODDS_API_KEY.
// Sondeo conservador: NFL/NBA/NHL, región us. Reporta cuota restante (x-requests-remaining).
// DINERO OFF en la app: esto solo guarda precios por casa; la app muestra el mejor precio, no EV/stake.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Deportes a sondear. Soccer se puede añadir luego (regions=eu,uk) si el presupuesto de cuota lo permite.
const SPORTS = ["americanfootball_nfl", "basketball_nba", "icehockey_nhl"];

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    const apiKey = Deno.env.get("ODDS_API_KEY") || "";
    if (!apiKey) {
      return new Response(JSON.stringify({ error: "ODDS_API_KEY no configurada. Agrega el secreto en Supabase para activar el line shopping." }), { status: 400, headers: jsonHeaders });
    }
    const sb = createClient(supabaseUrl, serviceKey);

    // Permite elegir deportes y región por body (opcional)
    let body: any = {};
    try { body = await req.json(); } catch { /* vacío */ }
    const sports: string[] = Array.isArray(body?.sports) && body.sports.length ? body.sports : SPORTS;
    const regions: string = body?.regions || "us";

    const resumen: any[] = [];
    let cuotaRestante: string | null = null;
    const rows: any[] = [];

    for (const sport of sports) {
      const url = `https://api.the-odds-api.com/v4/sports/${sport}/odds?apiKey=${apiKey}&regions=${regions}&markets=h2h&oddsFormat=decimal`;
      const r = await fetch(url);
      cuotaRestante = r.headers.get("x-requests-remaining") ?? cuotaRestante;
      if (!r.ok) {
        const t = await r.text();
        resumen.push({ sport, http: r.status, error: t.slice(0, 200) });
        continue;
      }
      const eventos = await r.json();
      let nEv = 0, nFilas = 0;
      for (const ev of (Array.isArray(eventos) ? eventos : [])) {
        nEv++;
        for (const bk of (ev.bookmakers || [])) {
          const h2h = (bk.markets || []).find((m: any) => m.key === "h2h");
          if (!h2h) continue;
          const out = h2h.outcomes || [];
          const find = (name: string) => out.find((o: any) => o.name === name)?.price ?? null;
          rows.push({
            sport_key: sport,
            oddsapi_event_id: ev.id,
            commence_time: ev.commence_time,
            home_team: ev.home_team,
            away_team: ev.away_team,
            bookmaker: bk.title,
            home_odds: find(ev.home_team),
            away_odds: find(ev.away_team),
            draw_odds: find("Draw"),
            captured_at: new Date().toISOString(),
          });
          nFilas++;
        }
      }
      resumen.push({ sport, eventos: nEv, filas: nFilas });
    }

    let upserted = 0;
    // Upsert en lotes por (oddsapi_event_id, bookmaker)
    for (let i = 0; i < rows.length; i += 500) {
      const chunk = rows.slice(i, i + 500);
      const { error } = await sb.from("reto_odds_multicasa_v1")
        .upsert(chunk, { onConflict: "oddsapi_event_id,bookmaker" });
      if (!error) upserted += chunk.length;
      else resumen.push({ upsert_error: error.message });
    }

    return new Response(JSON.stringify({ ok: true, cuota_restante: cuotaRestante, upserted, resumen }), { headers: jsonHeaders });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jsonHeaders });
  }
});
