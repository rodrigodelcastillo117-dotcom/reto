-- ============================================================================
-- iss038 — PARLAY CANONICAL PER-LEG CONTRACT + JOINT PROB FAIL-CLOSED (§25)
-- v2: corrige AUDIT_NO_PASS 5609355379 (contrato por-pata resuelto SERVER-SIDE).
-- STAGED, NO APLICAR.
-- ============================================================================
-- HALLAZGO original (read-only): `public.parlays.ai_prob_combinada` poblado 38/65 sin
--   escritor SQL (origen LLM/edge) — prob CONJUNTA no validada; `iss022` usa Π(P_RETO)
--   asumiendo independencia. §25: ninguno puede ser autoridad de prob conjunta.
--   => joint_probability = NULL ; joint_reason = 'NO_VALIDATED_JOINT_MODEL'.
--
-- DEFECTO v1 (auditoría 5609355379): el contrato sólo emitía por pata
--   {espn_event_id, pick_desc, resultado} y decía que "P_RETO se resuelve en cutover"
--   => dejaba la resolución en el frontend, rompiendo "una sola verdad backend por pata".
--
-- DIAGNÓSTICO PROD (read-only, chatgpt 5609588898 confirmado): últimos 30d en
--   `parlays.picks_data`: 363 legs; 0/363 con `mercado` estructurado; 0/363 con `linea`;
--   0/363 con `canonical_event_id`; 362/363 con `espn_event_id`. Los tickets NO traen
--   mercado/línea estructurados => hay que resolver contra la superficie canónica por
--   evento + parsear el pick, y FAIL-CLOSE cuando no es representable exactamente.
--
-- FIX v2 (staged): `v2.fn_parlay_leg_canonical(leg, decision_time)` resuelve CADA pata
--   SERVER-SIDE contra la salida AS-OF del builder `v2.soccer_prediction_v2_staged`
--   (que ya trae temporal fields, snapshot id, provenance, btts_no explícito, O/U línea
--   real). Emite por pata: canonical_event_id, canonical_market, canonical_side,
--   canonical_line, p_reto, model_status, model_version, model_snapshot_id, provenance,
--   data_asof, unavailable_reason. Reglas fail-close:
--     - evento no está en la matriz canónica         -> p_reto NULL, NO_CANONICAL_MATCH
--     - model_status != MODEL_ACTIVE                  -> p_reto NULL, <model_status_reason>
--     - feature_data_asof > decision_time             -> p_reto NULL, DATA_ASOF_AFTER_DECISION
--     - 1X2 lado no resuelto                          -> p_reto NULL, SIDE_UNRESOLVED
--     - BTTS No sin columna explícita                 -> p_reto NULL, BTTS_NO_NOT_EXPLICIT
--     - O/U línea != línea real de la matriz (exacto) -> p_reto NULL, OU_LINE_MISMATCH
--     - O/U line_asof > decision_time                 -> p_reto NULL, OU_LINE_AFTER_DECISION
--     - pick no clasificable a mercado canónico       -> p_reto NULL, UNPARSEABLE_PICK
--   NUNCA sustituye por otro pick/otra línea del evento. `ai_prob_combinada` SALE del
--   contrato visible; queda aislado en `v2.v_parlay_non_authority_audit` (admin-only)
--   como AVAILABLE_NOT_USED. `joint_probability` SIEMPRE NULL.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

create or replace function v2.fn_parlay_leg_canonical(p_leg jsonb, p_decision_time timestamptz)
returns jsonb language plpgsql stable as $$
declare
  v_espn    text    := nullif(p_leg->>'espn_event_id','');
  v_desc    text    := coalesce(nullif(p_leg->>'pick_desc',''), nullif(p_leg->>'seleccion',''), '');
  v_mkt_in  text    := lower(coalesce(p_leg->>'mercado',''));
  v_side_in text    := lower(coalesce(p_leg->>'lado', p_leg->>'side', ''));
  v_line_in numeric := nullif(regexp_replace(coalesce(p_leg->>'linea',''), '[^0-9.]', '', 'g'),'')::numeric;
  v_dl      text    := lower(v_desc);
  v_market  text    := 'UNRESOLVED';
  v_side    text    := null;
  v_line    numeric := null;
  r         record;
  v_p       numeric := null;
  v_reason  text    := null;
  v_status  text    := null;
  v_snap    uuid    := null;
  v_mver    text    := null;
  v_prov    jsonb   := null;
  v_asof    timestamptz := null;
