-- ISS154 — release P0: Parlay must consume ONLY the global official P_RETO pool.
-- Removes the remaining dependency on legacy v_reto13m_lo_mejor recomputation,
-- sport quotas and market/separation-based selection. Odds remain diagnostic only.

create or replace view public.v_reto_parlay_candidate_pool_v2_fast as
select
  g.espn_event_id,
  g.sport,
  g.league_name as competition_scope,
  g.league_name as competition_name,
  g.home_team,
  g.away_team,
  g.kickoff,
  g.market,
  g.selection_label as pick,
  g.p_reto_pct,
  null::numeric as separation_pp,
  case
    when g.p_reto_pct >= 65 then 'P_RETO_HIGH'
    when g.p_reto_pct >= 58 then 'P_RETO_MEDIUM'
    else 'P_RETO_CAUTION'
  end as confidence_band,
  g.model_version,
  g.validation_status as calibration_version,
  null::text as canonical_pick_version,
  'READY'::text as canonical_pick_status,
  true as selector_authoritative,
  true as top_only_authoritative,
  'FROZEN'::text as rank_policy_status,
  true as scientific_ready,
  true as product_release_authorized,
  false as money_authorized,
  o.selected_decimal_odds,
  o.bookmaker as odds_bookmaker,
  o.book_implied_raw_pct,
  case when o.book_implied_raw_pct is not null then round(g.p_reto_pct-o.book_implied_raw_pct,2) end as discrepancy_vs_book_raw_pp,
  row_number() over(partition by g.sport order by g.rank_global) as rn_deporte,
  g.rank_global,
  'GLOBAL_OFFICIAL_P_RETO'::text as razon,
  true as canonical_leg
from public.v_reto13m_global_top_v2 g
left join lateral (
  select
    case
      when lower(g.selection_label) like 'empate%' then x.draw_ml
      when lower(g.selection_label) like ('gana '||lower(g.home_team)||'%') then x.home_ml
      when lower(g.selection_label) like ('gana '||lower(g.away_team)||'%') then x.away_ml
      else null
    end as selected_decimal_odds,
    x.bookmaker,
    case
      when x.home_ml>1 and x.draw_ml>1 and x.away_ml>1 then
        case
          when lower(g.selection_label) like 'empate%' then 100*(1/x.draw_ml)/(1/x.home_ml+1/x.draw_ml+1/x.away_ml)
          when lower(g.selection_label) like ('gana '||lower(g.home_team)||'%') then 100*(1/x.home_ml)/(1/x.home_ml+1/x.draw_ml+1/x.away_ml)
          when lower(g.selection_label) like ('gana '||lower(g.away_team)||'%') then 100*(1/x.away_ml)/(1/x.home_ml+1/x.draw_ml+1/x.away_ml)
          else null
        end
      else null
    end as book_implied_raw_pct
  from public.v_momios_confiables x
  where x.espn_event_id=g.espn_event_id and x.confiable
  order by x.snapshot_at desc
  limit 1
) o on true
where g.product_authorized
  and g.display_class='OFFICIAL_P_RETO';

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
      'separacion_modelo_pp',null,'calibracion_confiable',true,
      'muestra_calibracion',null,'contexto_mercado',jsonb_build_object('momio_mercado',b.selected_decimal_odds,'casa',b.odds_bookmaker),
      'es_lock',false,'espn_event_id',b.espn_event_id,'rank_global',b.rank_global
    ) as j
  from base b
), top3 as (
  select * from fila order by p_reto_pct desc,kickoff,espn_event_id limit 3
), alta as (
  select * from fila where p_reto_pct>=65 order by p_reto_pct desc,kickoff,espn_event_id limit 5
), top6 as (
  select * from fila order by p_reto_pct desc,kickoff,espn_event_id limit 6
)
select jsonb_build_object(
  'generado_at',now(),
  'ventana_horas',least(greatest(p_ventana_horas,1),48),
  'nota_ventana','Todos los deportes con autoridad de producto compiten en la misma ventana global. No hay cupos por deporte.',
  'criterio','Selección global exclusivamente por P_RETO oficial. Momio/precio sólo contexto y nunca selecciona, ordena ni autoriza.',
  'deportes_disponibles',(select coalesce(jsonb_agg(distinct sport),'[]'::jsonb) from base),
  'bloque_1_los_3_mejores',jsonb_build_object('descripcion','Los 3 mejores candidatos oficiales globales, sin obligación por deporte','picks',coalesce((select jsonb_agg(j order by p_reto_pct desc,kickoff,espn_event_id) from top3),'[]'::jsonb)),
  'bloque_2_mas_arriesgado',jsonb_build_object('descripcion','Hasta 5 candidatos oficiales con P_RETO >= 65%; puede quedar vacío','picks',coalesce((select jsonb_agg(j order by p_reto_pct desc,kickoff,espn_event_id) from alta),'[]'::jsonb)),
  'bloque_3_los_6',jsonb_build_object('descripcion','Los 6 mejores globales. Cero relleno si hay menos','picks',coalesce((select jsonb_agg(j order by p_reto_pct desc,kickoff,espn_event_id) from top6),'[]'::jsonb)),
  'principles',jsonb_build_object('one_brain',true,'sport_quota',false,'market_selects',false,'research_allowed',false,'joint_probability_published',false)
);
$$;

