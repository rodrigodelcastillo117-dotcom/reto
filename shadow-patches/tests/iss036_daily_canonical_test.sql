-- ============================================================================
-- iss036 TEST — daily canónico: SELECCIONA/RANKEA, no recalcula (§24/§49)
--   AUDIT 5606928639 (STOP-SHIP v_reto13m_daily): sin 2.5 fijo, sin complemento BTTS,
--   O/U sólo a línea real, 1 fila/evento, mejor del día = rank 1, 0 recompute.
-- Requiere iss036 (v_soccer_daily_candidates / v_soccer_daily_canonical) + iss033 builder
--   + deps. Branch-only. Reusa el universo sintético de iss033.
-- ============================================================================
delete from public.agenda_espn where espn_event_id in ('EA','EB','EC','ED');
delete from public.v_momios_confiables where espn_event_id in ('EA','EB','EC','ED');
delete from public.historico_partidos_espn where home_espn_id in ('HA','HD','HC') or away_espn_id in ('AA','AD','AC');
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB','EC','ED');
delete from v2.feature_snapshot where espn_event_id in ('EA','EB','EC','ED');
insert into v2.liga_alias values ('Grecia SL',197) on conflict do nothing;
insert into v2.competition_catalog values (197,true) on conflict do nothing;
insert into v2.model_registry values ('soccer','reto_dc_v2','dc-2026.09.1',197,true) on conflict do nothing;
insert into public.v_liga_promedios_futbol values (197,1.5,1.2) on conflict do nothing;
insert into public.agenda_espn (espn_event_id,deporte,liga_id,liga_nombre,home_nombre,away_nombre,home_espn_id,away_espn_id,fecha) values
 ('EA','soccer',197,'Grecia SL','Home A','Away A','HA','AA', timestamptz '2026-09-10 18:00+00'),
 ('EB','soccer',500,'Unknown League','Home B','Away B','HB','AB', timestamptz '2026-09-10 18:00+00'),
 ('EC','soccer',197,'Grecia SL','Home C','Away C','HC','AC', timestamptz '2026-09-10 18:00+00'),
 ('ED','soccer',197,'Grecia SL','Home D','Away D','HD','AD', timestamptz '2026-09-10 18:00+00');
insert into public.v_momios_confiables (espn_event_id,over_line,bookmaker,snapshot_at,over_odds,under_odds,confiable)
 values ('EA',3.5,'pinnacle',timestamptz '2026-09-09 09:00+00',1.95,1.90,true);
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HA','o'||g,2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAA'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'o'||g,'AA',2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHD'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HD','o'||g,2,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAD'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'o'||g,'AD',1,1,timestamptz '2026-02-02+00' from generate_series(1,10) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hHC'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'HC','o'||g,3,0,timestamptz '2026-02-02+00' from generate_series(1,3) g;
insert into public.historico_partidos_espn (espn_event_id,liga_id,fecha,home_espn_id,away_espn_id,home_score,away_score,cargado_at)
 select 'hAC'||g,197,timestamptz '2026-02-01+00'+(g||' days')::interval,'o'||g,'AC',1,2,timestamptz '2026-02-02+00' from generate_series(1,3) g;
select v2.build_soccer_prediction_v2_staged(timestamptz '2026-09-09 12:00+00');

do $$
declare n int; ea_btts_no numeric; cand_btts_no numeric; ou_ed int; ou_ea int; bad int; best record;
begin
  select count(distinct canonical_event_id) into n from v2.v_soccer_daily_candidates;
  if n <> 2 then raise exception 'FAIL: candidatos sólo de EA,ED, hay %', n; end if;
  select btts_no into ea_btts_no from v2.soccer_prediction_v2_staged where espn_event_id='EA';
  select canonical_probability into cand_btts_no from v2.v_soccer_daily_candidates
    where canonical_event_id='EA' and canonical_market='BTTS' and canonical_side='NO';
  if cand_btts_no is distinct from ea_btts_no then raise exception 'FAIL BTTS NO != snapshot'; end if;
  select count(*) into ou_ea from v2.v_soccer_daily_candidates where canonical_event_id='EA' and canonical_market='OU';
  select count(*) into ou_ed from v2.v_soccer_daily_candidates where canonical_event_id='ED' and canonical_market='OU';
  if ou_ea <> 2 or ou_ed <> 0 then raise exception 'FAIL O/U EA=% ED=%', ou_ea, ou_ed; end if;
  select count(*) into bad from v2.v_soccer_daily_candidates where canonical_market='OU' and canonical_line is distinct from 3.5;
  if bad <> 0 then raise exception 'FAIL O/U línea != 3.5: %', bad; end if;
  select count(*) into n from v2.v_soccer_daily_canonical;
  if n <> 2 then raise exception 'FAIL daily 1-fila/evento, hay %', n; end if;
  select count(*) into bad from v2.v_soccer_daily_canonical where es_mejor_del_dia;
  if bad <> 1 then raise exception 'FAIL mejor del día != 1: %', bad; end if;
  select * into best from v2.v_soccer_daily_canonical where es_mejor_del_dia;
  if best.canonical_event_id<>'EA' or best.canonical_market<>'1X2' or best.canonical_side<>'HOME' then
    raise exception 'FAIL mejor del día inesperado'; end if;
  if best.canonical_probability is distinct from (select p_home from v2.soccer_prediction_v2_staged where espn_event_id='EA') then
    raise exception 'FAIL daily recomputó probabilidad'; end if;
  raise notice 'PASS iss036';
end $$;

delete from public.agenda_espn where espn_event_id in ('EA','EB','EC','ED');
delete from public.v_momios_confiables where espn_event_id in ('EA','EB','EC','ED');
delete from public.historico_partidos_espn where home_espn_id in ('HA','HD','HC') or away_espn_id in ('AA','AD','AC');
delete from v2.soccer_prediction_v2_staged where espn_event_id in ('EA','EB','EC','ED');
delete from v2.feature_snapshot where espn_event_id in ('EA','EB','EC','ED');
