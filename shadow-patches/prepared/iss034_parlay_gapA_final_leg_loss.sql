-- ============================================================================
-- iss034 — GAP A: parlay pierde SÓLO con pata FINAL realmente perdida · STAGED
-- ============================================================================
-- Bug (AUDIT): auto_cerrar_parlay_si_leg_perdido() y cerrar_parlays_con_pata_perdida()
-- cierran el parlay como 'perdido' si CUALQUIER pata tiene resultado='perdido',
-- SIN verificar que esa pata sea realmente FINAL. Una pata marcada 'perdido' por la
-- ruta EARLY (en vivo) => cierra el parlay. Combinado con iss028 (que ya impide la
-- pérdida anticipada de picks) esto blinda también el cierre del PARLAY.
-- Regla: una pata sólo cuenta como perdedora del parlay si su evento es
-- is_truly_final Y su resultado='perdido'. Pata LIVE/PRE nunca cierra el parlay.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- Helper: ¿la pata (por su espn_event_id) es realmente FINAL?
create or replace function v2.fn_leg_is_final(p_leg jsonb) returns boolean
language plpgsql stable as $$
declare v record; eid text := p_leg->>'espn_event_id';
begin
  if eid is null then return false; end if;                 -- sin evento -> no se puede afirmar final
  select * into v from public.live_scores where espn_event_id=eid limit 1;
  if not found then return false; end if;                   -- sin marcador -> no final demostrable
  -- STAGED-GATE FIX: pasar liga/deporte del propio live_scores (antes null,null), porque
  -- is_truly_final es FAIL-CLOSED para eventos sin deporte resoluble (no aplica la regla
  -- de "final" de fútbol si no puede clasificar el deporte). Un evento soccer con
  -- status='final'/period>=2 sólo se reconoce como final si lleva su liga/deporte.
  return public.is_truly_final(v.status, v.status_detail, v.minute, v.period,
                               v.home_score, v.away_score, v.liga, v.deporte);
end $$;

-- ── Trigger reescrito: cierre por pata perdida SÓLO si esa pata es FINAL ──────
create or replace function public.auto_cerrar_parlay_si_leg_perdido()
returns trigger language plpgsql set search_path to 'public' as $function$
declare v_leg jsonb; v_lost_final boolean := false;
begin
  if NEW.resultado is distinct from 'pendiente' then return NEW; end if;
  for v_leg in select jsonb_array_elements(coalesce(NEW.picks_data,'[]'::jsonb)) loop
    -- pata perdedora VÁLIDA = resultado 'perdido' Y evento realmente FINAL
    if (v_leg->>'resultado')='perdido' and v2.fn_leg_is_final(v_leg) then
      v_lost_final := true; exit;
    end if;
  end loop;
  if v_lost_final then
    NEW.resultado := 'perdido';
    NEW.ganancia_neta := -NEW.apuesta;
    NEW.confianza_calificacion := 'AUTO_LOST_LEG_FINAL';
  end if;
  -- Si hay patas 'perdido' pero NINGUNA es final aún -> el parlay SIGUE pendiente.
  return NEW;
end $function$;

-- ── Batch reescrito: idem (sólo cierra con pata FINAL perdida) ────────────────
create or replace function public.cerrar_parlays_con_pata_perdida(p_dry_run boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public','extensions' as $function$
declare r record; n int:=0; det jsonb:='[]'::jsonb; v_leg jsonb; v_final_lost int;
begin
  for r in
    select p.id, p.apodo, p.apuesta, p.fecha, p.picks_data
    from parlays p
    where p.resultado='pendiente' and p.picks_data is not null and coalesce(p.manual_lock,false)=false
  loop
    v_final_lost := 0;
    for v_leg in select jsonb_array_elements(r.picks_data) loop
      if (v_leg->>'resultado')='perdido' and v2.fn_leg_is_final(v_leg) then
        v_final_lost := v_final_lost + 1;
      end if;
    end loop;
    if v_final_lost > 0 then
      det := det || jsonb_build_object('parlay',r.id,'apodo',r.apodo,'fecha',r.fecha,'patas_perdidas_final',v_final_lost);
      if not p_dry_run then
        update parlays set resultado='perdido', ganancia_neta=-coalesce(apuesta,0), updated_at=now()
        where id=r.id and resultado='pendiente';
      end if;
      n := n+1;
    end if;
  end loop;
  return jsonb_build_object('cerrados',n,'dry_run',p_dry_run,'detalle',det);
end $function$;
