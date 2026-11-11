-- ============================================================================
-- iss037 — CROSS-LEAGUE φ VERSIONADO PARA REPLAY (§65) · STAGED, NO APLICAR
-- v3: corrige AUDIT_NO_PASS 5608706564 (snapshot-set atomicity/completeness),
--     además del previo 5607948324/5608359234 (append-only real + replay).
-- ============================================================================
-- PROBLEMA original (CROSS_LEAGUE_REPLAY_GATE=FAIL): `v2.liga_fuerza` guarda UN set φ
-- actual (TRUNCATE en cada re-fit), sin `phi_training_cutoff`, y `fn_crossleague_p_reto`
-- lee la tabla VIVA → replay histórico aplicaría el φ de HOY (fuga).
--
-- DEFECTO v1 (auditoría 5607948324): PK (phi_model_version, liga_id) + ON CONFLICT DO
-- UPDATE → un re-fit del MISMO model_version con cutoff posterior SOBRESCRIBÍA el
-- snapshot histórico. CORREGIDO en v2: cutoff en la PK + DO NOTHING.
--
-- DEFECTO v2 (auditoría 5608706564): `fn_seal_liga_fuerza_snapshot` sólo comparaba φ de
-- las ligas que YA coincidían por (model_version,cutoff,liga_id) y luego DO NOTHING. Si
-- para una clave ya existía un snapshot PARCIAL (o un set distinto de ligas), una llamada
-- posterior podía INSERTAR las ligas faltantes sin fallar → un mismo (model_version,cutoff)
-- con múltiples phi_config_hash y un SET de ligas que muta después del primer sello. No
-- había autoridad de "snapshot sellado/completo": `fn_crossleague_active_cutoff` daba por
-- activo cualquier cutoff con >=1 fila.
--
-- FIX v3 (staged):
--  1) MANIFEST inmutable `v2.liga_fuerza_snapshot_seal` con PK (phi_model_version,
--     phi_training_cutoff) que declara league_count + phi_config_hash + ridge + ref_liga_id
--     + sealed_at. Es la ÚNICA autoridad de "snapshot atómico y completo".
--  2) Writer atómico con advisory lock (mismo snapshot lógico serializado):
--     - Si NO existe manifest para la clave y YA hay filas hijas (huérfanas/parciales) →
--       RAISE (nunca completa un set parcial en silencio).
--     - Si NO existe manifest → inserta TODAS las filas hijas + el manifest en la MISMA
--       transacción (la función es una unidad atómica: cualquier RAISE hace rollback).
--     - Si YA existe manifest → exige league_count + phi_config_hash idénticos y filas
--       hijas físicamente intactas; cualquier diferencia (set mutado, hash distinto,
--       liga extra/faltante) → RAISE. Re-sello idéntico = no-op idempotente. NUNCA
--       inserta filas adicionales sobre un snapshot ya sellado.
--  3) `fn_crossleague_snapshot_integrity` verifica count de hijas == manifest.league_count
--     y un ÚNICO phi_config_hash == manifest.phi_config_hash.
--  4) `fn_crossleague_active_cutoff` considera SÓLO manifests sellados + físicamente
--     íntegros (nunca un cutoff con "al menos una fila").
--  5) `fn_crossleague_phi_asof` une contra el hash sellado del manifest y hace fail-close
--     si la integridad está rota.
--  6) Eliminado el seed hardcodeado ~2026-09-08: el cutoff real del fit debe venir de
--     metadata de entrenamiento reproducible en cutover.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- 1) Snapshot versionado APPEND-ONLY por fila (el cutoff es parte de la identidad).
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

-- 1b) MANIFEST atómico: autoridad de "snapshot sellado y completo". PK sin liga_id.
create table if not exists v2.liga_fuerza_snapshot_seal (
  phi_model_version   text        not null,
  phi_training_cutoff timestamptz not null,
  league_count        integer     not null,   -- nº de filas hijas selladas en esta clave
  phi_config_hash     text        not null,   -- hash del set COMPLETO al momento del sello
  ridge               numeric,
  ref_liga_id         integer,
  sealed_at           timestamptz not null default now(),
  primary key (phi_model_version, phi_training_cutoff)
);

