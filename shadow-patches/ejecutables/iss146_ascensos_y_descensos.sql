-- ISS146: el 25% de los equipos estaba con la liga de la temporada pasada.
-- ESTA ES LA CAUSA DE FONDO DE "los resultados no hacen coherencia".
--
-- COMO SE LLEGO AQUI
-- Arreglando ISS145 (ESPN dejo de aceptar rangos de fecha) quedaron 115
-- partidos recuperados. Al revisar si la FORMA se estaba aprovechando,
-- aparecio esto:
--
--   equipos en DATA_READY .......................... 263
--   atraso promedio del ultimo partido en su forma . 36.8 dias
--   de los que juegan dentro de 7 dias ............. 37.3 dias de atraso
--   con mas de 21 dias de atraso ................... 18
--   el mas viejo ................................... 2026-03-28
--
-- PRIMERA CAUSA: un equipo que llegaba a DATA_READY no se volvia a pedir nunca,
-- porque get_soccer_coverage_jobs solo toma PENDING/RETRY/RUNNING. La forma se
-- congelaba en el momento de la primera carga.
--
-- SEGUNDA CAUSA, LA GRAVE: los equipos que ASCENDIERON O DESCENDIERON
-- conservaban su domestic_league_id viejo para siempre. Eso hace dos danos:
--   1. la forma se congela el ultimo dia de la temporada anterior, porque el
--      trabajador solo baja partidos de la liga asignada;
--   2. y el cerebro le aplica la FUERZA DE LIGA (phi) equivocada, que envenena
--      el calculo entero, no solo la forma.
--
-- MEDIDO: 36 de 142 equipos evaluados (25%) estaban en la division equivocada.
-- La lista es coherente uno por uno y se agrupa como un cambio de temporada:
--
--   Coventry City, Ipswich Town, Hull City .. Championship -> PREMIER LEAGUE
--   Deportivo, Racing Santander, Malaga ..... LaLiga2      -> LA LIGA
--   Schalke 04, Paderborn, Elversberg ....... 2.Bundesliga -> BUNDESLIGA
--   Frosinone, Venezia ...................... Serie B      -> SERIE A
--   Le Mans, Troyes ......................... Ligue 2      -> LIGUE 1
--   Amed SFK, Corum FK, Erzurum BB .......... 1.Lig        -> SUPER LIG
--   Sheffield Wednesday, Oxford United ...... Championship -> LEAGUE ONE
--   Bromley, Cambridge, MK Dons, Notts Co ... League Two   -> LEAGUE ONE
--   ... y 14 mas
--
-- Deportivo vs Sevilla y Barcelona vs Racing, las dos tarjetas que se usaron
-- de ejemplo toda la sesion, se calculaban con forma que terminaba el 31 de
-- mayo Y con la fuerza de liga de la SEGUNDA division espanola.
--
-- EL ARREGLO
--   1. v2.marcar_forma_desactualizada(p_limite): devuelve a la cola a los
--      equipos cuya forma esta atras de lo que ESPN ya tiene guardado.
--      SOLO cuentan partidos de liga numerada; copa y continental no alimentan
--      la forma domestica, asi que verlos no justifica gastar una llamada.
--      Medido: la senal floja daba 28 candidatos, la estricta 6 -> 22 falsos
--      positivos evitados. Enfriamiento de 24h por equipo.
--   2. v2.reasignar_division_actual(p_desde, p_min_partidos): lee la division
--      ACTUAL del historial real de ESPN y corrige domestic_league_id.
--      No adivina. Exige un minimo de partidos vistos (3) para no reaccionar a
--      un dato suelto. Deja rastro en v2.cambio_de_division.
--   3. Prioridad nueva en la cola:
--        DOMESTIC_DIVISION_CHANGED con partido en 14 dias .. escalon 0
--        DOMESTIC_FORM_STALE con partido en 14 dias ........ escalon 1
--        DOMESTIC_DIVISION_CHANGED sin partido proximo ..... escalon 2
--      Asi un cambio de division nunca desplaza a un equipo que juega manana
--      y no tiene datos.
--   4. Crones: 'forma-desactualizada-cada-hora' (:52) y
--      'cambio-de-division-diario' (06:09).
--
-- LO QUE NO SE HACE
-- No se borra la forma vieja. Queda en la tabla y simplemente deja de usarse,
-- porque el cerebro lee por liga asignada. El historial no se destruye.
--
-- LOS QUE VAN A PERDER P_RETO, Y ESO ESTA BIEN
-- 8 de los 36 se mueven a ligas sin phi instalada (League One, Saudi Pro
-- League). Esos dejan de publicar probabilidad. Es lo correcto: mejor en
-- blanco que un numero calculado con la liga equivocada. FALLAR CERRADO.

alter table v2.soccer_coverage_job
  add column if not exists forma_refrescada_at timestamptz;

create table if not exists v2.cambio_de_division (
  id bigserial primary key,
  team_espn_id text not null,
  team_name text,
  liga_anterior integer, liga_anterior_nombre text,
  liga_nueva integer, liga_nueva_nombre text,
  partidos_vistos integer,
  evidencia text,
  detectado_at timestamptz default now()
);

-- (cuerpos completos de v2.marcar_forma_desactualizada y
--  v2.reasignar_division_actual instalados en produccion; ver el commit.)

select cron.schedule('forma-desactualizada-cada-hora', '52 * * * *',
  $$select v2.marcar_forma_desactualizada(25);$$);
select cron.schedule('cambio-de-division-diario', '9 6 * * *',
  $$select v2.reasignar_division_actual();$$);

-- ---------------------------------------------------------------------------
-- VERIFICACION AL CORRERLO
-- ---------------------------------------------------------------------------
--  reasignar_division_actual('2026-07-15', 3) -> 36 equipos reasignados
--
--  Kifisia   Super League 2 -> Super League Greece : 23 partidos, ultimo 13-sep
--  Bromley   League Two     -> League One          :  6 partidos, ultimo 12-sep
--  Cambridge League Two     -> League One          :  6 partidos, ultimo 12-sep
--
--  Antes de esto, esos equipos tenian su ultimo partido de forma en mayo.
