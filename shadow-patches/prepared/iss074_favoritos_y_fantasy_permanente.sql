-- iss074 · Dos cosas que el owner pidió y que simplemente NO EXISTÍAN.
--
-- ===== 1. EL EQUIPO DE FANTASY SE BORRABA AL CAMBIAR DE SEMANA =====
-- "yo ya draftee mi equipo, deberia guardarse para siempre".
-- `fantasy_roster_semanal` está particionada por (apodo, temporada, semana), y
-- VERIFICADO el 2026-09-11: NINGUNA función ni cron escribe en esa tabla salvo el
-- guardado manual del usuario. Nada copia el roster de una semana a la siguiente.
-- Estado real: 1 roster, apodo 'rodelcast', semana 1, 15 jugadores.
-- Consecuencia: el día que la NFL pase a la semana 2, el equipo drafteado DESAPARECE
-- de la app y hay que volver a capturarlo a mano. Era una falla programada, no un bug
-- que ya hubiera ocurrido: por eso no se había visto.
--
-- ARREGLO: `fantasy_arrastrar_roster()` copia el último roster conocido de cada apodo
-- a la semana actual, SOLO si esa semana no tiene roster propio con jugadores. Nunca
-- pisa lo que el usuario ya guardó. El `analisis` NO se arrastra a propósito: es de la
-- semana vieja y mostrarlo como actual sería mentira; se recalcula.
-- Cron 461 `fantasy-arrastrar-roster`, diario 09:20 UTC (no-op barato si no hay nada).
--
-- VERIFICADO: corrida en firme hoy = 0 filas (la semana 1 ya tiene roster, no lo
-- pisó). Simulacro de solo lectura para la semana 2 = arrastraría los 15 jugadores
-- (Mahomes, Achane, Kyren Williams, Smith-Njigba, Egbuka, Tyler Warren, Montgomery,
-- MarShawn Lloyd, Dowdle, Sutton, Josh Jacobs, Keenan Allen, Shakir, Dicker, Jaguars).
--
-- ===== 2. LA PESTAÑA FAVORITOS NO TENÍA NINGUNA VISTA =====
-- "PICKS Y ANALISIS EN PESTAÑA FAVORITOS... solo te da los analisis de tus favoritos
-- por deporte. INCLUIR NFL, URGENTE."
-- Las únicas vistas que se llaman v_favorito_* son OTRA COSA: v_favorito_nfl y
-- v_favorito_mlb devuelven "el favorito DEL PARTIDO" (quién va ganando según el
-- mercado), no los equipos favoritos DEL USUARIO. Es la misma palabra con dos
-- significados, y por eso parecía que ya estaba hecho.
-- La tabla `equipos_favoritos` existe y tiene datos reales (52 equipos de fútbol,
-- 6 de baseball, 1 de NFL), pero NO estaba conectada a ningún análisis.
--
-- ARREGLO: `v_mis_favoritos_analisis`, tres decisiones que importan:
--   a) NO lleva security_invoker. Con security_invoker=on la vista comprueba los
--      permisos de TODA la cadena de v_pick_canonico como el que llama, y en este
--      proyecto eso ya rompió una vista completa para anon. Corre como dueña y el
--      filtro por usuario se replica dentro, con la MISMA expresión que usa la
--      política RLS de equipos_favoritos. Cada quien ve solo sus equipos.
--   b) El cruce es por NOMBRE normalizado, no por espn_team_id: equipos_favoritos
--      guarda ids de ESPN por deporte y las fuentes de análisis traen nombres; los
--      espacios de id no coinciden entre sistemas (ya documentado en iss067 con MLB).
--   c) NFL va por una rama SEPARADA porque v_pick_canonico solo trae 1 de los 16
--      partidos de la semana. Se lee de nfl_tablero_semana, que sí trae los 16.
--
-- VERIFICADO (replicando el cuerpo con el usuario real, porque auth.uid() es null
-- en una sesión de servicio):
--   baseball  72 filas · 6 equipos · 18 partidos
--   soccer    35 filas · 6 equipos ·  5 partidos
--   football   1 fila  · Pittsburgh Steelers · ATL @ PIT ·
--              "Gana Pittsburgh Steelers" 59.2% · proyección 22-24
--
-- ===== TRAMPA DE CONTRATO QUE ENCONTRÉ DE PASO (para el front) =====
-- En `nfl_tablero_semana`, para un partido YA TERMINADO:
--   estado      = 'scheduled'   <- viene de la tabla de momios. MENTIRA.
--   marcador    = NULL          <- MENTIRA.
--   estado_espn = 'final', terminado = true,
--   live_pts_visitante = 27, live_pts_local = 7   <- ESTO es lo real.
-- Ejemplo verificado: SF @ LAR, terminado 27-7, y NE @ SEA, terminado 10-13.
-- Si el front lee `estado` y `marcador`, pinta partidos acabados como programados y
-- sin marcador. Hay que leer `terminado` / `estado_espn` y `live_pts_*`.
-- La vista de favoritos ya lo hace bien; el resto de la pantalla de NFL hay que
-- revisarlo. NO toqué nfl_tablero_semana porque tiene tres dependientes y recrearla
-- exige recrearlos todos (lección de iss056).

create or replace function public.fantasy_arrastrar_roster()
returns table (apodo text, temporada int, semana_origen int, semana_destino int, jugadores int)
language plpgsql
as $$
declare v_sem jsonb; v_semana int; v_temp int;
begin
  v_sem := public.fantasy_semana_nfl();
  v_semana := nullif(v_sem->>'semana','')::int;
  v_temp   := nullif(v_sem->>'temporada','')::int;
  if v_semana is null or v_temp is null then return; end if;

  return query
  with ultimo as (
    select distinct on (r.apodo) r.apodo, r.temporada, r.semana, r.jugadores
    from public.fantasy_roster_semanal r
    where jsonb_array_length(coalesce(r.jugadores,'[]'::jsonb)) > 0
      and (r.temporada < v_temp or (r.temporada = v_temp and r.semana < v_semana))
    order by r.apodo, r.temporada desc, r.semana desc, r.guardado_at desc
  ),
  faltantes as (
    select u.* from ultimo u
    where not exists (
      select 1 from public.fantasy_roster_semanal x
      where x.apodo = u.apodo and x.temporada = v_temp and x.semana = v_semana
        and jsonb_array_length(coalesce(x.jugadores,'[]'::jsonb)) > 0)
  ),
  insertado as (
    insert into public.fantasy_roster_semanal (apodo, temporada, semana, jugadores, guardado_at)
    select f.apodo, v_temp, v_semana, f.jugadores, now() from faltantes f
    returning fantasy_roster_semanal.apodo, fantasy_roster_semanal.temporada,
              fantasy_roster_semanal.semana, fantasy_roster_semanal.jugadores
  )
  select i.apodo, i.temporada, f.semana, i.semana, jsonb_array_length(i.jugadores)
  from insertado i join faltantes f on f.apodo = i.apodo;
end;
$$;

-- select cron.schedule('fantasy-arrastrar-roster','20 9 * * *',
--   'select * from public.fantasy_arrastrar_roster();');   -- jobid 461

-- v_mis_favoritos_analisis: el cuerpo vigente se recupera con
--   select pg_get_viewdef('public.v_mis_favoritos_analisis'::regclass, true);
-- Ojo al recrearla: hay que DROP + CREATE, no `create or replace`, porque cambia el
-- numero de columnas y Postgres no deja quitar columnas de una vista.
-- Y despues, el GRANT EN SU PROPIA LLAMADA:
--   grant select on public.v_mis_favoritos_analisis to anon, authenticated;
