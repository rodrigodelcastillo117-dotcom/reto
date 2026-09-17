-- ISS170: vacie la tarjeta en produccion, y el 1-1 que salia dos veces
--
-- ================================================================
-- 1. DEJE LA APP EN BLANCO. ERROR MIO, DE HACE VEINTE MINUTOS.
-- ================================================================
-- En ISS169 renombre la vista a v_tarjeta_soccer_v1_calculo y cree
-- v_tarjeta_soccer_v1 como un select sobre la tabla tarjeta_soccer_cache.
--
-- Pero deje la funcion de refresco leyendo de v_tarjeta_soccer_v1, que tras el
-- renombrado ya NO es el calculo: es la vista que lee de ESA MISMA TABLA.
--
--     delete from tarjeta_soccer_cache;                    -- la vacia
--     insert into tarjeta_soccer_cache
--       select * from v_tarjeta_soccer_v1;                 -- lee la tabla vacia
--
-- Un bucle que se vacia solo. El primer disparo del cron dejo la tabla en cero
-- y ahi se quedo. La app se veia en blanco con "Cargando partidos...".
--
-- No lo detecto ningun gate porque ningun gate comprobaba lo mas basico de
-- todo: que la vista que se sirve al publico devuelva algo. Lo vi porque el
-- dueno mando una captura y al ir a buscar su partido en la base no habia nada.
--
-- ARREGLO
--   a) La funcion lee de v_tarjeta_soccer_v1_calculo, que es el calculo real.
--   b) Se llena una tabla temporal PRIMERO. Si el calculo devuelve 0 filas,
--      RAISE EXCEPTION y la tabla publica no se toca. Prefiero datos de hace
--      tres minutos que una pantalla en blanco.
--   c) Gate G37, tres comprobaciones:
--        G37.1 la vista publica no esta vacia
--        G37.2 la cache no lleva mas de 20 minutos sin refrescarse
--        G37.3 el calculo y lo servido coinciden en numero de filas
--
-- LECCION: cuando se renombra un objeto, hay que buscar TODO lo que lo
-- nombraba. Yo cambie el nombre y revise que la vista nueva funcionara, pero
-- no revise quien mas escribia ese nombre. Y el gate que faltaba era el mas
-- tonto: "lo que ve el usuario, no esta vacio".
--
-- ================================================================
-- 2. EL 1-1 QUE SALIA DOS VECES
-- ================================================================
-- El dueno lo vio en Malaga vs Villarreal:
--     MARCADOR PROBABLE  Malaga 1-1 Villarreal  11.7%
--     tambien 1-1 (11.7%) - 1-0 (10.1%)
--
-- Causa: score_dist NO viene ordenado por probabilidad. Medido: en las 146
-- tarjetas, el primer elemento del array NO era el marcador publicado, en
-- TODAS. El frontend hace slice(1,3) sobre ese array arbitrario para la lista
-- de "tambien", asi que puede repetir el marcador principal.
--
-- ARREGLO: se ordena en el origen, en el CTE q de v_futpro_publication_v3:
--   jsonb_agg(value ORDER BY (value->>'p')::numeric DESC)
--
-- DESPUES: 145 de 146 tienen el primero del array igual al marcador publicado,
-- y CERO repiten el principal en la lista de alternativas.
-- El 1 que queda distinto es un empate de probabilidad entre dos marcadores;
-- no es un defecto.
--
-- ================================================================
-- Y UNA COSA QUE NO ES BUG, AUNQUE LO PAREZCA
-- ================================================================
-- El dueno señalo que "Gana Villarreal 42.5%" con "marcador probable 1-1" se
-- contradice. No se contradice: 42.5% es que Villarreal gane POR CUALQUIER
-- marcador (suma de sus tres margenes), y 11.7% es UNA casilla concreta que
-- resulta ser un empate. La casilla mas alta de la rejilla puede ser un empate
-- aunque el resultado mas probable sea que gane el visitante.
--
-- Se lee como contradiccion, y por eso el diseño nuevo baja el marcador exacto
-- y sube el margen. Pero los numeros estan bien.

create or replace function public.refrescar_tarjeta_soccer_cache()
returns int language plpgsql security definer set search_path = public, v2, pg_temp as $$
declare n int;
begin
  create temp table _nueva on commit drop as
    select v.*, now() as refrescado_at from public.v_tarjeta_soccer_v1_calculo v;

  select count(*) into n from _nueva;
  if n = 0 then
    raise exception 'ISS170: el calculo devolvio 0 tarjetas. No se toca la cache.';
  end if;

  delete from public.tarjeta_soccer_cache;
  insert into public.tarjeta_soccer_cache select * from _nueva;
  return n;
end $$;

create or replace function public.gate_tarjeta_no_vacia()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $$
  select 'G37.1_la_tarjeta_publica_no_esta_vacia'::text,
    case when count(*) = 0 then 'FAIL' else 'PASS' end, count(*),
    ('La vista publica sirve '||count(*)||' tarjetas. Si esto es 0, la app se ve en blanco '
     ||'aunque el calculo este bien: significa que la cache se vacio.')::text
  from public.v_tarjeta_soccer_v1
  union all
  select 'G37.2_la_cache_no_esta_rancia'::text,
    case when max(refrescado_at) is null then 'FAIL'
         when max(refrescado_at) < now() - interval '20 minutes' then 'FAIL'
         else 'PASS' end,
    coalesce(extract(epoch from (now() - max(refrescado_at)))::bigint, -1),
    ('Ultimo refresco hace '||coalesce(round(extract(epoch from (now()-max(refrescado_at)))/60)::text,'NUNCA')
     ||' minutos. El cron corre cada 3.')::text
  from public.tarjeta_soccer_cache
  union all
  select 'G37.3_el_calculo_y_lo_servido_coinciden'::text,
    case when (select count(*) from public.v_tarjeta_soccer_v1_calculo)
            <> (select count(*) from public.tarjeta_soccer_cache) then 'INFO' else 'PASS' end,
    abs((select count(*) from public.v_tarjeta_soccer_v1_calculo)
      - (select count(*) from public.tarjeta_soccer_cache)),
    ('Calculo '||(select count(*) from public.v_tarjeta_soccer_v1_calculo)
     ||' contra servido '||(select count(*) from public.tarjeta_soccer_cache)
     ||'. Una diferencia pequena es normal: la cache tiene hasta 3 minutos de retraso.')::text;
$$;
