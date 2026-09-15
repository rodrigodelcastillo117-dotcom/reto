-- ISS152 — Parlay selection on the same global official authority.
-- No per-sport quota, no research rows, no market selection, zero filler.

create or replace function public.reto_parlay_generate_v2(p_profile text default 'EQUILIBRADO', p_horizon_hours integer default 48, p_scenarios integer default 100000)
returns jsonb language plpgsql stable security definer set search_path to 'public','v2','pg_temp' as $$
declare
  v_profile text:=upper(trim(coalesce(p_profile,'EQUILIBRADO')));
  v_target int; v_min_p numeric; v_min_sep numeric; v_allowed_conf text[]; v_legs jsonb; v_n int; v_lab jsonb;
begin
  if v_profile='CONSERVADOR' then v_target:=2; v_min_p:=65; v_min_sep:=15; v_allowed_conf:=array['ALTA'];
  elsif v_profile='EQUILIBRADO' then v_target:=3; v_min_p:=60; v_min_sep:=10; v_allowed_conf:=array['ALTA','MEDIA'];
  elsif v_profile='AGRESIVO' then v_target:=4; v_min_p:=55; v_min_sep:=5; v_allowed_conf:=array['ALTA','MEDIA','CAUTELOSA'];
  else return jsonb_build_object('ok',false,'status','INVALID_PROFILE','allowed',jsonb_build_array('CONSERVADOR','EQUILIBRADO','AGRESIVO')); end if;
  if p_horizon_hours<1 or p_horizon_hours>48 then return jsonb_build_object('ok',false,'status','INVALID_HORIZON','min_hours',1,'max_hours',48); end if;

  with eligible as (
    select c.*,row_number() over(partition by c.competition_scope order by c.p_reto_pct desc,c.separation_pp desc nulls last,c.kickoff,c.espn_event_id) competition_rn
    from public.v_reto_parlay_candidate_pool_v2_fast c
    where c.kickoff<=now()+make_interval(hours=>p_horizon_hours)
      and c.p_reto_pct>=v_min_p and coalesce(c.separation_pp,0)>=v_min_sep and c.confidence_band=any(v_allowed_conf)
      and c.product_release_authorized and c.canonical_leg
  ), chosen as (
    select * from eligible where competition_rn=1 order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id limit v_target
  )
  select count(*)::int,coalesce(jsonb_agg(jsonb_build_object('espn_event_id',espn_event_id,'market',market,'pick',pick)
    order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id),'[]'::jsonb)
  into v_n,v_legs from chosen;

  if v_n<v_target then return jsonb_build_object('ok',true,'status','NO_QUALITY_PARLAY','profile',v_profile,
    'target_legs',v_target,'eligible_diversified_legs',v_n,'legs',v_legs,
    'thresholds',jsonb_build_object('min_p_reto_pct',v_min_p,'min_model_separation_pp',v_min_sep,'allowed_confidence',v_allowed_conf),
    'selection_role','GLOBAL_OFFICIAL_P_RETO_ONLY','market_used_for_selection',false,'sport_quota_used',false,
    'reason','RETO prefiere no fabricar un parlay cuando faltan patas oficiales que cumplan el perfil.'); end if;

  v_lab:=public.reto_parlay_lab_v2(v_legs,p_scenarios);
  return jsonb_build_object('ok',coalesce((v_lab->>'ok')::boolean,false),'status',v_lab->>'status','profile',v_profile,
    'profile_contract',case v_profile when 'CONSERVADOR' then '2 patas · P_RETO>=65 · separacion>=15pp · una por competición'
      when 'EQUILIBRADO' then '3 patas · P_RETO>=60 · separacion>=10pp · una por competición'
      else '4 patas · P_RETO>=55 · separacion>=5pp · una por competición' end,
    'selection_role','GLOBAL_OFFICIAL_P_RETO_ONLY','market_used_for_selection',false,'sport_quota_used',false,
    'sport_coverage','ALL_PRODUCT_AUTHORIZED_SPORTS_IN_GLOBAL_TOP','lab',v_lab);
end $$;

create or replace function public.parlay_del_dia_v3(p_ventana_horas integer default 48)
returns jsonb language sql stable security definer set search_path to 'public' as $$
with base as (
  select c.*
  from public.v_reto_parlay_candidate_pool_v2_fast c
  where c.kickoff>=now()
    and c.kickoff<=now()+make_interval(hours=>least(greatest(p_ventana_horas,1),48))
    and c.product_release_authorized
    and c.canonical_leg
), fila as (
  select b.*,
    jsonb_build_object(
      'deporte',b.sport,'liga',b.competition_name,'partido',b.home_team||' vs '||b.away_team,
      'arranca_en',b.kickoff,'mercado',b.market,'pick',b.pick,'probabilidad_pct',b.p_reto_pct,
      'separacion_modelo_pp',b.separation_pp,'calibracion_confiable',true,
      'muestra_calibracion',null,'contexto_mercado',jsonb_build_object('momio_mercado',b.selected_decimal_odds,'casa',b.odds_bookmaker),
      'es_lock',false,'espn_event_id',b.espn_event_id,'rank_global',b.rank_global
    ) as j
  from base b
), top3 as (
  select * from fila order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id limit 3
), alta as (
  select * from fila where confidence_band='ALTA' order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id limit 5
), top6 as (
  select * from fila order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id limit 6
)
select jsonb_build_object(
  'generado_at',now(),
  'ventana_horas',least(greatest(p_ventana_horas,1),48),
  'nota_ventana','Todos los deportes compiten en la misma ventana global. No hay cupos por deporte.',
  'criterio','Selección global exclusivamente por P_RETO oficial y separación interna del modelo. Momio/precio sólo contexto.',
  'deportes_disponibles',(select coalesce(jsonb_agg(distinct sport),'[]'::jsonb) from base),
  'bloque_1_los_3_mejores',jsonb_build_object('descripcion','Los 3 mejores candidatos oficiales globales, sin obligación por deporte','picks',coalesce((select jsonb_agg(j order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id) from top3),'[]'::jsonb)),
  'bloque_2_mas_arriesgado',jsonb_build_object('descripcion','Hasta 5 candidatos de confianza ALTA; puede quedar vacío','picks',coalesce((select jsonb_agg(j order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id) from alta),'[]'::jsonb)),
  'bloque_3_los_6',jsonb_build_object('descripcion','Los 6 mejores globales. Cero relleno si hay menos','picks',coalesce((select jsonb_agg(j order by p_reto_pct desc,separation_pp desc nulls last,kickoff,espn_event_id) from top6),'[]'::jsonb)),
  'principles',jsonb_build_object('one_brain',true,'sport_quota',false,'market_selects',false,'research_allowed',false,'joint_probability_published',false)
);
$$;
