-- verificar_invariantes.sql — las reglas del dueño y del auditor, como asserts.
--
-- No compara textos: comprueba PROPIEDADES. Sirve aunque el SQL cambie de
-- forma, y es lo que de verdad importa que no se rompa.
do $$
declare v_n int; v_t text;
begin
  -- 1) CANDADO DEL DUENO: ningun campo derivado del mercado puede seleccionar,
  --    ordenar, autorizar ni suprimir un pick. Se revisa que no aparezcan en
  --    ORDER BY / PARTITION BY / WHERE de las superficies de decision.
  with objs as (
    select c.relname::text nm, pg_get_viewdef(c.oid,true) t
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relkind in ('v','m')
    union all
    select p.proname::text, pg_get_functiondef(p.oid)
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f'
  ), ln as (select nm, l from objs, regexp_split_to_table(objs.t, E'\n') l)
  select count(*), coalesce(string_agg(distinct nm, ', '), '')
    into v_n, v_t
  from ln
  where l ~* '(order by|partition by|^\s*(and|or|where|having)\s)'
    and l ~* '(ev_pct|ev_estimado|ev_declarado|ev_ajustado|ev_dec|score_valor|brecha_pp|discriminacion_pp|vs_mercado_pts|prob_que_implica_el_precio_pct|precio_verificado|tiene_precio)'
    and l !~* '^\s*--'
    and nm in ('v_reto13m_mejores','v_reto13m_lo_mejor','v_mejor_pick_por_partido',
               'v_picks_con_valor','v_mejores_picks_mlb','parlay_del_dia_v3',
               'destacados_del_dia','mejor_oportunidad_hoy','mejor_pick_hoy');
  if v_n > 0 then
    raise exception 'CANDADO ROTO: el mercado volvio a decidir en: %', v_t;
  end if;

  -- 2) DEROGADA por iss093 (AUDIT_NO_PASS 5642144970).
  --    Decia 'PISO ROTO: % picks por debajo del azar', o sea EXIGIA el piso de
  --    ventaja-sobre-azar que el dueno acaba de prohibir. Su orden textual:
  --    «El usuario quiere lo que RETO cree que pasara, no lo que mas supera un
  --    baseline artificial». Un empate al 38% DEBE poder salir si es el
  --    resultado mas defendible. La sustituyen las 4 pruebas de
  --    public.pruebas_selector_limpio(), que se ejecutan mas abajo.
  --    No se borra el hueco en silencio: queda escrito que esta regla cambio.

  -- 3) NO-PASS del auditor: nada se declara validado fuera de muestra, y no
  --    hay LOCKs, hasta que exista la prueba temporal independiente.
  select count(*) into v_n from public.v_reto13m_mejores
   where coalesce(validado_fuera_de_muestra,false) or coalesce(es_lock,false);
  if v_n > 0 then
    raise exception 'NO-PASS VIOLADO: % filas se declaran validadas o LOCK sin prueba OOS', v_n;
  end if;

  -- 4) Sin columnas de EV en la vista que decide.
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='v_reto13m_mejores'
     and column_name in ('ev_pct','edge_pct','prob_que_implica_el_precio_pct','discriminacion_pp');
  if v_n > 0 then raise exception 'EV VOLVIO: % columnas de EV en v_reto13m_mejores', v_n; end if;

  -- 5) La calibracion no se presta entre deportes.
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='zonas_confiables' and column_name='deporte';
  if v_n = 0 then raise exception 'zonas_confiables perdio la columna deporte'; end if;

  -- 6) La muestra se cuenta en partidos independientes, no en filas.
  select count(*) into v_n from information_schema.columns
   where table_schema='public' and table_name='zonas_confiables' and column_name='n_partidos';
  if v_n = 0 then raise exception 'zonas_confiables perdio n_partidos (conteo inflado)'; end if;

  raise notice 'OK: 6 invariantes se cumplen.';
