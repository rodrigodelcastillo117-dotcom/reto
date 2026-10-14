-- iss076 · MLB: los nombres de equipo SÍ existían, estaban repartidos.
--
-- En iss067 el H2H y las carreras recibidas quedaron sin nombre de equipo. El motivo
-- documentado entonces: mlb_equipo_id_nombre usa ids de MLB StatsAPI (108-147) y
-- mlb_linescore usa ids de ESPN (1-32). Espacios de id distintos, no cruzan. Me
-- quedé mostrando el nombre del PARQUE como sustituto.
--
-- Estaba incompleto, no imposible. historico_partidos_espn trae home_espn_id y
-- away_espn_id JUNTO CON home_nombre y away_nombre, y mlb_linescore trae
-- competitor_id + lado. Cruzando por espn_event_id + lado sale el catálogo.
--
-- VERIFICACIÓN DEL CRUCE, antes de construir nada: 14,537 pares distintos.
--   lado='home' con competitor_id = home_espn_id : 7,277
--   lado='away' con competitor_id = away_espn_id : 7,260
--   7,277 + 7,260 = 14,537 = el total. Cuadra al 100%, sin una sola excepción.
--
-- ARTEFACTO REAL QUE SALIÓ: ids 31 y 32 son "American All-Stars" y "National
-- All-Stars", con 3 apariciones cada uno contra ~480 de un equipo real. Son los
-- rosters del Juego de Estrellas. NO se borran (el dato es cierto), se marcan con
-- es_equipo_real = false, porque con 3 juegos de muestra salían EN PRIMER LUGAR del
-- ranking por diferencial de carreras, arriba de los Dodgers.
-- El catálogo queda con 30 equipos reales, que son exactamente las franquicias de MLB.
--
-- RESULTADO, leído como anon:
--   v_mlb_equipo_carreras : 30 equipos. Top por diferencial: Dodgers (501 juegos,
--     5.25 anotadas / 4.18 recibidas, +1.07, récord 306-193, total 9.43), Braves,
--     Brewers.
--   v_mlb_h2h : 435 emparejamientos. Mets vs Marlins 51 juegos 24-24; Giants vs
--     Rockies 46 juegos 29-16 con total promedio 10.46 (se ve el efecto Coors Field);
--     Rangers vs Astros 44 juegos 18-26 con total 10.27.
--
-- ===== ERROR MÍO, PARA QUE QUEDE ESCRITO =====
-- Al recrear el matview usé `drop materialized view ... CASCADE` y eso DESTRUYÓ
-- v_mlb_h2h y v_mlb_equipo_carreras, que dependían de él. Es EXACTAMENTE el mismo
-- error que yo mismo documenté en iss056 ("recrear nfl_tablero_semana exige recrear
-- sus tres dependientes") y lo volví a cometer en la misma sesión.
-- Lo detecté porque después de cada cambio vuelvo a contar TODAS las superficies, no
-- solo la que toqué. Las dos vistas están recreadas y verificadas arriba.
-- REGLA: antes de un DROP ... CASCADE, listar los dependientes y tener su definición
-- a la mano:
--   select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
--   where n.nspname='public' and c.relkind in ('v','m')
--     and pg_get_viewdef(c.oid,true) ilike '%<objeto>%';

drop materialized view if exists public.mlb_equipo_espn_catalogo cascade;
create materialized view public.mlb_equipo_espn_catalogo as
select competitor_id::text as espn_team_id,
       (array_agg(nombre order by fecha desc))[1] as nombre,
       count(*) as apariciones,
       max(fecha) as visto_por_ultima_vez,
       ((array_agg(nombre order by fecha desc))[1] !~* 'all[- ]?stars?') as es_equipo_real
from (
  select l.competitor_id, h.home_nombre as nombre, h.fecha
  from (select distinct espn_event_id, competitor_id, lado from public.mlb_linescore) l
  join public.historico_partidos_espn h
    on h.espn_event_id = l.espn_event_id and h.espn_endpoint='baseball/mlb'
  where l.lado='home' and l.competitor_id = h.home_espn_id::text and h.home_nombre is not null
  union all
  select l.competitor_id, h.away_nombre, h.fecha
  from (select distinct espn_event_id, competitor_id, lado from public.mlb_linescore) l
  join public.historico_partidos_espn h
    on h.espn_event_id = l.espn_event_id and h.espn_endpoint='baseball/mlb'
  where l.lado='away' and l.competitor_id = h.away_espn_id::text and h.away_nombre is not null
) x
group by competitor_id;
create unique index mlb_equipo_espn_catalogo_pk on public.mlb_equipo_espn_catalogo (espn_team_id);

-- GRANT EN SU PROPIA LLAMADA, y DESPUÉS recrear los dependientes que el CASCADE se llevó:
-- grant select on public.mlb_equipo_espn_catalogo to anon, authenticated;
-- create view public.v_mlb_equipo_carreras as ... (con JOIN ... AND c.es_equipo_real)
-- create view public.v_mlb_h2h as ...            (con JOIN ... AND c.es_equipo_real)
-- grant select on public.v_mlb_h2h, public.v_mlb_equipo_carreras to anon, authenticated;
-- Los cuerpos vigentes se recuperan con pg_get_viewdef().
-- Cron 464 mlb-catalogo-refresh, diario 05:50 UTC.
