-- ============================================================================
-- iss038 — PARLAY JOINT PROBABILITY FAIL-CLOSED (§25) · STAGED, NO APLICAR
-- ============================================================================
-- HALLAZGO (read-only, verificado 2026-09-09):
--  - `public.parlays.ai_prob_combinada` (numeric) está poblado en 38/65 parlays, SIN
--    ningún escritor SQL (prefijo `ai_` => valor producido por LLM/edge). Es una
--    probabilidad CONJUNTA de parlay de proveniencia no validada.
--  - `iss022` calcula `prob_parlay_pct = producto de P_RETO de patas` (independencia).
-- §25: NO se puede presentar P_joint = Π(P_legs) ni una prob conjunta de LLM como
--    autoridad. Sin modelo conjunto científicamente validado:
--       joint_probability = NULL ; joint_reason = 'NO_VALIDATED_JOINT_MODEL'.
--    (No convertir correlación desconocida en independencia; especialmente same-game.)
--
-- FIX (staged): contrato canónico de parlay que expone las patas con su P_RETO
-- INDIVIDUAL y una prob conjunta SIEMPRE NULL + razón. Nunca lee ai_prob_combinada
-- ni el producto de patas como autoridad. El frontend consume ESTO.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

create or replace view v2.v_parlay_canonical_contract as
select
  p.id                       as parlay_id,
  p.apodo,
  p.fecha,
  jsonb_array_length(coalesce(p.picks_data,'[]'::jsonb)) as n_legs,
  -- patas con su P_RETO INDIVIDUAL (autoridad por-pata; el frontend agrega, no recalcula)
  (select jsonb_agg(jsonb_build_object(
       'espn_event_id', leg->>'espn_event_id',
       'pick_desc',     leg->>'pick_desc',
       'resultado',     leg->>'resultado'
       -- P_RETO por pata se resuelve contra la superficie canónica del evento en cutover
     ))
   from jsonb_array_elements(coalesce(p.picks_data,'[]'::jsonb)) leg) as legs,
  -- PROB CONJUNTA: fail-closed. Nunca ai_prob_combinada, nunca Π(P_legs).
  null::numeric              as joint_probability,
  'NO_VALIDATED_JOINT_MODEL' as joint_reason,
  -- se conserva ai_prob_combinada SÓLO como contexto auditable, marcado no-autoridad
  p.ai_prob_combinada        as ai_prob_combinada_context_only,
  'LLM_ORIGIN_NOT_AUTHORITY' as ai_prob_combinada_status
from public.parlays p;

-- Auditoría read-only asociada (para el reporte / regresión):
--   select count(*) filter (where ai_prob_combinada is not null) from public.parlays;
--   -> ai_prob_combinada NUNCA debe alimentar joint_probability del contrato.
-- INVARIANTE de contrato: en v2.v_parlay_canonical_contract, joint_probability IS NULL
--   para el 100% de las filas y joint_reason='NO_VALIDATED_JOINT_MODEL'.
