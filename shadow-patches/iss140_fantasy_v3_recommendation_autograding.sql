-- ISS140 — Fantasy V3 recommendation snapshots + autograding.
-- ADDITIVE ONLY. B1 / existing Fantasy functions remain untouched.

create table if not exists v2.fantasy_recommendation_snapshot_v3 (
  recommendation_id uuid primary key default gen_random_uuid(),
  apodo text not null,
  season integer not null,
  week integer not null,
  decision_time timestamptz not null,
  model_version text not null,
  engine text not null,
  summary jsonb not null default '{}'::jsonb,
  changes jsonb not null default '[]'::jsonb,
  players jsonb not null default '[]'::jsonb,
  source_payload jsonb not null,
  captured_at timestamptz not null default now(),
  grading jsonb,
  graded_at timestamptz,
  unique(apodo,season,week,decision_time,model_version)
);

create or replace function v2.guard_fantasy_recommendation_snapshot_v3()
returns trigger language plpgsql set search_path='v2','public','pg_temp' as $$
begin
  if new.apodo is distinct from old.apodo or new.season is distinct from old.season or new.week is distinct from old.week
     or new.decision_time is distinct from old.decision_time or new.model_version is distinct from old.model_version
     or new.engine is distinct from old.engine or new.summary is distinct from old.summary
     or new.changes is distinct from old.changes or new.players is distinct from old.players
     or new.source_payload is distinct from old.source_payload or new.captured_at is distinct from old.captured_at then
    raise exception 'Fantasy recommendation snapshot is immutable; only grading fields may change';
  end if;
  return new;
end $$;

drop trigger if exists trg_fantasy_recommendation_snapshot_v3 on v2.fantasy_recommendation_snapshot_v3;
create trigger trg_fantasy_recommendation_snapshot_v3
before update on v2.fantasy_recommendation_snapshot_v3
for each row execute function v2.guard_fantasy_recommendation_snapshot_v3();

create or replace function v2.capture_fantasy_recommendation_v3(
  p_apodo text,p_season integer,p_week integer,p_asof timestamptz default now(),p_mode text default 'BALANCEADO'
) returns jsonb
language plpgsql security definer set search_path='public','v2','pg_temp' as $$
declare r jsonb; v_id uuid; v_decision timestamptz:=date_trunc('hour',p_asof); v_model text:='fantasy-b1-rq80-2026.09.1';
begin
  r:=v2.fantasy_start_sit_auto_v2(p_apodo,p_season,p_week,p_mode,p_asof,v_model);
  if coalesce((r->>'ok')::boolean,false)=false then return r||jsonb_build_object('capture_status','NOT_CAPTURED'); end if;
  insert into v2.fantasy_recommendation_snapshot_v3(apodo,season,week,decision_time,model_version,engine,summary,changes,players,source_payload)
  values(p_apodo,p_season,p_week,v_decision,v_model,coalesce(r->>'engine','fantasy_b1_exact_optimizer_v1'),
    coalesce(r->'resumen','{}'::jsonb),coalesce(r->'cambios','[]'::jsonb),coalesce(r->'jugadores','[]'::jsonb),r)
  on conflict(apodo,season,week,decision_time,model_version) do nothing
  returning recommendation_id into v_id;
  if v_id is null then
    select recommendation_id into v_id from v2.fantasy_recommendation_snapshot_v3
    where apodo=p_apodo and season=p_season and week=p_week and decision_time=v_decision and model_version=v_model;
  end if;
  return jsonb_build_object('ok',true,'capture_status','CAPTURED_OR_ALREADY_EXISTS','recommendation_id',v_id,'decision_time',v_decision,
    'model_version',v_model,'start_sit',r);
end $$;

grant execute on function v2.capture_fantasy_recommendation_v3(text,integer,integer,timestamptz,text) to authenticated;

