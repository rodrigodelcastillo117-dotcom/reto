-- ISS142 — FutPro Premium Terminal V1
-- ADDITIVE ONLY. Does not replace v_futpro_publication_v3 / Pick Story / dossier functions.
-- Official prediction authority remains Pick Story / RETO Brain. Secondary markets and shot-derived xG are diagnostic only.

create or replace function public.futpro_terminal_v1(p_espn_event_id text)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  s jsonb;
  d jsonb;
  v_home text;
  v_away text;
  v_kickoff timestamptz;
  v_model text;
  v_timeline jsonb;
  v_secondary jsonb;
  v_xg_home jsonb;
  v_xg_away jsonb;
  v_xg_status text;
  v_home_n int;
  v_away_n int;
  v_home_latest timestamptz;
  v_away_latest timestamptz;
begin
  s:=public.reto_pick_story_v1(p_espn_event_id);
  if coalesce((s->>'ok')::boolean,false)=false then
    return s||jsonb_build_object('contract_version','futpro_terminal_v1');
  end if;

  select f.home_team,f.away_team,f.kickoff,f.model_version
    into v_home,v_away,v_kickoff,v_model
  from public.v_futpro_publication_v3 f
  where f.canonical_event_id=p_espn_event_id
  limit 1;

  if v_home is null then
    return jsonb_build_object('ok',false,'status','EVENT_NOT_FOUND','espn_event_id',p_espn_event_id,'contract_version','futpro_terminal_v1');
  end if;

  d:=public.construir_dossier_partido_base(p_espn_event_id,null);

  select coalesce(jsonb_agg(jsonb_build_object(
      'snapshot_at',t.snapshot_at,
      'home_pct',round(100*t.p1,2),
      'draw_pct',round(100*t.p2,2),
      'away_pct',round(100*t.p3,2),
      'model_version',t.model_version,
      'feature_version',t.feature_version,
      'temporal_safe',t.temporal_safe
    ) order by t.snapshot_at),'[]'::jsonb)
    into v_timeline
  from (
    select * from public.v_reto_brain_prediction_timeline_v1 x
    where x.espn_event_id=p_espn_event_id
      and x.sport='soccer'
      and x.market='1X2'
      and x.model_version=v_model
      and x.temporal_safe
      and x.snapshot_at<v_kickoff
    order by x.snapshot_at desc
    limit 32
  ) t;

  select coalesce(jsonb_agg(jsonb_build_object(
      'market',x.market,
      'snapshot_at',x.snapshot_at,
      'label_1',x.p1_label,'p1_pct',round(100*x.p1,2),
      'label_2',x.p2_label,'p2_pct',round(100*x.p2,2),
      'line',x.line,
      'status','NOT_RELEASE_AUTHORIZED',
      'role','MODEL_DIAGNOSTIC_ONLY'
    ) order by x.market),'[]'::jsonb)
    into v_secondary
  from (
    select distinct on(market) *
    from public.v_reto_brain_prediction_timeline_v1 q
    where q.espn_event_id=p_espn_event_id
      and q.sport='soccer'
      and q.market in ('BTTS','Over/Under')
      and q.model_version=v_model
      and q.temporal_safe
      and q.snapshot_at<v_kickoff
    order by market,snapshot_at desc
  ) x;

  with z as (
    select fecha,xg_est_favor,xg_est_contra
    from public.v_equipo_partido_espn_xg
    where equipo=v_home and fecha<v_kickoff
      and xg_est_favor is not null and xg_est_contra is not null
    order by fecha desc limit 8
  )
  select count(*)::int,max(fecha),
    jsonb_build_object('team',v_home,'n',count(*),'avg_xg_est_for',round(avg(xg_est_favor),2),
      'avg_xg_est_against',round(avg(xg_est_contra),2),'latest_match',max(fecha))
    into v_home_n,v_home_latest,v_xg_home from z;

  with z as (
    select fecha,xg_est_favor,xg_est_contra
    from public.v_equipo_partido_espn_xg
    where equipo=v_away and fecha<v_kickoff
      and xg_est_favor is not null and xg_est_contra is not null
    order by fecha desc limit 8
  )
  select count(*)::int,max(fecha),
    jsonb_build_object('team',v_away,'n',count(*),'avg_xg_est_for',round(avg(xg_est_favor),2),
      'avg_xg_est_against',round(avg(xg_est_contra),2),'latest_match',max(fecha))
    into v_away_n,v_away_latest,v_xg_away from z;

  v_xg_status:=case
    when coalesce(v_home_n,0)>=8 and coalesce(v_away_n,0)>=8
     and v_home_latest>=v_kickoff-interval '120 days'
     and v_away_latest>=v_kickoff-interval '120 days'
      then 'AVAILABLE_DIAGNOSTIC_ESTIMATE'
    else 'UNAVAILABLE_INSUFFICIENT_DEFENSIBLE_SAMPLE' end;

  return jsonb_build_object(
    'ok',true,
    'status',coalesce(s->>'status','UNKNOWN'),
    'contract_version','futpro_terminal_v1',
    'official_story',s,
    'probability_timeline',jsonb_build_object(
      'status',case when jsonb_array_length(v_timeline)>0 then 'READY' else 'NO_HISTORY' end,
      'market','1X2','authority','CANONICAL_P_RETO','snapshots',v_timeline),
    'secondary_markets',jsonb_build_object(
      'status','NOT_RELEASE_AUTHORIZED',
      'role','MODEL_DIAGNOSTIC_ONLY',
      'note','BTTS/totales pueden mostrarse como lectura del modelo, nunca como pick oficial hasta pasar un gate científico propio.',
      'latest',v_secondary),
    'estimated_xg',jsonb_build_object(
      'status',v_xg_status,
      'source_kind','SHOT_DERIVED_ESTIMATE_NOT_OFFICIAL_XG',
      'authority','DIAGNOSTIC_ONLY',
      'minimum_sample_each_team',8,
      'freshness_days',120,
      'home',case when v_xg_status='AVAILABLE_DIAGNOSTIC_ESTIMATE' then v_xg_home end,
      'away',case when v_xg_status='AVAILABLE_DIAGNOSTIC_ESTIMATE' then v_xg_away end,
      'note','No se etiqueta como xG oficial; si la muestra no es defendible se oculta.'),
    'match_context',jsonb_build_object(
      'recent_form',s#>'{context,recent_form}',
      'h2h',s#>'{context,h2h}',
      'injuries',s#>'{context,injuries}',
      'lineups',s#>'{context,lineups}',
      'schedule',s#>'{context,schedule}',
      'line_movement',s#>'{context,line_movement}',
      'data_quality',s#>'{context,data_quality}'),
    'availability',jsonb_build_object(
      'lineups',case when coalesce((d#>>'{calidad_datos,tiene_alineaciones}')::boolean,false) then 'AVAILABLE' else 'NOT_CONFIRMED' end,
      'h2h',case when coalesce((d#>>'{calidad_datos,tiene_h2h}')::boolean,false) then 'AVAILABLE' else 'INSUFFICIENT' end,
      'market',case when coalesce((d#>>'{calidad_datos,tiene_momios}')::boolean,false) then 'AVAILABLE_DIAGNOSTIC' else 'UNAVAILABLE' end),
    'principles',jsonb_build_object(
      'one_brain',true,
      'secondary_markets_can_override_pick',false,
      'estimated_xg_can_override_pick',false,
      'missing_data_invented',false,
      'legacy_contracts_mutated',false));
end $$;

grant execute on function public.futpro_terminal_v1(text) to anon,authenticated;

create or replace view public.v_futpro_terminal_v1_invariant_leaks as
select espn_event_id,leak from public.v_reto_pick_story_invariant_leaks_v1
union all
select t.espn_event_id,'UNSAFE_OFFICIAL_TIMELINE'::text leak
from public.v_reto_brain_prediction_timeline_v1 t
join public.v_reto_pick_story_cards_v1 c on c.espn_event_id=t.espn_event_id and c.model_version=t.model_version
where t.sport='soccer' and t.market='1X2'
  and (not t.temporal_safe or t.snapshot_at>=t.kickoff);

grant select on public.v_futpro_terminal_v1_invariant_leaks to authenticated;
