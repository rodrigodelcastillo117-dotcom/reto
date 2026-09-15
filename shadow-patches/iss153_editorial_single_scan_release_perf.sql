-- ISS153 — editorial release contract on global TOP_ONLY with a single materialized scan.
-- Fixes repeated heavy model recomputation/timeouts while preserving market-as-diagnostic semantics.

create or replace function public.reto_lo_mejor_editorial_v2(p_apodo text default null, p_horizon_hours integer default 48)
returns jsonb language plpgsql stable security definer set search_path to 'public','v2','pg_temp' as $$
declare
  v_top jsonb; v_safe jsonb; v_disagree jsonb; v_avoid jsonb; v_upset jsonb; v_parlay jsonb; v_fantasy jsonb; v_coverage jsonb;
begin
  if p_horizon_hours<1 or p_horizon_hours>48 then return jsonb_build_object('ok',false,'status','INVALID_HORIZON','min_hours',1,'max_hours',48); end if;

  with pool as materialized (
    select * from public.v_reto_editorial_pool_v2
    where arranca_en>=now() and arranca_en<=now()+make_interval(hours=>p_horizon_hours)
  )
  select
    (select to_jsonb(x) from (select espn_event_id,deporte,liga,home,away,arranca_en,mercado,pick_desc,probabilidad_pct,model_version,discriminacion_pp,confidence_band from pool order by rank_global nulls last,probabilidad_pct desc limit 1) x),
    (select to_jsonb(x) from (select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,confidence_band,discriminacion_pp,model_version from pool order by probabilidad_pct desc,discriminacion_pp desc nulls last,arranca_en limit 1) x),
    (select to_jsonb(x) from (select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,market_selected_novig_pct,round(probabilidad_pct-market_selected_novig_pct,2) discrepancy_pp,bookmaker from pool where market_selected_novig_pct is not null order by abs(probabilidad_pct-market_selected_novig_pct) desc,arranca_en limit 1) x),
    (select to_jsonb(x) from (select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,confidence_band,discriminacion_pp,case when market_selected_novig_pct is not null then round(probabilidad_pct-market_selected_novig_pct,2) end discrepancy_pp,case when confidence_band='CAUTELOSA' then 'CONFIANZA_BAJA_RELATIVA' when market_selected_novig_pct is not null and abs(probabilidad_pct-market_selected_novig_pct)>=12 then 'FUERTE_DESACUERDO_CON_MERCADO' else 'MAYOR_CAUTELA_RELATIVA' end reason from pool order by (confidence_band='CAUTELOSA') desc,abs(coalesce(probabilidad_pct-market_selected_novig_pct,0)) desc,discriminacion_pp asc nulls last,arranca_en limit 1) x),
    (select to_jsonb(x) from (select espn_event_id,liga,home,away,arranca_en,pick_desc,probabilidad_pct,selected_side,market_favorite_side,market_selected_novig_pct,round(probabilidad_pct-market_selected_novig_pct,2) discrepancy_pp,bookmaker from pool where market_favorite_side is not null and selected_side is not null and selected_side<>market_favorite_side and probabilidad_pct>=40 order by probabilidad_pct desc,discriminacion_pp desc nulls last,arranca_en limit 1) x)
  into v_top,v_safe,v_disagree,v_avoid,v_upset;

  v_parlay:=public.reto_parlay_generate_v2('CONSERVADOR',p_horizon_hours,100000);

  if p_apodo is null then v_fantasy:=jsonb_build_object('status','NOT_PERSONALIZED');
  else
    select jsonb_build_object('status','READY','season',s.season,'week',s.week,'decision_time',s.decision_time,'model_version',s.model_version,'move',m.value,'recommendation_id',s.recommendation_id)
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
    'labels',jsonb_build_object('biggest_disagreement','No significa edge ni EV. Sólo mide cuánto difieren RETO y mercado.','avoid','No revoca un pick oficial; señala el evento que merece mayor cautela relativa.'),
    'principles',jsonb_build_object('one_brain',true,'top_only_global',true,'sport_quota',false,'editorial_creates_probability',false,'market_creates_pick',false,'research_allowed_in_official',false,'heavy_model_recomputed_on_read',false));
end $$;
