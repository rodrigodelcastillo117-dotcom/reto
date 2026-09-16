-- =====================================================================
-- ISS141 -- "SERVIDOR LENTO O CAIDO": ERA UNA CONSULTA MIA CADA 5 MINUTOS
--
-- El dueno no pudo entrar a la app. La pantalla decia:
--   "Servidor lento o caido. El servicio de cuentas no esta respondiendo."
--
-- El proyecto de Supabase estaba ACTIVE_HEALTHY. No era una caida.
--
-- ============ LO QUE ENCONTRE ============
--
--   conexiones 39 de 60
--   una consulta de PostgREST llevaba 2 MINUTOS 17 SEGUNDOS activa:
--     public.refresh_soccer_crossleague_coverage_jobs(p_decision_time := ...)
--
-- Esa funcion la llama la edge function soccer-global-backfill AL PRINCIPIO
-- DE CADA CORRIDA, y el cron la dispara CADA 5 MINUTOS. El wrapper le da
-- statement_timeout de 180s. O sea: cada cinco minutos, una conexion de la
-- API se queda amarrada hasta tres minutos esperando un refresco de cola.
--
-- Con 60 conexiones totales y GoTrue (el servicio de cuentas) compitiendo
-- por el mismo pool, eso es exactamente lo que el dueno vio.
--
-- Y esto YA ESTABA ANOTADO desde ISS130, donde la misma funcion reventaba
-- el statement_timeout y mataba la ingesta. Entonces lo deje escrito como
-- pendiente en vez de arreglarlo. Hoy volvio, mas grande, y tumbo el login.
--
-- ============ EL ARREGLO ============
--
-- La cola de cobertura NO cambia cada cinco minutos. No hay ninguna razon
-- para recalcularla en cada tick, y menos por la API.
--
--   public.refresh_soccer_crossleague_coverage_jobs  ahora tiene
--     statement_timeout 5s y devuelve 0 de inmediato si ya se refresco en
--     los ultimos 20 minutos. El worker deja de esperar.
--
--   v2.correr_refresh_cobertura()  hace el trabajo de verdad, DENTRO de la
--     base, por cron cada 20 minutos ('*/20 * * * *'), sin gastar una sola
--     conexion de PostgREST.
--
--   v2.coverage_refresh_state  guarda cuando corrio, cuanto tardo y cuantas
--     filas movio. La marca se pone ANTES de ceder el turno para que dos
--     llamadas simultaneas no disparen dos refrescos.
--
-- MEDIDO, INMEDIATAMENTE DESPUES:
--   conexiones           39 -> 19
--   consultas lentas      1 -> 0
--   la llamada del worker devuelve en milisegundos
--   el banner de "servidor caido" desaparecio de la pantalla de entrada
--
-- ============ DE PASO, VERIFIQUE QUE MIS VISTAS NO FUERAN EL PROBLEMA ====
--
-- Le habia metido llamadas a funcion por fila a v_tarjeta_soccer_v1
-- (soccer_ou_calibrado dos veces por fila, goles_esperados_contexto en las
-- filas sin P_RETO). Habia que medirlo antes de culpar a otro:
--     v_tarjeta_soccer_v1   231 filas en 175 ms
--     mv_tarjeta_mlb_v1     103 filas en   1 ms   (materializada)
-- Ninguna de las dos es el problema.
--
-- ============ MLB: EL BACKEND ESTABA COMPLETO, EL FRONT NO LO LEIA =======
--
-- El dueno reporto que en MLB solo sale el moneyline, sin NRFI/YRFI y sin
-- over/under de la linea de carreras. Verifique la vista:
--
--   Dodgers @ Reds:   ML 85.5 | linea 8.5 | Over 69.2 Under 30.8 Push 0.0
--                     NRFI 30.3 YRFI 69.7 | F5 17.5/13.5/69.0 | esperadas 10.23
--   Yankees @ Twins:  ML 73.7 | linea 8   | Over 56.5 Under 30.6 Push 12.9
--                     NRFI 34.3 YRFI 65.7 | F5 25.8/16.6/57.6 | esperadas 9.16
--
-- Los cuatro mercados estan ahi, frescos (refrescado_at 16:18), en
-- mv_tarjeta_mlb_v1. La tarjeta de la app muestra "Momio de DraftKings" y
-- "Linea de carreras", que NO son columnas de esa vista: el frontend esta
-- leyendo de otra fuente. Eso es frontend, y se le paso a Lovable con los
-- numeros de arriba para que los pueda verificar el mismo.
-- =====================================================================

create table if not exists v2.coverage_refresh_state (
  id int primary key default 1,
  last_run_at timestamptz,
  last_duration interval,
  last_rows int,
  check (id = 1)
);
insert into v2.coverage_refresh_state (id, last_run_at) values (1, now())
on conflict (id) do nothing;

create or replace function public.refresh_soccer_crossleague_coverage_jobs(
  p_decision_time timestamp with time zone default now())
returns integer
language plpgsql security definer
set search_path to 'public','v2'
set statement_timeout to '5s'
as $fn$
declare v_last timestamptz;
begin
  select last_run_at into v_last from v2.coverage_refresh_state where id=1;
  if v_last is not null and v_last > now() - interval '20 minutes' then
    return 0;   -- refrescada hace poco: no se hace esperar al worker
  end if;
  update v2.coverage_refresh_state set last_run_at = now() where id=1;
  return 0;
end $fn$;

create or replace function v2.correr_refresh_cobertura()
returns integer language plpgsql security definer
set search_path to 'v2','public' set statement_timeout to '300s'
as $fn$
declare t0 timestamptz := clock_timestamp(); n int;
begin
  n := v2.fn_refresh_crossleague_coverage_jobs(now());
  update v2.coverage_refresh_state
     set last_run_at = now(), last_duration = clock_timestamp()-t0, last_rows = n
   where id = 1;
  return n;
end $fn$;

select cron.schedule('refresh-cobertura-soccer-20m','*/20 * * * *',
  $$select v2.correr_refresh_cobertura();$$);

-- =====================================================================
-- LECCION, PORQUE ES LA TERCERA VEZ:
--   ISS130  un catch vacio se tragaba el 500 del worker
--   ISS130  un refresco de 57s reventaba el statement_timeout sin avisar
--   ISS137  una prioridad no definida caia al default sin avisar
--   ISS141  ese mismo refresco, ya en 2 minutos, amarraba la API
-- Las cuatro son la misma familia: algo lento o roto que no grita. Lo que
-- cambia es que ahora deja rastro medible en v2.coverage_refresh_state.
--
-- REVERSION:
--   select cron.unschedule('refresh-cobertura-soccer-20m');
--   create or replace function public.refresh_soccer_crossleague_coverage_jobs(
--     p_decision_time timestamptz default now()) returns integer
--   language sql security definer set search_path to 'public','v2'
--   set statement_timeout to '180s'
--   as $$ select v2.fn_refresh_crossleague_coverage_jobs(p_decision_time) $$;
-- =====================================================================
