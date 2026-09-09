-- ============================================================================
-- iss037 TEST v3 — atomic sealed snapshot + historical replay (§65)
-- tx ROLLBACK. Requires iss037 v3 loaded on isolated branch. NEVER prod under freeze.
-- ============================================================================
begin;

-- --------------------------------------------------------------------------
-- A) Resolver histórico sobre DOS manifests sintéticos completos.
--    Dos ligas por snapshot; T1 y T2 deben coexistir y resolver por época.
-- --------------------------------------------------------------------------
insert into v2.liga_fuerza_snapshot_seal
  (phi_model_version, phi_training_cutoff, league_count, phi_config_hash, ridge, ref_liga_id)
values
  ('test_replay_v3', timestamptz '2026-01-01', 2, 'hashT1', 10, 39),
  ('test_replay_v3', timestamptz '2026-06-01', 2, 'hashT2', 10, 39);

insert into v2.liga_fuerza_version
  (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados,
   servible, ridge, ref_liga_id, phi_config_hash)
values
  ('test_replay_v3', timestamptz '2026-01-01', 999991, 'T-A', 0.1000, 50, true, 10, 39, 'hashT1'),
  ('test_replay_v3', timestamptz '2026-01-01', 999992, 'T-B',-0.1000, 50, true, 10, 39, 'hashT1'),
  ('test_replay_v3', timestamptz '2026-06-01', 999991, 'T-A', 0.2000, 60, true, 10, 39, 'hashT2'),
  ('test_replay_v3', timestamptz '2026-06-01', 999992, 'T-B',-0.2000, 60, true, 10, 39, 'hashT2');

do $$
declare a numeric; b numeric; n int;
begin
  if not v2.fn_crossleague_snapshot_integrity('test_replay_v3', timestamptz '2026-01-01') then
    raise exception 'FAIL A1: T1 debería estar íntegro';
  end if;
  if not v2.fn_crossleague_snapshot_integrity('test_replay_v3', timestamptz '2026-06-01') then
    raise exception 'FAIL A2: T2 debería estar íntegro';
  end if;

  select phi into a
  from v2.fn_crossleague_phi_asof(999991, timestamptz '2026-03-15', 'test_replay_v3');
  if a is distinct from 0.1000 then
    raise exception 'FAIL A3 replay entre T1/T2: esperaba 0.1000, dio %', a;
  end if;

  select phi into b
  from v2.fn_crossleague_phi_asof(999991, timestamptz '2026-09-01', 'test_replay_v3');
  if b is distinct from 0.2000 then
    raise exception 'FAIL A4 replay post T2: esperaba 0.2000, dio %', b;
  end if;

  if exists(select 1 from v2.fn_crossleague_phi_asof(999991, timestamptz '2025-06-01', 'test_replay_v3')) then
    raise exception 'FAIL A5: antes de T1 debería fail-close';
  end if;

  select count(*) into n
  from v2.liga_fuerza_version
  where phi_model_version='test_replay_v3' and liga_id=999991;
  if n <> 2 then raise exception 'FAIL A6: T1/T2 no coexisten; count=%', n; end if;
end $$;

-- --------------------------------------------------------------------------
-- B) ADVERSARIAL: mutar el SET después de sellado invalida el snapshot completo.
--    Añadimos una liga extra a T1. active_cutoff NO puede usar T1 ya.
-- --------------------------------------------------------------------------
insert into v2.liga_fuerza_version
  (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados,
   servible, ridge, ref_liga_id, phi_config_hash)
values
  ('test_replay_v3', timestamptz '2026-01-01', 999993, 'T-C', 0.3333, 1, true, 10, 39, 'hashT1');

do $$
begin
  if v2.fn_crossleague_snapshot_integrity('test_replay_v3', timestamptz '2026-01-01') then
    raise exception 'FAIL B1: T1 mutado no debe seguir íntegro';
  end if;
  if v2.fn_crossleague_active_cutoff(timestamptz '2026-03-15','test_replay_v3') is not null then
    raise exception 'FAIL B2: cutoff mutado debería fail-close';
  end if;
  if exists(select 1 from v2.fn_crossleague_phi_asof(999991, timestamptz '2026-03-15','test_replay_v3')) then
    raise exception 'FAIL B3: resolver no debe devolver phi desde snapshot mutado';
  end if;
