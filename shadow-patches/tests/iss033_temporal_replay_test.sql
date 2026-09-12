-- ============================================================================
-- iss033 TEST — replay + adversarial temporal (BLOQUE 5/6). Requiere iss033 cargado.
-- Corre en tx con ROLLBACK. Prueba que el feature vector AS OF decision_time:
--  (11) NO cambia si aparece un partido POSTERIOR a decision_time (adversarial).
--  (12) es reproducible: dos cómputos as-of dan el mismo vector (replay).
-- Usa Barcelona (83) en LaLiga (140) con decision histórica 2026-05-01.
-- ============================================================================
begin;
do $$
declare f1 record; f2 record; f_after record;
  v_away text; dec timestamptz := '2026-05-01';
begin
  -- un rival cualquiera con historia
  select away_espn_id into v_away from public.historico_partidos_espn
   where liga_id=140 and away_espn_id<>'83' and fecha<dec order by fecha desc limit 1;

  -- (12) replay: mismo cómputo dos veces == idéntico
  select * into f1 from v2.fn_soccer_features_asof('83', v_away, 140, dec);
  select * into f2 from v2.fn_soccer_features_asof('83', v_away, 140, dec);
  if f1.home_gf is distinct from f2.home_gf or f1.sample_home is distinct from f2.sample_home then
    raise exception 'FAIL replay: cómputo as-of no determinista';
  end if;
  raise notice 'PASS replay: as-of home_gf=% sample_home=% max_source=%', f1.home_gf, f1.sample_home, f1.max_source_event_time;

  -- (11) adversarial: el vector as-of usa SOLO fecha<decision. Insertar un partido
  -- POSTERIOR a decision NO debe cambiarlo.
  insert into public.historico_partidos_espn (espn_event_id, liga_id, fecha, home_espn_id, away_espn_id, home_score, away_score, cargado_at)
  values ('TEST_ADV_POST', 140, dec + interval '10 days', '83', v_away, 9, 0, now());
  select * into f_after from v2.fn_soccer_features_asof('83', v_away, 140, dec);
  if f_after.home_gf is distinct from f1.home_gf or f_after.sample_home is distinct from f1.sample_home then
    raise exception 'FAIL adversarial: un partido POSTERIOR a decision cambió el feature as-of (fuga temporal)';
  end if;
  raise notice 'PASS adversarial: partido post-decision (9-0) NO alteró el vector as-of (home_gf sigue %)', f_after.home_gf;

  -- invariante temporal_safe: max_source_event_time <= decision
  if f1.max_source_event_time > dec then
    raise exception 'FAIL: max_source_event_time > decision_time';
  end if;
  raise notice 'PASS temporal_safe: max_source_event_time (%) <= decision (%)', f1.max_source_event_time, dec;
end $$;
rollback;
