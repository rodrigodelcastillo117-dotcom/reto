-- ============================================================================
-- iss033 TEST (AUDIT 5611572904) — model_config WHOLE-ROW inmutable +
--   competition mapping AUTORIDAD END-TO-END (remap != identity => fail-close).
-- Requiere iss033 hardened + iss039. Branch-only. Siembra y limpia.
-- ============================================================================
insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
  values ('espn','197',197,'Grecia SL','compmap_v1') on conflict do nothing;
update v2.competition_mapping_config set active_mapping_version='compmap_v1' where singleton;
insert into v2.model_registry (sport,model_name,model_version,liga_id,approved) values ('soccer','reto_dc_v2','dc-2026.09.1',197,true) on conflict do nothing;
insert into public.v_liga_promedios_futbol (liga_id,media_goles_local,media_goles_visita) values (197,1.5,1.2) on conflict do nothing;
delete from public.agenda_espn where espn_event_id='EA';
delete from public.v_momios_confiables where espn_event_id='EA';
delete from public.historico_partidos_espn where home_espn_id='HA' or away_espn_id='AA';
delete from v2.soccer_prediction_v2_staged where espn_event_id='EA';
delete from v2.feature_snapshot where espn_event_id='EA';
insert into public.agenda_espn (espn_event_id,deporte,liga_id,liga_nombre,home_nombre,away_nombre,home_espn_id,away_espn_id,fecha)
 values ('EA','soccer',197,'Grecia SL','Home A','Away A','HA','AA', timestamptz '2026-09-10 18:00+00');
insert into public.v_momios_confiables (espn_event_id,over_line,bookmaker,snapshot_at,over_odds,under_odds,confiable)
 values ('EA',3.5,'pinnacle',timestamptz '2026-09-09 09:00+00',1.95,1.90,true);
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HA','o'||g,2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'o'||g,'AA',2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;

do $$
declare r record; got boolean;
begin
  -- END-TO-END identidad (197->197): publica
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00', true, 'compmap_v1');
  select * into r from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  if r.model_status<>'READY_UNVALIDATED' or r.competition_id<>197 then raise exception 'FAIL v1 e2e'; end if;

  -- REMAP 197->888: nunca publica 888 con registry/features de 197 => NO_MODEL fail-close
  insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
    values ('espn','197',888,'Remapped','remap_v2') on conflict do nothing;
  delete from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  delete from v2.feature_snapshot where espn_event_id='EA';
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00', true, 'remap_v2');
  select * into r from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  if r.model_status<>'NO_MODEL' or r.p_home is not null or r.model_status_reason not like '%MAPPING_NOT_END_TO_END%' then
    raise exception 'FAIL remap end-to-end (status=% p=% reason=%)', r.model_status, r.p_home, r.model_status_reason; end if;

  -- model_config WHOLE-ROW inmutable: cualquier campo semántico => RAISE
  got:=false; begin update v2.model_config set publish_authorized=not publish_authorized where sport='soccer' and model_version='dc-2026.09.1';
    exception when others then if sqlerrm like '%MODEL_CONFIG_DRIFT%' then got:=true; else raise; end if; end;
  if not got then raise exception 'FAIL model_config publish_authorized'; end if;
  got:=false; begin update v2.model_config set calibration_status='HACKED' where sport='soccer' and model_version='dc-2026.09.1';
    exception when others then if sqlerrm like '%MODEL_CONFIG_DRIFT%' then got:=true; else raise; end if; end;
  if not got then raise exception 'FAIL model_config calibration_status'; end if;
  got:=false; begin update v2.model_config set model_name='other' where sport='soccer' and model_version='dc-2026.09.1';
    exception when others then if sqlerrm like '%MODEL_CONFIG_DRIFT%' then got:=true; else raise; end if; end;
  if not got then raise exception 'FAIL model_config model_name'; end if;
  update v2.model_config set sample_floor=sample_floor where sport='soccer' and model_version='dc-2026.09.1';  -- no-op ok

  update v2.competition_mapping_config set active_mapping_version='compmap_v1' where singleton;
  raise notice 'PASS iss033 v2: model_config whole-row immutable + mapping end-to-end authority';
end $$;
delete from public.agenda_espn where espn_event_id='EA';
delete from public.v_momios_confiables where espn_event_id='EA';
delete from public.historico_partidos_espn where home_espn_id='HA' or away_espn_id='AA';
delete from v2.soccer_prediction_v2_staged where espn_event_id='EA';
delete from v2.feature_snapshot where espn_event_id='EA';
