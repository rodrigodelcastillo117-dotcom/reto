-- ============================================================================
-- iss033 TEST — builder as-of + CONTRATO CANÓNICO 1-fila/evento (BLOQUE 5/6)
--   AUDIT: agenda=universo (0 drops), 1X2/BTTS/OU invariantes, O/U línea REAL
--   (no 2.5 hardcode), NO_MODEL retención, DATA_INCOMPLETE, O/U fail-close sin línea,
--   feature_snapshot persistido, temporal_safe calculado. F8: feats CTE alineado a
--   iss032.fn_real_total_line (provider_total_line/provider/line_asof).
-- Requiere iss033 (builder+fn_soccer_features_asof), iss032 (fn_real_total_line),
--   fn_score_dist, model_config, y deps: liga_alias/competition_catalog/model_registry,
--   agenda_espn, historico_partidos_espn, v_liga_promedios_futbol, v_momios_confiables.
-- Branch-only. Siembra un universo sintético de 4 eventos, corre el builder y limpia.
-- ============================================================================
delete from public.agenda_espn where espn_event_id in ('EA','EB','EC','ED');
delete from public.v_momios_confiables where espn_event_id in ('EA','EB','EC','ED');
delete from public.historico_partidos_espn where home_espn_id in ('HA','HD','HC') or away_espn_id in ('AA','AD','AC');
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB','EC','ED');
delete from v2.feature_snapshot where espn_event_id in ('EA','EB','EC','ED');

-- §20 (iss039): el builder mapea competencia por PROVIDER-ID; sembrar el mapa + versión activa
insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
  values ('espn','197',197,'Grecia SL','compmap_v1') on conflict do nothing;
insert into v2.competition_mapping_config(singleton,active_mapping_version) values (true,'compmap_v1')
  on conflict (singleton) do update set active_mapping_version='compmap_v1';
insert into v2.model_registry (sport,model_name,model_version,liga_id,approved) values ('soccer','reto_dc_v2','dc-2026.09.1',197,true) on conflict do nothing;
insert into public.v_liga_promedios_futbol (liga_id,media_goles_local,media_goles_visita) values (197,1.5,1.2) on conflict do nothing;

insert into public.agenda_espn (espn_event_id,deporte,liga_id,liga_nombre,home_nombre,away_nombre,home_espn_id,away_espn_id,fecha) values
 ('EA','soccer',197,'Grecia SL','Home A','Away A','HA','AA', timestamptz '2026-09-10 18:00+00'),
 ('EB','soccer',500,'Unknown League','Home B','Away B','HB','AB', timestamptz '2026-09-10 18:00+00'),
 ('EC','soccer',197,'Grecia SL','Home C','Away C','HC','AC', timestamptz '2026-09-10 18:00+00'),
 ('ED','soccer',197,'Grecia SL','Home D','Away D','HD','AD', timestamptz '2026-09-10 18:00+00');
insert into public.v_momios_confiables (espn_event_id,over_line,bookmaker,snapshot_at,over_odds,under_odds,confiable)
 values ('EA',3.5,'pinnacle',timestamptz '2026-09-09 09:00+00',1.95,1.90,true);
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HA','opp'||g,2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'opp'||g,'AA',2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHD'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HD','opp'||g,2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAD'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'opp'||g,'AD',1,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHC'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HC','opp'||g,3,0,timestamptz '2026-02-02+00' from generate_series(1,3) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAC'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'opp'||g,'AC',1,2,timestamptz '2026-02-02+00' from generate_series(1,3) g;

do $$
declare n int; rEA record; rEB record; rEC record; rED record; agenda_n int;
begin
  n := v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00');
  select count(*) into agenda_n from public.agenda_espn where deporte='soccer' and fecha>timestamptz '2026-09-09 12:00+00';
  if n <> agenda_n then raise exception 'FAIL agenda-universe: builder % != agenda %', n, agenda_n; end if;  -- 0 drops

  select * into rEA from v2.soccer_prediction_v2_staged where espn_event_id='EA' and decision_time=timestamptz '2026-09-09 12:00+00';
  select * into rEB from v2.soccer_prediction_v2_staged where espn_event_id='EB' and decision_time=timestamptz '2026-09-09 12:00+00';
  select * into rEC from v2.soccer_prediction_v2_staged where espn_event_id='EC' and decision_time=timestamptz '2026-09-09 12:00+00';
  select * into rED from v2.soccer_prediction_v2_staged where espn_event_id='ED' and decision_time=timestamptz '2026-09-09 12:00+00';

  -- EA: publicado; invariantes 1X2/BTTS/OU; O/U a línea REAL 3.5; snapshot; temporal_safe
  if rEA.model_status<>'READY_UNVALIDATED' then raise exception 'FAIL EA status %', rEA.model_status; end if;
  if round(rEA.p_home+rEA.p_draw+rEA.p_away,1) not between 99.5 and 100.5 then raise exception 'FAIL EA 1X2 sum'; end if;
  if round(rEA.btts_yes+rEA.btts_no,1) not between 99.5 and 100.5 then raise exception 'FAIL EA BTTS sum'; end if;
  if rEA.btts_no is null then raise exception 'FAIL EA btts_no no explícito'; end if;
  if rEA.over_line is distinct from 3.5 then raise exception 'FAIL EA over_line % (no es línea real)', rEA.over_line; end if;
  if round(rEA.p_over+rEA.p_under,1) not between 99.5 and 100.5 then raise exception 'FAIL EA OU sum'; end if;
  if rEA.feature_snapshot_id is null then raise exception 'FAIL EA snapshot no persistido'; end if;
  if rEA.temporal_safe is not true then raise exception 'FAIL EA temporal_safe'; end if;

  -- EB: NO_MODEL, P NULL, PRESENTE (retención universo)
  if rEB.model_status<>'NO_MODEL' or rEB.p_home is not null then raise exception 'FAIL EB %', rEB.model_status; end if;

  -- EC: DATA_INCOMPLETE (muestra<8), P NULL
  if rEC.model_status<>'DATA_INCOMPLETE' or rEC.p_home is not null then raise exception 'FAIL EC %', rEC.model_status; end if;

  -- ED: publicado 1X2/BTTS pero O/U fail-close (sin línea real)
  if rED.model_status<>'READY_UNVALIDATED' or rED.p_home is null then raise exception 'FAIL ED status'; end if;
  if rED.over_line is not null or rED.p_over is not null or rED.p_under is not null then raise exception 'FAIL ED O/U debió fail-close sin línea'; end if;

  raise notice 'PASS iss033 builder: 0 drops, 1X2/BTTS/OU invariantes, O/U línea real, NO_MODEL/DATA_INCOMPLETE, O/U fail-close, snapshot';
end $$;

-- cleanup
delete from public.agenda_espn where espn_event_id in ('EA','EB','EC','ED');
delete from public.v_momios_confiables where espn_event_id in ('EA','EB','EC','ED');
delete from public.historico_partidos_espn where home_espn_id in ('HA','HD','HC') or away_espn_id in ('AA','AD','AC');
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB','EC','ED');
delete from v2.feature_snapshot where espn_event_id in ('EA','EB','EC','ED');
