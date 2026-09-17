-- ISS155: los ids de equipo de ESPN se repiten entre deportes
--
-- SINTOMA
--   Despues de la reconstruccion de ISS154, el gate G34.9 paso de
--   29/5597 discrepancias (0.52%) a 278/5984 (4.65%) y se puso en FAIL.
--   El desglose por equipo daba 100% de discrepancia en equipos argentinos:
--   Independiente 25/25, Racing Club 23/23, Union Santa Fe 22/22,
--   Talleres 22/22, Lanus 21/21, San Lorenzo 21/21...
--
-- CAUSA RAIZ
--   Sacando una fila concreta de Independiente:
--
--     kickoff 2026-09-06 20:00 | gf 1 ga 0 | Liga Profesional Argentina
--     fecha_espn 2026-09-06 20:10 | Seattle Mariners vs Athletics | 2-0
--     espn_endpoint: baseball/mlb
--
--   Los ids de equipo de ESPN SOLO son unicos DENTRO de cada deporte.
--   public.historico_partidos_espn mezcla deportes en la misma tabla.
--   El join del gate cruzaba por team_espn_id y fecha sin filtrar deporte,
--   asi que comparaba el historial de un equipo de futbol contra el
--   marcador de un partido de beisbol del mismo dia.
--
--   No era un defecto de datos: era el gate midiendo mal.
--   Es exactamente el mismo error que produjo la correlacion falsa de
--   0.7775 al principio de esta linea de trabajo. Mismo origen, misma tabla.
--
-- ARREGLO
--   Una sola linea en el join: and h.espn_endpoint like 'soccer/%'
--   No se toca ningun dato, ni el umbral del gate (sigue en 2.0%).
--
-- MEDIDO ANTES DE APLICAR
--   sin filtro de deporte: comparados 5984 | equipos 166 | discrepan 278 | 4.65%
--   con filtro de deporte: comparados 5730 | equipos 154 | discrepan  29 | 0.51%
--
--   Las 254 comparaciones que desaparecen son cruces contra otros deportes;
--   no eran partidos de futbol que dejemos de vigilar.
--
-- DESPUES DE APLICAR (verificado en produccion)
--   G34.9 PASS - "Comparados 5730 partidos de 154 equipos ... Discrepan 29 (0.51%)"
--   gate_cobertura_y_competencias(): sin ningun FAIL (solo G34.7 y G34.8 en INFO)
--   gate_frescura_de_datos(): sin ningun FAIL
--
-- DISCIPLINA DE PARCHE
--   Se sustituye exactamente una ocurrencia; si hay 0 o mas de 1, revienta
--   y no aplica nada.

do $mig$
declare
  v_def text; v_o text; v_n text; c int;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='gate_cobertura_y_competencias';

  v_o := '     and h.fecha::date = o.kickoff::date and h.home_score is not null';
  v_n := v_o || E'\n     and h.espn_endpoint like ''soccer/%''  -- ISS155: los ids de ESPN solo son unicos DENTRO de cada deporte';

  c := (length(v_def)-length(replace(v_def, v_o, '')))/length(v_o);
  if c <> 1 then raise exception 'ISS155: esperaba 1 ocurrencia, encontre %', c; end if;

  execute replace(v_def, v_o, v_n);
end
$mig$;

-- COMPROBACION
--   select * from public.gate_cobertura_y_competencias() t where t::text like '%G34.9%';
--   debe decir PASS y ~0.5%.