-- 2) Writer atómico. Sella el estado ACTUAL de v2.liga_fuerza como snapshot inmutable a
--    (p_model_version, p_cutoff). Idempotente en re-sello idéntico; RAISE en cualquier
--    mutación de set/config o snapshot parcial preexistente.
create or replace function v2.fn_seal_liga_fuerza_snapshot(
  p_model_version text, p_cutoff timestamptz, p_ridge numeric default 10.0, p_ref_liga_id int default 39
) returns integer language plpgsql as $$
declare
  v_hash        text;
  v_count       int;
  v_child_rows  int;
  v_seal        v2.liga_fuerza_snapshot_seal;
  v_ins         int;
  v_bad         int;
begin
  -- serializa el mismo snapshot lógico (evita dos sellos concurrentes de la misma clave)
  perform pg_advisory_xact_lock(hashtextextended(p_model_version || '@' || p_cutoff::text, 0));

  -- estado ACTUAL del fit vivo (fuente del sello)
  select count(*),
         md5(coalesce(string_agg(liga_id || ':' || phi, ',' order by liga_id), ''))
    into v_count, v_hash
  from v2.liga_fuerza;

  if v_count = 0 then
    raise exception 'SNAPSHOT_EMPTY: v2.liga_fuerza no tiene filas; no hay set que sellar';
  end if;

  -- filas hijas ya presentes en esta clave (posible sello previo o huérfanas parciales)
  select count(*) into v_child_rows
  from v2.liga_fuerza_version
  where phi_model_version = p_model_version and phi_training_cutoff = p_cutoff;

  select * into v_seal
  from v2.liga_fuerza_snapshot_seal
  where phi_model_version = p_model_version and phi_training_cutoff = p_cutoff;

  if not found then
    -- NO hay manifest para la clave.
    -- (a) si YA hay filas hijas sin manifest → set parcial/huérfano: abortar, no completar.
    if v_child_rows > 0 then
      raise exception 'SNAPSHOT_ORPHAN: existen % filas hijas en (%,%) sin manifest sellado; no se completa un set parcial',
        v_child_rows, p_model_version, p_cutoff;
    end if;

    -- (b) primer sello atómico: filas hijas + manifest en la misma transacción.
    insert into v2.liga_fuerza_version
      (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible,
       ridge, ref_liga_id, phi_config_hash)
    select p_model_version, p_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible,
       p_ridge, p_ref_liga_id, v_hash
    from v2.liga_fuerza;
    get diagnostics v_ins = row_count;

    insert into v2.liga_fuerza_snapshot_seal
      (phi_model_version, phi_training_cutoff, league_count, phi_config_hash, ridge, ref_liga_id)
    values (p_model_version, p_cutoff, v_ins, v_hash, p_ridge, p_ref_liga_id);

    -- validación post-inserción: count/hash del conjunto físico == manifest.
    if not v2.fn_crossleague_snapshot_integrity(p_model_version, p_cutoff) then
      raise exception 'SNAPSHOT_INTEGRITY: sello inicial no verifica integridad físico↔manifest en (%,%)',
        p_model_version, p_cutoff;
    end if;
    return v_ins;
  else
    -- YA existe manifest: re-sello sólo válido si es EXACTAMENTE el mismo set/config.
    if v_seal.league_count <> v_count or v_seal.phi_config_hash is distinct from v_hash then
      raise exception 'SNAPSHOT_INTEGRITY: re-sello con set/config distinto en (%,%): manifest(count=%,hash=%) vs actual(count=%,hash=%); no se reescribe historia',
        p_model_version, p_cutoff, v_seal.league_count, v_seal.phi_config_hash, v_count, v_hash;
    end if;
    -- además el conjunto físico ya sellado debe estar intacto (sin ligas extra/faltantes).
    select count(*) into v_bad
    from v2.liga_fuerza_version
    where phi_model_version = p_model_version and phi_training_cutoff = p_cutoff
      and (phi_config_hash is distinct from v_seal.phi_config_hash);
    if v_bad > 0 or v_child_rows <> v_seal.league_count then
      raise exception 'SNAPSHOT_INTEGRITY: filas hijas de (%,%) no coinciden con el manifest sellado (rows=%, expected=%, bad_hash=%)',
        p_model_version, p_cutoff, v_child_rows, v_seal.league_count, v_bad;
    end if;
    return 0;  -- no-op idempotente: snapshot ya sellado e intacto
  end if;
