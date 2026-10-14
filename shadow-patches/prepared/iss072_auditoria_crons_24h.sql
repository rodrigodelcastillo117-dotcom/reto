-- iss072 · Auditoría de los crons en 24 h, como pidió el owner
--          ("comprueba, analiza que cada cron trabaja 24 hrs después, ningún error").
--
-- NÚMEROS CRUDOS (2026-09-11, ventana de 24 h)
--   16,264 corridas · 16,142 exitosas · 122 fallidas (0.75%) · 31 jobs distintos
--
-- Lo importante: 122 fallos NO son 31 problemas. Son CUATRO causas.
--
-- ===== CAUSA 1: "server restarted" (~70 fallos) — y ya está arreglada =====
-- El peor job de todo el sistema era el 314 `picks-futbol-cache`, con 46 fallos.
-- Su comando es `select public.refrescar_picks_futbol()`, y esa función hace:
--     delete from picks_futbol_cache;
--     insert into picks_futbol_cache select * from v_picks_futbol_calc;
-- `v_picks_futbol_calc` es EXACTAMENTE la vista del producto cartesiano de 83.5
-- millones de pares que documenté en iss068. Corría cada 10 minutos y tumbaba el
-- servidor. Medido después del arreglo: 29 filas en 0.073 segundos.
-- Y como efecto secundario: el caché que alimenta la pestaña de fútbol estaba
-- vacío/rancio porque el refresco llevaba días sin completar ni una vez.
--
-- HIPÓTESIS, no hecho probado: los otros "server restarted" son VÍCTIMAS del mismo
-- evento, no problemas propios. job 227 (12), 370 (6), 373 (2), 310 (1), 192 (1).
-- Evidencia a favor: `diagnostico_automatico()` y `auditar_coherencia_agenda(40)`
-- corren bien a demanda ahora mismo, no se pueden reproducir; y sus horarios caen
-- cerca de las corridas del job 314 (cada 10 min en el minuto 3). Cuando el servidor
-- se reinicia, todo lo que estaba corriendo muere con ese mensaje.
-- SE VERIFICA MAÑANA: si los fallos de 227/370/373/310/192 desaparecen sin que yo
-- los haya tocado, la hipótesis era correcta. Si siguen, son problemas propios.
--
-- ===== CAUSA 2: "job startup timeout" (~25 fallos en 22 jobs) — un solo evento =====
-- NO son 22 bugs. Comparten el minuto EXACTO:
--   14 jobs fallaron todos a las 2026-09-11 10:43:00.40365
--    8 jobs fallaron todos a las 2026-09-10 15:04:19.192917
-- Es el lanzador de pg_cron saturado en dos momentos: ningún job alcanzó a arrancar.
-- Un job que no arranca se reintenta en su siguiente horario, así que no hay pérdida
-- de datos. No hay nada que arreglar en esos 22 jobs.
--
-- ===== CAUSA 3: clv-capturar, el bug de "50.5." (16 fallos) — ya arreglado =====
-- `regexp_replace(pick_desc,'[^0-9.]','','g')::numeric` sobre
-- "Menos de 50.5 puntos totales (incl. prórroga)" deja "50.5." porque el punto de
-- "incl." sobrevive, y el cast truena. Ya estaba parchado a
-- `(regexp_match(pick_desc, '(\d+(?:\.\d+)?)'))[1]` en las 4 ocurrencias.
-- VERIFICADO que el parche aguanta: job 196 falló 16 veces entre 00:01 y 03:46, y
-- desde entonces lleva 32 corridas exitosas seguidas, la última a las 11:01.
-- Cero fallos en más de 7 horas.
--
-- ===== CAUSA 4: deadlock 201 <-> 401 (6 fallos) — arreglado aquí =====
-- Los dos hacen UPDATE sobre live_scores:
--   201 completar_metadatos_con_candado  (cada 20 min, minuto :14)
--   401 completar_metadatos_live         (cada 30 min)
-- El 201 YA tomaba el candado advisory 778002. Su propio comentario en el código
-- dice "2 deadlocks en 144 corridas": alguien ya resolvió este patrón una vez, para
-- otra pareja de jobs. Pero el 401 no participaba del candado, así que seguían
-- trabándose. Los 3 fallos del 201 y los 3 del 401 son el MISMO evento contado dos
-- veces (en un deadlock Postgres mata a uno de los dos).
-- ARREGLO: envoltorio `completar_metadatos_live_con_candado()` que toma el MISMO
-- candado 778002 con pg_try_advisory_lock (no el bloqueante): si el otro job está
-- dentro, esta corrida se salta y vuelve en 30 minutos. Perder una corrida no cuesta
-- nada; un deadlock sí. No se tocó la lógica de completar_metadatos_live.
-- Primera corrida: cerró 209 partidos viejos que estaban colgados.
--
-- ===== HALLAZGO APARTE: el watchdog llevaba 12 de 12 corridas en rojo =====
-- El job 227 `autodiagnostico` tenía 100% de fallos: 12 fallidas, 0 exitosas en 24 h.
-- LA ALARMA DEL SISTEMA ESTABA MUERTA. Por eso ninguno de los bugs de hoy saltó.
-- Y cuando la corrí a mano, daba "rojo" con 2 fallos que resultaron ser FALSAS
-- ALARMAS: el smoke test llamaba firmas desactualizadas.
--   kelly_stake     ganó el parámetro p_mercado SIN default -> necesita 5
--                   argumentos; el test pasaba 4.
--   revisar_apuesta ganó p_es_reto y p_espn_event_id -> necesita 9; el test pasaba 7.
-- Nadie actualizó el smoke test al cambiar las firmas. Una alarma que siempre está
-- en rojo es una alarma que nadie mira, y eso es peor que no tenerla.
-- Verificado antes de tocar: ninguna de las dos funciones escribe (sin
-- INSERT/UPDATE/DELETE en su cuerpo), así que probarlas es seguro.
-- DESPUÉS: diagnostico_automatico() devuelve estado "verde", 0 fallos, 19 probadas.

