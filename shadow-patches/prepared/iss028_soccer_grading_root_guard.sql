-- ============================================================================
-- iss028 — GRADING ROOT GUARD (pagos anticipados / early-settle) · STAGED
-- ============================================================================
-- BLOQUE 8 (foco SOCCER, raíz compartida sport-agnóstica). NO APLICAR bajo freeze.
-- NO va en supabase/migrations. Read-only diagnóstico + este guard staged.
--
-- RAÍCES detectadas (SQL real de prod, 2026-09-09):
--  R1) protect_picks_premature_grading() y bloquear_calificacion_pick_futuro()
--      hacen bypass del bloqueo cuando confianza_calificacion IN
--      ('EARLY_HIGH','EARLY_MEDIUM'). Ese bypass NO distingue ganado vs perdido,
--      así que la ruta de calificación TEMPRANA permite marcar 'perdido' con el
--      partido aún en vivo/por jugar. => "parlay/pick marcado perdido sin jugarse".
--      REGLA: un pago/decisión anticipada sólo puede ser GANADO (o 'nulo'), nunca
--      PERDIDO antes de que el partido sea realmente final.
--  R2) Dos rutas de Pago Anticipado (PA) divergentes:
--      - dispatch_pa_para_pierna_parlay() (patas de parlay) graba pa_score_snapshot
--        + pa_activado_at (correcto, con idempotencia via 'pierna_ya_procesada').
--      - la tabla picks puede quedar con pa_activado=true SIN pa_score_snapshot ni
--        pa_activado_at (1 fila así hoy). Un pago anticipado sin marcador ni hora
--        no es auditable.
--
-- Este guard es DEFENSIVO (trigger sobre la fila), independiente de quién escriba.
-- ============================================================================

-- ── G1) Prohibir PÉRDIDA anticipada: 'perdido' sólo si el partido es final ────
-- Aplica a picks y a parlays. 'ganado'/'nulo' anticipados siguen permitidos
-- (pago anticipado = adelantar una GANANCIA, nunca una pérdida).
create or replace function public.guard_no_early_loss()
returns trigger language plpgsql as $$
declare
  v_live record; v_final boolean := false; v_eid text;
begin
  if TG_OP <> 'UPDATE' then return new; end if;
  if new.resultado is not distinct from old.resultado then return new; end if;
  if new.resultado <> 'perdido' then return new; end if;
  -- overrides humanos explícitos se respetan (auditables aparte)
  if coalesce(new.confianza_calificacion,'') in ('MANUAL','ADMIN_OVERRIDE') then return new; end if;

  v_eid := case when TG_TABLE_NAME='picks' then new.espn_event_id else null end;
  if v_eid is null then
    -- parlays: la pérdida del parlay debe venir de una pata realmente perdida y final;
    -- se delega a los cierres de parlay (auto_cerrar_parlay_si_leg_perdido) que ya
    -- exigen pata decidida. Aquí sólo bloqueamos el atajo directo sin evento.
    return new;
  end if;

  select * into v_live from live_scores where espn_event_id = v_eid limit 1;
  if found then
    v_final := is_truly_final(v_live.status, v_live.status_detail, v_live.minute,
                              v_live.period, v_live.home_score, v_live.away_score,
                              new.liga, new.deporte);
  end if;

  if not v_final then
    if public.es_accion_de_persona() then
      raise exception 'No se puede marcar PERDIDO "%": el partido no ha terminado. Un pago anticipado sólo adelanta ganancias, nunca pérdidas.',
        coalesce(new.partido,'(sin nombre)') using errcode='check_violation';
    end if;
    raise warning 'GUARD: bloqueada pérdida anticipada pick/parlay % (evento % no final)', new.id, v_eid;
    new.resultado := 'pendiente';
    new.ganancia_neta := null;
  end if;
  return new;
end $$;

-- Se instalaría como BEFORE UPDATE, ANTES de protect_picks_premature_grading,
-- para que la pérdida anticipada nunca pase aunque confianza sea EARLY_*:
-- drop trigger if exists trg_guard_no_early_loss_picks on public.picks;
-- create trigger trg_guard_no_early_loss_picks before update on public.picks
--   for each row execute function public.guard_no_early_loss();

-- ── G2) Evidencia obligatoria del Pago Anticipado en picks ────────────────────
-- Si pa_activado pasa a true, exigir pa_score_snapshot y pa_activado_at.
create or replace function public.guard_pa_evidencia_obligatoria()
returns trigger language plpgsql as $$
begin
  if coalesce(new.pa_activado,false) = true
     and coalesce(old.pa_activado,false) = false then
    if new.pa_score_snapshot is null then
      raise exception 'PA sin pa_score_snapshot en pick %: un pago anticipado debe registrar el marcador que lo disparó.', new.id
        using errcode='check_violation';
    end if;
    if new.pa_activado_at is null then
      new.pa_activado_at := now();  -- sello automático si falta, para no perder trazabilidad
    end if;
  end if;
  return new;
end $$;
-- create trigger trg_guard_pa_evidencia before update on public.picks
--   for each row execute function public.guard_pa_evidencia_obligatoria();

-- Alternativa dura (constraint) para nuevas filas/edición:
-- alter table public.picks add constraint chk_pa_evidencia
--   check (pa_activado is not true or (pa_score_snapshot is not null and pa_activado_at is not null))
--   not valid;   -- 'not valid' para no romper la fila huérfana histórica; validar tras sanearla.

-- ── G3) Saneo de la fila huérfana (1 pick con pa_activado sin evidencia) ───────
-- Diagnóstico (read-only) ya hecho: 1 fila con pa_activado=true, pa_score_snapshot
-- y pa_activado_at NULL. Decisión al aplicar (NO ahora):
--   opción A: si el partido ya es final y ganó -> re-gradar normal y limpiar pa_activado.
--   opción B: si no es auditable -> pa_activado=false (revertir el PA sin evidencia).
-- update public.picks set pa_activado=false
--  where pa_activado is true and pa_score_snapshot is null and pa_activado_at is null;

-- ── G4) Idempotencia de bankroll (nota) ──────────────────────────────────────
-- actualizar_bankroll_post_al_calificar / _parlay deben ser idempotentes: recalcular
-- bankroll_post desde el estado, no acumular. Se audita en iss029 (no en este guard).
