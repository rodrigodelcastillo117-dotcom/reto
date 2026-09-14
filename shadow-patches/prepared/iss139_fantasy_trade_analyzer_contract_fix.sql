-- ISS139 — Fantasy Trade Analyzer contract repair
-- Scope: adapter/orchestration only. No model math changes.
-- Root causes:
--   1) v2.fantasy_trade_side_eval_v1 required `position` + `name` in every JSON leg,
--      while the frontend and canonical roster already supplied a verified espn_player_id.
--   2) public.fantasy_trade_analyzer_v1 returned only nested aggregates, while the
--      deployed frontend adapter expects additive flat compatibility fields too.
-- Repair:
--   - infer missing name/position from public.nfl_jugadores using exact espn_player_id
--   - accept both `name` and `jugador`
--   - preserve nested contract and add flat read fields; no probabilities/market data

create or replace function v2.fantasy_trade_side_eval_v1(
  p_players jsonb,
  p_season integer,
  p_week integer,
  p_asof timestamptz default now()
) returns jsonb
language sql
stable security definer
set search_path to 'v2','public','pg_temp'
as $function$
with req0 as (
  select ord::int,
         nullif(x->>'espn_player_id','') espn_player_id,
         nullif(upper(coalesce(x->>'position','')),'') supplied_position,
         coalesce(nullif(x->>'name',''),nullif(x->>'jugador','')) supplied_name
  from jsonb_array_elements(coalesce(p_players,'[]'::jsonb)) with ordinality q(x,ord)
), req as (
  select r.ord,
         r.espn_player_id,
         coalesce(r.supplied_position, upper(nullif(j.posicion,''))) position,
         coalesce(r.supplied_name, nullif(j.nombre,'')) supplied_name
  from req0 r
  left join public.nfl_jugadores j on j.espn_player_id=r.espn_player_id
), ev as (
  select r.*,
         p.model_version,p.projected_mean,p.floor_points,p.ceiling_points,p.uncertainty,
         p.n_history,p.cold_start,p.feature_data_asof,p.model_status,p.quality_flag,p.provenance
  from req r
  left join lateral v2.fn_fantasy_project_b1_rq80_v2(
    r.espn_player_id,r.position,p_season,p_week,p_asof
  ) p on true
)
select jsonb_build_object(
  'status',case
    when count(*)=0 then 'EMPTY'
    when count(*) filter(where model_status='READY')=count(*) then 'READY'
    else 'DATA_INCOMPLETE'
  end,
  'count',count(*),
  'ready_count',count(*) filter(where model_status='READY'),
  'projected_mean_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(projected_mean),2) end,
  'floor_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(floor_points),2) end,
  'ceiling_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(ceiling_points),2) end,
  'uncertainty_total',case when count(*) filter(where model_status='READY')=count(*) then round(sum(uncertainty),2) end,
  'players',coalesce(jsonb_agg(jsonb_build_object(
    'espn_player_id',espn_player_id,
    'position',coalesce(position,''),
    'name',supplied_name,
    'model_version',model_version,
    'projected_mean',projected_mean,
    'floor',floor_points,
    'ceiling',ceiling_points,
    'uncertainty',uncertainty,
    'n_history',n_history,
    'cold_start',cold_start,
    'model_status',model_status,
    'quality_flag',quality_flag,
    'feature_data_asof',feature_data_asof
  ) order by ord),'[]'::jsonb)
)
from ev;
$function$;

create or replace function public.fantasy_trade_analyzer_v1(
  p_send jsonb,
  p_receive jsonb,
  p_season integer,
  p_week integer,
  p_asof timestamptz default now()
) returns jsonb
language plpgsql
stable security definer
set search_path to 'public','v2','pg_temp'
as $function$
declare
  s jsonb;
  r jsonb;
  ns int;
  nr int;
  dmean numeric;
  dfloor numeric;
  dceil numeric;
  status text;
  verdict text;
