-- ============================================================================
-- iss030 v3 TEST — TRAZABILIDAD del dossier (AUDIT 5612053961 / 5612773823)
-- Invariantes + prueba de que las MODEL inputs salen del feature_snapshot EXACTO
-- (no de v_futpro_v2), son byte-estables ante mutación del agregado móvil, y que
-- sin snapshot enlazado el rol es MODEL_ACTIVE_TEMPORAL_UNPROVEN (fail-closed).
-- Requiere iss033 (builder + feature_snapshot + staged) + iss039 + iss030 v3.
-- Branch-only. Corre en tx con ROLLBACK. Reusa el universo sintético de iss033.
-- ============================================================================

-- ---- A) INVARIANTES sobre un evento fail-closed real (sin staged) ----
begin;
do $$
declare r record; n_bad_role int:=0; n_model_active int:=0;
begin
  for r in select * from v2.fn_soccer_dossier_manifest('401915446') loop
    if r.role not in ('MODEL_ACTIVE','MODEL_ACTIVE_TEMPORAL_UNPROVEN','CONTEXT_ONLY','AVAILABLE_NOT_USED') then n_bad_role:=n_bad_role+1; end if;
    if r.role='MODEL_ACTIVE' then
      n_model_active:=n_model_active+1;
      if r.data_asof is null or r.data_asof > r.decision_time then
        raise exception 'FAIL: % MODEL_ACTIVE con as_of inválido (asof=% dec=%)', r.source_name, r.data_asof, r.decision_time; end if;
      if r.feature_snapshot_id is null then raise exception 'FAIL: % MODEL_ACTIVE sin feature_snapshot_id', r.source_name; end if;
    end if;
    -- used_in_p_reto sólo si MODEL_ACTIVE
    if r.used_in_p_reto and r.role<>'MODEL_ACTIVE' then raise exception 'FAIL: % used_in_p_reto sin MODEL_ACTIVE (role=%)', r.source_name, r.role; end if;
    -- UNPROVEN nunca pasa
    if r.role='MODEL_ACTIVE_TEMPORAL_UNPROVEN' and r.used_in_p_reto then raise exception 'FAIL: UNPROVEN marcado usado'; end if;
  end loop;
  if n_bad_role>0 then raise exception 'FAIL: % roles inválidos', n_bad_role; end if;
  raise notice 'PASS A: roles válidos, % MODEL_ACTIVE en evento fail-closed', n_model_active;
end $$;
rollback;

-- ---- B) TRAZABILIDAD + byte-estabilidad + UNPROVEN (universo sintético) ----
begin;
insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
  values ('espn','197',197,'Grecia SL','compmap_v1') on conflict do nothing;
insert into v2.competition_mapping_config(singleton,active_mapping_version) values (true,'compmap_v1')
  on conflict (singleton) do update set active_mapping_version='compmap_v1';
insert into v2.model_registry values ('soccer','reto_dc_v2','dc-2026.09.1',197,true) on conflict do nothing;
insert into public.v_liga_promedios_futbol values (197,1.5,1.2) on conflict do nothing;
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
declare
  v_dec timestamptz := timestamptz '2026-09-09 12:00+00';
  fs record; d_home record; d_p record; d_home2 record; d_home3 record; got boolean;
begin
  perform v2.build_soccer_prediction_v2_staged(v_dec, true, 'compmap_v1');
  select * into fs from v2.feature_snapshot where espn_event_id='EA';
  if fs.feature_snapshot_id is null then raise exception 'FAIL setup: sin feature_snapshot'; end if;

  -- B1) La MODEL input sale del snapshot EXACTO: valor, as_of y snapshot_id coinciden.
  select * into d_home from v2.fn_soccer_dossier_manifest('EA', v_dec) where source_name='feat_goal_rate_home';
  if d_home.role<>'MODEL_ACTIVE' then raise exception 'FAIL B1 role=%', d_home.role; end if;
  if not d_home.used_in_p_reto then raise exception 'FAIL B1 used_in_p_reto=false'; end if;
  if d_home.effective_value is distinct from fs.home_gf then raise exception 'FAIL B1 valor % <> snapshot %', d_home.effective_value, fs.home_gf; end if;
  if d_home.data_asof is distinct from fs.feature_data_asof then raise exception 'FAIL B1 as_of % <> snapshot %', d_home.data_asof, fs.feature_data_asof; end if;
  if d_home.feature_snapshot_id is distinct from fs.feature_snapshot_id then raise exception 'FAIL B1 snapshot_id'; end if;
  if d_home.provenance not like 'v2.feature_snapshot%' then raise exception 'FAIL B1 provenance prestada: %', d_home.provenance; end if;
  if d_home.max_source_event_time is distinct from fs.max_source_event_time then raise exception 'FAIL B1 max_source_event_time'; end if;

  -- P_RETO de la fila staged congelada (no de v_futpro_v2)
  select * into d_p from v2.fn_soccer_dossier_manifest('EA', v_dec) where source_name='modelo_p_reto';
  if d_p.provenance <> 'v2.soccer_prediction_v2_staged' then raise exception 'FAIL B1 P_RETO no viene de staged'; end if;

  -- B2) BYTE-ESTABILIDAD: mutar el agregado móvil (más historico de HA) DESPUÉS del sello
  --     NO cambia el valor/as_of/snapshot_id del dossier (lee el snapshot congelado).
  insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
   select 'hHAx'||g,197,timestamptz '2026-08-01+00'+(g||' days')::interval,'HA','ox'||g,9,0,timestamptz '2026-08-02+00' from generate_series(1,20) g;
  select * into d_home2 from v2.fn_soccer_dossier_manifest('EA', v_dec) where source_name='feat_goal_rate_home';
  if d_home2.effective_value is distinct from d_home.effective_value then
    raise exception 'FAIL B2 valor cambió tras mutar agregado móvil: % -> %', d_home.effective_value, d_home2.effective_value; end if;
  if d_home2.feature_snapshot_id is distinct from d_home.feature_snapshot_id then raise exception 'FAIL B2 snapshot_id cambió'; end if;
  if d_home2.data_asof is distinct from d_home.data_asof then raise exception 'FAIL B2 as_of cambió'; end if;

  -- B3) UNPROVEN fail-closed: predicción READY con p pero SIN feature_snapshot_id enlazado.
  update v2.soccer_prediction_v2_staged set feature_snapshot_id=null where espn_event_id='EA';
  select * into d_home3 from v2.fn_soccer_dossier_manifest('EA', v_dec) where source_name='feat_goal_rate_home';
  if d_home3.role<>'MODEL_ACTIVE_TEMPORAL_UNPROVEN' then raise exception 'FAIL B3 role=% (esperaba UNPROVEN)', d_home3.role; end if;
  if d_home3.used_in_p_reto then raise exception 'FAIL B3 UNPROVEN usado en p_reto'; end if;
  if d_home3.freshness_status<>'MODEL_ACTIVE_TEMPORAL_UNPROVEN' then raise exception 'FAIL B3 freshness=%', d_home3.freshness_status; end if;

  raise notice 'PASS B: MODEL inputs trazables al feature_snapshot exacto, byte-estables, UNPROVEN fail-closed';
end $$;
rollback;
