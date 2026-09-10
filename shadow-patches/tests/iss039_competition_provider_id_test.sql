-- ============================================================================
-- iss039 v2 TEST — §20 competition identity por provider-id, INMUTABLE + wiring builder
--   AUDIT 5610547890: (1) append-only real (no UPDATE/DELETE in-place); (2) builder
--   resuelve competition por provider-id end-to-end (no sólo comentario de cutover).
-- Requiere iss039 v2 (competition_provider_map + trigger inmutabilidad + mapping_config
--   + fn_resolve_competition/fn_competition_active_mapping) + iss033 builder + deps.
-- Branch-only. Parte 1 en tx ROLLBACK (el trigger prohíbe DELETE). Parte 2 usa el builder.
-- ============================================================================

-- PARTE 1 — inmutabilidad append-only (tx rollback; DELETE está prohibido por diseño)
begin;
insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
values ('espn','197',197,'Grecia SL','imtest_v1');
do $$
declare got_upd boolean; got_del boolean; r record;
begin
  got_upd:=false;
  begin update v2.competition_provider_map set competition_id=888
    where provider='espn' and provider_competition_id=197 and mapping_version='imtest_v1';
  exception when others then if sqlerrm like '%COMPETITION_MAP_IMMUTABLE%' then got_upd:=true; else raise; end if; end;
  if not got_upd then raise exception 'FAIL: UPDATE in-place debió rechazarse'; end if;
  got_del:=false;
  begin delete from v2.competition_provider_map where provider='espn' and provider_competition_id=197 and mapping_version='imtest_v1';
  exception when others then if sqlerrm like '%COMPETITION_MAP_IMMUTABLE%' then got_del:=true; else raise; end if; end;
  if not got_del then raise exception 'FAIL: DELETE debió rechazarse'; end if;
  -- remap = nueva mapping_version (INSERT permitido)
  insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
  values ('espn','197',888,'Grecia (remap)','imtest_v2');
  select * into r from v2.fn_resolve_competition('espn',197,'imtest_v1');
  if r.competition_id is distinct from 197 then raise exception 'FAIL: v1 replay cambió a %', r.competition_id; end if;
  select * into r from v2.fn_resolve_competition('espn',197,'imtest_v2');
  if r.competition_id is distinct from 888 then raise exception 'FAIL: v2 no devuelve 888'; end if;
  raise notice 'PASS iss039 v2 inmutabilidad';
end $$;
rollback;

-- PARTE 2 — wiring real del builder por provider-id (mapping persistente compmap_v1)
insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
values ('espn','197',197,'Grecia SL','compmap_v1') on conflict do nothing;
insert into v2.competition_mapping_config(singleton,active_mapping_version) values (true,'compmap_v1')
  on conflict (singleton) do update set active_mapping_version='compmap_v1';
insert into v2.model_registry values ('soccer','reto_dc_v2','dc-2026.09.1',197,true) on conflict do nothing;
insert into public.v_liga_promedios_futbol values (197,1.5,1.2) on conflict do nothing;

delete from public.agenda_espn where espn_event_id in ('EA','EB');
delete from public.v_momios_confiables where espn_event_id in ('EA','EB');
delete from public.historico_partidos_espn where home_espn_id in ('HA') or away_espn_id in ('AA');
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB');
delete from v2.feature_snapshot where espn_event_id in ('EA','EB');
insert into public.agenda_espn (espn_event_id,deporte,liga_id,liga_nombre,home_nombre,away_nombre,home_espn_id,away_espn_id,fecha) values
 ('EA','soccer',197,'Grecia SL','Home A','Away A','HA','AA', timestamptz '2026-09-10 18:00+00'),
 ('EB','soccer',500,'Unknown League','Home B','Away B','HB','AB', timestamptz '2026-09-10 18:00+00');
insert into public.v_momios_confiables (espn_event_id,over_line,bookmaker,snapshot_at,over_odds,under_odds,confiable)
 values ('EA',3.5,'pinnacle',timestamptz '2026-09-09 09:00+00',1.95,1.90,true);
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HA','o'||g,2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'o'||g,'AA',2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;

do $$
declare rEA record; rEB record; ea_v2 int;
begin
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00');
  select * into rEA from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  select * into rEB from v2.soccer_prediction_v2_staged where espn_event_id='EB';
  if rEA.competition_id is distinct from 197 then raise exception 'FAIL EA competition_id por provider-id'; end if;
  if rEA.model_status<>'READY_UNVALIDATED' then raise exception 'FAIL EA status'; end if;
  if rEB.competition_id is not null or rEB.model_status<>'NO_MODEL' then raise exception 'FAIL EB unmapped provider-id debió NO_MODEL'; end if;
  -- identidad estable ante cambio de label (nueva mapping_version, mismo provider-id)
  insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
  values ('espn','197',197,'Grecia Super League','compmap_v2') on conflict do nothing;
  update v2.competition_mapping_config set active_mapping_version='compmap_v2' where singleton;
  delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB');
  perform v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00');
  select competition_id into ea_v2 from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  if ea_v2 is distinct from 197 then raise exception 'FAIL: label change alteró identidad'; end if;
  update v2.competition_mapping_config set active_mapping_version='compmap_v1' where singleton;
  raise notice 'PASS iss039 v2 builder wiring';
end $$;

delete from public.agenda_espn where espn_event_id in ('EA','EB');
delete from public.v_momios_confiables where espn_event_id in ('EA','EB');
delete from public.historico_partidos_espn where home_espn_id in ('HA') or away_espn_id in ('AA');
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB');
delete from v2.feature_snapshot where espn_event_id in ('EA','EB');
