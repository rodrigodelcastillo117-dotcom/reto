-- ============================================================================
-- iss028 TEST — regresión del guard de grading (early loss + PA evidencia)
-- ============================================================================
-- Corre TODO en una transacción con ROLLBACK final: NO persiste nada. Seguro en
-- cualquier DB (branch/local). Reproduce el bug "marcado perdido antes de finalizar"
-- y prueba que el guard lo bloquea, más la evidencia obligatoria del pago anticipado.
--
-- Uso: psql <conn> -f iss028_grading_guard_test.sql   (o Supabase branch)
-- Requiere iss028_soccer_grading_root_guard.sql cargado (define las funciones guard).
-- ============================================================================
begin;

-- Instalar los guards que en iss028 quedan comentados (aquí, sólo dentro de la tx)
drop trigger if exists trg_guard_no_early_loss_picks on public.picks;
create trigger trg_guard_no_early_loss_picks before update on public.picks
  for each row execute function public.guard_no_early_loss();
drop trigger if exists trg_guard_pa_evidencia on public.picks;
create trigger trg_guard_pa_evidencia before update on public.picks
  for each row execute function public.guard_pa_evidencia_obligatoria();

-- Evento de fútbol EN VIVO (no final)
insert into public.live_scores (espn_event_id, status, minute, period, home_score, away_score, home_team, away_team)
values ('TEST_EVT_LIVE', 'in_progress', 55, 2, 1, 2, 'Local FC', 'Visita FC')
on conflict (espn_event_id) do update set status=excluded.status, home_score=excluded.home_score, away_score=excluded.away_score;

-- Pick pendiente ligado a ese evento en vivo
insert into public.picks (id, apodo, fecha, deporte, liga, partido, pick_desc, momio, apuesta,
                          resultado, espn_event_id, confianza_calificacion)
values ('00000000-0000-0000-0000-0000000028a1','tester', now(), 'FUT','UEFA Champions League',
        'Local FC vs Visita FC','Gana Local FC', 1.8, 100, 'pendiente','TEST_EVT_LIVE', null);

-- ── CASO 1: intento de PÉRDIDA anticipada por ruta EARLY_HIGH (el bug) ─────────
-- es_accion_de_persona() es false en este contexto de script => el guard degrada a 'pendiente'
update public.picks set resultado='perdido', confianza_calificacion='EARLY_HIGH'
where id='00000000-0000-0000-0000-0000000028a1';

do $$
declare r text;
begin
  select resultado into r from public.picks where id='00000000-0000-0000-0000-0000000028a1';
  if r = 'perdido' then
    raise exception 'FAIL C1: se marcó PERDIDO con el partido en vivo (bug NO corregido)';
  end if;
  raise notice 'PASS C1: pérdida anticipada bloqueada -> resultado=%', r;
end $$;

-- ── CASO 2: GANANCIA anticipada SÍ permitida (pago anticipado legítimo) ────────
update public.picks set resultado='ganado', confianza_calificacion='EARLY_HIGH'
where id='00000000-0000-0000-0000-0000000028a1';
do $$
declare r text;
begin
  select resultado into r from public.picks where id='00000000-0000-0000-0000-0000000028a1';
  if r <> 'ganado' then
    raise exception 'FAIL C2: la ganancia anticipada legítima fue bloqueada (r=%)', r;
  end if;
  raise notice 'PASS C2: ganancia anticipada permitida -> resultado=%', r;
end $$;

-- ── CASO 3: PA sin score_snapshot debe fallar duro ────────────────────────────
do $$
begin
  begin
    update public.picks set pa_activado=true, pa_score_snapshot=null, pa_activado_at=null
    where id='00000000-0000-0000-0000-0000000028a1';
    raise exception 'FAIL C3: se activó PA sin pa_score_snapshot';
  exception when check_violation then
    raise notice 'PASS C3: PA sin snapshot rechazado correctamente';
  end;
end $$;

-- ── CASO 4: PA con snapshot; activated_at se autosella si falta ────────────────
update public.picks set pa_activado=true,
  pa_score_snapshot=jsonb_build_object('home_score',2,'away_score',0,'minute',60),
  pa_activado_at=null
where id='00000000-0000-0000-0000-0000000028a1';
do $$
declare t timestamptz;
begin
  select pa_activado_at into t from public.picks where id='00000000-0000-0000-0000-0000000028a1';
  if t is null then raise exception 'FAIL C4: pa_activado_at quedó NULL con PA activo'; end if;
  raise notice 'PASS C4: PA con snapshot ok, activated_at autosellado=%', t;
end $$;

rollback;  -- no persistir NADA
