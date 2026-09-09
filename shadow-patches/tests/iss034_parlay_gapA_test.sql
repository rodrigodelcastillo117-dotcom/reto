-- ============================================================================
-- iss034 TEST — GAP A regression (tx ROLLBACK). Requiere iss034 cargado.
-- Caso: parlay 3 patas; 1 pata LIVE marcada EARLY_HIGH 'perdido' -> parlay SIGUE
-- pendiente. Sólo cuando esa pata es realmente FINAL y perdida -> parlay 'perdido'.
-- ============================================================================
begin;
-- El trigger auto_cerrar se dispara en UPDATE de parlays; lo aseguramos:
drop trigger if exists trg_auto_cerrar_parlay on public.parlays;
create trigger trg_auto_cerrar_parlay before update on public.parlays
  for each row execute function public.auto_cerrar_parlay_si_leg_perdido();

-- Evento LIVE (no final) para la pata "perdedora" temprana
insert into public.live_scores (espn_event_id,status,minute,period,home_score,away_score,home_team,away_team)
values ('GAPA_LIVE','in_progress',60,2,0,1,'A','B')
on conflict (espn_event_id) do update set status=excluded.status,home_score=excluded.home_score,away_score=excluded.away_score;

-- Parlay 3 patas: 1 ganada final, 1 pendiente, 1 "perdido" pero su evento está EN VIVO
insert into public.parlays (id, apodo, fecha, apuesta, momio_total, resultado, picks_data)
values ('00000000-0000-0000-0000-0000000034a1','tester', now(), 100, 5.0, 'pendiente',
  jsonb_build_array(
    jsonb_build_object('espn_event_id','GAPA_DONE','resultado','ganado','pick_desc','x'),
    jsonb_build_object('espn_event_id','GAPA_PEND','resultado','pendiente','pick_desc','y'),
    jsonb_build_object('espn_event_id','GAPA_LIVE','resultado','perdido','pick_desc','z','confianza_calificacion','EARLY_HIGH')
  ));

-- Disparo del trigger con un UPDATE no-op
update public.parlays set updated_at=now() where id='00000000-0000-0000-0000-0000000034a1';

do $$ declare r text; begin
  select resultado into r from public.parlays where id='00000000-0000-0000-0000-0000000034a1';
  if r='perdido' then raise exception 'FAIL C1: parlay cerrado como perdido con pata LIVE (no final)'; end if;
  raise notice 'PASS C1: pata LIVE perdida no cierra el parlay -> resultado=%', r;
end $$;

-- Ahora el evento pasa a FINAL con derrota real de esa pata
update public.live_scores set status='final', home_score=0, away_score=2 where espn_event_id='GAPA_LIVE';
update public.parlays set updated_at=now() where id='00000000-0000-0000-0000-0000000034a1';

do $$ declare r text; g numeric; begin
  select resultado, ganancia_neta into r,g from public.parlays where id='00000000-0000-0000-0000-0000000034a1';
  if r<>'perdido' then raise exception 'FAIL C2: pata FINAL perdida no cerró el parlay (r=%)', r; end if;
  if g<>-100 then raise exception 'FAIL C2: ganancia_neta esperada -100, fue %', g; end if;
  raise notice 'PASS C2: pata FINAL perdida cierra el parlay -> % (ganancia %)', r, g;
end $$;
rollback;
