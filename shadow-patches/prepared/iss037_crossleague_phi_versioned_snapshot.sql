-- ============================================================================
-- iss037 — CROSS-LEAGUE φ VERSIONADO PARA REPLAY (§65) · STAGED, NO APLICAR
-- v3: snapshot append-only + SELLADO ATÓMICO DEL SET COMPLETO.
-- Corrige AUDIT_NO_PASS 5607948324 / 5608359234 / 5608706564.
-- ============================================================================
-- PROBLEMA original:
--   v2.liga_fuerza guarda UN set φ vivo; un replay histórico podía leer el φ de hoy.
--
-- DEFECTOS ya detectados/corregidos:
--   v1: PK (model_version, liga_id) + DO UPDATE -> sobrescribía historia.
--   v2: PK incluye cutoff y no sobrescribe filas, PERO un snapshot parcial podía
--       completarse después del primer seal; active_cutoff aceptaba cualquier cutoff
--       con >=1 fila. Eso permitía que el SET de ligas mutara tras el sellado.
--
-- FIX v3 (staged):
--   1) Filas φ append-only por (model_version, cutoff, liga_id).
--   2) MANIFEST/SEAL separado por (model_version, cutoff), con league_count + hash.
--   3) Writer serializado por advisory xact lock; un cutoff sólo puede sellarse una vez.
--   4) Si existen filas huérfanas/parciales antes del primer seal -> FAIL, no las completa.
--   5) Re-seal idéntico -> no-op. Re-seal con set/config distinto -> FAIL.
--   6) active_cutoff sólo considera manifests SEALED cuyo set físico sigue íntegro.
--   7) phi_asof exige mismo cutoff + mismo config_hash del manifest sellado.
--
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- 1) Filas versionadas APPEND-ONLY. El cutoff es parte de la identidad.
create table if not exists v2.liga_fuerza_version (
  phi_model_version   text        not null,
  phi_training_cutoff timestamptz not null,
  liga_id             integer     not null,
  liga_nombre         text,
  phi                 numeric     not null,
  n_cruzados          integer     not null,
  servible            boolean     not null default false,
  ridge               numeric,
  ref_liga_id         integer,
  phi_config_hash     text        not null,
  fit_at              timestamptz not null default now(),
  primary key (phi_model_version, phi_training_cutoff, liga_id)
);

-- 2) Manifest atómico: autoridad de que el SET COMPLETO quedó sellado.
create table if not exists v2.liga_fuerza_snapshot_seal (
  phi_model_version   text        not null,
  phi_training_cutoff timestamptz not null,
  league_count        integer     not null check (league_count > 0),
  phi_config_hash     text        not null,
  ridge               numeric,
  ref_liga_id         integer,
  sealed_at           timestamptz not null default now(),
  status              text        not null default 'SEALED' check (status = 'SEALED'),
  primary key (phi_model_version, phi_training_cutoff)
);

-- 3) Writer: sella TODO el set actual de v2.liga_fuerza en una sola transacción.
-- Reglas:
--   - advisory xact lock por model_version+cutoff evita carreras concurrentes;
--   - si ya existe manifest, sólo acepta reintento byte-equivalente (hash/count/config);
--   - si NO existe manifest pero ya hay cualquier child row para esa clave, FAIL:
--     no "completa" snapshots parciales/huérfanos;
--   - inserta todas las filas y DESPUÉS el manifest dentro de la misma transacción;
--     un error revierte todo.
create or replace function v2.fn_seal_liga_fuerza_snapshot(
  p_model_version text,
  p_cutoff timestamptz,
  p_ridge numeric default 10.0,
  p_ref_liga_id int default 39
) returns integer
language plpgsql
as $$
declare
  v_n              integer;
  v_existing_rows  integer;
  v_expected_count integer;
  v_hash           text;
  v_seal           v2.liga_fuerza_snapshot_seal%rowtype;
begin
  if p_model_version is null or btrim(p_model_version) = '' or p_cutoff is null then
    raise exception 'SNAPSHOT_INVALID_ARGUMENT';
  end if;

  -- Serializa el mismo snapshot lógico dentro de la transacción actual.
  perform pg_advisory_xact_lock(hashtextextended(p_model_version || '|' || p_cutoff::text, 0));

  select
    count(*)::int,
    md5(coalesce(string_agg(
      liga_id::text || ':' || coalesce(liga_nombre,'') || ':' || phi::text || ':' ||
      n_cruzados::text || ':' || servible::text,
      ',' order by liga_id
    ),''))
  into v_expected_count, v_hash
  from v2.liga_fuerza;

  if v_expected_count <= 0 then
    raise exception 'SNAPSHOT_EMPTY_SOURCE: v2.liga_fuerza no tiene filas';
  end if;

  -- Si ya fue sellado, sólo permitimos reintento idéntico y verificamos que el child
  -- set físico siga exactamente igual al manifest.
  select * into v_seal
  from v2.liga_fuerza_snapshot_seal
  where phi_model_version = p_model_version
    and phi_training_cutoff = p_cutoff
  for update;

  if found then
    if v_seal.league_count is distinct from v_expected_count
       or v_seal.phi_config_hash is distinct from v_hash
       or v_seal.ridge is distinct from p_ridge
       or v_seal.ref_liga_id is distinct from p_ref_liga_id then
      raise exception 'SNAPSHOT_INTEGRITY: snapshot (%,%) ya sellado con set/config distinto',
        p_model_version, p_cutoff;
    end if;

    if not v2.fn_crossleague_snapshot_integrity(p_model_version, p_cutoff) then
      raise exception 'SNAPSHOT_INTEGRITY: child set físico no coincide con manifest sellado (%,%)',
        p_model_version, p_cutoff;
    end if;

    return 0;
  end if;

  -- Si aún NO hay manifest, cualquier child row preexistente es evidencia de snapshot
  -- parcial/huérfano. Nunca lo completamos silenciosamente.
  select count(*)::int into v_existing_rows
  from v2.liga_fuerza_version
  where phi_model_version = p_model_version
    and phi_training_cutoff = p_cutoff;

  if v_existing_rows <> 0 then
    raise exception 'SNAPSHOT_PARTIAL_EXISTING: hay % child rows sin manifest para (%,%); abortado',
      v_existing_rows, p_model_version, p_cutoff;
  end if;

  insert into v2.liga_fuerza_version
    (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados,
     servible, ridge, ref_liga_id, phi_config_hash)
  select
    p_model_version, p_cutoff, liga_id, liga_nombre, phi, n_cruzados,
    servible, p_ridge, p_ref_liga_id, v_hash
  from v2.liga_fuerza;
  get diagnostics v_n = row_count;

  if v_n <> v_expected_count then
    raise exception 'SNAPSHOT_ATOMICITY: esperaba insertar % filas y se insertaron %',
      v_expected_count, v_n;
  end if;

  insert into v2.liga_fuerza_snapshot_seal
    (phi_model_version, phi_training_cutoff, league_count, phi_config_hash, ridge, ref_liga_id)
  values
    (p_model_version, p_cutoff, v_expected_count, v_hash, p_ridge, p_ref_liga_id);

  return v_n;
