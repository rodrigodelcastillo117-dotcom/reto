// Generic domestic-history backfill for international soccer participants.
// v6: la regla de "liga que sirve como forma SENIOR" ya no vive aqui.
// La decide la base (v2.fn_liga_domestica_valida) y este trabajador la consulta.
// Antes este archivo tenia su propia regla (solo tipo=league) y por eso asigno
// la liga de JUVENILES a equipos portugueses: el historial U19 entraba como
// forma del equipo mayor. Una sola regla, en un solo lugar.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.1";
const U=Deno.env.get("SUPABASE_URL")!; const K=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const API_KEY=Deno.env.get("API_FOOTBALL_KEY")||""; const API_BASE="https://v3.football.api-sports.io";
const sb=createClient(U,K);
function norm(s:string){return String(s||"").normalize("NFD").replace(/[̀-ͯ]/g,"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim()}
function finished(s:string){return ["FT","AET","PEN"].includes(String(s||""))}
function logoId(url?:string|null){const m=String(url||"").match(/\/teams\/(\d+)\.png/i);return m?Number(m[1]):null}
async function af(path:string,params:Record<string,string|number>){const {data:puede}=await sb.rpc("apifootball_puede_llamar",{p_costo:1,p_prioridad:"medio"});if(!puede)throw new Error("API_FOOTBALL_QUOTA_BLOCKED");const url=new URL(API_BASE+path);for(const [k,v] of Object.entries(params))url.searchParams.set(k,String(v));const r=await fetch(url,{headers:{"x-apisports-key":API_KEY}});const rem=r.headers.get("x-ratelimit-requests-remaining");if(rem&&Number.isFinite(Number(rem)))try{await sb.rpc("apifootball_conciliar",{p_restantes:Number(rem)})}catch{};if(r.status===429){try{await sb.rpc("apifootball_marcar_agotada",{p_msg:`soccer-global-backfill ${path} 429`})}catch{};throw new Error("API_FOOTBALL_429")}if(!r.ok)throw new Error(`AF ${path} ${r.status}`);const j=await r.json();if(j?.errors&&Object.keys(j.errors||{}).length)throw new Error(`AF ${path}: ${JSON.stringify(j.errors).slice(0,220)}`);return Array.isArray(j?.response)?j.response:[]}
async function resolveApiTeam(job:any){
 if(job.api_team_id)return Number(job.api_team_id);
 const {data:mapped}=await sb.from("ligamx_equipos").select("api_football_id").eq("espn_id",String(job.team_espn_id)).not("api_football_id","is",null).limit(1).maybeSingle();
 if(mapped?.api_football_id)return Number(mapped.api_football_id);
 const {data:ags}=await sb.from("agenda_espn").select("espn_event_id,home_espn_id,away_espn_id,fecha").or(`home_espn_id.eq.${job.team_espn_id},away_espn_id.eq.${job.team_espn_id}`).gt("fecha",new Date(Date.now()-86400000).toISOString()).order("fecha",{ascending:true}).limit(5);
 for(const ag of ags||[]){const {data:e}=await sb.from("escudos_evento").select("escudo_local,escudo_visitante").eq("espn_event_id",ag.espn_event_id).maybeSingle();const id=ag.home_espn_id===job.team_espn_id?logoId(e?.escudo_local):logoId(e?.escudo_visitante);if(id)return id}
 const ts=await af("/teams",{search:job.team_name});const exact=ts.find((x:any)=>norm(x?.team?.name)===norm(job.team_name));const pick=exact||(ts.length===1?ts[0]:null);return pick?.team?.id?Number(pick.team.id):null
}
// LA REGLA LA DECIDE LA BASE. Aqui solo se pregunta, en UNA llamada.
// Si la base no responde, se falla cerrado: no se asigna ninguna liga.
async function ligasValidas(ids:number[]):Promise<Set<number>>{
 const limpios=[...new Set(ids.filter(n=>Number.isFinite(n)))];
 if(!limpios.length)return new Set<number>();
 const {data,error}=await sb.rpc("filtrar_ligas_domesticas_validas",{p_liga_ids:limpios});
 if(error)throw new Error(`REGLA_DE_LIGA_NO_DISPONIBLE: ${error.message}`);
 return new Set((data||[]).map((x:any)=>Number(x)));
}
async function chooseLeague(apiTeam:number,recent:any[]){
 const cnt=new Map<number,{n:number,name:string,country:string}>();
 for(const f of recent){if(!finished(f?.fixture?.status?.short)||f?.goals?.home==null||f?.goals?.away==null)continue;const id=Number(f?.league?.id);if(!id)continue;const z=cnt.get(id)||{n:0,name:String(f?.league?.name||""),country:String(f?.league?.country||"")};z.n++;cnt.set(id,z)}
 const ids=[...cnt.keys()];
 let cats:any[]=[];
 if(ids.length){const {data}=await sb.from("apifootball_ligas_catalogo").select("liga_id,nombre,tipo,pais").in("liga_id",ids);cats=data||[]}
 const cm=new Map(cats.map((x:any)=>[Number(x.liga_id),x]));
 // Se queda con las ligas que la base acepta como forma senior, y de esas
 // elige la que mas partidos recientes aporta. Juveniles, reservas, femenil,
 // copas e internacionales quedan fuera porque la base las rechaza.
 const ok=await ligasValidas(ids);
 const candidates=ids.map(id=>({id,...cnt.get(id)!,c:cm.get(id)})).filter(x=>ok.has(x.id)).sort((a,b)=>b.n-a.n);
 if(candidates[0])return{id:candidates[0].id,name:candidates[0].c?.nombre||candidates[0].name};
 const leagues=await af("/leagues",{team:apiTeam,current:"true"});
 const ok2=await ligasValidas(leagues.map((x:any)=>Number(x?.league?.id)));
 const ls=leagues.filter((x:any)=>ok2.has(Number(x?.league?.id)));
 if(!ls.length)return null;
 return{id:Number(ls[0].league.id),name:String(ls[0].league.name||"")}
}
async function store(job:any,apiTeam:number,league:any,fixtures:any[]){let writes=0;for(const f of fixtures){if(!finished(f?.fixture?.status?.short)||f?.goals?.home==null||f?.goals?.away==null||Number(f?.league?.id)!==Number(league.id))continue;const home=Number(f?.teams?.home?.id)===apiTeam,away=Number(f?.teams?.away?.id)===apiTeam;if(!home&&!away)continue;const gf=Number(home?f.goals.home:f.goals.away),ga=Number(home?f.goals.away:f.goals.home);if(!Number.isFinite(gf)||!Number.isFinite(ga))continue;const {error}=await sb.rpc("upsert_soccer_domestic_observation",{p_team_espn_id:String(job.team_espn_id),p_provider:"API_FOOTBALL",p_provider_team_id:String(apiTeam),p_provider_fixture_id:String(f.fixture.id),p_domestic_league_id:Number(league.id),p_domestic_league_name:String(league.name||f.league?.name||""),p_kickoff:f.fixture.date,p_gf:gf,p_ga:ga,p_loaded_at:new Date().toISOString(),p_metadata:{opponent_id:home?f.teams.away?.id:f.teams.home?.id,opponent_name:home?f.teams.away?.name:f.teams.home?.name,season:f.league?.season,round:f.league?.round}});if(!error)writes++}return writes}
async function count(team:string,league:number){const {data,error}=await sb.rpc("count_soccer_domestic_observations",{p_team_espn_id:team,p_domestic_league_id:league});if(error)throw error;return Number(data||0)}
async function bounds(team:string,league:number){const {data,error}=await sb.rpc("get_soccer_domestic_observation_bounds",{p_team_espn_id:team,p_domestic_league_id:league});if(error)throw error;return Array.isArray(data)&&data[0]?data[0]:{n:0,min_kickoff:null,max_kickoff:null}}
async function upd(job:any,status:string,more:any={}){const {error}=await sb.rpc("update_soccer_coverage_job",{p_team_espn_id:job.team_espn_id,p_status:status,p_api_team_id:more.apiTeam??null,p_domestic_league_id:more.league?.id??null,p_domestic_league_name:more.league?.name??null,p_reason:more.reason??null,p_last_error:more.error??null,p_increment_attempt:more.increment??false});if(error)throw error}
Deno.serve(async(req)=>{try{if(!API_KEY)throw new Error("API_FOOTBALL_KEY_MISSING");const body=req.method==="POST"?await req.json().catch(()=>({})):{};const limit=Math.max(1,Math.min(Number(body.limit||3),6));const {error:re}=await sb.rpc("refresh_soccer_crossleague_coverage_jobs",{p_decision_time:new Date().toISOString()});if(re)throw re;const {data:activeModel,error:ae}=await sb.rpc("get_active_crossleague_model_version");if(ae)throw ae;if(activeModel){const {error:pe}=await sb.rpc("refresh_soccer_phi_history_jobs",{p_model_version:String(activeModel)});if(pe)throw pe}const {data:jobs,error}=await sb.rpc("get_soccer_coverage_jobs",{p_limit:limit});if(error)throw error;const out:any[]=[];
for(const job of jobs||[]){try{await upd(job,"RUNNING",{increment:true});const apiTeam=await resolveApiTeam(job);if(!apiTeam)throw new Error("TEAM_IDENTITY_NOT_RESOLVED");const deep=job.reason==="PHI_HISTORY_REQUIRED"&&job.history_start;let league=job.domestic_league_id?{id:Number(job.domestic_league_id),name:String(job.domestic_league_name||"")}:null;let writes=0;
if(deep){if(!league?.id)throw new Error("PHI_HISTORY_LEAGUE_MISSING");const before=await bounds(job.team_espn_id,league.id);const target=new Date(job.history_start).getTime();const minBefore=before.min_kickoff?new Date(before.min_kickoff).getTime():Infinity;if(Number(before.n||0)>=30&&minBefore<=target+180*86400000){await upd(job,"DATA_READY",{apiTeam,league,reason:"PHI_HISTORY_READY"});out.push({team:job.team_name,mode:"PHI_HISTORY",status:"DATA_READY",observations:Number(before.n||0),min_kickoff:before.min_kickoff,writes:0});continue}const currentY=new Date().getUTCFullYear();const targetY=new Date(job.history_start).getUTCFullYear()-1;const season=before.min_kickoff?new Date(before.min_kickoff).getUTCFullYear()-1:currentY;const fetchY=Math.max(targetY,Math.min(currentY,season));const more=await af("/fixtures",{team:apiTeam,league:league.id,season:fetchY});writes+=await store(job,apiTeam,league,more);const b=await bounds(job.team_espn_id,league.id);const n=Number(b.n||0);const min=b.min_kickoff?new Date(b.min_kickoff).getTime():Infinity;const ready=n>=30&&min<=target+180*86400000;await upd(job,ready?"DATA_READY":"RETRY",{apiTeam,league,reason:ready?"PHI_HISTORY_READY":"PHI_HISTORY_REQUIRED",error:ready?null:`cursor=${fetchY}; n=${n}; min=${b.min_kickoff}; target=${job.history_start}`});out.push({team:job.team_name,mode:"PHI_HISTORY",season:fetchY,observations:n,min_kickoff:b.min_kickoff,writes,status:ready?"DATA_READY":"RETRY"});continue}
const recent=await af("/fixtures",{team:apiTeam,last:40});if(!league?.id)league=await chooseLeague(apiTeam,recent);if(!league?.id)throw new Error("DOMESTIC_LEAGUE_NOT_RESOLVED");writes+=await store(job,apiTeam,league,recent);let n=await count(job.team_espn_id,league.id);if(n<Number(job.target_sample||20)){const y=new Date().getUTCFullYear();for(const season of [y,y-1]){const more=await af("/fixtures",{team:apiTeam,league:league.id,season});writes+=await store(job,apiTeam,league,more);n=await count(job.team_espn_id,league.id);if(n>=Number(job.target_sample||20))break}}const status=n>=15?"DATA_READY":"RETRY";await upd(job,status,{apiTeam,league,reason:status==="DATA_READY"?"DOMESTIC_DATA_READY":"DOMESTIC_SAMPLE_STILL_LOW"});out.push({team:job.team_name,mode:"CURRENT",api_team_id:apiTeam,league,observations:n,writes,status})}catch(e:any){try{await upd(job,"RETRY",{error:String(e?.message||e).slice(0,500),reason:job.reason==="PHI_HISTORY_REQUIRED"?"PHI_HISTORY_REQUIRED":"BACKFILL_RETRY"})}catch{};out.push({team:job.team_name,error:String(e?.message||e)})}}
return new Response(JSON.stringify({ok:true,processed:out.length,results:out}),{headers:{"content-type":"application/json"}})}catch(e:any){return new Response(JSON.stringify({ok:false,error:String(e?.message||e)}),{status:500,headers:{"content-type":"application/json"}})}});
