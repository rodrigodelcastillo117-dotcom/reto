-- ============================================================================
-- REGRESIÓN: AGENDA = UNIVERSO (0 drops) · parte de FULL_DATA_SOCCER_ANALYSIS_GATE
-- Dos formas:
--  (1) READ-ONLY hoy (diseño LEFT JOIN) — corre contra prod sin mutación.
--  (2) POST-DEPLOY en branch — tras correr iss033.build_soccer_prediction_v2_staged.
-- Zero-row guard (§61): falla si agenda_universe = 0.
-- ============================================================================

-- (1) READ-ONLY: el universo tras LEFT JOINs == agenda soccer futura.
do $$
declare v_agenda int; v_universe int;
begin
  select count(*) into v_agenda from (
    select distinct espn_event_id from public.agenda_espn
    where deporte='soccer' and fecha > now()) u;
  if v_agenda = 0 then raise exception 'FAIL setup: agenda_universe=0 (zero-row guard)'; end if;
  select count(*) into v_universe from (
    select a.espn_event_id
    from (select distinct espn_event_id, liga_id, liga_nombre from public.agenda_espn
          where deporte='soccer' and fecha > now()) a
    left join v2.liga_alias la on la.liga_source=a.liga_nombre
    left join v2.competition_catalog cc on cc.competition_id=la.competition_id and cc.enabled=true
  ) m;
  if v_universe <> v_agenda then
    raise exception 'FAIL: LEFT-JOIN universe % != agenda %', v_universe, v_agenda;
  end if;
  raise notice 'PASS (read-only): agenda=universe=% (0 drops)', v_agenda;
end $$;

-- (2) POST-DEPLOY (branch): tras build_soccer_prediction_v2_staged(decision_time),
--     la superficie canónica debe contener TODOS los eventos futuros de agenda.
-- do $$
-- declare v_agenda int; v_canon int; v_dec timestamptz := now();
-- begin
--   perform v2.build_soccer_prediction_v2_staged(v_dec);
--   select count(distinct espn_event_id) into v_agenda from public.agenda_espn
--     where deporte='soccer' and fecha > v_dec;
--   select count(distinct espn_event_id) into v_canon from v2.soccer_prediction_v2_staged
--     where decision_time = v_dec;
--   if v_agenda = 0 then raise exception 'FAIL setup: agenda=0'; end if;
--   if v_canon <> v_agenda then
--     raise exception 'FAIL: canonical % != agenda universe % (silent drops)', v_canon, v_agenda;
--   end if;
--   raise notice 'PASS (branch): canonical=agenda=% (0 drops)', v_agenda;
-- end $$;
