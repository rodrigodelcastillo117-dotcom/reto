-- ============================================================================
-- iss038 — PARLAY CANONICAL LEG CONTRACT + JOINT PROBABILITY FAIL-CLOSED (§25)
-- STAGED ONLY · NO APLICAR A PROD DURANTE RELEASE_GATE=HOLD
-- ============================================================================
-- Objetivo:
--   1) cada pata SOCCER resuelve SERVER-SIDE contra resolver_p_reto_futbol();
--   2) mercado/lado/línea/P_RETO provienen de la misma matriz canónica;
--   3) un ticket no representable EXACTAMENTE queda P_RETO=NULL + razón;
--   4) data_asof y, para O/U, provider_line_asof deben ser <= decision_time;
--   5) la probabilidad conjunta SIEMPRE es NULL hasta existir modelo conjunto validado;
--   6) ai_prob_combinada NO forma parte del contrato visible. Sólo existe en una vista
--      de auditoría separada y explícitamente no-autoritativa.
--
-- Dependencias staged: iss018 + iss021. iss031 mejora identidad AF->ESPN pero no es
-- requisito para no inventar: resolver_p_reto_futbol() ya falla cerrado si no resuelve.
-- ============================================================================

-- Una pata -> contrato canónico. La función NO recalcula probabilidad.
create or replace function v2.fn_parlay_leg_canonical_contract(
  p_leg jsonb,
  p_decision_time timestamptz
)
returns jsonb
language plpgsql
stable
set search_path = 'public','v2'
as $$
declare
  v_sport text;
  v_raw_event text;
  v_market_text text;
  v_pick_text text;
  v_requested_line numeric := null;
  v_res jsonb;
  v_status text;
  v_reason text;
  v_event text;
  v_family text;
  r record;
begin
  v_sport := lower(public.sin_acentos(coalesce(p_leg->>'deporte','')));

  -- Este contrato sólo certifica SOCCER. Otros deportes esperan su matriz propia.
  if v_sport !~ '(soccer|futbol)' then
    return jsonb_build_object(
      'espn_event_id', p_leg->>'espn_event_id',
      'canonical_event_id', p_leg->>'canonical_event_id',
      'pick_desc', p_leg->>'pick_desc',
      'resultado', p_leg->>'resultado',
      'canonical_market', null,
      'canonical_side', null,
      'canonical_line', null,
      'p_reto', null,
      'model_status', null,
      'model_version', null,
      'model_snapshot_id', null,
      'provenance', null,
      'unavailable_reason', 'NON_SOCCER_PENDING_SPORT_CONTRACT'
    );
  end if;

  v_raw_event := coalesce(nullif(p_leg->>'canonical_event_id',''), nullif(p_leg->>'espn_event_id',''));
  if v_raw_event is null then
    return jsonb_build_object(
      'espn_event_id', p_leg->>'espn_event_id',
      'canonical_event_id', null,
      'pick_desc', p_leg->>'pick_desc',
      'resultado', p_leg->>'resultado',
      'canonical_market', null,
      'canonical_side', null,
      'canonical_line', null,
      'p_reto', null,
      'model_status', null,
      'model_version', null,
      'model_snapshot_id', null,
      'provenance', null,
      'unavailable_reason', 'MISSING_EVENT_ID'
    );
  end if;

  -- Históricamente picks_data no tiene `mercado` ni `linea` estructurados en muchas
  -- filas. NO inventamos esos campos: usamos pick_desc como texto de resolución y el
  -- resolver canónico decide OK / UNSUPPORTED / LINE_MISMATCH / UNRESOLVED.
  v_market_text := coalesce(nullif(p_leg->>'mercado',''), nullif(p_leg->>'pick_desc',''));
  v_pick_text := coalesce(nullif(p_leg->>'pick_desc',''), nullif(p_leg->>'seleccion',''), v_market_text);

  if nullif(p_leg->>'linea','') is not null
     and (p_leg->>'linea') ~ '^[-+]?[0-9]+([.][0-9]+)?$' then
    v_requested_line := (p_leg->>'linea')::numeric;
  end if;

  if v_market_text is null or v_pick_text is null then
    return jsonb_build_object(
      'espn_event_id', p_leg->>'espn_event_id',
      'canonical_event_id', v_raw_event,
      'pick_desc', p_leg->>'pick_desc',
      'resultado', p_leg->>'resultado',
      'canonical_market', null,
      'canonical_side', null,
      'canonical_line', null,
      'p_reto', null,
      'model_status', null,
      'model_version', null,
      'model_snapshot_id', null,
      'provenance', null,
      'unavailable_reason', 'LEGACY_UNSTRUCTURED_SELECTION'
    );
  end if;

  v_res := public.resolver_p_reto_futbol(
    v_raw_event,
    v_market_text,
    v_pick_text,
    v_requested_line
  );
  v_status := coalesce(v_res->>'status','RESOLVER_NO_STATUS');
  v_reason := v_res->>'reason';
  v_event := coalesce(v_res->>'canonical_event_id',v_raw_event);
  v_family := v_res->>'market_family';

  -- Traemos únicamente metadata de la MISMA fila canónica; no otra probabilidad.
  select * into r
  from public.v_prediccion_reto_futbol m
  where m.canonical_event_id=v_event
  limit 1;

  if v_status <> 'OK' then
    return jsonb_build_object(
      'espn_event_id', p_leg->>'espn_event_id',
      'canonical_event_id', v_event,
      'pick_desc', p_leg->>'pick_desc',
      'resultado', p_leg->>'resultado',
      'canonical_market', v_family,
      'canonical_side', v_res->>'selection',
      'canonical_line', v_res->'line',
      'p_reto', null,
      'model_status', coalesce(v_res->>'model_status', case when found then r.model_status else null end),
      'model_version', case when found then concat_ws(':',r.prob_source,r.score_version) else null end,
      'model_snapshot_id', null,
      'model_snapshot_reason', 'CURRENT_STAGED_MATRIX_DOES_NOT_EXPOSE_PERSISTED_SNAPSHOT_ID',
      'provenance', case when found then jsonb_build_object(
        'model_source', jsonb_build_object(
          'classification','MODEL_ACTIVE',
          'source',r.prob_source,
          'data_asof',r.data_asof,
          'decision_time',p_decision_time,
          'temporal_safe',r.temporal_safe
        )
      ) else null end,
      'unavailable_reason', coalesce(v_reason,v_status)
    );
  end if;

  if not found then
    v_status := 'NO_CANONICAL_ROW';
    v_reason := 'resolver devolvió OK pero no existe la fila canónica asociada';
  elsif p_decision_time is null then
    v_status := 'MISSING_DECISION_TIME';
    v_reason := 'sin decision_time no se puede demostrar integridad temporal';
  elsif r.data_asof is null then
    v_status := 'MISSING_DATA_ASOF';
    v_reason := 'P_RETO sin data_asof auditable';
  elsif r.data_asof > p_decision_time then
    v_status := 'TEMPORAL_AFTER_DECISION';
    v_reason := 'data_asof posterior al decision_time de la pata';
  elsif r.temporal_safe is distinct from true then
    v_status := 'TEMPORAL_UNSAFE';
    v_reason := 'fila canónica marcada temporalmente insegura';
  elsif v_family='OU' and r.provider_line_asof is null then
    v_status := 'MISSING_LINE_ASOF';
    v_reason := 'O/U sin as_of auditable de la línea real del proveedor';
  elsif v_family='OU' and r.provider_line_asof > p_decision_time then
    v_status := 'LINE_AFTER_DECISION';
    v_reason := 'línea del proveedor posterior al decision_time';
  else
    v_status := 'OK';
    v_reason := null;
  end if;

  return jsonb_build_object(
    'espn_event_id', p_leg->>'espn_event_id',
    'canonical_event_id', v_event,
    'pick_desc', p_leg->>'pick_desc',
    'resultado', p_leg->>'resultado',
    'canonical_market', v_family,
    'canonical_side', v_res->>'selection',
    'canonical_line', v_res->'line',
    'p_reto', case when v_status='OK' then v_res->'prob_pct' else 'null'::jsonb end,
    'model_status', r.model_status,
    -- No fingimos un snapshot persistido que el contrato staged aún no expone.
    -- model_version deriva sólo de identificadores reales de la matriz.
    'model_version', concat_ws(':',r.prob_source,r.score_version),
    'model_snapshot_id', null,
    'model_snapshot_reason', 'CURRENT_STAGED_MATRIX_DOES_NOT_EXPOSE_PERSISTED_SNAPSHOT_ID',
    'provenance', jsonb_build_object(
      'model_source', jsonb_build_object(
        'classification','MODEL_ACTIVE',
        'source',r.prob_source,
        'model_generated_at',r.model_generated_at,
        'data_asof',r.data_asof,
        'decision_time',p_decision_time,
        'temporal_safe',(r.data_asof <= p_decision_time and r.temporal_safe is true)
      ),
      'provider_total_line', jsonb_build_object(
        'classification','CONTEXT_ONLY',
        'role','MARKET_DEFINITION_ONLY_NOT_MODEL_FEATURE',
        'provider',r.provider_name,
        'line',case when v_family='OU' then r.linea_ou else null end,
        'as_of',case when v_family='OU' then r.provider_line_asof else null end,
        'used_for_this_leg',(v_family='OU')
      )
    ),
    'unavailable_reason', v_reason
  );
