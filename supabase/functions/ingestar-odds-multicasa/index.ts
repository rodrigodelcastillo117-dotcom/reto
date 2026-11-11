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

// Mapa liga del motor (soccer_league_map.liga_nombre) -> key de The Odds API.
// Se usa en modo soccer_auto: solo se gastan creditos en ligas que de verdad tienen picks proximos.
const LIGA_ODDSAPI: Record<string, string> = {
  "Premier League": "soccer_epl",
  "La Liga": "soccer_spain_la_liga",
  "Serie A": "soccer_italy_serie_a",
  "Bundesliga": "soccer_germany_bundesliga",
  "Ligue 1": "soccer_france_ligue_one",
  "Eredivisie": "soccer_netherlands_eredivisie",
  "Liga MX": "soccer_mexico_ligamx",
  "Liga Portugal": "soccer_portugal_primeira_liga",
  "Süper Lig": "soccer_turkey_super_league",
  "Jupiler Pro League": "soccer_belgium_first_div",
  "Brazil Serie A": "soccer_brazil_campeonato",
  "Argentine LPF": "soccer_argentina_primera_division",
  "MLS": "soccer_usa_mls",
  "Eliteserien": "soccer_norway_eliteserien",
  "Allsvenskan": "soccer_sweden_allsvenskan",
  "Süper Lig Turkey": "soccer_turkey_super_league",
  "Saudi Pro League": "soccer_saudi_arabia",
  "UEFA Champions League": "soccer_uefa_champs_league",
  "UEFA Europa League": "soccer_uefa_europa_league",
  "UEFA Conference League": "soccer_uefa_europa_conference_league",
  "Copa Libertadores": "soccer_conmebol_copa_libertadores",
  "Copa Sudamericana": "soccer_conmebol_copa_sudamericana",
};
// Competencias de seleccion siempre consideradas cuando estan activas (ventana FIFA).
const SOCCER_INTL_SIEMPRE = ["soccer_uefa_nations_league"];

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
    let sports: string[] = Array.isArray(body?.sports) && body.sports.length ? body.sports : SPORTS;
    const regions: string = body?.regions || (body?.soccer_auto ? "eu" : "us");

    // 🎯 Modo POR DEMANDA (soccer_auto): solo gasta créditos en ligas con picks próximos.
    // Lee las ligas de los picks publicables (próximos N días) y las traduce a keys de The Odds API.
    // En descanso FIFA se apaga casi solo (solo selecciones); cuando los clubes vuelven, se expande solo.
    let autoInfo: any = null;
    if (body?.soccer_auto) {
      const dias = Number(body?.dias) > 0 ? Number(body.dias) : 3;
      const hastaIso = new Date(Date.now() + dias * 86400000).toISOString();
      const { data: prox } = await sb.from("v_reto_soccer_pick_v1")
        .select("liga_nombre, kickoff")
        .gte("kickoff", new Date().toISOString())
        .lte("kickoff", hastaIso);
      const ligas = Array.from(new Set((prox || []).map((r: any) => String(r.liga_nombre || "").trim())));
      const keys = new Set<string>(SOCCER_INTL_SIEMPRE);
      const sinKey: string[] = [];
      for (const lg of ligas) {
        const k = LIGA_ODDSAPI[lg];
        if (k) keys.add(k); else if (lg) sinKey.push(lg);
      }
      sports = Array.from(keys);
      autoInfo = { ligas_con_picks: ligas, keys_elegidas: sports, ligas_sin_key: sinKey, dias };
    }

    // Modo listar: devuelve las competencias de futbol ACTIVAS (no gasta cuota de /sports).
    if (body?.list) {
      const r = await fetch(`https://api.the-odds-api.com/v4/sports/?apiKey=${apiKey}`);
      const all = await r.json();
      const soccer = (Array.isArray(all) ? all : [])
        .filter((s: any) => s.group === "Soccer")
        .map((s: any) => ({ key: s.key, title: s.title, active: s.active, has_outrights: s.has_outrights }));
      return new Response(JSON.stringify({ ok: true, cuota_restante: r.headers.get("x-requests-remaining"), n: soccer.length, soccer }), { headers: jsonHeaders });
    }

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

    return new Response(JSON.stringify({ ok: true, cuota_restante: cuotaRestante, upserted, n_keys: sports.length, auto: autoInfo, resumen }), { headers: jsonHeaders });
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message || String(e) }), { status: 500, headers: jsonHeaders });
  }
});
