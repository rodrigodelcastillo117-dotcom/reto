-- ISS139e — profile generator over lightweight canonical pool. ADDITIVE ONLY.
create or replace function public.reto_parlay_generate_v2(p_profile text default 'EQUILIBRADO',p_horizon_hours integer default 192,p_scenarios integer default 100000)
returns jsonb language plpgsql stable security definer set search_path='public','v2','pg_temp' as $$
declare
  v_profile text:=upper(trim(coalesce(p_profile,'EQUILIBRADO'));
  v_target int; v_min_p numeric; v_min_sep numeric; v_allowed_conf text[]; v_legs jsonb; v_n int; v_lab jsonb;
begin
  if v_profile='CONSERVADOR' then v_target:=2; v_min_p:=70; v_min_sep:=45; v_allowed_conf:=array['ALTA'];
  elsif v_profile='EQUILIBRADO' then v_target:=3; v_min_p:=64; v_min_sep:=38; v_allowed_conf:=array['ALTA','MEDIA'];
  elsif v_profile='AGRESIVO' then v_target:=4; v_min_p:=58; v_min_sep:=28; v_allowed_conf:=array['ALTA','MEDIA','CAUTELOSA'];
  else return jsonb_build_object('ok',false,'status','INVALID_PROFILE','allowed',jsonb_build_array('CONSERVADOR','EQUILIBRADO','AGRESIVO')); end if;
  if p_horizon_hours<1 or p_horizon_hours>336 then return jsonb_build_object('ok',false,'status','INVALID_HORIZON','min_hours',1,'max_hours',336); end if;

  with eligible as (
    select c.*,row_number() over(partition by c.competition_scope order by c.p_reto_pct desc,c.separation_pp desc,c.kickoff,c.espn_event_id) competition_rn
    from public.v_reto_parlay_candidate_pool_v2_fast c
    where c.kickoff<=now()+make_interval(hours=>p_horizon_hours)
      and c.p_reto_pct>=v_min_p and c.separation_pp>=v_min_sep and c.confidence_band=any(v_allowed_conf)
  ), chosen as (
    select * from eligible where competition_rn=1 order by p_reto_pct desc,separation_pp desc,kickoff,espn_event_id limit v_target
  )
  select count(*)::int,coalesce(jsonb_agg(jsonb_build_object('espn_event_id',espn_event_id,'market',market,'pick',pick)
    order by p_reto_pct desc,separation_pp desc,kickoff,espn_event_id),'[]'::jsonb)
  into v_n,v_legs from chosen;

  if v_n<v_target then return jsonb_build_object('ok',true,'status','NO_QUALITY_PARLAY','profile',v_profile,
    'target_legs',v_target,'eligible_diversified_legs',v_n,'legs',v_legs,
    'thresholds',jsonb_build_object('min_p_reto_pct',v_min_p,'min_separation_pp',v_min_sep,'allowed_confidence',v_allowed_conf),
    'reason','RETO prefiere no fabricar un parlay cuando faltan patas canónicas que cumplan el perfil.'); end if;

  v_lab:=public.reto_parlay_lab_v2(v_legs,p_scenarios);
  return jsonb_build_object('ok',coalesce((v_lab->>'ok')::boolean,false),'status',v_lab->>'status','profile',v_profile,
    'profile_contract',case v_profile when 'CONSERVADOR' then '2 patas · P_RETO>=70 · ALTA · una por competición'
      when 'EQUILIBRADO' then '3 patas · P_RETO>=64 · ALTA/MEDIA · una por competición'
      else '4 patas · P_RETO>=58 · una por competición · más varianza' end,
    'selection_role','P_RETO_AND_MODEL_SEPARATION_ONLY','market_used_for_selection',false,
    'sport_coverage','SOCCER_1X2_ONLY_UNTIL_OTHER_SPORTS_GAIN_PRODUCT_RELEASE_AUTHORITY','lab',v_lab);
end $$;

grant execute on function public.reto_parlay_generate_v2(text,integer,integer) to anon,authenticated;