end $$;

-- 4) Validador del SET físico contra su manifest. SECURITY/REPLAY fail-closed:
--    - exactamente league_count filas para esa clave;
--    - todas comparten el hash sellado;
--    - cero filas extra con hash distinto.
create or replace function v2.fn_crossleague_snapshot_integrity(
  p_model_version text,
  p_cutoff timestamptz
) returns boolean
language sql stable
as $$
  select coalesce((
    select
      s.status = 'SEALED'
      and (select count(*) from v2.liga_fuerza_version v
           where v.phi_model_version=s.phi_model_version
             and v.phi_training_cutoff=s.phi_training_cutoff) = s.league_count
      and not exists (
        select 1 from v2.liga_fuerza_version v
        where v.phi_model_version=s.phi_model_version
          and v.phi_training_cutoff=s.phi_training_cutoff
          and v.phi_config_hash is distinct from s.phi_config_hash
      )
    from v2.liga_fuerza_snapshot_seal s
    where s.phi_model_version=p_model_version
      and s.phi_training_cutoff=p_cutoff
  ), false);
$$;

-- Nota de orden DDL: fn_seal referencia fn_crossleague_snapshot_integrity. PostgreSQL
-- resuelve la función al ejecutar el body PL/pgSQL, no al crearla; el helper queda creado
-- antes de cualquier llamada de seal en este artefacto.

-- 5) Cutoff activo: SÓLO manifests sellados e íntegros, nunca ">=1 child row".
create or replace function v2.fn_crossleague_active_cutoff(
  p_decision_time timestamptz,
  p_model_version text default 'crossleague_v1'
) returns timestamptz
language sql stable
as $$
  select max(s.phi_training_cutoff)
  from v2.liga_fuerza_snapshot_seal s
  where s.phi_model_version = p_model_version
    and s.phi_training_cutoff <= p_decision_time
    and s.status = 'SEALED'
    and v2.fn_crossleague_snapshot_integrity(s.phi_model_version, s.phi_training_cutoff);
$$;

-- 6) φ AS-OF anclado al ÚNICO cutoff activo y al hash exacto del manifest.
create or replace function v2.fn_crossleague_phi_asof(
  p_liga_id integer,
  p_decision_time timestamptz,
  p_model_version text default 'crossleague_v1'
) returns table(
  phi numeric,
  servible boolean,
  phi_model_version text,
  phi_training_cutoff timestamptz,
  phi_config_hash text
)
language sql stable
as $$
  with active as (
    select v2.fn_crossleague_active_cutoff(p_decision_time, p_model_version) as cutoff
  )
  select v.phi, v.servible, v.phi_model_version, v.phi_training_cutoff, v.phi_config_hash
  from active a
  join v2.liga_fuerza_snapshot_seal s
    on s.phi_model_version = p_model_version
   and s.phi_training_cutoff = a.cutoff
   and s.status = 'SEALED'
  join v2.liga_fuerza_version v
    on v.phi_model_version = s.phi_model_version
   and v.phi_training_cutoff = s.phi_training_cutoff
   and v.phi_config_hash = s.phi_config_hash
   and v.liga_id = p_liga_id
  where a.cutoff is not null
    and v2.fn_crossleague_snapshot_integrity(s.phi_model_version, s.phi_training_cutoff)
  limit 1;
$$;

-- 7) Backfill/cutover contract.
-- IMPORTANTE: NO usar una fecha aproximada para sellar el fit real. El cutoff debe venir
-- del artefacto/metadata reproducible del entrenamiento. Por eso v3 ELIMINA el seed
-- hardcodeado 2026-09-08 que existía en v2. El runbook de cutover deberá pasar el cutoff
-- exacto demostrado por el fit, o fail-close.
--
-- fn_crossleague_p_reto en cutover deberá:
--   - recibir decision_time;
--   - resolver cutoff una vez con fn_crossleague_active_cutoff;
--   - leer TODAS las φ con fn_crossleague_phi_asof;
--   - si cutoff=NULL o integrity=false -> no publicar P cross-league.
--
-- CROSS_LEAGUE_REPLAY_GATE: STAGED_ONLY hasta ejecutar este DDL+tests en branch aislada.