end $$;

-- ---------------------------------------------------------------------------
-- Invariantes añadidas por iss089/iss090/iss091
-- ---------------------------------------------------------------------------
do $$
declare v_n int; v_t text;
begin
  -- 7) LINAJE: ningun feature puede mirar el dia del partido ni despues.
  select count(*) into v_n from public.calib_lambda
   where greatest(asof_home, asof_away, asof_league, asof_dispersion) >= fecha;
  if v_n > 0 then raise exception 'FUGA TEMPORAL: % filas con un feature a la fecha del partido o posterior', v_n; end if;

  select count(*) into v_n from public.calib_eventos
   where data_asof_real >= fecha_partido;
  if v_n > 0 then raise exception 'FUGA TEMPORAL en eventos: % filas', v_n; end if;

  -- 8) VENTANAS POR DEPORTE: el bug de iss087 era declararlas y no usarlas.
  --    Aqui quedan materializadas por fila, asi que se pueden verificar.
  select count(*) into v_n from public.calib_lambda
   where (deporte='baseball' and (vent_equipo <> '24 months' or vent_liga <> '30 days'))
      or (deporte='football' and (vent_equipo <> '36 months' or vent_liga <> '120 days'));
  if v_n > 0 then raise exception 'VENTANAS MAL APLICADAS: % filas no usan la ventana de su deporte', v_n; end if;

  -- 9) PUSH: una linea .5 no puede empujar nunca.
  select count(*) into v_n from public.calib_eventos
   where not linea_entera and (resultado='PUSH' or p_push > 0.0001);
  if v_n > 0 then raise exception 'PUSH FANTASMA: % eventos en linea .5 con push', v_n; end if;

  -- 10) PRETEMPORADA fuera de todo backtest.
  select count(*) into v_n from public.calib_lambda where tipo_temporada <> 'regular_o_playoffs';
  if v_n > 0 then raise exception 'PRETEMPORADA DENTRO: % filas', v_n; end if;

  -- 11) apto_para_lock no se regala: ningun calibrador lo tiene sin holdout
  --     significativo. Si algun dia se enciende, tiene que ser explicito.
  select count(*), coalesce(string_agg(calibration_version||'/'||deporte||'/'||metodo, ', '),'')
    into v_n, v_t
  from public.calibradores where apto_para_lock and not mejora_oos;
  if v_n > 0 then raise exception 'LOCK REGALADO: % calibradores aptos sin mejora OOS: %', v_n, v_t; end if;

  -- 12) Un solo calibrador elegido por (deporte, mercado) entre los vigentes.
  select count(*) into v_n from (
    select deporte, mercado from public.calibradores
     where elegido and not invalidado group by 1,2 having count(*) > 1) d;
  if v_n > 0 then raise exception 'CALIBRADOR AMBIGUO: % (deporte,mercado) con mas de un elegido', v_n; end if;

  raise notice 'OK: 6 invariantes nuevas (7-12) se cumplen.';
end $$;

