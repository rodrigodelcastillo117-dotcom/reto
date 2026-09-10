// ISS-042 — UEFA domestic backfill v1 (STAGED, DO NOT DEPLOY UNDER RELEASE_GATE=HOLD)
// Purpose: fill temporal domestic history needed by CROSS_LEAGUE_V1 for clubs whose
// domestic competitions are not covered by ESPN history.
// Targets: Ukraine Premier League (333), Czech Liga (345), Azerbaijan Premyer Liqa (419).
// This function NEVER creates a probability. It only persists finished domestic fixtures.
// Writes require body.confirm === 'UEFA_DOMESTIC_BACKFILL_V1'.

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const API_KEY = Deno.env.get("API_FOOTBALL_KEY")!;
const API_BASE = "https://v3.football.api-sports.io";
const sb = createClient(SB_URL, SERVICE_KEY);

const TARGETS = [
  { league: 333, name: "Ukraine Premier League", seasons: [2025, 2026] },
  { league: 345, name: "Czech Liga", seasons: [2025, 2026] },
  { league: 419, name: "Azerbaijan Premyer Liqa", seasons: [2025, 2026] },
];

const CLUBS = [
  { espn_name: "Shakhtar Donetsk", api_id: 550, league: 333 },
  { espn_name: "Slavia Prague", api_id: 560, league: 345 },
  { espn_name: "Sabah FK", api_id: 13976, league: 419 },
];

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

async function af(path: string, params: Record<string, string | number>) {
  const { data: allowed } = await sb.rpc("apifootball_puede_llamar", { p_costo: 1, p_prioridad: "normal" });
  if (!allowed) throw new Error("API_FOOTBALL_QUOTA_NOT_AVAILABLE");
  const u = new URL(`${API_BASE}${path}`);
  for (const [k, v] of Object.entries(params)) u.searchParams.set(k, String(v));
  const r = await fetch(u, { headers: { "x-apisports-key": API_KEY }, signal: AbortSignal.timeout(20000) });
  const remaining = r.headers.get("x-ratelimit-requests-remaining");
  if (remaining && Number.isFinite(Number(remaining))) {
    try { await sb.rpc("apifootball_conciliar", { p_restantes: Number(remaining) }); } catch { /* non-blocking */ }
  }
  if (r.status === 429) {
    try { await sb.rpc("apifootball_marcar_agotada", { p_msg: `iss042 ${path} 429` }); } catch { /* non-blocking */ }
    throw new Error("API_FOOTBALL_429");
  }
  if (!r.ok) throw new Error(`API_FOOTBALL_HTTP_${r.status}`);
  const j = await r.json();
  if (j?.errors && Object.keys(j.errors).length) throw new Error(`API_FOOTBALL_ERROR:${JSON.stringify(j.errors)}`);
  return j.response || [];
}

function finished(short: string) { return ["FT", "AET", "PEN"].includes(short); }

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    if (body.confirm !== "UEFA_DOMESTIC_BACKFILL_V1") {
      return Response.json({
        ok: false,
        staged: true,
        error: "CONFIRMATION_REQUIRED",
        confirm_required: "UEFA_DOMESTIC_BACKFILL_V1",
        targets: TARGETS,
        clubs: CLUBS,
      }, { status: 409, headers: cors });
    }

    let api_calls = 0, fixtures_seen = 0, finished_seen = 0, form_rows = 0, match_rows = 0;
    const perLeague: any[] = [];

    for (const target of TARGETS) {
      const lr: any = { league: target.league, name: target.name, seasons: [] };
      for (const season of target.seasons) {
        const fixtures = await af("/fixtures", { league: target.league, season });
        api_calls++;
        fixtures_seen += fixtures.length;
        let nFinished = 0;
        for (const f of fixtures) {
          const fx = f.fixture, teams = f.teams, goals = f.goals, score = f.score;
          if (!fx?.id || !teams?.home?.id || !teams?.away?.id) continue;
          if (!finished(fx.status?.short || "") || goals?.home == null || goals?.away == null) continue;
          nFinished++; finished_seen++;

          for (const t of [teams.home, teams.away]) {
            await sb.from("ligamx_equipos").upsert({
              id: t.id, api_football_id: t.id, nombre: t.name,
              nombre_corto: t.code || null, escudo_url: t.logo || null,
            }, { onConflict: "id" });
          }

          const { error: pe } = await sb.from("ligamx_partidos").upsert({
            id: fx.id, liga_id: target.league, liga_nombre: target.name, temporada: season,
            jornada: f.league?.round || null, fase: f.league?.round || null,
            fecha_utc: fx.date, home_id: teams.home.id, away_id: teams.away.id,
            status: "finished", home_score: goals.home, away_score: goals.away,
            home_ht: score?.halftime?.home ?? null, away_ht: score?.halftime?.away ?? null,
            raw: f,
          }, { onConflict: "id" });
          if (pe) throw new Error(`ligamx_partidos:${pe.message}`);
          match_rows++;

          const rows = [
            { team: teams.home, rival: teams.away, local: true, gf: goals.home, gc: goals.away },
            { team: teams.away, rival: teams.home, local: false, gf: goals.away, gc: goals.home },
          ];
          for (const r of rows) {
            const { error: fe } = await sb.from("ligamx_team_form").upsert({
              team_id: r.team.id, fixture_id: fx.id, fecha_utc: fx.date,
              rival_id: r.rival.id, rival_nombre: r.rival.name, local: r.local,
              resultado: r.gf > r.gc ? "W" : r.gf < r.gc ? "L" : "D",
              gf: r.gf, gc: r.gc, liga_id: target.league,
            }, { onConflict: "team_id,fixture_id" });
            if (fe) throw new Error(`ligamx_team_form:${fe.message}`);
            form_rows++;
          }
        }
        lr.seasons.push({ season, fixtures: fixtures.length, finished: nFinished });
      }
      perLeague.push(lr);
    }

    // Explicit identity bridge for the three current UCL clubs. No fuzzy mapping.
    for (const c of CLUBS) {
      await sb.from("api_sports_team_map").upsert({
        espn_name: c.espn_name, api_sports_id: c.api_id, league: c.league,
      }, { onConflict: "espn_name" });
    }

    const counts: any[] = [];
    for (const c of CLUBS) {
      const { count } = await sb.from("ligamx_team_form")
        .select("id", { head: true, count: "exact" })
        .eq("team_id", c.api_id).eq("liga_id", c.league);
      counts.push({ ...c, domestic_n: count ?? 0, floor15_pass: (count ?? 0) >= 15 });
    }

    return Response.json({
      ok: true, version: "iss042_v1", api_calls, fixtures_seen, finished_seen,
      match_rows, form_rows, perLeague, counts,
      next_gate: "ALL three clubs must have domestic_n>=15; then refit/validate phi for 333/345/419 before P_RETO can publish",
    }, { headers: cors });
  } catch (e: any) {
    return Response.json({ ok: false, error: String(e?.message || e) }, { status: 500, headers: cors });
  }
});