create or replace function public.completar_metadatos_live_con_candado()
returns table (por_equipos int, por_liga int, normalizados int, viejos_cerrados int, corrio boolean)
language plpgsql
as $$
begin
  if not pg_try_advisory_lock(778002) then
    return query select 0,0,0,0,false;
    return;
  end if;
  begin
    return query
      select m.por_equipos, m.por_liga, m.normalizados, m.viejos_cerrados, true
      from public.completar_metadatos_live() m;
  exception when others then
    perform pg_advisory_unlock(778002);
    raise;
  end;
  perform pg_advisory_unlock(778002);
end;
$$;

-- select cron.alter_job(401, command => 'select * from public.completar_metadatos_live_con_candado();');

-- El parche de firmas en autodiagnostico() se aplicó con cirugía de texto sobre
-- pg_get_functiondef exigiendo que cada ancla apareciera exactamente 1 vez:
--   kelly_stake('rodelcast',60,1.9,100)
--     -> kelly_stake('rodelcast',60::numeric,1.9,100::numeric,null::text)
--   revisar_apuesta('rodelcast','⚽ Fútbol','Gana local',2.0,100,55,null)
--     -> revisar_apuesta('rodelcast','⚽ Fútbol','Gana local',2.0,100::numeric,
--                        55::numeric,null::text,false,null::text)

-- CÓMO SE VERIFICA MAÑANA (la prueba real son los números de 24 h, no los de hoy):
--   select count(*) corridas, count(*) filter (where status='failed') fallos
--   from cron.job_run_details where start_time > now() - interval '24 hours';
--   -- detalle por job:
--   select d.jobid, j.jobname, count(*) fallos,
--          left(regexp_replace(max(d.return_message), E'\\s+', ' ', 'g'), 150) error
--   from cron.job_run_details d left join cron.job j on j.jobid=d.jobid
--   where d.start_time > now() - interval '24 hours' and d.status='failed'
--   group by d.jobid, j.jobname order by fallos desc;
--   -- el watchdog debe estar en verde:
--   select public.diagnostico_automatico();