end;
$$;

-- Contrato de consumo visible. NO expone ai_prob_combinada ni una pseudo-P conjunta.
create or replace view v2.v_parlay_canonical_contract as
select
  p.id as parlay_id,
  p.apodo,
  p.fecha,
  p.created_at as decision_time,
  jsonb_array_length(coalesce(p.picks_data,'[]'::jsonb)) as n_legs,
  (
    select jsonb_agg(
      v2.fn_parlay_leg_canonical_contract(leg,p.created_at)
      order by ord
    )
    from jsonb_array_elements(coalesce(p.picks_data,'[]'::jsonb)) with ordinality x(leg,ord)
  ) as legs,
  null::numeric as joint_probability,
  'NO_VALIDATED_JOINT_MODEL'::text as joint_reason
from public.parlays p;

-- Auditoría administrativa SEPARADA. Nunca usar como contrato visible/predictivo.
create or replace view v2.v_parlay_non_authority_audit as
select
  p.id as parlay_id,
  p.ai_prob_combinada as ai_prob_combinada_context_only,
  'AVAILABLE_NOT_USED'::text as classification,
  'LLM_ORIGIN_NOT_AUTHORITY'::text as reason
from public.parlays p
where p.ai_prob_combinada is not null;

-- INVARIANTES DE CUTOVER (ejecutar sólo en rama DB aislada):
--   * joint_probability IS NULL para 100% de parlays.
--   * ninguna pata soccer con unavailable_reason no-null expone p_reto.
--   * O/U solicitada 2.5 cuando provider line=3.5 => LINE_MISMATCH + p_reto NULL.
--   * BTTS No sólo puede ser OK si resolver_p_reto_futbol devuelve p_btts_no explícita.
--   * todo p_reto no-null cumple data_asof <= decision_time; O/U además line_asof <= decision_time.
--   * ai_prob_combinada no aparece en v2.v_parlay_canonical_contract.
