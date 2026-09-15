-- ============================================================================
-- iss035 — GAP B: idempotencia de bankroll · STAGED, NO APLICAR
-- ============================================================================
-- HALLAZGO: el bankroll-VERDAD ya es idempotente por construcción.
-- calcular_bankroll_actual__base = bankroll_inicial + SUM(ajustes)
--   + SUM(picks.ganancia_neta where graded) + SUM(parlays.ganancia_total where graded).
-- Es una SUMA sobre el ESTADO actual de las filas, nunca un acumulador incremental.
-- Por tanto: doble callback, retry, re-grade, PUSH y early payout NO pueden doble
-- contabilizar — al recalcular, la suma refleja el valor actual de cada fila una vez.
--
-- ÚNICO residual: la columna CACHE picks.bankroll_post / parlays.bankroll_post
-- (snapshot "bankroll tras esta apuesta") sólo se recalcula en la transición
-- pendiente->graded (el trigger exige OLD.resultado='pendiente'). En una CORRECCIÓN
-- de resultado (graded->graded, p.ej. ganado->perdido) el cache queda STALE, aunque
-- el bankroll-verdad ya esté correcto. Fix: recalcular el cache también cuando
-- cambia ganancia_neta/resultado en una fila ya calificada.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- picks: recalcular bankroll_post también en corrección/re-grade (idempotente)
create or replace function public.actualizar_bankroll_post_al_calificar()
returns trigger language plpgsql set search_path to 'public' as $function$
declare v_base numeric;
begin
  if (TG_OP='INSERT' and NEW.resultado in ('ganado','perdido','push','nulo'))
     or (TG_OP='UPDATE' and NEW.resultado in ('ganado','perdido','push','nulo','retirado')
         and (OLD.resultado is distinct from NEW.resultado
              or OLD.ganancia_neta is distinct from NEW.ganancia_neta)) then
    begin
      -- calcular_bankroll_actual es SUMA de estado (idempotente): recalcular, no acumular
      v_base := calcular_bankroll_actual(NEW.apodo);
      NEW.bankroll_post := v_base + coalesce(NEW.ganancia_neta,0);
    exception when others then
      raise warning 'bankroll_post picks no calculado (% %): [%] %', TG_OP, NEW.apodo, SQLSTATE, SQLERRM;
    end;
  end if;
  return NEW;
end $function$;

-- parlays: idem (misma fórmula de bono que ganancia_total, recalculada en corrección)
create or replace function public.actualizar_bankroll_post_parlay()
returns trigger language plpgsql set search_path to 'public' as $function$
declare v_base numeric;
begin
  if (TG_OP='INSERT' and NEW.resultado in ('ganado','perdido','push','nulo'))
     or (TG_OP='UPDATE' and NEW.resultado in ('ganado','perdido','push','nulo','retirado')
         and (OLD.resultado is distinct from NEW.resultado
              or OLD.ganancia_neta is distinct from NEW.ganancia_neta)) then
    begin
      v_base := calcular_bankroll_actual(NEW.apodo);
      NEW.bankroll_post := v_base + coalesce(NEW.ganancia_neta,0)
        + case when NEW.resultado <> 'ganado' then 0
               when NEW.cashout_monto is not null then 0
               when coalesce(NEW.momio_efectivo,0) > coalesce(NEW.momio_total,0) then 0
               else coalesce(NEW.bono,0) end;
    exception when others then
      raise warning 'bankroll_post parlays no calculado (% %): [%] %', TG_OP, NEW.apodo, SQLSTATE, SQLERRM;
    end;
  end if;
  return NEW;
end $function$;

-- NOTA: no se cambia calcular_bankroll_actual__base (ya idempotente). El cambio es
-- sólo extender cuándo se refresca el cache bankroll_post para que no quede stale.
