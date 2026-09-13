-- ISS129b — close direct NFL RPC bypass. STAGED / NO PROD MUTATION.
-- Depends on ISS129.

create or replace function v2.fn_nfl_reto_predice(p_event text)
returns jsonb language plpgsql stable as $function$
declare s record; mejor record; v_gate text;
begin
  select * into s
  from v2.nfl_decision_snapshot
  where espn_event_id=p_event
  order by decision_time desc, built_at desc
  limit 1;

  if s.espn_event_id is null then return null; end if;

  select validation_status into v_gate
  from v2.nfl_model_validation_gate
  where model_version=s.model_version;

  -- Missing gate row, non-OOS-validated version, or non-READY snapshot: fail closed.
  if not v2.fn_nfl_release_allowed(s.model_version) or s.model_status <> 'READY' then
    return jsonb_build_object(
      'disponible', false,
      'model_status', case when not v2.fn_nfl_release_allowed(s.model_version)
                           then 'VALIDATION_BLOCKED' else s.model_status end,
      'validation_status', coalesce(v_gate,'FAIL_CLOSED_OOS_NOT_PROVEN'),
      'motivo', case when not v2.fn_nfl_release_allowed(s.model_version)
                     then 'P_RETO bloqueado: validacion OOS independiente no demostrada'
                     else s.suppression_reason end,
      'model_version', s.model_version,
      'decision_time', s.decision_time
    );
  end if;

  -- Only an authorized model reaches this block. Candidate selection is model-probability
  -- only; market lines are context and never determine P_RETO.
  select c.mercado, c.lado, c.linea, c.p_reto into mejor
  from (values
    ('ML'::text, s.home_team, null::numeric, s.p_home_ml),
    ('ML', s.away_team, null::numeric, s.p_away_ml),
    ('SPREAD', s.home_team, s.dk_spread_home, s.p_home_cover),
    ('SPREAD', s.away_team, -s.dk_spread_home, s.p_away_cover),
    ('TOTAL', 'OVER', s.dk_total, s.p_over),
    ('TOTAL', 'UNDER', s.dk_total, s.p_under)
  ) c(mercado,lado,linea,p_reto)
  where c.p_reto is not null
  order by c.p_reto desc
  limit 1;

  return jsonb_build_object(
    'disponible', true,
    'model_version', s.model_version,
    'model_status', s.model_status,
    'validation_status', v_gate,
    'calibration_status', s.calibration_status,
    'decision_time', s.decision_time,
    'ganador', jsonb_build_object(
      'local', s.home_team, 'p_local', s.p_home_ml,
      'visitante', s.away_team, 'p_visitante', s.p_away_ml,
      'p_empate_regular', s.p_tie_regulation),
    'spread', case when s.dk_spread_home is not null then jsonb_build_object(
      'linea_dk', s.dk_spread_home, 'cubre_local', s.p_home_cover,
      'cubre_visitante', s.p_away_cover, 'push', s.p_spread_push) end,
    'total', case when s.dk_total is not null then jsonb_build_object(
      'linea_dk', s.dk_total, 'over', s.p_over,
      'under', s.p_under, 'push', s.p_total_push) end,
    'proyeccion', jsonb_build_object(
      'puntos_local', s.exp_home, 'puntos_visitante', s.exp_away,
      'margen', s.exp_margin, 'total', s.exp_total),
    'mejor_candidato', case when mejor.mercado is not null then jsonb_build_object(
      'mercado', mejor.mercado, 'lado', mejor.lado,
      'linea', mejor.linea, 'probabilidad', mejor.p_reto) end,
    'incertidumbre_puntos', s.uncertainty,
    'cobertura', s.coverage,
    'calidad', s.quality_status,
    'fuente_probabilidad', s.prob_source,
    'advertencia', 'P_RETO propio de RETO. Mercado/momios son contexto diagnostico/economico y nunca sustituyen la probabilidad.'
  );
end $function$;
