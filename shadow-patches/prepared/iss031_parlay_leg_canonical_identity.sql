-- ============================================================================
-- iss031 — IDENTIDAD CANÓNICA DE PATAS DE PARLAY (agrupado) · STAGED, NO APLICAR
-- ============================================================================
-- Bug (reportado por usuario, 2026-09-09): en un parlay, dos patas del MISMO partido
-- NO se agrupan. Causa raíz (verificada): una pata quedó con id 'af_<fixture>' (API-
-- Football sin resolver) y la otra con el id ESPN real → dos identidades → no agrupan.
-- Alcance: 63/363 patas (17%) en 16/58 parlays (30 días) con id 'af_' sin resolver.
--
-- Por qué el canonizador actual falla: canonizar_evento_id('af_1635698') devuelve
-- 'af_1635698' SIN CAMBIO (sólo mapea vía registro de fixtures, vacío para estos
-- partidos de Champions). En cambio resolver_evento_canonico('af_1635698') SÍ
-- resuelve a '401915423' por equipos+fecha (reason_code FUZZY_UNIQUE).
--
-- Fix: canonicalizar cada pata con el resolver FUERTE (equipos+fecha) como fallback,
-- y escribir canonical_event_id por pata para que el frontend agrupe por él.
-- Regla dura: NUNCA adivinar. Sólo se adopta el id ESPN si el resolver es EXACT o
-- FUZZY_UNIQUE; si es ambiguo/nulo -> se conserva el id crudo y needs_review=true.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- ── 1) Id canónico de UNA pata (passthrough ESPN; resolver fuerte para af_) ───
create or replace function v2.fn_leg_canonical_event_id(p_raw_id text)
returns table(canonical_id text, resuelto boolean, reason text)
language plpgsql stable as $$
declare r jsonb; rc text; eid text;
begin
  if p_raw_id is null then
    return query select null::text, false, 'sin id'; return;
  end if;
  if p_raw_id not like 'af\_%' then          -- ya es id ESPN
    return query select p_raw_id, true, 'YA_ESPN'; return;
  end if;
  r  := resolver_evento_canonico(p_raw_id);   -- resolver fuerte (equipos+fecha)
  rc := r->>'reason_code';
  eid:= r->>'espn_event_id';
  if eid is not null and eid not like 'af\_%' and rc in ('EXACT','FUZZY_UNIQUE','exact','fuzzy_unique') then
    return query select eid, true, rc; return;
  end if;
  -- ambiguo o sin match: NO adivinar
  return query select p_raw_id, false, coalesce(rc,'NO_RESUELTO'); return;
end $$;

-- ── 2) Normalización de un parlay (DRY-RUN): añade canonical_event_id por pata ─
-- Devuelve el picks_data propuesto SIN escribir. El apply real es el UPDATE de §4.
create or replace function v2.fn_parlay_identidad_propuesta(p_parlay_id uuid)
returns jsonb language plpgsql stable as $$
declare v jsonb; out jsonb := '[]'::jsonb; leg jsonb; c record;
begin
  select picks_data into v from parlays where id=p_parlay_id;
  if v is null then return null; end if;
  for leg in select * from jsonb_array_elements(v) loop
    select * into c from v2.fn_leg_canonical_event_id(leg->>'espn_event_id');
    out := out || jsonb_build_array(
      leg || jsonb_build_object(
        'canonical_event_id', c.canonical_id,
        'identity_resuelto', c.resuelto,
        'identity_reason', c.reason,
        'needs_review', (not c.resuelto)
      ));
  end loop;
  return out;
end $$;

-- ── 3) Auditoría de identidad de evento (evidencia; read-only) ────────────────
create or replace view v2.v_parlay_identity_audit as
select p.id parlay_id, p.apodo, p.created_at,
  count(*) legs,
  count(*) filter (where (leg->>'espn_event_id') like 'af\_%') af_sin_resolver,
  count(distinct case when (leg->>'espn_event_id') like 'af\_%' then null else leg->>'espn_event_id' end) grupos_espn
from parlays p, lateral jsonb_array_elements(p.picks_data) leg
group by p.id, p.apodo, p.created_at;

-- ── 4) BACKFILL staged (NO aplicar): escribir canonical_event_id en patas ─────
-- Sólo adopta ESPN cuando el resolver es EXACT/FUZZY_UNIQUE; el resto queda
-- needs_review=true (nunca se sobreescribe con un id inventado).
-- update parlays p set picks_data = v2.fn_parlay_identidad_propuesta(p.id), updated_at=now()
-- where exists (select 1 from jsonb_array_elements(p.picks_data) l where (l->>'espn_event_id') like 'af\_%');

-- ── 5) FIX PERMANENTE (deploy): canonizar_legs_parlay() debe usar el resolver
-- FUERTE como fallback (equipos+fecha) cuando el id siga en 'af_' tras el registro,
-- y escribir canonical_event_id por pata. Y el SCANNER (BLOQUE 7) debe resolver
-- ESPN-first en el ingest para que ninguna pata nazca con 'af_'.
-- El FRONTEND (Remix, ChatGPT) agrupa las patas por canonical_event_id — no por el
-- string 'partido' (que trae dos formatos: "Napoli vs Arsenal" vs "SSC Nápoles - Arsenal FC").
