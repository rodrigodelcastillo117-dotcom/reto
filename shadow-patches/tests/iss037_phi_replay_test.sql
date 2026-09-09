-- ============================================================================
-- iss037 TEST — replay φ versionado append-only (§65; AUDIT 5607948324/5608359234)
-- tx ROLLBACK. Requiere iss037 v2 cargado. Branch-only (no prod bajo freeze).
-- Prueba: dos cutoffs (T1<T2) para el MISMO model_version+liga coexisten; el replay
-- resuelve EXACTAMENTE la φ de época; antes de T1 fail-close; T1 sigue presente tras T2.
-- Usa model_version sintético 'test_v' y liga_id 999999 (no toca datos reales).
-- ============================================================================
begin;
-- dos snapshots del MISMO model_version+liga con cutoffs distintos
insert into v2.liga_fuerza_version
  (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible, ridge, ref_liga_id, phi_config_hash)
values
  ('test_v', timestamptz '2026-01-01', 999999, 'T', 0.1000, 50, true, 10, 39, 'hashA'),
  ('test_v', timestamptz '2026-06-01', 999999, 'T', 0.2000, 60, true, 10, 39, 'hashB');

do $$
declare a numeric; b numeric; c record; n int;
begin
  -- ambos snapshots físicamente presentes
  select count(*) into n from v2.liga_fuerza_version where phi_model_version='test_v' and liga_id=999999;
  if n <> 2 then raise exception 'FAIL: esperaba 2 snapshots coexistiendo, hay %', n; end if;

  -- decision ENTRE T1 y T2 -> phi de época T1 (0.1000)
  select phi into a from v2.fn_crossleague_phi_asof(999999, timestamptz '2026-03-15','test_v');
  if a is distinct from 0.1000 then raise exception 'FAIL replay(entre T1,T2): esperaba 0.1000, dio %', a; end if;

  -- decision DESPUES de T2 -> phi nueva T2 (0.2000)
  select phi into b from v2.fn_crossleague_phi_asof(999999, timestamptz '2026-09-01','test_v');
  if b is distinct from 0.2000 then raise exception 'FAIL replay(post T2): esperaba 0.2000, dio %', b; end if;

  -- decision ANTES de T1 -> fail-close (0 filas)
  if exists(select 1 from v2.fn_crossleague_phi_asof(999999, timestamptz '2025-06-01','test_v')) then
    raise exception 'FAIL: replay anterior a T1 deberia fail-close (0 filas)';
  end if;

  -- append-only: intentar reescribir T1 con phi distinto NO cambia la historia
  insert into v2.liga_fuerza_version
    (phi_model_version, phi_training_cutoff, liga_id, liga_nombre, phi, n_cruzados, servible)
  values ('test_v', timestamptz '2026-01-01', 999999, 'T', 0.9999, 99, true)
  on conflict (phi_model_version, phi_training_cutoff, liga_id) do nothing;
  select phi into a from v2.liga_fuerza_version
    where phi_model_version='test_v' and liga_id=999999 and phi_training_cutoff='2026-01-01';
  if a is distinct from 0.1000 then raise exception 'FAIL append-only: T1 fue sobrescrito a %', a; end if;

  raise notice 'PASS iss037: replay φ as-of correcto (T1/T2/fail-close) + append-only preservado';
end $$;
rollback;