begin
  -- ---- 1) CLASIFICACIÓN de mercado/lado/línea (estructurado primero, luego desc) ----
  if v_mkt_in ~ 'btts|ambos|both' or v_dl ~ 'btts|ambos anotan|ambos marcan|both teams' then
    v_market := 'BTTS';
    if    v_side_in ~ '(^|[^a-z])no' or v_dl ~ '(^|[^a-z])no( |$)' then v_side := 'NO';
    elsif v_side_in ~ 'si|sí|yes'    or v_dl ~ 'si|sí|yes'          then v_side := 'YES';
    end if;
  elsif v_mkt_in ~ 'over|under|total|o/u|ou|más|mas|menos|goles' or v_dl ~ 'over|under|más de|mas de|menos de|total de goles' then
    v_market := 'OU';
    if    v_side_in ~ 'over|más|mas' or v_dl ~ 'over|más de|mas de' then v_side := 'OVER';
    elsif v_side_in ~ 'under|menos'  or v_dl ~ 'under|menos de'     then v_side := 'UNDER';
    end if;
    v_line := coalesce(v_line_in, nullif(substring(v_desc from '([0-9]+\.?[0-9]*)'),'')::numeric);
  elsif v_mkt_in ~ '1x2|ml|money|result|gana' or v_dl ~ 'gana|empate|draw|local|visita|home|away|1x2|moneyline' then
    v_market := '1X2';
    if    v_side_in ~ 'home|local|(^|[^0-9])1' or v_dl ~ 'gana local|local gana|(^| )home' then v_side := 'HOME';
    elsif v_side_in ~ 'draw|empate|x'          or v_dl ~ 'empate|draw'                      then v_side := 'DRAW';
    elsif v_side_in ~ 'away|visit|(^|[^0-9])2' or v_dl ~ 'gana visita|visita gana|away|visitante' then v_side := 'AWAY';
    end if;
  end if;

  -- ---- 2) LOOKUP canónico as-of (nunca live/leaky); toma la fila as-of vigente ----
  select * into r
  from v2.soccer_prediction_v2_staged s
  where s.espn_event_id = v_espn
    and s.feature_data_asof <= p_decision_time
  order by s.decision_time desc nulls last, s.built_at desc nulls last
  limit 1;

  if v_espn is null then
    v_reason := 'NO_EVENT_ID';
  elsif not found then
    v_reason := 'NO_CANONICAL_MATCH';
  else
    v_status := r.model_status; v_snap := r.feature_snapshot_id; v_mver := r.model_version;
    v_prov := r.provenance; v_asof := r.feature_data_asof;
    if r.feature_data_asof > p_decision_time then
      v_reason := 'DATA_ASOF_AFTER_DECISION';
    elsif coalesce(r.model_status,'') <> 'MODEL_ACTIVE' then
      v_reason := coalesce(nullif(r.model_status_reason,''), coalesce(r.model_status,'NO_MODEL'));
    elsif v_market = 'UNRESOLVED' then
      v_reason := 'UNPARSEABLE_PICK';
    elsif v_market = '1X2' then
      if    v_side = 'HOME' then v_p := r.p_home;
      elsif v_side = 'DRAW' then v_p := r.p_draw;
      elsif v_side = 'AWAY' then v_p := r.p_away;
      else  v_reason := 'SIDE_UNRESOLVED'; end if;
    elsif v_market = 'BTTS' then
      if    v_side = 'YES' then v_p := r.btts_yes;
      elsif v_side = 'NO'  then
              if r.btts_no is null then v_reason := 'BTTS_NO_NOT_EXPLICIT'; else v_p := r.btts_no; end if;
      else  v_reason := 'SIDE_UNRESOLVED'; end if;
    elsif v_market = 'OU' then
      if v_side is null then v_reason := 'SIDE_UNRESOLVED';
      elsif v_line is null then v_reason := 'OU_LINE_MISSING';
      elsif r.over_line is null or v_line <> r.over_line then v_reason := 'OU_LINE_MISMATCH';   -- exacto; nunca sustituye
      elsif r.line_asof is not null and r.line_asof > p_decision_time then v_reason := 'OU_LINE_AFTER_DECISION';
      elsif v_side = 'OVER'  then v_p := r.p_over;
      elsif v_side = 'UNDER' then v_p := r.p_under;
      end if;
    end if;
  end if;

  -- p_reto sólo sobrevive si no hubo razón de fail-close
  if v_reason is not null then v_p := null; end if;

  return jsonb_build_object(
    'espn_event_id',    v_espn,
    'canonical_event_id', v_espn,                       -- ESPN id ES la identidad canónica del evento
    'pick_desc',        v_desc,
    'canonical_market', v_market,
    'canonical_side',   v_side,
    'canonical_line',   v_line,
    'p_reto',           v_p,
    'model_status',     v_status,
    'model_version',    v_mver,
    'model_snapshot_id', v_snap,
    'provenance',       v_prov,
    'data_asof',        v_asof,
    'temporal_ok',      (v_asof is not null and v_asof <= p_decision_time),
    'unavailable_reason', v_reason
  );
end $$;

-- Contrato VISIBLE consumible por frontend: patas resueltas server-side; joint NULL;
-- sin ai_prob_combinada.
create or replace view v2.v_parlay_canonical_contract as
select
  p.id    as parlay_id,
  p.apodo,
  p.fecha,
  jsonb_array_length(coalesce(p.picks_data,'[]'::jsonb)) as n_legs,
  (select jsonb_agg(v2.fn_parlay_leg_canonical(leg, coalesce(p.created_at, (p.fecha)::timestamptz)))
     from jsonb_array_elements(coalesce(p.picks_data,'[]'::jsonb)) leg) as legs,
  null::numeric              as joint_probability,     -- §25: nunca Π(P_legs) ni LLM
  'NO_VALIDATED_JOINT_MODEL' as joint_reason
from public.parlays p;

-- Aislamiento admin-only del valor LLM: existe pero NO es autoridad ni parte del contrato.
create or replace view v2.v_parlay_non_authority_audit as
select
  p.id                       as parlay_id,
  p.ai_prob_combinada,
  'LLM_ORIGIN_NOT_AUTHORITY' as origin,
  'AVAILABLE_NOT_USED'       as usage_status
from public.parlays p
where p.ai_prob_combinada is not null;

-- INVARIANTES de contrato (regresión iss038):
--  1) joint_probability IS NULL en el 100% de v2.v_parlay_canonical_contract.
--  2) toda pata con p_reto NOT NULL cumple temporal_ok=true (data_asof<=decision).
--  3) O/U con línea != línea real de la matriz => p_reto NULL + OU_LINE_MISMATCH (no sustituye).
--  4) BTTS No sólo desde btts_no explícito de la matriz (nunca 100-yes).
--  5) v2.v_parlay_canonical_contract NO expone ai_prob_combinada.
