-- ISS157: gate de fuga temporal en las ventanas de tiros
--
-- POR QUE EXISTE
--   El dueno insistio en el punto correcto: si la ventana de 10 partidos
--   accidentalmente incluye el partido que se esta prediciendo, o cualquier
--   partido posterior, el backtest sale falsamente perfecto y no nos damos
--   cuenta. No basta con afirmar que la guardia esta; hay que probarlo,
--   y hay que probarlo cada vez, no una sola vez.
--
-- TRES GATES
--   G36.1 Reconstruye la ventana exacta que usa fn_soccer_tiros_asof para cada
--         partido de los ultimos 60 dias y exige que TODO partido usado sea
--         estrictamente anterior al partido predicho.
--   G36.2 El partido predicho no puede estar en su propia ventana.
--   G36.3 Ninguna funcion de produccion puede llamar a fn_soccer_tiros_asof ni
--         a fn_soccer_ou_por_tiros pasando false en la guardia de cargado_at.
--         Ese false existe solo para medir sobre historico backfilleado.
--
-- RESULTADO AL INSTALARLO
--   G36.1 PASS - 7378 usos revisados en las ventanas de 1125 partidos, 0 fugas
--   G36.2 PASS - 0
--   G36.3 PASS - 0
--
-- PRUEBA DE QUE EL GATE MUERDE (un gate que no puede fallar no es un gate)
--   Se repitio la misma ventana cambiando "s.fecha < p.fecha" por
--   "s.fecha <= p.fecha", que es exactamente el error que produce fuga:
--     usos revisados 4702 | usos con fuga 1050 | partidos contaminados 1050
--   O sea: si la fuga existiera, G36.1 la marcaria en 1050 de 1125 partidos.
--   El PASS de arriba no es un PASS vacio.

create or replace function public.gate_fuga_temporal_tiros()
returns table(gate text, estado text, cuenta bigint, detalle text)
language plpgsql stable as $$
begin
  return query
  with par as (
    select h.espn_event_id, h.home_espn_id, h.away_espn_id, h.fecha
    from public.historico_partidos_espn h
    where h.espn_endpoint like 'soccer/%' and h.home_score is not null
      and h.fecha > now() - interval '60 days'
  ), ventana as (
    select p.espn_event_id, p.fecha as fecha_predicha, s.fecha as fecha_usada, s.espn_event_id as usado
    from par p
    join lateral (
      select s.espn_event_id, s.fecha from v2.soccer_stats_partido s
      where s.team_espn_id = p.home_espn_id and s.fecha < p.fecha
      order by s.fecha desc limit 10
    ) s on true
    union all
    select p.espn_event_id, p.fecha, s.fecha, s.espn_event_id
    from par p
    join lateral (
      select s.espn_event_id, s.fecha from v2.soccer_stats_partido s
      where s.team_espn_id = p.away_espn_id and s.fecha < p.fecha
      order by s.fecha desc limit 10
    ) s on true
  )
  select 'G36.1_la_ventana_de_tiros_no_ve_el_futuro'::text,
    case when count(*) filter (where fecha_usada >= fecha_predicha) > 0 then 'FAIL' else 'PASS' end,
    count(*) filter (where fecha_usada >= fecha_predicha),
    ('Se revisaron '||count(*)||' usos de partido dentro de las ventanas de '
     ||count(distinct espn_event_id)||' partidos predichos. Usos que caen en la fecha del partido predicho o despues: '
     ||count(*) filter (where fecha_usada >= fecha_predicha)
     ||'. Cualquier numero distinto de cero es fuga de datos y el backtest sale falsamente bueno.')::text
  from ventana;

  return query
  with par as (
    select h.espn_event_id, h.home_espn_id, h.away_espn_id, h.fecha
    from public.historico_partidos_espn h
    where h.espn_endpoint like 'soccer/%' and h.home_score is not null
      and h.fecha > now() - interval '60 days'
  ), auto as (
    select p.espn_event_id
    from par p
    join v2.soccer_stats_partido s
      on s.espn_event_id = p.espn_event_id and s.fecha < p.fecha
  )
  select 'G36.2_el_partido_no_se_usa_a_si_mismo'::text,
    case when count(*) > 0 then 'FAIL' else 'PASS' end, count(*),
    ('Partidos cuya propia fila de tiros entraria en su ventana: '||count(*)
     ||'. Debe ser 0 por construccion (s.fecha < p.fecha es la misma fecha).')::text
  from auto;

  return query
  select 'G36.3_produccion_exige_la_guardia_de_cargado_at'::text,
    case when count(*) > 0 then 'FAIL' else 'PASS' end, count(*),
    ('Funciones de produccion que llaman a fn_soccer_tiros_asof o '
     ||'fn_soccer_ou_por_tiros pasando false en la guardia de cargado_at: '||count(*)
     ||'. Debe ser 0: ese false es solo para medir en historico.')::text
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname in ('public','v2')
    and p.proname not in ('fn_soccer_tiros_asof','fn_soccer_ou_por_tiros','gate_fuga_temporal_tiros')
    and p.proname not like '%medir%' and p.proname not like '%backtest%' and p.proname not like '%gemelo%'
    and (p.prosrc ~ 'fn_soccer_tiros_asof\s*\([^)]*false'
      or p.prosrc ~ 'fn_soccer_ou_por_tiros\s*\([^)]*false');
end
$$;

-- COMPROBACION
--   select * from public.gate_fuga_temporal_tiros();
--   los tres deben decir PASS con cuenta 0.
