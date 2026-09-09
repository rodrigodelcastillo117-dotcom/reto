-- ============================================================================
-- iss037 — CROSS-LEAGUE φ VERSIONADO PARA REPLAY (§65) · STAGED, NO APLICAR
-- v2: corrige AUDIT_NO_PASS 5607948324 / 5608359234 (append-only real + replay).
-- ============================================================================
-- PROBLEMA original (CROSS_LEAGUE_REPLAY_GATE=FAIL): `v2.liga_fuerza` guarda UN set φ
-- actual (TRUNCATE en cada re-fit), sin `phi_training_cutoff`, y `fn_crossleague_p_reto`
-- lee la tabla VIVA → replay histórico aplicaría el φ de HOY (fuga).
--
-- DEFECTO de la v1 de este archivo (detectado por auditoría): la tabla de snapshots
-- tenía PK (phi_model_version, liga_id) + ON CONFLICT DO UPDATE. Con eso un re-fit del
-- MISMO model_version con cutoff posterior SOBRESCRIBÍA el snapshot histórico → NO era
-- append-only y el replay entre re-fits perdía la φ de época. CORREGIDO abajo.
--
-- FIX v2 (staged):
--  1) Identidad del snapshot INCLUYE el cutoff: PK (phi_model_version, phi_training_cutoff,
--     liga_id). Varios cutoffs del mismo model_version COEXISTEN.
--  2) Writer NUNCA sobrescribe historia: ON CONFLICT DO NOTHING + guarda de integridad
--     que FALLA si en la misma clave ya hay un φ distinto (no reescribe, aborta).
--  3) Resolución por UN solo snapshot: se elige el cutoff aplicable (max<=decision) UNA
--     vez y TODAS las ligas del replay resuelven a ESE mismo (model_version, cutoff),
--     nunca cutoffs mezclados por liga.
--  4) Persiste fit_at, phi_training_cutoff, ridge, ref_liga_id (+ hash opcional).
--  5) Fail-close si no existía versión con cutoff<=decision.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- 1) Snapshot versionado APPEND-ONLY. El cutoff es parte de la identidad.
create table if not exists v2.liga_fuerza_version (
  phi_model_version   text        not null,
  phi_training_cutoff timestamptz not null,   -- datos usados: kickoff < cutoff (parte de PK)
  liga_id             integer     not null,
  liga_nombre         text,
  phi                 numeric     not null,
  n_cruzados          integer     not null,
  servible            boolean     not null default false,
  ridge               numeric,
  ref_liga_id         integer,
  phi_config_hash     text,                    -- hash del set del fit (integridad/replay)
  fit_at              timestamptz not null default now(),
  primary key (phi_model_version, phi_training_cutoff, liga_id)
);

-- 2) Writer append-only con guarda de integridad. Sella el estado ACTUAL de
--    v2.liga_fuerza como snapshot inmutable a (p_model_version, p_cutoff).
--    - Si ya existe la clave con φ IDÉNTICO -> no-op (idempotente).
--    - Si ya existe con φ DISTINTO -> RAISE (no reescribe historia).
create or replace function v2.fn_seal_liga_fuerza_snapshot(
  p_model_version text, p_cutoff timestamptz, p_ridge numeric default 10.0, p_ref_liga_id int default 39
) returns integer language plpgsql as $$
declare v_n int; v_conflict int; v_hash text;
begin
  -- integridad: ¿alguna liga ya sellada en esta clave con φ distinto al actual?
  select count(*) into v_conflict
  from v2.liga_fuerza lf
  join v2.liga_fuerza_version v
    on v.phi_model_version=p_model_version and v.phi_training_cutoff=p_cutoff and v.liga_id=lf.liga_id
  where v.phi is distinct from lf.phi;
  if v_conflict > 0 then
    raise exception 'SNAPSHOT_INTEGRITY: % filas ya selladas en (%,%) con phi distinto; no se reescribe historia',
      v_conflict, p_model_version, p_cutoff;
  end if;

  v_hash := md5(coalesce(string_agg(liga_id||':'||phi, ',' order by liga_id),'')) from v2.liga_fuerza;

  insert into v2.liga_fuerza_version
    (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible,
     ridge, ref_liga_id, phi_config_hash)
  select p_model_version, p_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible,
     p_ridge, p_ref_liga_id, v_hash
  from v2.liga_fuerza
  on conflict (phi_model_version, phi_training_cutoff, liga_id) do nothing;  -- NUNCA overwrite
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Sella el fit v1 ACTUAL con su cutoff de entrenamiento honesto (~backfill 2026-09-08).
select v2.fn_seal_liga_fuerza_snapshot('crossleague_v1', timestamptz '2026-09-08 00:00:00+00', 10.0, 39);

-- 3a) Cutoff aplicable para un replay: el más reciente <= decision para ese model_version.
--     UNA sola resolución para todo el replay (no por liga) → sin cutoffs mezclados.
create or replace function v2.fn_crossleague_active_cutoff(
  p_decision_time timestamptz, p_model_version text default 'crossleague_v1'
) returns timestamptz language sql stable as $$
  select max(phi_training_cutoff)
  from v2.liga_fuerza_version
  where phi_model_version = p_model_version and phi_training_cutoff <= p_decision_time;
$$;

-- 3b) φ AS-OF de UNA liga, anclado al cutoff activo del replay (mismo snapshot p/ todas).
--     Fail-close (0 filas) si no existía versión con cutoff<=decision.
create or replace function v2.fn_crossleague_phi_asof(
  p_liga_id integer, p_decision_time timestamptz, p_model_version text default 'crossleague_v1'
) returns table(phi numeric, servible boolean, phi_model_version text,
                phi_training_cutoff timestamptz, phi_config_hash text)
language sql stable as $$
  select v.phi, v.servible, v.phi_model_version, v.phi_training_cutoff, v.phi_config_hash
  from v2.liga_fuerza_version v
  where v.liga_id = p_liga_id
    and v.phi_model_version = p_model_version
    and v.phi_training_cutoff = v2.fn_crossleague_active_cutoff(p_decision_time, p_model_version)
  limit 1;
$$;

-- 4) CONTRATO para fn_crossleague_p_reto (§45/§65) en cutover:
--    - recibir decision_time; resolver cutoff UNA vez con fn_crossleague_active_cutoff;
--    - leer φ de cada liga con fn_crossleague_phi_asof (mismo cutoff);
--    - si el cutoff es NULL (no existía versión) → fail-close (no φ del futuro).
--    Con la PK que incluye el cutoff + DO NOTHING + guarda de integridad, la historia φ
--    es append-only: un re-fit posterior crea una fila nueva (cutoff nuevo) y NUNCA
--    sobrescribe la de época. CROSS_LEAGUE_REPLAY_GATE: FAIL → STAGED_ONLY.
