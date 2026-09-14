-- ISS143 — MLB Premium Terminal + immutable pregame feature snapshots
-- ADDITIVE ONLY. Does not reactivate rejected MLB prediction models or replace legacy MLB objects.

create or replace function public.mlb_terminal_v1(p_espn_event_id text)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','pg_temp'
as $$
declare
  m public.mlb_stats_cache%rowtype;
  d jsonb;
  v_home_espn text;
  v_away_espn text;
  v_lineups jsonb;
  v_lineup_n int;
  v_weather jsonb;
  v_contact_home jsonb;
  v_contact_away jsonb;
  v_authority jsonb;
begin
  select * into m from public.mlb_stats_cache
  where espn_event_id=p_espn_event_id and fetch_success
  order by cached_at desc limit 1;
  if m.id is null then
    return jsonb_build_object('ok',false,'status','DATA_UNAVAILABLE','espn_event_id',p_espn_event_id,'contract_version','mlb_terminal_v1');
  end if;

  d:=public.construir_dossier_mlb(p_espn_event_id);
  select team_espn_id into v_home_espn from public.v_mlb_nombre_espn where nombre=m.home_team limit 1;
  select team_espn_id into v_away_espn from public.v_mlb_nombre_espn where nombre=m.away_team limit 1;

  select count(*)::int,
    coalesce(jsonb_agg(jsonb_build_object('side',lado,'order',orden,'player_id',mlb_player_id,'name',nombre,'position',posicion)
      order by lado,orden),'[]'::jsonb)
    into v_lineup_n,v_lineups
  from public.mlb_alineacion where mlb_game_pk=m.mlb_game_pk;

  if v_home_espn is not null then
    select jsonb_build_object('hora_utc',w.hora_utc,'temp_f',w.temp_f,'wind_mph',w.viento_mph,'wind_dir_deg',w.viento_dir,
      'humidity_pct',w.humedad,'rain_mm',w.lluvia_mm,
      'distance_to_first_pitch_minutes',round(abs(extract(epoch from(w.hora_utc-m.game_date)))/60.0,0))
    into v_weather
    from public.mlb_clima_hora w
    where w.team_espn_id=v_home_espn
    order by abs(extract(epoch from(w.hora_utc-m.game_date))) limit 1;
  end if;

  with z as (
    select * from public.v_mlb_contacto_equipo
    where espn_team_id=v_home_espn and fecha<m.game_date
    order by fecha desc limit 10
  ) select jsonb_build_object('games',count(*),'batted_balls',sum(batazos),'avg_exit_vel',round(avg(vel_media),1),
      'hard_hit_pct',round(avg(hard_hit_pct),1),'barrel_pct',round(avg(barrel_pct),1),'through',max(fecha))
    into v_contact_home from z;

  with z as (
    select * from public.v_mlb_contacto_equipo
    where espn_team_id=v_away_espn and fecha<m.game_date
    order by fecha desc limit 10
  ) select jsonb_build_object('games',count(*),'batted_balls',sum(batazos),'avg_exit_vel',round(avg(vel_media),1),
      'hard_hit_pct',round(avg(hard_hit_pct),1),'barrel_pct',round(avg(barrel_pct),1),'through',max(fecha))
    into v_contact_away from z;

  select coalesce(jsonb_agg(jsonb_build_object(
    'market',market,'model_version',model_version,'scientific_ready',scientific_ready,
    'product_release_authorized',product_release_authorized,'money_authorized',money_authorized,
    'release_status',release_status,'validation_status',validation_status,'reason',reason
  ) order by market,model_version),'[]'::jsonb)
  into v_authority
  from public.v_reto_brain_release_authority_v1
  where sport='baseball' and league_scope='MLB';

  return jsonb_build_object(
    'ok',true,'status','READY_ANALYSIS_NO_OFFICIAL_PICK','contract_version','mlb_terminal_v1',
    'event',jsonb_build_object('espn_event_id',p_espn_event_id,'mlb_game_pk',m.mlb_game_pk,'home',m.home_team,'away',m.away_team,
      'first_pitch',m.game_date,'park',m.park_name),
    'official_prediction',jsonb_build_object('status','NOT_RELEASE_AUTHORIZED','pick',null,'p_reto_pct',null,
      'reason','MLB Moneyline no tiene modelo aprobado; RETO muestra análisis factual sin inventar ganador.'),
    'starting_pitchers',jsonb_build_object('home',d->'abridor_local','away',d->'abridor_visitante','duel',d->'duelo_abridores'),
    'offense_splits',d->'ofensivas',
    'bullpen',d->'bullpen',
    'park',d->'partido',
    'weather',case when v_weather is not null and coalesce((v_weather->>'distance_to_first_pitch_minutes')::numeric,99999)<=180
      then jsonb_build_object('status','AVAILABLE','data',v_weather) else jsonb_build_object('status','UNAVAILABLE_OR_NOT_CLOSE_ENOUGH_TO_FIRST_PITCH') end,
    'lineups',jsonb_build_object('status',case when v_lineup_n>=18 then 'CONFIRMED_OR_COMPLETE' when v_lineup_n>0 then 'PARTIAL' else 'NOT_CONFIRMED' end,
      'rows',v_lineup_n,'players',case when v_lineup_n>0 then v_lineups else '[]'::jsonb end),
    'contact_quality',jsonb_build_object('status','DIAGNOSTIC_FACTUAL','home_last10',v_contact_home,'away_last10',v_contact_away),
    'market_context',jsonb_build_object('role','DIAGNOSTIC_ECONOMIC_ONLY','data',d->'mercado'),
    'expected_runs_reference',jsonb_build_object('status','COARSE_DIAGNOSTIC_ONLY','data',d->'total_estimado',
      'note','No es una probabilidad ni un pick oficial.'),
    'brain_authority',v_authority,
    'data_quality',d->'calidad_datos',
    'principles',jsonb_build_object('one_brain',true,'rejected_model_reactivated',false,'market_can_create_p_reto',false,
      'unvalidated_probability_shown',false,'missing_lineup_invented',false,'legacy_contracts_mutated',false));