-- ---------------------------------------------------------------------------
-- Invariantes añadidas por iss092 (soccer 1X2 multiclase)
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  -- 13) Linaje en soccer.
  select count(*) into v_n from public.calib_lambda_1x2
   where greatest(asof_home, asof_away, asof_league) >= fecha;
  if v_n > 0 then raise exception 'FUGA TEMPORAL soccer: % filas', v_n; end if;

  -- 14) Las 3 clases de un 1X2 suman 1. Una distribucion que no suma 1 no es
  --     una distribucion, y todo lo que se muestre encima seria mentira.
  select count(*) into v_n from public.calib_eventos
   where mercado='1X2' and p_raw_multi is not null
     and abs( (p_raw_multi->>'home')::numeric + (p_raw_multi->>'draw')::numeric
            + (p_raw_multi->>'away')::numeric - 1 ) > 0.000005;
  if v_n > 0 then raise exception '1X2 NO SUMA 1: % filas', v_n; end if;

  -- 15) Ninguna clase en 0 ni en 1: nada es imposible ni seguro.
  select count(*) into v_n from public.calib_eventos
   where mercado='1X2' and p_raw_multi is not null and (
     (p_raw_multi->>'home')::numeric <= 0 or (p_raw_multi->>'home')::numeric >= 1 or
     (p_raw_multi->>'draw')::numeric <= 0 or (p_raw_multi->>'draw')::numeric >= 1 or
     (p_raw_multi->>'away')::numeric <= 0 or (p_raw_multi->>'away')::numeric >= 1);
  if v_n > 0 then raise exception '1X2 FUERA DE RANGO: % filas', v_n; end if;

  -- 16) Amistosos de club fuera: son el analogo de la pretemporada.
  select count(*) into v_n from public.calib_lambda_1x2
   where competencia = 'soccer/club.friendly';
  if v_n > 0 then raise exception 'AMISTOSOS DENTRO: % filas', v_n; end if;

  -- 17) La ventaja local no puede salir invertida (el bug cazado en iss092).
  select count(*) into v_n from (
    select avg(lam_home) lh, avg(lam_away) la, avg(home_score) rh, avg(away_score) ra
    from public.calib_lambda_1x2) t
   where (lh > la) is distinct from (rh > ra);
  if v_n > 0 then raise exception 'VENTAJA LOCAL INVERTIDA en calib_lambda_1x2'; end if;

  raise notice 'OK: invariantes 13-17 (soccer) se cumplen.';
end $$;

-- ---------------------------------------------------------------------------
-- Las 4 pruebas obligatorias del selector limpio (iss093).
-- Sustituyen a la invariante 2 derogada.
-- ---------------------------------------------------------------------------
do $$
declare r jsonb;
begin
  r := public.pruebas_selector_limpio();
  if (r->>'EV_FIELDS_USER_VISIBLE')::int <> 0 then
    raise exception 'EV_FIELDS_USER_VISIBLE = % : %', r->>'EV_FIELDS_USER_VISIBLE', r->'EV_FIELDS_detalle';
  end if;
  if (r->>'UNIFORM_BASELINE_PICK_GATE')::int <> 0 then
    raise exception 'UNIFORM_BASELINE_PICK_GATE = % : %', r->>'UNIFORM_BASELINE_PICK_GATE', r->'BASELINE_detalle';
  end if;
  if (r->>'SPORT_QUOTA')::int <> 0 then
    raise exception 'SPORT_QUOTA = % : %', r->>'SPORT_QUOTA', r->'SPORT_QUOTA_detalle';
  end if;
  if (r->>'IN_SAMPLE_PROB_MUTATION')::int <> 0 then
    raise exception 'IN_SAMPLE_PROB_MUTATION = % : %', r->>'IN_SAMPLE_PROB_MUTATION', r->'IN_SAMPLE_detalle';
  end if;
  raise notice 'OK: las 4 pruebas del selector limpio estan en cero (cadena de % vistas).', r->>'cadena_revisada';
end $$;

-- 18) Ningun pick se declara LOCK si su mercado no tiene apto_para_lock.
do $$
declare v_n int;
begin
  select count(*) into v_n from public.v_reto13m_mejores
   where not public.mercado_apto_para_lock(deporte, mercado);
  if v_n > 0 then raise exception 'LOCK SIN AVAL: % filas en Reto13M cuyo mercado no es apto_para_lock', v_n; end if;

  -- 19) La superficie experimental nunca se declara validada.
  select count(*) into v_n from public.v_reto13m_analisis_experimental
   where coalesce(es_lock,false) or coalesce(validado_fuera_de_muestra,false);
  if v_n > 0 then raise exception 'EXPERIMENTAL SE DECLARA VALIDADO: % filas', v_n; end if;

  raise notice 'OK: invariantes 18-19 se cumplen.';
end $$;
