// nfl-props-sync-v1 — STAGED / NO PROD DEPLOY
// Root ingestion for Remix Reto 13M NFL Prop Board.
// Real lines only. DraftKings line/price never becomes P_RETO.
// The Odds API non-featured player props are fetched one event at a time.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const API = 'https://api.the-odds-api.com/v4/sports/americanfootball_nfl';
const CORE_MARKETS = [
  'player_pass_yds',
  'player_pass_tds',
  'player_pass_completions',
  'player_pass_attempts',
  'player_pass_interceptions',
  'player_rush_yds',
  'player_rush_attempts',
  'player_receptions',
  'player_reception_yds',
  'player_anytime_td',
] as const;

const CANON: Record<string,string> = {
  player_pass_yds: 'passing_yards',
  player_pass_tds: 'passing_tds',
  player_pass_completions: 'pass_completions',
  player_pass_attempts: 'pass_attempts',
  player_pass_interceptions: 'interceptions',
  player_rush_yds: 'rushing_yards',
  player_rush_attempts: 'rushing_attempts',
  player_receptions: 'receptions',
  player_reception_yds: 'receiving_yards',
  player_anytime_td: 'anytime_td',
};

function norm(s: string | null | undefined) {
  return (s ?? '').normalize('NFD').replace(/[\u0300-\u036f]/g,'').toLowerCase()
    .replace(/\b(jr|sr|ii|iii|iv|v)\b\.?/g,'').replace(/[^a-z0-9]/g,'');
}
function sideOf(name: string, market: string) {
  const n = name.toLowerCase();
  if (market === 'player_anytime_td') {
    if (n === 'yes' || n === 'over') return 'YES';
    if (n === 'no' || n === 'under') return 'NO';
  }
  if (n === 'over') return 'OVER';
  if (n === 'under') return 'UNDER';
  return null;
}

Deno.serve(async (req: Request) => {
  const t0 = Date.now();
  try {
    const apiKey = Deno.env.get('ODDS_API_KEY');
    if (!apiKey) return Response.json({ok:false,error:'ODDS_API_KEY missing'}, {status:500});
    const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const body = req.method === 'POST' ? await req.json().catch(()=>({})) : {};
    const season = Number(body.season ?? 2026);
    const week = Number(body.week ?? 1);
    const onlyEvent = body.espn_event_id ? String(body.espn_event_id) : null;
    const nowIso = new Date().toISOString();

    const {data: games,error:gErr} = await sb.from('nfl_partidos')
      .select('espn_event_id,fecha,home_team,away_team,home_abrev,away_abrev')
      .eq('temporada',season).eq('semana',week).gt('fecha',nowIso)
      .order('fecha',{ascending:true});
    if (gErr) throw gErr;
    const selected = (games ?? []).filter((g:any)=>!onlyEvent || g.espn_event_id===onlyEvent);

    const evRes = await fetch(`${API}/events?apiKey=${encodeURIComponent(apiKey)}`);
    if (!evRes.ok) return Response.json({ok:false,step:'events',status:evRes.status,body:await evRes.text()},{status:502});
    const providerEvents:any[] = await evRes.json();

    const {data: players,error:pErr} = await sb.from('nfl_jugadores')
      .select('espn_player_id,nombre,equipo,posicion');
    if (pErr) throw pErr;
    const byName = new Map<string,any>();
    for (const p of players ?? []) {
      const k=norm(p.nombre); if (!byName.has(k)) byName.set(k,p); else byName.set(k,null);
    }

    let matchedGames=0, fetchedGames=0, inserted=0, unresolvedPlayers=0, skippedPostKick=0;
    const errors:any[]=[]; const unresolved=new Set<string>();
    let quotaRemaining:string|null=null, quotaUsed:string|null=null;

    for (const g of selected) {
      const pe = providerEvents.find((e:any)=>norm(e.home_team)===norm(g.home_team) && norm(e.away_team)===norm(g.away_team));
      if (!pe) { errors.push({event:g.espn_event_id,error:'PROVIDER_EVENT_NOT_FOUND'}); continue; }
      matchedGames++;
      const markets = CORE_MARKETS.join(',');
      const url = `${API}/events/${pe.id}/odds?apiKey=${encodeURIComponent(apiKey)}&bookmakers=draftkings&markets=${markets}&oddsFormat=american`;
      const r = await fetch(url);
      quotaRemaining=r.headers.get('x-requests-remaining'); quotaUsed=r.headers.get('x-requests-used');
      if (!r.ok) { errors.push({event:g.espn_event_id,status:r.status,body:(await r.text()).slice(0,300)}); continue; }
      fetchedGames++;
      const j:any=await r.json();
      const capturedAt=new Date().toISOString();
      if (new Date(capturedAt) >= new Date(g.fecha)) { skippedPostKick++; continue; }
      const rows:any[]=[];
      for (const book of j.bookmakers ?? []) {
        if (book.key !== 'draftkings') continue;
        for (const market of book.markets ?? []) {
          const canon=CANON[market.key]; if (!canon) continue;
          for (const o of market.outcomes ?? []) {
            const playerName=String(o.description ?? (market.key==='player_anytime_td' ? o.name : '') ?? '').trim();
            if (!playerName) continue;
            const p=byName.get(norm(playerName));
            if (!p) { unresolvedPlayers++; unresolved.add(playerName); continue; }
            const side=sideOf(String(o.name ?? ''),market.key); if (!side) continue;
            const line = market.key==='player_anytime_td' ? 0.5 : (o.point ?? null);
            rows.push({
              season,week,espn_event_id:g.espn_event_id,kickoff:g.fecha,captured_at:capturedAt,
              provider:'the_odds_api',bookmaker:'DraftKings',provider_event_id:pe.id,
              espn_player_id:p.espn_player_id,player_name:p.nombre,team:p.equipo,player_position:p.posicion,
              market:canon,line,side,odds_american:o.price ?? null,
              source_payload:{market_key:market.key,outcome:o,book_updated_at:book.last_update ?? null},
              source_version:'nfl_prop_lines_v1'
            });
          }
        }
      }
      if (rows.length) {
        const {error:iErr} = await sb.schema('v2').from('nfl_player_prop_line_snapshot').insert(rows);
        if (iErr) errors.push({event:g.espn_event_id,error:'INSERT',detail:iErr.message});
        else inserted += rows.length;
      }
    }
    return Response.json({ok:errors.length===0,season,week,games:selected.length,matched_games:matchedGames,
      fetched_games:fetchedGames,inserted,unresolved_players:unresolvedPlayers,
      unresolved_names:[...unresolved].slice(0,40),skipped_post_kick:skippedPostKick,
      quota_remaining:quotaRemaining,quota_used:quotaUsed,errors:errors.slice(0,20),ms:Date.now()-t0});
  } catch (e) {
    return Response.json({ok:false,error:String(e),ms:Date.now()-t0},{status:500});
  }
});
