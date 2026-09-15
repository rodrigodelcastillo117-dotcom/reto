-- ============================================================================
-- iss034 GAP A — casos adversariales EXTRA C3/C4/C5 (§26) · tx ROLLBACK
-- Requiere el set COMPLETO de triggers de prod en parlays (auto_cerrar iss034 +
-- protect_parlays_premature_grading + bloquear_..._legs_futuros) e is_truly_final.
-- Branch-only (no correr en prod bajo freeze).
-- ============================================================================
begin;

-- C3: pata FINAL push + resto PRE => parlay sigue pendiente (push no pierde)
insert into public.live_scores (espn_event_id,status,minute,period,home_score,away_score,home_team,away_team,liga,deporte)
values ('GAPA_PUSH','final',90,2,1,1,'A','B','UEFA Champions League','⚽ Fútbol')
on conflict (espn_event_id) do update set status='final',home_score=1,away_score=1,liga=excluded.liga,deporte=excluded.deporte;
insert into public.parlays (id, apodo, fecha, apuesta, momio_total, resultado, picks_data)
values ('00000000-0000-0000-0000-0000000034c3','tester', now(), 100, 4.0, 'pendiente',
  jsonb_build_array(
    jsonb_build_object('espn_event_id','GAPA_PUSH','resultado','push','pick_desc','x'),
    jsonb_build_object('espn_event_id','GAPA_C3PEND','resultado','pendiente','pick_desc','y')
  ));
update public.parlays set updated_at=now() where id='00000000-0000-0000-0000-0000000034c3';
do $$ declare r text; begin
  select resultado into r from public.parlays where id='00000000-0000-0000-0000-0000000034c3';
  if r is distinct from 'pendiente' then raise exception 'FAIL C3: push+pendiente cerro el parlay (r=%)', r; end if;
  raise notice 'PASS C3: push + pendiente -> parlay pendiente';
end $$;

-- C4: pata marcada 'perdido' pero evento POSTPONED (no final) => pending
insert into public.live_scores (espn_event_id,status,status_detail,minute,period,home_score,away_score,home_team,away_team,liga,deporte)
values ('GAPA_PPD','postponed','Postponed',0,1,0,0,'A','B','UEFA Champions League','⚽ Fútbol')
on conflict (espn_event_id) do update set status='postponed',status_detail='Postponed',liga=excluded.liga,deporte=excluded.deporte;
insert into public.parlays (id, apodo, fecha, apuesta, momio_total, resultado, picks_data)
values ('00000000-0000-0000-0000-0000000034c4','tester', now(), 100, 4.0, 'pendiente',
  jsonb_build_array(
    jsonb_build_object('espn_event_id','GAPA_PPD','resultado','perdido','pick_desc','x'),
    jsonb_build_object('espn_event_id','GAPA_C4PEND','resultado','pendiente','pick_desc','y')
  ));
update public.parlays set updated_at=now() where id='00000000-0000-0000-0000-0000000034c4';
do $$ declare r text; begin
  select resultado into r from public.parlays where id='00000000-0000-0000-0000-0000000034c4';
  if r='perdido' then raise exception 'FAIL C4: pata POSTPONED (no final) cerro el parlay como perdido'; end if;
  raise notice 'PASS C4: pata postponed no final -> parlay pendiente (r=%)', r;
end $$;

-- C5: pata FINAL perdida cierra el parlay; luego el proveedor revierte a live.
--     No debe re-abrir/duplicar de forma irreversible: el cierre queda estable y
--     cualquier correccion pasa por recalc (idempotente, GAP B).
insert into public.live_scores (espn_event_id,status,minute,period,home_score,away_score,home_team,away_team,liga,deporte)
values ('GAPA_C5','final',90,2,0,2,'A','B','UEFA Champions League','⚽ Fútbol')
on conflict (espn_event_id) do update set status='final',home_score=0,away_score=2,liga=excluded.liga,deporte=excluded.deporte;
insert into public.parlays (id, apodo, fecha, apuesta, momio_total, resultado, picks_data)
values ('00000000-0000-0000-0000-0000000034c5','tester', now(), 100, 3.0, 'pendiente',
  jsonb_build_array(
    jsonb_build_object('espn_event_id','GAPA_C5','resultado','perdido','pick_desc','x')
  ));
update public.parlays set updated_at=now() where id='00000000-0000-0000-0000-0000000034c5';
do $$ declare r text; begin
  select resultado into r from public.parlays where id='00000000-0000-0000-0000-0000000034c5';
  if r is distinct from 'perdido' then raise exception 'FAIL C5a: pata FINAL perdida no cerro (r=%)', r; end if;
  raise notice 'PASS C5a: pata FINAL perdida -> perdido';
end $$;
-- proveedor revierte a live
update public.live_scores set status='in_progress', minute=70 where espn_event_id='GAPA_C5';
update public.parlays set updated_at=now() where id='00000000-0000-0000-0000-0000000034c5';
do $$ declare r text; begin
  select resultado into r from public.parlays where id='00000000-0000-0000-0000-0000000034c5';
  -- protect solo actua desde estado no-graded; ya graded permanece (no doble-cierre)
  if r is distinct from 'perdido' then raise exception 'FAIL C5b: cierre no estable tras revert (r=%)', r; end if;
  raise notice 'PASS C5b: cierre estable, sin doble-cierre irreversible';
end $$;

rollback;
