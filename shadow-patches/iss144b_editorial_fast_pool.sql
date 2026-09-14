-- ISS144b — lightweight editorial pool; avoid re-running heavy FutPro distributions.

create or replace view public.v_reto_editorial_pool_v2 as
select l.espn_event_id,l.deporte,l.liga,l.home,l.away,l.arranca_en,l.mercado,l.pick_desc,l.probabilidad_pct,l.model_version,
  l.discriminacion_pp,l.rank_global,l.rn_deporte,l.es_validado,l.selector_authoritative,l.top_only_authoritative,l.rank_policy_status,
  case when lower(l.pick_desc) like 'empate%' then 'DRAW'
       when lower(l.pick_desc) like 'gana '||lower(l.home)||'%' then 'HOME'
       when lower(l.pick_desc) like 'gana '||lower(l.away)||'%' then 'AWAY'
       else null end selected_side,
  o.bookmaker,o.snapshot_at odds_captured_at,o.home_ml,o.draw_ml,o.away_ml,
  case when o.home_ml>1 and o.draw_ml>1 and o.away_ml>1 then
    case when lower(l.pick_desc) like 'empate%' then 100*(1/o.draw_ml)/((1/o.home_ml)+(1/o.draw_ml)+(1/o.away_ml))
         when lower(l.pick_desc) like 'gana '||lower(l.home)||'%' then 100*(1/o.home_ml)/((1/o.home_ml)+(1/o.draw_ml)+(1/o.away_ml))
         when lower(l.pick_desc) like 'gana '||lower(l.away)||'%' then 100*(1/o.away_ml)/((1/o.home_ml)+(1/o.draw_ml)+(1/o.away_ml)) end
  end market_selected_novig_pct,
  case when o.home_ml>1 and o.draw_ml>1 and o.away_ml>1 then
    case when o.home_ml<=o.draw_ml and o.home_ml<=o.away_ml then 'HOME'
         when o.draw_ml<=o.home_ml and o.draw_ml<=o.away_ml then 'DRAW' else 'AWAY' end
  end market_favorite_side,
  case when l.probabilidad_pct>=70 and coalesce(l.discriminacion_pp,0)>=20 then 'ALTA'
       when l.probabilidad_pct>=58 and coalesce(l.discriminacion_pp,0)>=12 then 'MEDIA' else 'CAUTELOSA' end confidence_band
from public.v_reto13m_lo_mejor l
left join lateral (
  select x.* from public.v_momios_confiables x
  where x.espn_event_id=l.espn_event_id and x.confiable
  order by x.snapshot_at desc limit 1
) o on true
where l.es_validado and l.selector_authoritative and l.top_only_authoritative and l.rank_policy_status='FROZEN';

grant select on public.v_reto_editorial_pool_v2 to anon,authenticated;

