-- ============================================================================
-- iss032 — REAL PROVIDER TOTAL LINE CONTRACT (BLOQUE 4) · STAGED, NO APLICAR
-- ============================================================================
-- Toda O/U debe exponer: provider_total_line, provider, line_asof, decision_time,
-- con invariante line_asof <= decision_time. Prohibido: hardcode 2.5, nearest-line
-- silenciosa, fallback inventado. Sin línea real confiable <= decision -> O/U fail-closed.
--
-- Fuente canónica = v_momios_confiables (la MISMA que consume v_futpro_v2 vía line_source):
--   over_line (provider_total_line), bookmaker (provider), snapshot_at (line_asof),
--   over_odds/under_odds, confiable.
--
-- AUDIT real (2026-09-09, eventos READY con O/U en v_futpro_v2):
--   ready_con_ou=77 · con_linea_real<=dec=77/77 · linea_publicada==linea_proveedor=77/77
--   sin_linea_real(fail-close esperado)=0 · line_asof<=decision=77/77
--   over_line=2.5 aparece 46/77 pero NO es hardcode: coincide 1:1 con la línea real
--   del libro en los 77 (linea_coincide=77). Cero líneas fabricadas.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- Contrato: línea real del proveedor para un evento a un decision_time dado.
-- Devuelve fila SOLO si hay línea confiable con snapshot_at <= decision. Si no,
-- 0 filas => el caller deja O/U fail-closed (over_prob/under_prob = NULL).
create or replace function v2.fn_real_total_line(
  p_event_id text, p_decision_time timestamptz
) returns table(
  provider_total_line numeric, provider text, line_asof timestamptz,
  decision_time timestamptz, over_odds numeric, under_odds numeric, temporally_safe boolean
) language sql stable as $$
  select mc.over_line, mc.bookmaker, mc.snapshot_at, p_decision_time,
         mc.over_odds, mc.under_odds, (mc.snapshot_at <= p_decision_time)
  from v_momios_confiables mc
  where mc.espn_event_id = p_event_id
    and mc.confiable is true
    and mc.over_line is not null
    and mc.snapshot_at <= p_decision_time            -- invariante line_asof<=decision
  order by mc.snapshot_at desc                        -- última captura válida (no max sin filtro)
  limit 1;
$$;

-- Auditoría de línea real (evidencia continua; read-only).
-- STAGED-GATE FIX: v_futpro_v2 es un objeto base de prod con cierre de dependencias
-- que explota (>3 objetos: soccer_prediction_v2, v_goles_equipo_futbol, escudos_evento,
-- team_logo, fn_dist_from_lambda...). En un branch vacío no existe. La vista de
-- auditoría se crea SOLO si v_futpro_v2 está presente (no bloquea el deliverable
-- central, que es v2.fn_real_total_line). En prod real la vista se crea normal.
do $iss032$ begin
  if to_regclass('public.v_futpro_v2') is not null then
    execute $view$
      create or replace view v2.v_real_line_audit as
      with ev as (
        select canonical_event_id eid, coalesce(prediction_time,computed_at) dec, over_line, p_over
        from v_futpro_v2 where model_status like 'READY%' and p_over is not null
      )
      select e.eid, e.dec, e.over_line as linea_publicada,
        l.provider_total_line as linea_real, l.provider, l.line_asof,
        (l.provider_total_line is null) as fail_close_por_sin_linea,
        (l.provider_total_line is not null and l.provider_total_line = e.over_line) as coincide
      from ev e
      left join lateral v2.fn_real_total_line(e.eid, e.dec) l on true;
    $view$;
  end if;
end $iss032$;

-- Regla de consumo (BLOQUE 5): over_prob/under_prob SOLO si fn_real_total_line
-- devuelve fila Y la línea usada por el modelo == provider_total_line. Si difieren
-- o no hay línea -> O/U fail-closed (NULL), nunca se re-ancla a otra línea.
