-- verificar_checksums_iss094_096.sql — CHECKSUMS DE REPRODUCIBILIDAD
--
-- PARA QUE SIRVE: si alguien reconstruye la base corriendo los archivos de esta
-- carpeta en orden, esto falla si el resultado NO es identico a produccion.
-- Un hash que no cuadra significa que la reconstruccion divergio y hay que
-- averiguar por que ANTES de confiar en cualquier metrica.
--
-- Capturado el 2026-09-12 sobre produccion, despues de iss096 y de las
-- correcciones de elegibilidad/temporalidad, bootstrap y aislamiento de NFL.
-- ORDEN: iss088 -> iss089 -> iss090 -> iss091 -> iss094 -> iss094b -> iss095
--        -> iss096 -> gates_selector
-- NO correr iss087 despues de iss089: reintroduce el bug de ventanas.

do $$
declare
  esperados jsonb := '[
    {"tipo":"vista",  "nm":"v_pick_canonico",                "md5":"d12fd2437bba938a4ab90f8d833afce4"},
    {"tipo":"vista",  "nm":"v_mejor_pick_por_partido",       "md5":"6287055fc7ecd3b1ac4a71d6d3b9ad52"},
    {"tipo":"vista",  "nm":"v_reto13m_mejores",              "md5":"526776eab7017dd2edd0a6ed2ef21d62"},
    {"tipo":"vista",  "nm":"v_reto13m_lo_mejor",             "md5":"58712a800c56073cd5997be776273395"},
    {"tipo":"vista",  "nm":"v_reto13m_analisis_experimental","md5":"36d3c73832eb96f2a954fb24fb29da41"},
    {"tipo":"funcion","nm":"modelo_de_pick",                 "md5":"00504f3d312c91508b7d53dbe68a4770"},
    {"tipo":"funcion","nm":"estado_respaldo",                "md5":"d6615a96fb8d1d88f0f2e3be154cf96f"},
    {"tipo":"funcion","nm":"linea_es_canonica",              "md5":"5072bf25fe60e894a5b4f60885279eec"},
    {"tipo":"funcion","nm":"mercado_apto_para_lock",         "md5":"ee3d0847d9e037fa6e0f96cccd8242ff"},
    {"tipo":"funcion","nm":"elegibilidad_no_economica_v1",   "md5":"59b3a0d1e5cd6f87a0fde22cc5949987"},
    {"tipo":"funcion","nm":"mlb_backfill_cosechar",          "md5":"e3779f24dd62d27f5e0a74465b423a32"},
    {"tipo":"funcion","nm":"mlb_season_type_aplicar",        "md5":"d68a88db545e1507db45b995f18996f4"},
    {"tipo":"funcion","nm":"mlb_backfill_encolar",           "md5":"fd950e8e9fa3af7ed3043bd78125a323"},
    {"tipo":"funcion","nm":"mlb_bootstrap_paso",             "md5":"9d548fe8f92940b7be55dbbd03ced07c"},
    {"tipo":"funcion","nm":"mlb_bootstrap_tick",             "md5":"0a8a287645bf47b3967b09439b077640"},
    {"tipo":"funcion","nm":"mlb_bootstrap_arrancar",         "md5":"a41fcc25d23a384ad812f210f21f412f"},
    {"tipo":"funcion","nm":"guardia_nfl_sin_season_type",    "md5":"0b7fb1fd213506fb55abbdabae3f74dd"},
    {"tipo":"funcion","nm":"mlb_backfill_aplicar",           "md5":"74f1e20cf42059279a4c122f5412cbd6"}
  ]'::jsonb;
  e jsonb; actual text; malos text := '';
begin
  for e in select * from jsonb_array_elements(esperados) loop
    if e->>'tipo' = 'vista' then
      select md5(pg_get_viewdef(c.oid,true)) into actual
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname = e->>'nm';
    else
      select md5(pg_get_functiondef(p.oid)) into actual
      from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.proname = e->>'nm'
      order by p.oid limit 1;
    end if;

    if actual is null then
      malos := malos || format(E'\n  FALTA   %s %s', e->>'tipo', e->>'nm');
    elsif actual <> (e->>'md5') then
      malos := malos || format(E'\n  DIVERGE %s %s: esperado %s, real %s',
        e->>'tipo', e->>'nm', e->>'md5', actual);
    end if;
  end loop;

  if malos <> '' then
    raise exception 'CHECKSUMS NO CUADRAN. La reconstruccion NO es identica a produccion:%', malos;
  end if;
  raise notice 'CHECKSUMS OK: 18 objetos identicos a produccion';
end $$;

-- Conteos de referencia. No son checksums pero detectan una carga incompleta.
do $$
declare v_n int;
begin
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type=2 and season_year=2024;
  if v_n <> 2430 then raise warning 'MLB 2024 regular: % partidos (referencia 2,430)', v_n; end if;

  select count(*) into v_n from public.calib_lambda where deporte='baseball';
  if v_n not between 8500 and 8700 then
    raise warning 'calib_lambda baseball: % filas (referencia ~8,630)', v_n; end if;

  select count(*) into v_n from public.calib_lambda where deporte='football';
  if v_n > 0 then raise warning 'NFL EN EL UNIVERSO: % filas. Debe estar aislado hasta recuperar su season_type.', v_n; end if;

  select count(*) into v_n from public.superficie_usuario;
  if v_n < 80 then raise warning 'superficie_usuario: % vistas (referencia 83). Registro chico = falso verde.', v_n; end if;
end $$;
