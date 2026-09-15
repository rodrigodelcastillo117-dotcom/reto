-- ============================================================================
-- iss033 TEST (AUDIT 5611083879) — mapping-version congelada + availability enforce +
--   inmutabilidad de feature_snapshot / model_config.
-- Requiere iss033 hardened (builder con p_enforce_availability/p_mapping_version +
--   columnas competition_mapping_version/availability_verified + triggers de
--   inmutabilidad) + iss039 (competition_provider_map/config) + deps. Branch-only.
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
 values ('hHAlate',197, timestamptz '2026-03-01+00','HA','olate',10,0, timestamptz '2026-09-15+00');  -- kickoff<decision, cargado>decision
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'o'||g,'AA',2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;

do $$
declare r record; got boolean; hg numeric;
begin
  -- FORWARD (enforce=true): excluye late-backfill; temporal_safe/availability true; READY
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00', true, null);
  select * into r from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  if r.availability_verified is not true or r.temporal_safe is not true or r.model_status<>'READY_UNVALIDATED' then raise exception 'FAIL forward'; end if;
  select round(home_gf,3) into hg from v2.feature_snapshot where espn_event_id='EA';
  if hg<>2.0 then raise exception 'FAIL forward home_gf (late debió excluirse): %', hg; end if;
  if r.competition_mapping_version<>'compmap_v1' then raise exception 'FAIL mapping_version persistida'; end if;

  -- mapping freeze: mover puntero activo NO cambia la fila vieja
  insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
    values ('espn','197',197,'Grecia SL v2','compmap_v2') on conflict do nothing;
  update v2.competition_mapping_config set active_mapping_version='compmap_v2' where singleton;
  if (select competition_mapping_version from v2.soccer_prediction_v2_staged where espn_event_id='EA')<>'compmap_v1'
    then raise exception 'FAIL: fila vieja mutó al mover puntero'; end if;

  -- feature_snapshot drift => RAISE; idéntico => ok
  got:=false;
  begin update v2.feature_snapshot set home_gf=99 where espn_event_id='EA';
  exception when others then if sqlerrm like '%FEATURE_SNAPSHOT_DRIFT%' then got:=true; else raise; end if; end;
  if not got then raise exception 'FAIL feature_snapshot drift'; end if;
  update v2.feature_snapshot set home_gf=home_gf where espn_event_id='EA';

  -- model_config drift => RAISE
  got:=false;
  begin update v2.model_config set sample_floor=99 where sport='soccer' and model_version='dc-2026.09.1';
  exception when others then if sqlerrm like '%MODEL_CONFIG_DRIFT%' then got:=true; else raise; end if; end;
  if not got then raise exception 'FAIL model_config drift'; end if;

  -- REPLAY (enforce=false): incluye late-backfill; NO reclama temporal_safe; NO publica P
  delete from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  delete from v2.feature_snapshot where espn_event_id='EA';
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00', false, null);
  select * into r from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  if r.availability_verified is not false or r.temporal_safe is not false or r.p_home is not null then raise exception 'FAIL replay flags'; end if;
  if r.model_status_reason not like '%REPLAY_AVAILABILITY_UNVERIFIED%' then raise exception 'FAIL replay reason'; end if;
  select round(home_gf,3) into hg from v2.feature_snapshot where espn_event_id='EA';
  if hg<>2.727 then raise exception 'FAIL replay home_gf (late debió entrar): %', hg; end if;

  -- replay explícito compmap_v1 reproduce identidad aunque el puntero esté en v2
  delete from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  delete from v2.feature_snapshot where espn_event_id='EA';
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00', true, 'compmap_v1');
  select * into r from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  if r.competition_mapping_version<>'compmap_v1' or r.competition_id<>197 then raise exception 'FAIL replay explícito v1'; end if;

  update v2.competition_mapping_config set active_mapping_version='compmap_v1' where singleton;
  raise notice 'PASS iss033 hardening (mapping-freeze + availability + immutability)';
end $$;

delete from public.agenda_espn where espn_event_id='EA';
delete from public.v_momios_confiables where espn_event_id='EA';
delete from public.historico_partidos_espn where home_espn_id='HA' or away_espn_id='AA';
delete from v2.soccer_prediction_v2_staged where espn_event_id='EA';
delete from v2.feature_snapshot where espn_event_id='EA';
