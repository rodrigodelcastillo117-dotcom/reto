-- ============================================================================
-- iss036 — DAILY PICK CANÓNICO (reemplazo staged de v_reto13m_daily) · STAGED
-- Corrige AUDIT_NO_PASS 5606928639 (STOP-SHIP v_reto13m_daily) + §24 del prompt.
-- NO APLICAR bajo freeze. NO va en supabase/migrations. Depende de iss033.
-- ============================================================================
-- CONTAMINACIÓN de public.v_reto13m_daily (verificada en pg_get_viewdef, 2026-09-09):
--   1) btts_no := 100 - btts_yes   (COMPLEMENTO derivado, no del mismo snapshot). §16/N.
--   2) candidato "Over 2.5 goles" := (markets->>'over25')  SIN mirar la línea real del
--      proveedor => ofrece Over 2.5 cuando la línea real es 3.5 (Vancouver, Atlanta,
--      Portland MLS hoy). STOP-SHIP §15/§18.
--   3) set de candidatos + umbrales (45..83.3) hardcodeados en la vista.
--
-- PRINCIPIO (§24, §49): el daily NO recalcula probabilidad. SELECCIONA y RANKEA
-- filas de la superficie canónica. Prohibido: recalcular P, hardcodear 2.5,
-- complemento BTTS, mercado con línea distinta a la del proveedor.
--
-- FUENTE CANÓNICA: v2.soccer_prediction_v2_staged (iss033) — 1 fila/evento con
-- p_home/p_draw/p_away, btts_yes+btts_no EXPLÍCITOS del mismo snapshot, y O/U
-- (p_over/p_under) SOLO sobre la línea REAL del proveedor (over_line, line_source).
-- ============================================================================

-- Candidatos canónicos: 1X2 (3) + BTTS sí/no (explícitos) + O/U a la línea REAL.
-- Cada candidato lleva su market/side/line y su probabilidad canónica tal cual.
create or replace view v2.v_soccer_daily_candidates as
select c.espn_event_id as canonical_event_id,
       c.home_team, c.away_team, c.competition_id, c.kickoff, c.decision_time,
       c.model_version, c.feature_snapshot_id as model_snapshot_id,
       cand.canonical_market, cand.canonical_side, cand.canonical_line, cand.canonical_probability,
       c.sample_home, c.sample_away
from v2.soccer_prediction_v2_staged c
cross join lateral (
  values
    ('1X2'::text, 'HOME'::text, null::numeric, c.p_home),
    ('1X2',       'DRAW',        null,          c.p_draw),
    ('1X2',       'AWAY',        null,          c.p_away),
    ('BTTS',      'YES',         null,          c.btts_yes),
    ('BTTS',      'NO',          null,          c.btts_no),   -- del MISMO snapshot, NO 100-yes
    -- O/U SOLO a la línea real del proveedor; si over_line es null => no hay candidato O/U
    ('OU',        'OVER',        c.over_line,   case when c.over_line is not null then c.p_over end),
    ('OU',        'UNDER',       c.over_line,   case when c.over_line is not null then c.p_under end)
) cand(canonical_market, canonical_side, canonical_line, canonical_probability)
where c.model_status = 'READY_UNVALIDATED'          -- fail-closed: sólo eventos con P_RETO
  and cand.canonical_probability is not null;

-- Ranking diario: NO crea probabilidad; ordena candidatos por probabilidad canónica
-- (+ desempates por muestra y kickoff). rank_dia sobre (día MX). Pick del Día = rank 1.
create or replace view v2.v_soccer_daily_canonical as
with cand as (
  select d.*,
    (d.kickoff at time zone 'America/Mexico_City')::date as dia_mx,
    least(coalesce(d.sample_home,0), coalesce(d.sample_away,0)) as muestra_min
  from v2.v_soccer_daily_candidates d
),
-- mejor candidato POR EVENTO (para no listar 7 filas del mismo partido)
best_per_event as (
  select *, row_number() over (
      partition by canonical_event_id
      order by canonical_probability desc, muestra_min desc, canonical_market
    ) as rn_event
  from cand
),
ranked as (
  select b.*, row_number() over (
      partition by dia_mx
      order by canonical_probability desc, muestra_min desc, kickoff, canonical_event_id
    ) as rank_dia
  from best_per_event b
  where rn_event = 1
)
select 'FUT'::text as deporte, canonical_event_id, home_team, away_team, competition_id,
       kickoff, dia_mx, decision_time, model_version, model_snapshot_id,
       canonical_market, canonical_side, canonical_line, canonical_probability,
       muestra_min, rank_dia, (rank_dia = 1) as es_mejor_del_dia
from ranked;

-- Contrato de salida (§24): canonical_event_id, canonical_market, canonical_side,
-- canonical_line, canonical_probability, model_snapshot_id, rank_dia. Sin recomputo,
-- sin 2.5 fijo, sin complemento BTTS, O/U sólo a la línea real del proveedor.