create or replace function public.reto_parlay_generate_v2(p_profile text default 'EQUILIBRADO', p_horizon_hours integer default 48, p_scenarios integer default 100000)
returns jsonb language plpgsql stable security definer set search_path to 'public','v2','pg_temp' as $$
declare
  v_profile text:=upper(trim(coalesce(p_profile,'EQUILIBRADO'));
  v_target int; v_min_p numeric; v_legs jsonb; v_n int; v_lab jsonb;
begin
  if v_profile='CONSERVADOR' then v_target:=2; v_min_p:=65;
  elsif v_profile='EQUILIBRADO' then v_target:=3; v_min_p:=60;
  elsif v_profile='AGRESIVO' then v_target:=4; v_min_p:=55;
  else return jsonb_build_object('ok',false,'status','INVALID_PROFILE','allowed',jsonb_build_array('CONSERVADOR','EQUILIBRADO','AGRESIVO')); end if;
  if p_horizon_hours<1 or p_horizon_hours>48 then return jsonb_build_object('ok',false,'status','INVALID_HORIZON','min_hours',1,'max_hours',48); end if;

  with eligible as (
    select c.*,row_number() over(partition by c.competition_scope order by c.p_reto_pct desc,c.kickoff,c.espn_event_id) competition_rn
    from public.v_reto_parlay_candidate_pool_v2_fast c
    where c.kickoff>=now() and c.kickoff<=now()+make_interval(hours=>p_horizon_hours)
      and c.p_reto_pct>=v_min_p and c.product_release_authorized and c.canonical_leg
  ), chosen as (
    select * from eligible where competition_rn=1 order by p_reto_pct desc,kickoff,espn_event_id limit v_target
  )
  select count(*)::int,coalesce(jsonb_agg(jsonb_build_object('espn_event_id',espn_event_id,'market',market,'pick',pick)
    order by p_reto_pct desc,kickoff,espn_event_id),'[]'::jsonb)
  into v_n,v_legs from chosen;

  if v_n<v_target then return jsonb_build_object('ok',true,'status','NO_QUALITY_PARLAY','profile',v_profile,
    'target_legs',v_target,'eligible_diversified_legs',v_n,'legs',v_legs,
    'thresholds',jsonb_build_object('min_p_reto_pct',v_min_p),
    'reason','RETO prefiere no fabricar un parlay cuando faltan patas oficiales que cumplan el perfil.'); end if;

  v_lab:=public.reto_parlay_lab_v2(v_legs,p_scenarios);
  return jsonb_build_object('ok',coalesce((v_lab->>'ok')::boolean,false),'status',v_lab->>'status','profile',v_profile,
    'profile_contract',case v_profile when 'CONSERVADOR' then '2 patas · P_RETO>=65 · una por competición'
      when 'EQUILIBRADO' then '3 patas · P_RETO>=60 · una por competición'
      else '4 patas · P_RETO>=55 · una por competición' end,
    'selection_role','GLOBAL_OFFICIAL_P_RETO_ONLY','market_used_for_selection',false,'sport_quota_used',false,
    'sport_coverage','ALL_PRODUCT_AUTHORIZED_SPORTS_IN_GLOBAL_TOP','lab',v_lab);
end $$;