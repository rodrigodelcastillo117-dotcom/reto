-- Dossier full-data coverage distribution over upcoming soccer universe (read-only).
-- decision proxy = now() (eventos proximos). Ejecutado 2026-09-09. Ver report .md
with uni as (
  select distinct espn_event_id eid from public.agenda_espn where deporte='soccer' and fecha>now()
), n as (select count(*) tot from uni)
select 'xg_forward' src, (select tot from n) universe,
  (select count(*) from uni u where exists(select 1 from public.lab_soccer_xg_forward x where x.match_id=u.eid)) available,
  (select count(*) from uni u where exists(select 1 from public.lab_soccer_xg_forward x where x.match_id=u.eid and x.usable_pre_kickoff and x.available_at<=now())) valid_asof
union all select 'alineaciones',(select tot from n),
  (select count(*) from uni u where exists(select 1 from public.alineaciones_espn a where a.espn_event_id=u.eid and a.hay_alineacion)),
  (select count(*) from uni u where exists(select 1 from public.alineaciones_espn a where a.espn_event_id=u.eid and a.hay_alineacion and a.capturado_at<=now()))
union all select 'arbitro',(select tot from n),
  (select count(*) from uni u where exists(select 1 from public.futbol_arbitro_partido r where r.espn_event_id=u.eid)),
  (select count(*) from uni u where exists(select 1 from public.futbol_arbitro_partido r where r.espn_event_id=u.eid and r.cargado_at<=now()))
union all select 'h2h',(select tot from n),
  (select count(*) from uni u where exists(select 1 from public.bt_h2h h where h.espn_event_id=u.eid)),0
union all select 'descanso',(select tot from n),
  (select count(*) from uni u where exists(select 1 from public.bt_descanso d where d.espn_event_id=u.eid)),0
union all select 'forma',(select tot from n),
  (select count(*) from uni u where exists(select 1 from public.bt_forma b where b.espn_event_id=u.eid)),0
union all select 'total_line',(select tot from n),
  (select count(*) from uni u where exists(select 1 from public.v_momios_confiables mc where mc.espn_event_id=u.eid and mc.over_line is not null)),
  (select count(*) from uni u where exists(select 1 from public.v_momios_confiables mc where mc.espn_event_id=u.eid and mc.confiable and mc.over_line is not null and mc.snapshot_at<=now()));