create or replace function public.reto_lo_mejor_editorial_v2(p_apodo text default null,p_horizon_hours integer default 72)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  v_top jsonb; v_safe jsonb; v_disagree jsonb; v_avoid jsonb; v_upset jsonb; v_parlay jsonb; v_fantasy jsonb; v_coverage jsonb;
begin
  if p_horizon_hours<1 or p_horizon_hours>336 then return jsonb_build_object('ok',false,'status','INVALID_HORIZON'); end if;

  select to_jsonb(x) into v_top from (
    select espn_event_id,deporte,liga,home,away,arranca_en,mercado,pick_desc,probabilidad_pct,model_version,discriminacion_pp,confidence_band
    from public.v_reto_editorial_pool_v2
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours)
    order by rank_global nulls last,rn_deporte,probabilidad_pct desc limit 1
  ) x;

  select to_jsonb(x) into v_safe from (
    select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,confidence_band,discriminacion_pp,model_version
    from public.v_reto_editorial_pool_v2
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours)
    order by probabilidad_pct desc,discriminacion_pp desc,arranca_en limit 1
  ) x;

  select to_jsonb(x) into v_disagree from (
    select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,market_selected_novig_pct,
      round(probabilidad_pct-market_selected_novig_pct,2) discrepancy_pp,bookmaker
    from public.v_reto_editorial_pool_v2
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours) and market_selected_novig_pct is not null
    order by abs(probabilidad_pct-market_selected_novig_pct) desc,arranca_en limit 1
  ) x;

  select to_jsonb(x) into v_avoid from (
    select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,confidence_band,discriminacion_pp,
      case when market_selected_novig_pct is not null then round(probabilidad_pct-market_selected_novig_pct,2) end discrepancy_pp,
      case when confidence_band='CAUTELOSA' then 'CONFIANZA_CAUTEL0SA'
           when market_selected_novig_pct is not null and abs(probabilidad_pct-market_selected_novig_pct)>=12 then 'FUERTE_DESACUERDO_CON_MERCADO'
           else 'MAYOR_CAUTELA_RELATIVA' end reason
    from public.v_reto_editorial_pool_v2
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours)
    order by (confidence_band='CAUTELOSA') desc,
      abs(coalesce(probabilidad_pct-market_selected_novig_pct,0)) desc,discriminacion_pp asc,arranca_en limit 1
  ) x;

  select to_jsonb(x) into v_upset from (
    select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,selected_side,market_favorite_side,
      market_selected_novig_pct,round(probabilidad_pct-market_selected_novig_pct,2) discrepancy_pp,bookmaker
    from public.v_reto_editorial_pool_v2
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours)
      and market_favorite_side is not null and selected_side is not null and selected_side<>market_favorite_side and probabilidad_pct>=40
    order by probabilidad_pct desc,discriminacion_pp desc,arranca_en limit 1
  ) x;

  v_parlay:=public.reto_parlay_generate_v2('CONSERVADOR',least(p_horizon_hours,192),100000);

  if p_apodo is null then v_fantasy:=jsonb_build_object('status','NOT_PERSONALIZED');
  else
    select jsonb_build_object('status','READY','season',s.season,'week',s.week,'decision_time',s.decision_time,'model_version',s.model_version,
      'move',m.value,'recommendation_id',s.recommendation_id)
    into v_fantasy
    from v2.fantasy_recommendation_snapshot_v3 s cross join lateral jsonb_array_elements(s.changes) m(value)
    where s.apodo=p_apodo and jsonb_array_length(s.changes)>0
    order by s.season desc,s.week desc,s.decision_time desc,coalesce((m.value->>'ganancia')::numeric,-999) desc limit 1;
    if v_fantasy is null then v_fantasy:=jsonb_build_object('status','NO_RECOMMENDED_MOVE_YET'); end if;
  end if;

  select jsonb_agg(jsonb_build_object('sport',sport,'product_ready_scopes',ready,'blocked_scopes',blocked) order by sport)
  into v_coverage from (
    select sport,count(*) filter(where product_release_authorized) ready,count(*) filter(where not product_release_authorized) blocked
    from public.v_reto_brain_release_authority_v1 group by sport
  ) z;

  return jsonb_build_object('ok',true,'status','READY','contract_version','reto_lo_mejor_editorial_v2','generated_at',now(),
    'top_opportunity',coalesce(v_top,jsonb_build_object('status','NONE_IN_WINDOW')),
    'safest_by_p_reto',coalesce(v_safe,jsonb_build_object('status','NONE_IN_WINDOW')),
    'biggest_model_market_disagreement',coalesce(v_disagree,jsonb_build_object('status','NO_MARKET_COMPARISON')),
    'avoid_or_caution',coalesce(v_avoid,jsonb_build_object('status','NONE_IN_WINDOW')),
    'upset_watch',coalesce(v_upset,jsonb_build_object('status','NONE_QUALIFIED')),
    'reto_parlay',v_parlay,'fantasy_move_of_week',v_fantasy,'coverage',v_coverage,
    'labels',jsonb_build_object('biggest_disagreement','No significa edge ni EV. Sólo mide cuánto difieren RETO y mercado.',
      'avoid','No revoca un pick oficial; señala el evento que merece mayor cautela relativa.'),
    'principles',jsonb_build_object('one_brain',true,'editorial_creates_probability',false,'market_creates_pick',false,'heavy_model_recomputed_on_read',false));
end $$;
