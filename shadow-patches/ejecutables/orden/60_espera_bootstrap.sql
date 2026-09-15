-- orden/60_espera_bootstrap.sql — BLOQUEA HASTA QUE LA DESCARGA TERMINE
--
-- POR QUE EXISTE: pg_net es asincrono y pg_cron corre cada minuto, asi que en
-- una base virgen las assertions de season_type podian correr ANTES de que
-- terminara la descarga. El dueno lo detecto. Este archivo ABORTA el arranque si
-- los datos no estan completos, en vez de dejar pasar comprobaciones vacias.
--
-- Se vuelve a correr hasta que pase. No hay sleep: el cron avanza por su cuenta.

do $$
declare v_pend int; v_vuelo int; v_err int; v_fin boolean; v_d date; v_h date;
begin
  select desde, hasta into v_d, v_h from public.mlb_bootstrap_estado where id = 1;
  if v_d is null then
    raise exception 'BOOTSTRAP NO ARRANCADO: correr orden/50_bootstrap.sql primero';
  end if;

  select count(*) filter (where estado='pendiente'),
         count(*) filter (where estado='solicitado'),
         count(*) filter (where estado='error')
    into v_pend, v_vuelo, v_err
  from public.mlb_backfill_control where fecha between v_d and v_h;

  v_fin := exists (select 1 from public.mlb_bootstrap_log
                    where paso->>'fase' = 'fin');

  if not v_fin then
    raise exception
      'BOOTSTRAP EN CURSO: % pendientes, % en vuelo, % con error en el rango %..%. '
      'El job mlb_bootstrap corre cada minuto y se desprograma solo al terminar. '
      'Volver a correr este archivo hasta que pase. NO continuar a 70/80: las '
      'comprobaciones sobre datos incompletos no prueban nada.',
      v_pend, v_vuelo, v_err, v_d, v_h;
  end if;

  if v_err > 0 then
    raise exception 'BOOTSTRAP TERMINO CON % FECHAS EN ERROR: revisar mlb_backfill_control', v_err;
  end if;

  raise notice 'BOOTSTRAP COMPLETO: rango %..%, 0 errores. Se puede continuar a 70_universo.', v_d, v_h;
end $$;