end $$;

-- 3) Integridad: el conjunto FÍSICO de filas hijas coincide con el manifest sellado.
create or replace function v2.fn_crossleague_snapshot_integrity(
  p_model_version text, p_cutoff timestamptz
) returns boolean language sql stable as $$
  select exists (
    select 1
    from v2.liga_fuerza_snapshot_seal s
    where s.phi_model_version = p_model_version and s.phi_training_cutoff = p_cutoff
      and s.league_count = (
        select count(*) from v2.liga_fuerza_version v
        where v.phi_model_version = p_model_version and v.phi_training_cutoff = p_cutoff)
      and 1 = (
        select count(distinct v.phi_config_hash) from v2.liga_fuerza_version v
        where v.phi_model_version = p_model_version and v.phi_training_cutoff = p_cutoff)
      and s.phi_config_hash = (
        select max(v.phi_config_hash) from v2.liga_fuerza_version v
        where v.phi_model_version = p_model_version and v.phi_training_cutoff = p_cutoff)
  );
$$;

-- 3a) Cutoff aplicable para un replay: el más reciente <= decision para ese model_version,
--     SÓLO entre manifests sellados y físicamente íntegros. UNA sola resolución para todo
--     el replay (no por liga) → sin cutoffs mezclados; ignora snapshots parciales/huérfanos.
create or replace function v2.fn_crossleague_active_cutoff(
  p_decision_time timestamptz, p_model_version text default 'crossleague_v1'
) returns timestamptz language sql stable as $$
  select max(s.phi_training_cutoff)
  from v2.liga_fuerza_snapshot_seal s
  where s.phi_model_version = p_model_version
    and s.phi_training_cutoff <= p_decision_time
    and v2.fn_crossleague_snapshot_integrity(s.phi_model_version, s.phi_training_cutoff);
$$;

-- 3b) φ AS-OF de UNA liga, anclada al cutoff activo del replay (mismo snapshot p/ todas),
--     unida contra el hash sellado del manifest. Fail-close (0 filas) si no había versión
--     con cutoff<=decision o si la integridad del snapshot está rota.
create or replace function v2.fn_crossleague_phi_asof(
  p_liga_id integer, p_decision_time timestamptz, p_model_version text default 'crossleague_v1'
) returns table(phi numeric, servible boolean, phi_model_version text,
                phi_training_cutoff timestamptz, phi_config_hash text)
language sql stable as $$
  select v.phi, v.servible, v.phi_model_version, v.phi_training_cutoff, v.phi_config_hash
  from v2.liga_fuerza_version v
  join v2.liga_fuerza_snapshot_seal s
    on s.phi_model_version = v.phi_model_version
   and s.phi_training_cutoff = v.phi_training_cutoff
   and s.phi_config_hash = v.phi_config_hash          -- hash sellado == hash de la fila
  where v.liga_id = p_liga_id
    and v.phi_model_version = p_model_version
    and v.phi_training_cutoff = v2.fn_crossleague_active_cutoff(p_decision_time, p_model_version)
  limit 1;
$$;

-- 4) CONTRATO para fn_crossleague_p_reto (§45/§65) en cutover:
--    - recibir decision_time; resolver cutoff UNA vez con fn_crossleague_active_cutoff
--      (que ya sólo ve manifests sellados e íntegros);
--    - leer φ de cada liga con fn_crossleague_phi_asof (mismo cutoff + hash sellado);
--    - si el cutoff es NULL (no existía snapshot sellado) → fail-close (no φ del futuro).
--    Con el manifest + advisory lock + validación de integridad, la historia φ es
--    append-only Y atómica: un snapshot parcial nunca se completa a posteriori, y un
--    re-fit crea SIEMPRE una clave nueva (cutoff nuevo) sin mutar la de época.
--    CROSS_LEAGUE_REPLAY_GATE: FAIL → STAGED_ONLY → (branch) BRANCH_TESTED.
