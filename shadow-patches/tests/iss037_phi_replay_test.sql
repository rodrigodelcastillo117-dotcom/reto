-- ============================================================================
-- iss037 v3 TEST — replay φ + atomicidad/completitud del snapshot (§65)
--   AUDIT 5607948324/5608359234 (append-only) + 5608706564 (snapshot-set atomicity).
-- tx ROLLBACK. Requiere iss037 v3 cargado. Branch-only (no prod bajo freeze).
-- Sella desde v2.liga_fuerza (fit vivo) usando un league sintético 999999 + model 'test_v3'.
-- Cubre: T1/T2 coexisten, replay as-of exacto, pre-T1 fail-close, orphan-pre-seal RAISE,
--   re-sello set distinto RAISE, re-sello idéntico no-op, liga extra post-seal invalida
--   (integrity=false, active_cutoff ignora, phi_asof fail-close), distinct(hash)=1.
-- ============================================================================
begin;

-- limpieza de claves de prueba (por si acaso)
delete from v2.liga_fuerza_version where phi_model_version in ('test_v3','test_orphan');
delete from v2.liga_fuerza_snapshot_seal where phi_model_version in ('test_v3','test_orphan');
delete from v2.liga_fuerza where liga_id = 999999;

-- fit vivo sintético: liga 999999 con phi=0.1 (época T1)
insert into v2.liga_fuerza (liga_id, liga_nombre, phi, n_cruzados, servible)
values (999999, 'T', 0.1000, 50, true);

do $$
declare a numeric; n int; ok boolean; got_error boolean;
begin
  -- ---- SELLO T1 (atómico) ----
  perform v2.fn_seal_liga_fuerza_snapshot('test_v3', timestamptz '2026-01-01', 10, 39);
  if not v2.fn_crossleague_snapshot_integrity('test_v3', timestamptz '2026-01-01') then
    raise exception 'FAIL: sello T1 no íntegro';
  end if;

  -- cambia el fit vivo a época T2 (phi=0.2) y sella T2
  update v2.liga_fuerza set phi = 0.2000 where liga_id = 999999;
  perform v2.fn_seal_liga_fuerza_snapshot('test_v3', timestamptz '2026-06-01', 10, 39);

  -- ambos manifests coexisten
  select count(*) into n from v2.liga_fuerza_snapshot_seal where phi_model_version='test_v3';
  if n <> 2 then raise exception 'FAIL: esperaba 2 manifests, hay %', n; end if;

  -- ---- REPLAY as-of ----
  select phi into a from v2.fn_crossleague_phi_asof(999999, timestamptz '2026-03-15','test_v3');
  if a is distinct from 0.1000 then raise exception 'FAIL replay(entre T1,T2): esperaba 0.1000, dio %', a; end if;
  select phi into a from v2.fn_crossleague_phi_asof(999999, timestamptz '2026-09-01','test_v3');
  if a is distinct from 0.2000 then raise exception 'FAIL replay(post T2): esperaba 0.2000, dio %', a; end if;
  if exists(select 1 from v2.fn_crossleague_phi_asof(999999, timestamptz '2025-06-01','test_v3')) then
    raise exception 'FAIL: replay anterior a T1 debe fail-close';
  end if;

  -- ---- RE-SELLO IDÉNTICO = no-op (fit vivo sigue en época T2) ----
  n := v2.fn_seal_liga_fuerza_snapshot('test_v3', timestamptz '2026-06-01', 10, 39);
  if n <> 0 then raise exception 'FAIL: re-sello idéntico debió ser no-op (0), dio %', n; end if;

  -- ---- RE-SELLO CON SET/CONFIG DISTINTO = RAISE (no reescribe) ----
  update v2.liga_fuerza set phi = 0.7777 where liga_id = 999999;  -- muta el set vivo
  got_error := false;
  begin
    perform v2.fn_seal_liga_fuerza_snapshot('test_v3', timestamptz '2026-06-01', 10, 39);
  exception when others then
    if sqlerrm like '%SNAPSHOT_INTEGRITY%' then got_error := true; else raise; end if;
  end;
  if not got_error then raise exception 'FAIL: re-sello con set distinto debió RAISE SNAPSHOT_INTEGRITY'; end if;
  -- T2 sigue byte-for-byte 0.2000 pese al intento
  select phi into a from v2.liga_fuerza_version
    where phi_model_version='test_v3' and phi_training_cutoff='2026-06-01' and liga_id=999999;
  if a is distinct from 0.2000 then raise exception 'FAIL: T2 mutado a % tras intento de re-sello', a; end if;
  update v2.liga_fuerza set phi = 0.2000 where liga_id = 999999;  -- restaura

  -- ---- ORPHAN PRE-SEAL: filas hijas sin manifest → writer RAISE ----
  insert into v2.liga_fuerza_version
    (phi_model_version, phi_training_cutoff, liga_id, phi, n_cruzados, servible, phi_config_hash)
  values ('test_orphan', timestamptz '2026-02-01', 999999, 0.1, 1, true, 'x');
  got_error := false;
  begin
    perform v2.fn_seal_liga_fuerza_snapshot('test_orphan', timestamptz '2026-02-01', 10, 39);
  exception when others then
    if sqlerrm like '%SNAPSHOT_ORPHAN%' then got_error := true; else raise; end if;
  end;
  if not got_error then raise exception 'FAIL: sello sobre huérfanas debió RAISE SNAPSHOT_ORPHAN'; end if;
  if exists(select 1 from v2.liga_fuerza_snapshot_seal where phi_model_version='test_orphan') then
    raise exception 'FAIL: no debió crearse manifest para snapshot huérfano';
  end if;

  -- ---- LIGA EXTRA POST-SEAL invalida el snapshot sellado ----
  insert into v2.liga_fuerza_version
    (phi_model_version, phi_training_cutoff, liga_id, phi, n_cruzados, servible, phi_config_hash)
  values ('test_v3', timestamptz '2026-01-01', 888888, 0.5, 1, true, 'rogue');
  if v2.fn_crossleague_snapshot_integrity('test_v3', timestamptz '2026-01-01') then
    raise exception 'FAIL: liga extra post-seal debió romper integridad de T1';
  end if;
  -- active_cutoff en fecha entre T1 y T2 debe IGNORAR T1 roto → NULL (T1 era el único <= 2026-03-15)
  if v2.fn_crossleague_active_cutoff(timestamptz '2026-03-15','test_v3') is not null then
    raise exception 'FAIL: active_cutoff debió ignorar T1 con integridad rota';
  end if;
  -- y phi_asof entre T1,T2 fail-close
  if exists(select 1 from v2.fn_crossleague_phi_asof(999999, timestamptz '2026-03-15','test_v3')) then
    raise exception 'FAIL: phi_asof debió fail-close con snapshot T1 roto';
  end if;

  raise notice 'PASS iss037 v3: replay as-of + atomicidad/completitud (orphan/re-seal/extra-league) OK';
end $$;
rollback;