create or replace function v2.grade_fantasy_recommendations_v3(
  p_apodo text default null,p_season integer default null,p_week integer default null
) returns jsonb
language plpgsql security definer set search_path='public','v2','pg_temp' as $$
declare rec record; g jsonb; v_total int:=0; v_complete int:=0;
begin
  for rec in
    select * from v2.fantasy_recommendation_snapshot_v3 s
    where (p_apodo is null or s.apodo=p_apodo) and (p_season is null or s.season=p_season) and (p_week is null or s.week=p_week)
      and jsonb_array_length(s.changes)>0
    order by s.decision_time
  loop
    with actual as (
      select player_name,max(actual_points) actual_points
      from public.lab_ff_forward
      where temporada=rec.season and semana=rec.week and actual_points is not null
      group by player_name
    ), ch as (
      select e.ordinality ord,e.value j from jsonb_array_elements(rec.changes) with ordinality e(value,ordinality)
    ), scored as (
      select ord,j->>'entra' entra,j->>'sale' sale,
        ai.actual_points actual_entra,ao.actual_points actual_sale,
        case when ai.actual_points is not null and ao.actual_points is not null then round(ai.actual_points-ao.actual_points,2) end realized_delta
      from ch left join actual ai on ai.player_name=j->>'entra' left join actual ao on ao.player_name=j->>'sale'
    )
    select jsonb_build_object(
      'status',case when count(*) filter(where actual_entra is not null and actual_sale is not null)=count(*) then 'COMPLETE' else 'PARTIAL' end,
      'changes',coalesce(jsonb_agg(jsonb_build_object('entra',entra,'sale',sale,'actual_entra',actual_entra,'actual_sale',actual_sale,
        'realized_delta',realized_delta,'recommendation_won',case when realized_delta is null then null else realized_delta>0 end) order by ord),'[]'::jsonb),
      'graded_changes',count(*) filter(where actual_entra is not null and actual_sale is not null),
      'total_changes',count(*),
      'wins',count(*) filter(where realized_delta>0),
      'losses',count(*) filter(where realized_delta<0),
      'ties',count(*) filter(where realized_delta=0),
      'realized_gain_total',round(coalesce(sum(realized_delta),0),2),
      'graded_from','lab_ff_forward actual_points') into g
    from scored;

    update v2.fantasy_recommendation_snapshot_v3
      set grading=g,graded_at=case when g->>'status'='COMPLETE' then now() else graded_at end
    where recommendation_id=rec.recommendation_id;
    v_total:=v_total+1;
    if g->>'status'='COMPLETE' then v_complete:=v_complete+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'snapshots_checked',v_total,'complete',v_complete,'partial',v_total-v_complete);
end $$;

grant execute on function v2.grade_fantasy_recommendations_v3(text,integer,integer) to authenticated;

create or replace function public.fantasy_week_hub_v3(
  p_apodo text,p_season integer,p_week integer,p_mode text default 'BALANCEADO',p_asof timestamptz default now()
) returns jsonb
language plpgsql security definer set search_path='public','v2','pg_temp' as $$
declare ss jsonb; cierre jsonb; last_grade jsonb; v_real_league text; v_waivers jsonb; v_capture jsonb;
begin
  ss:=v2.fantasy_start_sit_auto_v2(p_apodo,p_season,p_week,p_mode,p_asof,'fantasy-b1-rq80-2026.09.1');
  cierre:=public.fantasy_cierre_semana(p_week,p_season);
  v_capture:=v2.capture_fantasy_recommendation_v3(p_apodo,p_season,p_week,p_asof,p_mode);
  perform v2.grade_fantasy_recommendations_v3(p_apodo,p_season,null);

  select jsonb_build_object('season',season,'week',week,'decision_time',decision_time,'grading',grading,'graded_at',graded_at)
  into last_grade from v2.fantasy_recommendation_snapshot_v3
  where apodo=p_apodo and season=p_season and grading is not null and week<p_week
  order by week desc,decision_time desc limit 1;

  select league_id into v_real_league from public.lab_ff_ownership
  where temporada=p_season and semana=p_week and league_id not like 'E2E%' limit 1;
  if v_real_league is null then
    v_waivers:=jsonb_build_object('status','LEAGUE_OWNERSHIP_NOT_CONNECTED','recommendations','[]'::jsonb,
      'reason','RETO no adivina quién está libre: conecta/sincroniza ownership real de la liga antes de recomendar waivers.');
  else
    select jsonb_build_object('status','READY','league_id',v_real_league,'recommendations',coalesce(jsonb_agg(to_jsonb(w) order by w.starter_delta desc nulls last),'[]'::jsonb))
    into v_waivers from (select * from public.lab_ff_waivers_v2(v_real_league,p_season,p_week) order by starter_delta desc nulls last limit 12) w;
  end if;

  return jsonb_build_object('ok',coalesce((ss->>'ok')::boolean,false),'contract_version','fantasy_week_hub_v3','brain','fantasy-b1-rq80-2026.09.1',
    'start_sit',ss,'week_close',cierre,'waivers',v_waivers,'previous_week_self_grade',coalesce(last_grade,jsonb_build_object('status','NO_GRADED_RECOMMENDATION_YET')),
    'capture',jsonb_build_object('status',v_capture->>'capture_status','recommendation_id',v_capture->'recommendation_id'),
    'modules',jsonb_build_object('start_sit','READY','floor_median_ceiling','READY','locks','READY','autograding','READY_FORWARD_ONLY',
      'waivers',v_waivers->>'status','trade_analyzer','NEXT_MODULE','playoff_simulator','BLOCKED_UNTIL_LEAGUE_STATE_SYNC'),
    'principles',jsonb_build_object('one_brain',true,'k_dst_projection_invented',false,'ownership_invented',false,'past_recomputed',false));
end $$;

grant execute on function public.fantasy_week_hub_v3(text,integer,integer,text,timestamptz) to authenticated;