begin
  if jsonb_typeof(coalesce(p_send,'null'::jsonb))<>'array'
     or jsonb_typeof(coalesce(p_receive,'null'::jsonb))<>'array' then
    return jsonb_build_object(
      'ok',false,'status','INVALID_INPUT',
      'reason','send y receive deben ser arreglos JSON'
    );
  end if;

  ns:=jsonb_array_length(p_send);
  nr:=jsonb_array_length(p_receive);
  if ns<1 or nr<1 or ns>4 or nr>4 then
    return jsonb_build_object(
      'ok',false,'status','INVALID_PLAYER_COUNT','min_each_side',1,'max_each_side',4
    );
  end if;

  s:=v2.fantasy_trade_side_eval_v1(p_send,p_season,p_week,p_asof);
  r:=v2.fantasy_trade_side_eval_v1(p_receive,p_season,p_week,p_asof);

  if s->>'status'<>'READY' or r->>'status'<>'READY' then
    return jsonb_build_object(
      'ok',true,'status','DATA_INCOMPLETE','send',s,'receive',r,
      'media_envia',null,'media_recibe',null,
      'piso_envia',null,'piso_recibe',null,
      'techo_envia',null,'techo_recibe',null,
      'delta',null,
      'verdict','NO_VERDICT','veredicto','NO_VERDICT',
      'reason','RETO no emite veredicto si cualquier jugador carece de proyección B1 READY.'
    );
  end if;

  if ns<>nr then
    return jsonb_build_object(
      'ok',true,'status','ROSTER_IMPACT_REQUIRED','send',s,'receive',r,
      'media_envia',(s->>'projected_mean_total')::numeric,
      'media_recibe',(r->>'projected_mean_total')::numeric,
      'piso_envia',(s->>'floor_total')::numeric,
      'piso_recibe',(r->>'floor_total')::numeric,
      'techo_envia',(s->>'ceiling_total')::numeric,
      'techo_recibe',(r->>'ceiling_total')::numeric,
      'delta',null,
      'verdict','NO_VERDICT','veredicto','NO_VERDICT',
      'reason','Trades con distinto número de jugadores requieren valorar el slot liberado/reemplazo dentro del roster; RETO no suma jugadores como si los slots fueran infinitos.'
    );
  end if;

  dmean:=round((r->>'projected_mean_total')::numeric-(s->>'projected_mean_total')::numeric,2);
  dfloor:=round((r->>'floor_total')::numeric-(s->>'floor_total')::numeric,2);
  dceil:=round((r->>'ceiling_total')::numeric-(s->>'ceiling_total')::numeric,2);
  verdict:=case
    when dmean>=2 and dfloor>=0 then 'RECEIVE_SIDE_STRONGER'
    when dmean<=-2 and dfloor<=0 then 'SEND_SIDE_STRONGER'
    else 'CLOSE_OR_PROFILE_DEPENDENT'
  end;
  status:='READY_EQUAL_COUNT';

  return jsonb_build_object(
    'ok',true,
    'status',status,
    'contract_version','fantasy_trade_analyzer_v1',
    'brain','fantasy-b1-rq80-2026.09.1',
    'send',s,
    'receive',r,
    'media_envia',(s->>'projected_mean_total')::numeric,
    'media_recibe',(r->>'projected_mean_total')::numeric,
    'piso_envia',(s->>'floor_total')::numeric,
    'piso_recibe',(r->>'floor_total')::numeric,
    'techo_envia',(s->>'ceiling_total')::numeric,
    'techo_recibe',(r->>'ceiling_total')::numeric,
    'delta',dmean,
    'delta_receive_minus_send',jsonb_build_object(
      'mean',dmean,'floor',dfloor,'ceiling',dceil
    ),
    'verdict',verdict,
    'veredicto',verdict,
    'note','Este V1 compara valor proyectado B1 intrínseco en trades de igual cantidad. No inventa valor de roster/waiver para trades desiguales.',
    'principles',jsonb_build_object(
      'one_brain',true,'market_used',false,'missing_projection_invented',false
    )
  );
end
$function$;
