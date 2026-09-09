-- ============================================================================
-- iss035 GAP B — idempotencia de bankroll (branch, tx ROLLBACK). Requiere iss035.
-- Prueba que aplicar N veces la misma transicion deja el MISMO bankroll, y que una
-- correccion no doble-contabiliza. La verdad = calcular_bankroll_actual (SUM estado).
-- Branch-only (no correr en prod bajo freeze).
-- ============================================================================
begin;
do $$
declare
  v_apodo text := 'test_idem_'||floor(random()*100000)::text;
  b0 numeric; b1 numeric; b2 numeric; b3 numeric; b_corr numeric; b_corr2 numeric;
  pid uuid := gen_random_uuid();
begin
  insert into public.usuarios(apodo, bankroll_inicial) values (v_apodo, 1000)
    on conflict (apodo) do update set bankroll_inicial=1000;
  b0 := public.calcular_bankroll_actual(v_apodo);
  if b0 <> 1000 then raise exception 'FAIL base: bankroll inicial %', b0; end if;

  -- pending -> ganado (+150). Aplicar el "callback" 3 veces (misma transicion).
  insert into public.picks(id, apodo, resultado, ganancia_neta, created_at)
    values (pid, v_apodo, 'ganado', 150, now());
  b1 := public.calcular_bankroll_actual(v_apodo);
  update public.picks set resultado='ganado', ganancia_neta=150 where id=pid; -- retry
  b2 := public.calcular_bankroll_actual(v_apodo);
  update public.picks set resultado='ganado', ganancia_neta=150 where id=pid; -- retry
  b3 := public.calcular_bankroll_actual(v_apodo);
  if not (b1=b2 and b2=b3 and b1=1150) then
    raise exception 'FAIL idempotencia: b1=% b2=% b3=% (esperado 1150 cada uno)', b1,b2,b3;
  end if;
  raise notice 'PASS idempotencia doble/triple callback: % (=1150)', b3;

  -- correccion ganado(+150) -> perdido(-100): sin acumular, valor corregido
  update public.picks set resultado='perdido', ganancia_neta=-100 where id=pid;
  b_corr := public.calcular_bankroll_actual(v_apodo);
  if b_corr <> 900 then raise exception 'FAIL correccion: % (esperado 900)', b_corr; end if;
  -- reaplicar la correccion (retry) -> mismo valor
  update public.picks set resultado='perdido', ganancia_neta=-100 where id=pid;
  b_corr2 := public.calcular_bankroll_actual(v_apodo);
  if b_corr2 <> 900 then raise exception 'FAIL correccion retry: % (esperado 900)', b_corr2; end if;
  raise notice 'PASS correccion ganado->perdido sin acumular: % (=900)', b_corr2;
end $$;
rollback;