end $$;

grant execute on function public.mlb_terminal_v1(text) to anon,authenticated;

create table if not exists v2.mlb_premium_feature_snapshot_v1 (
  snapshot_id uuid primary key default gen_random_uuid(),
  espn_event_id text not null,
  mlb_game_pk text,
  captured_at timestamptz not null,
  kickoff timestamptz not null,
  feature_version text not null default 'mlb_premium_features_v1',
  temporal_safe boolean not null,
  payload jsonb not null,
  unique(espn_event_id,captured_at,feature_version)
);

create or replace function v2.guard_mlb_premium_feature_snapshot_v1()
returns trigger language plpgsql set search_path='v2','public','pg_temp' as $$
begin
  raise exception 'MLB premium feature snapshots are immutable';
end $$;

drop trigger if exists trg_mlb_premium_feature_snapshot_v1 on v2.mlb_premium_feature_snapshot_v1;
create trigger trg_mlb_premium_feature_snapshot_v1 before update or delete on v2.mlb_premium_feature_snapshot_v1
for each row execute function v2.guard_mlb_premium_feature_snapshot_v1();

create or replace function v2.capture_mlb_premium_features_v1(p_horizon_hours integer default 48,p_asof timestamptz default now())
returns jsonb
language plpgsql security definer set search_path='v2','public','pg_temp' as $$
declare r record; j jsonb; n int:=0; blocked int:=0; dt timestamptz:=date_trunc('hour',p_asof);
begin
  if p_horizon_hours<1 or p_horizon_hours>168 then return jsonb_build_object('ok',false,'status','INVALID_HORIZON'); end if;
  for r in select * from public.v_favorito_mlb where arranca_en>p_asof and arranca_en<=p_asof+make_interval(hours=>p_horizon_hours) order by arranca_en loop
    j:=public.mlb_terminal_v1(r.espn_event_id);
    if coalesce((j->>'ok')::boolean,false) then
      insert into v2.mlb_premium_feature_snapshot_v1(espn_event_id,mlb_game_pk,captured_at,kickoff,temporal_safe,payload)
      values(r.espn_event_id,j#>>'{event,mlb_game_pk}',dt,r.arranca_en,dt<r.arranca_en,j)
      on conflict do nothing;
      n:=n+1;
    else blocked:=blocked+1; end if;
  end loop;
  return jsonb_build_object('ok',true,'feature_version','mlb_premium_features_v1','captured_or_existing',n,'blocked_missing_data',blocked,'captured_at',dt);
end $$;

grant execute on function v2.capture_mlb_premium_features_v1(integer,timestamptz) to authenticated;

create or replace view public.v_mlb_terminal_v1_invariant_leaks as
select espn_event_id,'TEMPORAL_UNSAFE_FEATURE_SNAPSHOT'::text leak
from v2.mlb_premium_feature_snapshot_v1 where not temporal_safe or captured_at>=kickoff;

grant select on public.v_mlb_terminal_v1_invariant_leaks to authenticated;
