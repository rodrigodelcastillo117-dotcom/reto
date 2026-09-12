-- orden/80_assertions.sql — COMPROBACIONES, SEPARADAS DEL BOOTSTRAP
--
-- Se ejecuta DESPUES de 60_espera_bootstrap.sql (que bloquea hasta que la
-- descarga termino) y de 70_universo.sql. Antes vivian al final de iss094 y
-- podian correr sobre datos a medio cargar.

-- ===========================================================================
-- 5) ASSERTIONS: si esto no pasa, el patch NO quedó aplicado
-- ===========================================================================
do $$
declare v_n int; v_reg int;
begin
  -- 5a) la etiqueta se DERIVA del entero, sin excepciones
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type is not null
     and tipo_temporada is distinct from
         (case season_type when 1 then 'pretemporada' else 'regular_o_playoffs' end);
  if v_n > 0 then raise exception 'ETIQUETA NO DERIVADA: % filas', v_n; end if;

  -- 5b) ninguna fila de MLB sin season_type
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type is null;
  if v_n > 0 then raise exception 'SIN SEASON_TYPE: % filas de MLB', v_n; end if;

  -- 5c) la temporada regular tiene que cuadrar con las ~2,430 reales
  for v_reg in select season_year from public.historico_partidos_espn
                where espn_endpoint='baseball/mlb' and season_type=2
                  and season_year between 2023 and 2025 group by 1
  loop
    select count(*) into v_n from public.historico_partidos_espn
     where espn_endpoint='baseball/mlb' and season_type=2 and season_year=v_reg;
    if v_n not between 2400 and 2440 then
      raise exception 'TEMPORADA REGULAR % fuera de rango: % partidos (esperado ~2,430)', v_reg, v_n;
    end if;
  end loop;

  -- 5d) regular y postseason NO se mezclan
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint='baseball/mlb' and season_type=3 and season_year between 2023 and 2025;
  if v_n < 100 then raise exception 'POSTSEASON NO SEPARADA: solo % partidos type 3', v_n; end if;

  -- 5e) los conflictos quedaron registrados, no corregidos en silencio
  select count(*) into v_n from public.mlb_season_type_conflictos;
  if v_n = 0 then raise exception 'SIN REGISTRO DE CONFLICTOS: se corrigio en silencio'; end if;

  -- 5f) 0 duplicados APLICADOS en el destino
  select count(*) into v_n from (
    select espn_event_id from public.historico_partidos_espn
     where espn_endpoint='baseball/mlb' group by 1 having count(*)>1) d;
  if v_n > 0 then raise exception 'DUPLICADOS APLICADOS: %', v_n; end if;

  raise notice 'iss094 OK: season_type exacto, regular y postseason separadas, 0 duplicados aplicados';
end $$;

-- FIN iss094. El universo del backtest lo reconstruye iss094b.