end $$;

-- --------------------------------------------------------------------------
-- C) ADVERSARIAL: child rows huérfanos ANTES del primer seal no pueden completarse.
--    Usa el writer real; esperamos SNAPSHOT_PARTIAL_EXISTING.
-- --------------------------------------------------------------------------
insert into v2.liga_fuerza_version
  (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados,
   servible, ridge, ref_liga_id, phi_config_hash)
values
  ('test_partial_v3', timestamptz '2026-07-01', 999994, 'ORPHAN', 0.5, 1, true, 10, 39, 'orphan');

do $$
begin
  begin
    perform v2.fn_seal_liga_fuerza_snapshot('test_partial_v3', timestamptz '2026-07-01', 10, 39);
    raise exception 'FAIL C1: writer aceptó/completó child set parcial';
  exception
    when others then
      if position('SNAPSHOT_PARTIAL_EXISTING' in sqlerrm) = 0 then
        raise;
      end if;
  end;

  if exists(
    select 1 from v2.liga_fuerza_snapshot_seal
    where phi_model_version='test_partial_v3' and phi_training_cutoff=timestamptz '2026-07-01'
  ) then
    raise exception 'FAIL C2: se creó manifest para snapshot parcial';
  end if;
end $$;

-- --------------------------------------------------------------------------
-- D) Writer real: seal inicial del set actual + re-seal idéntico = idempotente.
--    No modifica v2.liga_fuerza; todo lo nuevo queda dentro de esta tx y rollback.
-- --------------------------------------------------------------------------
do $$
declare n1 int; n2 int; c int;
begin
  select count(*)::int into c from v2.liga_fuerza;
  if c <= 0 then raise exception 'FAIL D0: fixture source v2.liga_fuerza está vacío'; end if;

  n1 := v2.fn_seal_liga_fuerza_snapshot('test_writer_v3', timestamptz '2026-08-01', 10, 39);
  if n1 <> c then raise exception 'FAIL D1: seal insertó %, esperaba %', n1, c; end if;
  if not v2.fn_crossleague_snapshot_integrity('test_writer_v3', timestamptz '2026-08-01') then
    raise exception 'FAIL D2: snapshot recién sellado no está íntegro';
  end if;

  n2 := v2.fn_seal_liga_fuerza_snapshot('test_writer_v3', timestamptz '2026-08-01', 10, 39);
  if n2 <> 0 then raise exception 'FAIL D3: re-seal idéntico debe ser no-op, dio %', n2; end if;
end $$;

-- --------------------------------------------------------------------------
-- E) Manifest no basta si se inyecta fila con HASH DISTINTO aun conservando count-ish.
--    Integrity debe fallar tanto por count como por hash mismatch.
-- --------------------------------------------------------------------------
insert into v2.liga_fuerza_snapshot_seal
  (phi_model_version, phi_training_cutoff, league_count, phi_config_hash, ridge, ref_liga_id)
values ('test_hash_v3', timestamptz '2026-02-01', 1, 'sealedHash', 10, 39);
insert into v2.liga_fuerza_version
  (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados,
   servible, ridge, ref_liga_id, phi_config_hash)
values ('test_hash_v3', timestamptz '2026-02-01', 999995, 'X', 0.1, 1, true, 10, 39, 'wrongHash');

do $$
begin
  if v2.fn_crossleague_snapshot_integrity('test_hash_v3', timestamptz '2026-02-01') then
    raise exception 'FAIL E1: hash distinto no fue detectado';
  end if;
  if v2.fn_crossleague_active_cutoff(timestamptz '2026-03-01','test_hash_v3') is not null then
    raise exception 'FAIL E2: snapshot hash-corrupto no debe activarse';
  end if;
end $$;

raise notice 'PASS iss037 v3: replay AS-OF + manifest atómico + partial-set fail-close + tamper fail-close + writer idempotente';
rollback;
